import Foundation

/// What a flags fetch got back.
enum FlagFetchResult: Sendable, Equatable {
    /// The ruleset the device already holds is current (304).
    case notModified
    case ruleset(FlagRuleset)
    /// Anything else: kept the previous ruleset. The reason is for the log.
    case failed(String)
}

protocol FlagTransport: Sendable {
    func fetch(writeKey: String, environment: Environment, etag: String?) async -> FlagFetchResult
}

/// `GET /v1/flags`, derived from the batch endpoint like the crash upload (`/v1/batch` → `/v1/flags`).
struct URLSessionFlagTransport: FlagTransport {
    let endpoint: URL
    let userAgent: String
    let session: URLSession

    init(endpoint: URL, userAgent: String) {
        self.endpoint = endpoint
        self.userAgent = userAgent
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    static func endpoint(from batchEndpoint: URL) -> URL {
        batchEndpoint.deletingLastPathComponent().appendingPathComponent("flags")
    }

    func fetch(writeKey: String, environment: Environment, etag: String?) async -> FlagFetchResult {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "environment", value: environment.rawValue)]
        guard let url = components?.url else { return .failed("bad flags endpoint") }
        var req = URLRequest(url: url)
        req.setValue(writeKey, forHTTPHeaderField: "x-tapll-key")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let etag { req.setValue("\"\(etag)\"", forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 304 { return .notModified }
            guard status == 200 else { return .failed("HTTP \(status)") }
            return .ruleset(try JSONDecoder().decode(FlagRuleset.self, from: data))
        } catch {
            return .failed(String(describing: error))
        }
    }
}

/**
 * The device's flags (ADR 0006): the last ruleset the server sent, on disk next to the event queue,
 * and synchronous evaluation over it.
 *
 * Reads never wait for the network and never throw. Before the first fetch — and offline — a flag
 * the ruleset does not hold answers the default coded in the app. A fetch that fails keeps what the
 * device had: a phone in a tunnel must not lose a rollout it already got.
 */
final class FlagController: @unchecked Sendable {
    /// How often a return to the app may fetch again. Start always fetches.
    static let refetchInterval: TimeInterval = 300

    private let writeKey: String
    private let transport: FlagTransport
    private let file: URL?
    private let logger: SDKLogger
    private let lock = NSLock()
    private var ruleset: FlagRuleset
    private var environment: Environment
    private var lastFetch: Date?
    private var fetching = false
    private var handlers: [@Sendable () -> Void] = []

    init(writeKey: String, environment: Environment, transport: FlagTransport, directoryName: String?, logger: SDKLogger) {
        self.writeKey = writeKey
        self.environment = environment
        self.transport = transport
        self.logger = logger
        file = directoryName.flatMap(FlagController.fileURL(directoryName:))
        if let file, let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(FlagRuleset.self, from: data) {
            ruleset = stored
        } else {
            ruleset = .empty
        }
    }

    /// `Application Support/Tapll/<keyHash>/flags.json`, beside `queue.ndjson`, excluded from backup:
    /// restoring a ruleset onto a new phone would serve a rollout the server no longer has.
    static func fileURL(directoryName: String) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        var dir = base.appendingPathComponent("Tapll", isDirectory: true).appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir.appendingPathComponent("flags.json")
    }

    func setEnvironment(_ env: Environment) {
        lock.lock(); defer { lock.unlock() }
        guard env != environment else { return }
        environment = env
        // Another environment has another ruleset: the stored one no longer describes this build.
        lastFetch = nil
        ruleset = .empty
    }

    var current: FlagRuleset {
        lock.lock(); defer { lock.unlock() }
        return ruleset
    }

    /// `nil` = the ruleset holds no such flag, so the app's coded default stands and nothing is exposed.
    func evaluate(_ key: String, context: FlagContext) -> FlagEvaluation? {
        let def: FlagDefinition? = { lock.lock(); defer { lock.unlock() }; return ruleset.flags[key] }()
        return def.map { FlagEvaluator.evaluate($0, context) }
    }

    func onChange(_ handler: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        handlers.append(handler)
    }

    /// Fetches unless one is in flight or, without `force`, the last one is younger than the interval.
    func refresh(force: Bool = false, now: Date = Date()) async {
        guard let (env, etag) = beginFetch(force: force, now: now) else { return }
        let result = await transport.fetch(writeKey: writeKey, environment: env, etag: etag)
        let (changed, snapshot, toNotify) = finishFetch(result, now: now)
        guard changed else { return }
        if let file, let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
        logger.log(.debug, "flags: ruleset \(snapshot.version) · \(snapshot.flags.count) flag(s)")
        for h in toNotify { h() }
    }

    /// The locked half before the request: claims the fetch and reads what to send.
    private func beginFetch(force: Bool, now: Date) -> (Environment, String?)? {
        lock.lock(); defer { lock.unlock() }
        let due = force || lastFetch.map { now.timeIntervalSince($0) >= FlagController.refetchInterval } ?? true
        guard !fetching, due else { return nil }
        fetching = true
        return (environment, ruleset.version == FlagRuleset.empty.version ? nil : ruleset.version)
    }

    /// The locked half after it: applies the answer, and says whether anything changed.
    private func finishFetch(_ result: FlagFetchResult, now: Date) -> (Bool, FlagRuleset, [@Sendable () -> Void]) {
        lock.lock(); defer { lock.unlock() }
        fetching = false
        switch result {
        case .notModified:
            lastFetch = now
            return (false, ruleset, [])
        case .ruleset(let next):
            lastFetch = now
            let changed = next != ruleset
            ruleset = next
            return (changed, next, changed ? handlers : [])
        case .failed(let reason):
            logger.log(.debug, "flags: fetch failed, keeping the previous ruleset (\(reason))")
            return (false, ruleset, [])
        }
    }
}
