import Foundation

/// The notification authorization the app reports through `Tapll.notificationPermission`.
/// Map `UNAuthorizationStatus` onto it; `.ephemeral` counts as `.granted`.
public enum NotificationPermission: String, Sendable, CaseIterable {
    case granted
    case denied
    case provisional
    case notDetermined = "not_determined"
}

/**
 * When to ask for an App Store review. It decides and never asks: the app calls `requestReview()`
 * and then `Tapll.reviewRequested(source:)`.
 *
 * Apple shows the prompt at most three times a year and may show it never, so one spent too early
 * cannot be spent later. The policy waits for `minSuccesses` moments the app counts as a success
 * (a finished task, a completed workout) and for `minDaysSinceFirstUse` days since the policy first
 * ran, and then answers yes once per app version.
 *
 * State is local to the device and independent of analytics consent: it is a UI decision, and an
 * opted-out user should be asked no more and no less often than anyone else.
 */
public struct ReviewPolicy: Sendable {
    public let minSuccesses: Int
    public let minDaysSinceFirstUse: Int
    private let store: KeyValueStore
    private let clock: Clock
    private let appVersion: String

    private static let successesKey = "review.successes"
    private static let firstUseKey = "review.first_use"
    private static let askedVersionKey = "review.asked_version"

    public init(minSuccesses: Int = 3, minDaysSinceFirstUse: Int = 1) {
        self.init(
            minSuccesses: minSuccesses,
            minDaysSinceFirstUse: minDaysSinceFirstUse,
            store: UserDefaultsStore(suite: "app.tapll.sdk.review"),
            clock: SystemClock(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        )
    }

    init(minSuccesses: Int, minDaysSinceFirstUse: Int, store: KeyValueStore, clock: Clock, appVersion: String) {
        self.minSuccesses = minSuccesses
        self.minDaysSinceFirstUse = minDaysSinceFirstUse
        self.store = store
        self.clock = clock
        self.appVersion = appVersion
        if store.string(forKey: Self.firstUseKey) == nil {
            store.set(String(clock.now.timeIntervalSince1970), forKey: Self.firstUseKey)
        }
    }

    /// Counts one success. Cheap; call it from wherever the success happens.
    public func recordSuccess() {
        store.set(String(successes + 1), forKey: Self.successesKey)
    }

    /// Whether to ask now. True at most once per app version, until `markAsked()`.
    public var shouldAsk: Bool {
        guard store.string(forKey: Self.askedVersionKey) != appVersion else { return false }
        guard successes >= minSuccesses else { return false }
        let firstUse = Double(store.string(forKey: Self.firstUseKey) ?? "") ?? clock.now.timeIntervalSince1970
        let days = (clock.now.timeIntervalSince1970 - firstUse) / 86_400
        return days >= Double(minDaysSinceFirstUse)
    }

    /// Records that the app asked, so `shouldAsk` stays false for this version, and starts the
    /// success count again for the next one.
    public func markAsked() {
        store.set(appVersion, forKey: Self.askedVersionKey)
        store.set("0", forKey: Self.successesKey)
    }

    private var successes: Int { Int(store.string(forKey: Self.successesKey) ?? "") ?? 0 }
}
