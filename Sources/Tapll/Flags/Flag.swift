import Foundation

/**
 * One feature flag as this device sees it right now: `Tapll.flag("new_paywall")`.
 *
 * ```swift
 * if Tapll.flag("new_paywall").isEnabled { showNewPaywall() }
 *
 * switch Tapll.flag("paywall_layout").value(default: "control") {
 * case "annual": showAnnualFirst()
 * default: showControl()
 * }
 * ```
 *
 * Reading never waits and never throws. A flag the device has no ruleset for — before the first
 * fetch, offline on a first launch, a key the project does not have — has `variant == nil`, so
 * `isEnabled` is `false` and `value(default:)` returns the default you pass: the behaviour you coded.
 */
public struct Flag: Sendable, Equatable {
    public let key: String
    /// The variant this device gets (`"on"`/`"off"` for an on/off flag), or `nil` when the ruleset does not hold the flag.
    public let variant: String?
    /// Why — `nil` together with `variant`.
    public let reason: FlagReason?

    /// `true` only for an on/off flag that is on for this device.
    public var isEnabled: Bool { variant == "on" }

    /// The variant, or `defaultValue` when the device has none.
    public func value(default defaultValue: String) -> String { variant ?? defaultValue }

    init(key: String, evaluation: FlagEvaluation?) {
        self.key = key
        variant = evaluation?.variant
        reason = evaluation?.reason
    }
}
