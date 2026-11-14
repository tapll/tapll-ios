import XCTest
@testable import Tapll

final class RetentionTests: XCTestCase {
    private struct FixedClock: Clock { var now: Date }

    func testRetentionEventsCarryIdsOnlyAndConformToSchema() async throws {
        let transport = StubTransport()
        let p = Fixtures.pipeline(transport: transport)
        await p.reviewRequested(source: "task_completed")
        await p.notificationPermission(status: .granted, prompted: true)
        await p.notificationOpened(kind: "due", action: "open")
        await p.flush()

        let events = transport.sent.flatMap(\.events).filter { $0.name.hasPrefix("$review") || $0.name.hasPrefix("$notification") }
        XCTAssertEqual(events.map(\.name), ["$review_requested", "$notification_permission", "$notification_opened"])
        XCTAssertEqual(events[0].properties, ["source": "task_completed"])
        XCTAssertEqual(events[1].properties, ["status": "granted", "prompted": true])
        XCTAssertEqual(events[2].properties, ["kind": "due", "action": "open"])

        let validator = try MiniSchemaValidator(schema: Fixtures.schemaData())
        for batch in transport.sent {
            let errors = try validator.validate(WireCoding.encoder.encode(batch))
            XCTAssertEqual(errors, [], errors.joined(separator: "\n"))
        }
    }

    func testPermissionIsSentOnlyWhenItChanges() async {
        let transport = StubTransport()
        let kv = InMemoryKeyValueStore()
        let p = Fixtures.pipeline(transport: transport, kv: kv)
        await p.notificationPermission(status: .notDetermined, prompted: false)
        await p.notificationPermission(status: .notDetermined, prompted: false)
        await p.notificationPermission(status: .granted, prompted: true)
        await p.notificationPermission(status: .granted, prompted: false)
        await p.flush()
        // A relaunch remembers the last status it sent.
        let relaunched = Fixtures.pipeline(transport: transport, kv: kv)
        await relaunched.notificationPermission(status: .granted, prompted: false)
        await relaunched.flush()

        let statuses = transport.sent.flatMap(\.events)
            .filter { $0.name == "$notification_permission" }
            .compactMap { $0.properties?["status"] }
        XCTAssertEqual(statuses, ["not_determined", "granted"])
    }

    func testFreeTextIsDroppedRatherThanSent() async {
        let transport = StubTransport()
        let p = Fixtures.pipeline(transport: transport)
        await p.notificationOpened(kind: "Buy milk at 5pm", action: "open")
        await p.reviewRequested(source: "Settings Screen")
        await p.flush()
        let names = transport.sent.flatMap(\.events).map(\.name)
        XCTAssertFalse(names.contains("$notification_opened"))
        XCTAssertFalse(names.contains("$review_requested"))
    }

    func testOptOutForgetsTheLastPermissionSoOptInReportsItAgain() async {
        let transport = StubTransport()
        let p = Fixtures.pipeline(transport: transport)
        await p.notificationPermission(status: .denied, prompted: true)
        await p.optOut()
        await p.optIn()
        await p.notificationPermission(status: .denied, prompted: false)
        await p.flush()
        let sent = transport.sent.flatMap(\.events).filter { $0.name == "$notification_permission" }
        XCTAssertEqual(sent.count, 1, "the event queued before opt-out was wiped; the one after opt-in is sent")
        XCTAssertEqual(sent.first?.properties?["prompted"], false)
    }

    func testReviewPolicyWaitsForSuccessesAndDaysAndAsksOncePerVersion() {
        let kv = InMemoryKeyValueStore()
        let start = Date(timeIntervalSince1970: 1_000_000)
        func policy(at date: Date, version: String = "1.0") -> ReviewPolicy {
            ReviewPolicy(minSuccesses: 3, minDaysSinceFirstUse: 1, store: kv, clock: FixedClock(now: date), appVersion: version)
        }
        let day0 = policy(at: start)
        for _ in 0..<3 { day0.recordSuccess() }
        XCTAssertFalse(day0.shouldAsk, "enough successes, but not a day of use yet")

        let day1 = policy(at: start.addingTimeInterval(86_400))
        XCTAssertTrue(day1.shouldAsk)
        day1.markAsked()
        XCTAssertFalse(day1.shouldAsk)
        for _ in 0..<5 { day1.recordSuccess() }
        XCTAssertFalse(day1.shouldAsk, "once per version")

        let nextVersion = policy(at: start.addingTimeInterval(2 * 86_400), version: "1.1")
        XCTAssertTrue(nextVersion.shouldAsk, "successes after the last ask count toward the next version")
    }
}
