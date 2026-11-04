import XCTest
@testable import Tapll

/// Feature flags (ADR 0006): the port must agree with the contract's vectors bucket for bucket, a
/// failed fetch keeps what the device had, and a flag read in every frame is one exposure per session.
final class FlagTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Context: Decodable {
            var bucketId: String?
            var platform: String
            var appVersion: String?
            var locale: String?
            var traits: [String: String]?
        }
        struct Expected: Decodable { var variant: String; var reason: String }
        struct Case: Decodable { var flag: String; var context: Context; var bucket: Int?; var expected: Expected }
        struct Hash: Decodable { var input: String; var fnv1a32: UInt32 }
        var definitions: [String: FlagDefinition]
        var cases: [Case]
        var hashes: [Hash]
    }

    private func vectors() throws -> Vectors {
        let url = Bundle.module.url(forResource: "flag-vectors.v1", withExtension: "json", subdirectory: "Fixtures")!
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    func testPortAgreesWithTheContractVectors() throws {
        let v = try vectors()
        for h in v.hashes { XCTAssertEqual(FlagEvaluator.fnv1a32(h.input), h.fnv1a32, "fnv1a32(\(h.input))") }
        XCTAssertGreaterThan(v.cases.count, 10)
        for c in v.cases {
            let def = try XCTUnwrap(v.definitions[c.flag])
            let ctx = FlagContext(bucketId: c.context.bucketId, platform: c.context.platform, appVersion: c.context.appVersion,
                                  locale: c.context.locale, traits: c.context.traits ?? [:])
            if let id = c.context.bucketId { XCTAssertEqual(FlagEvaluator.bucket(salt: def.salt, bucketId: id), c.bucket, "bucket of \(id)") }
            let got = FlagEvaluator.evaluate(def, ctx)
            XCTAssertEqual(got.variant, c.expected.variant, "\(c.flag) for \(c.context)")
            XCTAssertEqual(got.reason.rawValue, c.expected.reason, "\(c.flag) for \(c.context)")
        }
    }

    private final class StubFlags: FlagTransport, @unchecked Sendable {
        var answers: [FlagFetchResult]
        private(set) var etags: [String?] = []
        init(_ answers: [FlagFetchResult]) { self.answers = answers }
        func fetch(writeKey: String, environment: Environment, etag: String?) async -> FlagFetchResult {
            etags.append(etag)
            return answers.isEmpty ? .failed("no answer") : answers.removeFirst()
        }
    }

    private func ruleset(_ version: String, on: Int) -> FlagRuleset {
        FlagRuleset(version: version, flags: [
            "new_paywall": FlagDefinition(kind: "boolean", variants: ["off", "on"], salt: "s", enabled: true, defaultVariant: "off", rules: [],
                                          rollout: [FlagSlice(variant: "off", weight: 10_000 - on), FlagSlice(variant: "on", weight: on)]),
        ])
    }

    func testKeepsTheRulesetOnFailureAndSendsItsVersionBack() async {
        let stub = StubFlags([.ruleset(ruleset("v1", on: 10_000)), .failed("offline"), .notModified])
        let flags = FlagController(writeKey: "k", environment: .production, transport: stub, directoryName: nil, logger: SDKLogger(level: .none, handler: nil))
        XCTAssertNil(flags.evaluate("new_paywall", context: FlagContext(bucketId: "a")), "no ruleset yet: the coded default stands")
        await flags.refresh(force: true)
        XCTAssertEqual(flags.evaluate("new_paywall", context: FlagContext(bucketId: "a"))?.variant, "on")
        await flags.refresh(force: true)
        XCTAssertEqual(flags.current.version, "v1", "a failed fetch keeps what the device had")
        await flags.refresh(force: true)
        XCTAssertEqual(stub.etags, [nil, "v1", "v1"])
    }

    func testRefetchesOnlyAfterTheInterval() async {
        let stub = StubFlags([.ruleset(ruleset("v1", on: 0)), .notModified, .notModified])
        let flags = FlagController(writeKey: "k", environment: .production, transport: stub, directoryName: nil, logger: SDKLogger(level: .none, handler: nil))
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        await flags.refresh(now: t0)
        await flags.refresh(now: t0.addingTimeInterval(60))
        XCTAssertEqual(stub.etags.count, 1, "a return to the app inside 5 minutes does not fetch")
        await flags.refresh(now: t0.addingTimeInterval(FlagController.refetchInterval + 1))
        XCTAssertEqual(stub.etags.count, 2)
    }

    func testPersistsTheRulesetForTheNextLaunch() async throws {
        let dir = "flags-test-\(UUID().uuidString)"
        let first = FlagController(writeKey: "k", environment: .production, transport: StubFlags([.ruleset(ruleset("v2", on: 10_000))]),
                                   directoryName: dir, logger: SDKLogger(level: .none, handler: nil))
        await first.refresh(force: true)
        let second = FlagController(writeKey: "k", environment: .production, transport: StubFlags([]), directoryName: dir, logger: SDKLogger(level: .none, handler: nil))
        XCTAssertEqual(second.current.version, "v2", "read from disk before any fetch")
        if let url = FlagController.fileURL(directoryName: dir) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    func testStrictAnonymousGetsTheDefaultOnASplit() {
        let def = ruleset("v", on: 5_000).flags["new_paywall"]!
        XCTAssertEqual(FlagEvaluator.evaluate(def, FlagContext(bucketId: nil)), FlagEvaluation(variant: "off", reason: .default))
    }

    func testOneExposurePerSessionPerFlagAndTheBatchConformsToSchema() async throws {
        let transport = StubTransport()
        let p = Fixtures.pipeline(transport: transport)
        await p.start(hadPersistentIdentity: false)
        for _ in 0..<5 { await p.flagExposure(flag: "new_paywall", variant: "on", reason: .rollout) }
        await p.flagExposure(flag: "layout", variant: "grid", reason: .rule)
        await p.flush()
        let exposures = transport.sent.flatMap(\.events).filter { $0.name == "$flag_exposure" }
        XCTAssertEqual(exposures.count, 2)
        XCTAssertEqual(exposures.first?.properties?["variant"], .string("on"))
        let validator = try MiniSchemaValidator(schema: Fixtures.schemaData())
        for batch in transport.sent {
            let errors = try validator.validate(WireCoding.encoder.encode(batch))
            XCTAssertEqual(errors, [], errors.joined(separator: "\n"))
        }
    }

    func testAFlagReadWithoutConfigureIsTheCodedDefault() {
        Tapll.resetForTesting()
        let flag = Tapll.flag("anything")
        XCTAssertNil(flag.variant)
        XCTAssertFalse(flag.isEnabled)
        XCTAssertEqual(flag.value(default: "control"), "control")
    }
}
