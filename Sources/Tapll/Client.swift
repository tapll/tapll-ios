import Foundation

/// Wires real dependencies together. One instance per `configure`.
final class Client: Sendable {
    let pipeline: EventPipeline
    let logger: SDKLogger
    /// Held so `Tapll.installId` can read the id without hopping onto the pipeline
    /// actor: the facade is synchronous everywhere else, and an `async` getter here
    /// would be the only call a caller has to await. The coordinator caches, so repeated
    /// reads cost nothing after the first — it used to go to the Keychain every time.
    let identity: IdentityCoordinator
    /// `nil` when `Options.crashReporting` is off — nothing is installed then, not even the directory.
    let crash: CrashReporter?
    /// Feature flags (ADR 0006): the stored ruleset and synchronous evaluation over it.
    let flags: FlagController
    /// App version and locale for flag rules; fixed for the process, like the batch's device block.
    let flagDevice: (appVersion: String, locale: String)
    #if canImport(UIKit) && !os(watchOS)
    @MainActor private var lifecycle: AppLifecycleObserver?
    #endif

    init(writeKey: String, privacyMode: PrivacyMode, options: Options, wrapper: String? = nil) {
        logger = SDKLogger(level: options.logLevel, handler: options.logHandler)
        let device = DeviceContextProvider.current(wrapper: wrapper)
        let environment = options.environment ?? EnvironmentDetector.detect()
        // Deterministic: Swift's `hashValue` is seeded per process, which would give every launch a new queue directory.
        let keyHash = Client.stableHash(writeKey)
        // Before any store opens: carries the 0.4.x (Union) queue, crash reports and defaults over.
        LegacyMigration.migrateDefaults()
        LegacyMigration.migrateSupportDirectory()
        let store: EventStore = (try? FileEventStore(directoryName: keyHash)) ?? InMemoryEventStore()
        let identityStore: IdentityStore
        #if canImport(Security)
        identityStore = privacyMode == .strictAnonymous ? NoopIdentityStore() : KeychainIdentityStore()
        #else
        identityStore = privacyMode == .strictAnonymous ? NoopIdentityStore() : InMemoryIdentityStore()
        #endif
        // Constructed, not read. The Keychain is touched by whoever asks first, which is the pipeline
        // actor unless the app reads `Tapll.installId` before it gets there.
        let identity = IdentityCoordinator(store: identityStore, privacyMode: privacyMode)
        self.identity = identity
        pipeline = EventPipeline(
            config: PipelineConfig(writeKey: writeKey, environment: environment, privacyMode: privacyMode, flushAt: options.flushAt, flushInterval: options.flushInterval, maxQueuedEvents: options.maxQueuedEvents, analyticsCollectionEnabled: options.startsCollecting),
            store: store,
            transport: URLSessionTransport(endpoint: options.endpoint, userAgent: SDKInfo.userAgent(wrapper: wrapper)),
            identity: identity,
            kv: UserDefaultsStore(),
            clock: SystemClock(),
            logger: logger,
            device: device
        )
        /*
         * Crash reporting is installed before the first event is pushed, because the window it cannot
         * cover is the window before it exists — and a crash during launch is the crash a developer
         * most wants and least often gets.
         */
        let reporter = options.crashReporting
            ? Client.makeCrashReporter(writeKey: writeKey, keyHash: keyHash, environment: environment,
                                       privacyMode: privacyMode, options: options, device: device,
                                       userAgent: SDKInfo.userAgent(wrapper: wrapper),
                                       identityStore: identityStore, logger: logger)
            : nil
        crash = reporter
        let flags = FlagController(
            writeKey: writeKey,
            environment: environment,
            transport: URLSessionFlagTransport(endpoint: options.flagsEndpoint ?? URLSessionFlagTransport.endpoint(from: options.endpoint),
                                               userAgent: SDKInfo.userAgent(wrapper: wrapper)),
            directoryName: keyHash,
            logger: logger
        )
        self.flags = flags
        flagDevice = (device.appVersion, device.locale)
        logger.log(.info, "configured · env=\(environment.rawValue) · privacy=\(privacyMode.rawValue) · sdk=\(SDKInfo.version)\(wrapper.map { " wrapper=\($0)" } ?? "") · crashes=\(options.crashReporting ? "on" : "off")")
        let p = pipeline
        // The synchronous guess above can be wrong, and with one write key for every build nothing
        // downstream refuses it. StoreKit's signed answer replaces it when it comes; an explicit
        // `Options.environment` is the developer's word and is never second-guessed.
        if options.environment == nil {
            let log = logger
            let initial = environment
            Task {
                guard let refined = await EnvironmentDetector.refined(), refined != initial else { return }
                await p.setEnvironment(refined)
                reporter?.setEnvironment(refined)
                flags.setEnvironment(refined)
                await flags.refresh(force: true)
                log.log(.info, "environment · \(initial.rawValue) → \(refined.rawValue) (StoreKit AppTransaction)")
            }
        }
        Task { await flags.refresh(force: true) }
        if let reporter {
            reporter.start(sessionId: nil)
            Task {
                await p.attach(crash: reporter)
                await p.start()
            }
        } else {
            Task { await p.start() }
        }
        #if canImport(UIKit) && !os(watchOS)
        let auto = options.automaticScreenTracking
        Task { @MainActor in
            self.lifecycle = AppLifecycleObserver(pipeline: p, crash: reporter, flags: flags)
            if auto { AutomaticScreenTracking.install() }
        }
        #endif
    }

    /// The device as flag rules see it: the bucket id is the account after identify, else the install.
    func flagContext() -> FlagContext {
        let id = identity.ensure(now: Date())
        return FlagContext(bucketId: id.userId ?? id.installId, platform: "ios", appVersion: flagDevice.appVersion,
                           locale: flagDevice.locale, traits: id.traits ?? [:])
    }

    func shutdown() {
        crash?.stop()
        let p = pipeline
        Task { await p.shutdown() }
    }

    private static func makeCrashReporter(writeKey: String,
                                          keyHash: String,
                                          environment: Environment,
                                          privacyMode: PrivacyMode,
                                          options: Options,
                                          device: DeviceContext,
                                          userAgent: String,
                                          identityStore: IdentityStore,
                                          logger: SDKLogger) -> CrashReporter? {
        guard let store = try? CrashStore.standard(directoryName: keyHash) else {
            // No directory means no descriptor for the handler to write to, so there is nothing to
            // install. Said out loud rather than left as a reporter that silently reports nothing.
            logger.log(.warning, "crash: could not create the crash directory — crash reporting is off")
            return nil
        }
        let endpoint = options.crashEndpoint ?? URLSessionCrashTransport.endpoint(from: options.endpoint)
        return CrashReporter(
            config: CrashReporter.Config(writeKey: writeKey, environment: environment,
                                         privacyMode: privacyMode, hangThreshold: options.hangThreshold,
                                         detectHangs: options.hangDetection,
                                         maxStored: options.maxStoredCrashReports),
            store: store,
            transport: URLSessionCrashTransport(endpoint: endpoint, userAgent: userAgent),
            identityStore: identityStore,
            device: device,
            logger: logger,
            clock: SystemClock()
        )
    }

    /// FNV-1a 64-bit, base-36. Stable across launches and OS versions; only used to name the on-disk queue directory.
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 36)
    }
}
