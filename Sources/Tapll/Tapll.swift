import Foundation

/// Tapll iOS SDK — public facade. All calls are synchronous, thread-safe and never throw or crash the host app;
/// invalid input is logged and dropped. Configure once, as early as possible in app launch.
///
/// ```swift
/// Tapll.configure(writeKey: "av_…", privacyMode: .productAnalytics)
/// Tapll.track("workout_started", properties: ["plan": "strength", "minutes": 30], role: .start)
///
/// let checkout = Tapll.feature("checkout")      // declares the feature; the server creates it
/// checkout.start("checkout_started")
/// checkout.success("order_placed")
/// ```
public enum Tapll {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var client: Client?
    /// `<name>/<version>` from `setWrapper`, read by `configure` under `lock`.
    nonisolated(unsafe) private static var wrapper: String?

    private static var shared: Client? {
        lock.lock(); defer { lock.unlock() }
        return client
    }

    /// Creates the SDK. Calling twice replaces the previous client (useful in tests / logout flows).
    public static func configure(writeKey: String, privacyMode: PrivacyMode, options: Options = Options()) {
        lock.lock()
        client?.shutdown()
        client = Client(writeKey: writeKey, privacyMode: privacyMode, options: options, wrapper: wrapper)
        lock.unlock()
    }

    /// Wrapper bridge, see `Sources/Tapll/Wrapper.swift`. Lives here only because the state is private.
    static func registerWrapper(name: String, version: String) {
        lock.lock(); defer { lock.unlock() }
        if let client {
            client.logger.log(.warning, "setWrapper(\(name)/\(version)) ignored: it must be called before configure")
            return
        }
        guard let value = WrapperInfo.value(name: name, version: version) else {
            SDKLogger(level: .warning, handler: nil).log(.warning, "setWrapper ignored: \"\(name)\"/\"\(version)\" is not a valid <name>/<version> of at most \(WrapperInfo.maxLength) characters")
            return
        }
        wrapper = value
    }

    /// Test hook: shuts the client down and forgets a registered wrapper, so suites that touch the
    /// facade do not leak into each other.
    static func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        client?.shutdown()
        client = nil
        wrapper = nil
    }

    static var currentClient: Client? { shared }

    static var registeredWrapper: String? {
        lock.lock(); defer { lock.unlock() }
        return wrapper
    }

    /// Custom event. `name` must be lowercase snake_case (`workout_started`); `$`-prefixed names are reserved.
    /// `feature` + `role` declare the event's place in a feature — see `Tapll.feature(_:)` for the typed form.
    public static func track(_ name: String, properties: [String: PropertyValue] = [:], feature: String? = nil, role: FeatureRole? = nil, screen: String? = nil) {
        guard let p = shared?.pipeline else { return }
        Task { await p.track(name: name, properties: properties, feature: feature, role: role, screen: screen) }
    }

    /// Manual `$screen_view`. Use `.trackScreen(_:)` in SwiftUI or `Options.automaticScreenTracking` in UIKit.
    /// With `feature`, the view is that feature's discovery step.
    public static func screen(_ name: String, properties: [String: PropertyValue] = [:], feature: String? = nil) {
        guard let p = shared?.pipeline else { return }
        Task { await p.screen(name: name, properties: properties, feature: feature) }
    }

    /// A feature flag as this device sees it now (ADR 0006): `Tapll.flag("new_paywall").isEnabled`.
    ///
    /// Synchronous, never throws, never waits for the network: it evaluates the ruleset the device
    /// last fetched. Without one — before the first fetch, offline on a first launch, a key the
    /// project does not have — `variant` is `nil` and your coded default applies. The first read of
    /// each flag in a session sends one `$flag_exposure`, which is what the panel's results follow.
    public static func flag(_ key: String) -> Flag {
        guard let client = shared else { return Flag(key: key, evaluation: nil) }
        let evaluation = client.flags.evaluate(key, context: client.flagContext())
        if let evaluation {
            let p = client.pipeline
            Task { await p.flagExposure(flag: key, variant: evaluation.variant, reason: evaluation.reason) }
        }
        return Flag(key: key, evaluation: evaluation)
    }

    /// Fetches the project's flags now, ignoring the 5-minute interval. `configure` and every
    /// return to the app already fetch; call this only after something the app knows changed them.
    public static func refreshFlags() async {
        await shared?.flags.refresh(force: true)
    }

    /// Called (on an arbitrary thread) when a fetch brought a different ruleset. Re-read the flags you show.
    public static func onFlagsChanged(_ handler: @escaping @Sendable () -> Void) {
        shared?.flags.onChange(handler)
    }

    /// A typed handle for one feature: `Tapll.feature("checkout").success("order_placed")`. The key is
    /// validated here so a bad one is logged once, not on every event; events through a bad handle are
    /// dropped (see `Feature`).
    public static func feature(_ key: String) -> Feature {
        if let client = shared {
            do { try Validation.validate(featureKey: key) } catch {
                client.logger.log(.warning, "feature handle \"\(key)\" will drop its events: \(error)")
            }
        }
        return Feature(key: key)
    }

    /// Attach your own user id after login, optionally with traits describing the person —
    /// `name`, `email`, `plan`. The panel shows them instead of a raw id, and they are merged
    /// key by key across calls, so `identify(userId:traits:["plan": "pro"])` later does not erase
    /// an email sent earlier. Up to 8 traits, values ≤ 256 characters.
    ///
    /// Traits are stored as sent. An app that puts an email or a name here is collecting that data
    /// and has to say so in its own App Privacy answers — the SDK cannot declare it for you.
    /// Ignored (with a warning) in `strictAnonymous`.
    public static func identify(userId: String, traits: [String: String] = [:]) {
        guard let p = shared?.pipeline else { return }
        Task { await p.identify(userId: userId, traits: traits) }
    }

    /// Logout: forgets the user id and starts a new session. The install id is kept. Safe to call when nobody is
    /// signed in — it does nothing then, so a cold launch that resets before auth restores keeps one session.
    public static func reset() {
        guard let p = shared?.pipeline else { return }
        Task { await p.reset() }
    }

    /// Enables or disables product analytics while leaving crash and hang reporting active.
    /// Use `optOut()` when the user wants all Tapll collection, including diagnostics, disabled.
    public static func setAnalyticsCollectionEnabled(_ enabled: Bool) {
        guard let p = shared?.pipeline else { return }
        Task { await p.setAnalyticsCollectionEnabled(enabled) }
    }

    /// Stops collection and wipes all locally stored data. Persists across launches until `optIn()`.
    public static func optOut() {
        guard let p = shared?.pipeline else { return }
        Task { await p.optOut() }
    }

    public static func optIn() {
        guard let p = shared?.pipeline else { return }
        Task { await p.optIn() }
    }

    /// Today equivalent to `optOut()`. Server-side deletion of already-ingested data is requested from the panel
    /// (Settings → Privacy) until a public deletion API ships.
    public static func requestDataDeletion() { optOut() }

    /// Records `$deep_link { url_scheme, host, path }`. Query strings are never sent.
    public static func handleDeepLink(_ url: URL) {
        guard let p = shared?.pipeline else { return }
        Task { await p.deepLink(url) }
    }

    // MARK: - Crashes

    /**
     * An error the app caught and wants counted anyway.
     *
     * Reported as a `nonfatal`, which is a **separate severity** and never added to the crash count:
     * a caught error and a terminated process are two different facts about the app, and one number
     * over both would describe neither. It counts toward nothing that carries the word "crash-free".
     *
     * The stack is the caller's, taken here. Write it where the error was handled, not in a shared
     * logging helper — a helper's stack groups every unrelated error into one issue.
     */
    public static func recordError(_ type: String, reason: String? = nil) {
        shared?.crash?.recordError(type: type, reason: reason)
    }

    /// The same for a Swift `Error`. The type name is the group; `localizedDescription` is the sample
    /// message, and like every app-authored string it may carry personal data the app chose to put
    /// there.
    public static func recordError(_ error: Error) {
        shared?.crash?.recordError(type: String(describing: Swift.type(of: error)),
                                   reason: error.localizedDescription)
    }

    /**
     * A label attached to every crash report from now on — Crashlytics' "custom keys".
     *
     * Up to 8 keys, values ≤ 256 characters. Pass `nil` to remove one. Ignored in
     * `strictAnonymous`: an app that may not send a `user_id` may not send an email under a crash
     * key instead, and the server refuses such a report as well.
     *
     * These are app-authored strings about a person, so — as with `identify(userId:traits:)` — an app
     * that puts an identifier here is collecting it and answers for it in its own App Privacy
     * disclosures.
     */
    public static func setCrashKey(_ key: String, _ value: String?) {
        shared?.crash?.setCustomKey(key, value)
    }

    /**
     * A note in the trail that a crash report carries — a name, never a value.
     *
     * There is deliberately no parameter for a value: breadcrumbs are dumped by the crash handler and
     * so never pass the remote kill switch that filters events, which means a value here would carry
     * app data out of screens a customer believed were excluded. Screens and events already leave
     * their own breadcrumbs; this is for the steps in between.
     */
    public static func leaveBreadcrumb(_ name: String) {
        shared?.crash?.breadcrumb(.log, name)
    }

    /// Sends queued events now. The SDK also flushes every `Options.flushInterval`, at `flushAt` events and on background.
    public static func flush() async {
        guard let p = shared?.pipeline else { return }
        await p.flush()
    }

    public static var isConfigured: Bool { shared != nil }

    /// The pseudonymous install id, or `nil` before `configure(…)` and in
    /// `strictAnonymous` — that mode stores no identity, so there is nothing to return
    /// and returning a fresh id would quietly defeat it.
    ///
    /// Exposed so a backend can send `/v1/server` events for the same install: that
    /// contract needs a `session_id` or an `install_id` to attribute an event, and a
    /// customer's own `user_id` is not enough. Pass it to your server as an opaque
    /// string; it is stable across launches and reinstalls on the same device.
    ///
    /// This is an identifier for a device, so an app that forwards it is responsible
    /// for its own App Privacy answers — as with `identify(userId:traits:)`.
    public static var installId: String? {
        // `ensure` rather than a plain read: the id is minted on first use, and before this the mint
        // happened in `Client.init`, so an app that reads this straight after `configure` must still
        // get a value. It is cached, so only the first caller anywhere pays for it.
        shared.map { $0.identity.ensure(now: Date()).installId } ?? nil
    }

    /// The same install id as a `UUID`, for StoreKit's `Product.PurchaseOption.appAccountToken`.
    ///
    /// Apple echoes that token on every App Store Server Notification, which is how Tapll joins
    /// a purchase, renewal or refund to the person and the session. The token has to be a UUID:
    /// Apple accepts a non-UUID value without complaining and it links nothing, and purchases
    /// made before the token was set cannot be linked afterwards — the token is not something
    /// we stored. So the type carries that guarantee instead of a paragraph asking every caller
    /// to convert the string correctly.
    ///
    /// `nil` before `configure(…)` and in `strictAnonymous`, exactly like `installId`.
    public static var installUUID: UUID? {
        installId.flatMap(UUID.init(uuidString:))
    }
}

/// `Union` was renamed `Tapll` in 0.5.0. Kept for source compatibility for a minor or two; note the module
/// is renamed too, so `import Union` becomes `import Tapll` regardless.
@available(*, deprecated, renamed: "Tapll")
public typealias Union = Tapll
