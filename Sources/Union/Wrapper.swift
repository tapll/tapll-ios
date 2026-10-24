import Foundation

/*
 * The bridge for the Flutter and React Native wrappers — and nothing else.
 *
 * `@_spi(Wrapper)`, so it does not appear in the public interface an app developer sees or completes
 * against; a wrapper opts in with `@_spi(Wrapper) import Union`. It is deliberately not documented
 * as API and carries no stability promise beyond the agreement in `SDK-PLATFORMS.md`
 * ("Wrapper bridge"): two calls, the same two on Android.
 *
 * Wrappers never talk to ingest. Every event, session, queue and crash file is this SDK's; a wrapper
 * only forwards calls, so there is one implementation of the response policy and the privacy modes.
 */

/// One frame of a Dart or JavaScript stack, as the wrapper parsed it. The frame number is assigned
/// from array order by `recordManagedError`; innermost first.
@_spi(Wrapper)
public struct ManagedFrame: Sendable, Equatable {
    public var function: String
    /// The class, Dart library or JS bundle, when the runtime gives it apart from the function.
    public var module: String?
    public var file: String?
    public var line: Int?
    public var column: Int?
    /// The wrapper's call: whether this frame is the app's own code.
    public var inApp: Bool

    public init(function: String, module: String? = nil, file: String? = nil,
                line: Int? = nil, column: Int? = nil, inApp: Bool) {
        self.function = function
        self.module = module
        self.file = file
        self.line = line
        self.column = column
        self.inApp = inApp
    }
}

/// What `device.sdk_wrapper` and the User-Agent suffix are built from.
enum WrapperInfo {
    /// `device.sdk_wrapper` is at most 32 characters in the contract.
    static let maxLength = 32

    /// `<name>/<version>`, or `nil` when it cannot be sent as is. Cut rather than accepted
    /// truncated: a clipped version string would name a release that does not exist.
    static func value(name: String, version: String) -> String? {
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        func ok(_ part: String, allowSlash: Bool) -> Bool {
            !part.isEmpty
                && part.rangeOfCharacter(from: forbidden) == nil
                && (allowSlash || !part.contains("/"))
                && part.unicodeScalars.allSatisfy { $0.isASCII }
        }
        guard ok(name, allowSlash: false), ok(version, allowSlash: false) else { return nil }
        let joined = "\(name)/\(version)"
        return joined.count <= maxLength ? joined : nil
    }
}

extension Union {
    /**
     * Declares which wrapper sits in front of this SDK: sets `device.sdk_wrapper` to
     * `<name>/<version>` and appends ` <name>/<version>` to the User-Agent.
     *
     * Must be called **before** `configure`. After it, the call is ignored with a log: the device
     * context is built once per client, so a late wrapper would label some batches and not others.
     * A name or version that is empty, contains whitespace or `/`, or makes the whole value longer
     * than 32 characters is ignored with a log as well.
     */
    @_spi(Wrapper)
    public static func setWrapper(name: String, version: String) {
        registerWrapper(name: name, version: version)
    }

    /**
     * A Dart or JS error with its parsed stack.
     *
     * `fatal: false` is reported as a `nonfatal`, exactly like `recordError`. `fatal: true` is
     * written to the crash store **synchronously** — the managed runtime is about to take the process
     * down — and uploaded on the next launch. `thread` names the crashed thread (`js` for React
     * Native's JS thread, `main` for Dart's UI isolate). Managed reports carry no binary images.
     */
    @_spi(Wrapper)
    public static func recordManagedError(type: String, reason: String?, frames: [ManagedFrame],
                                          fatal: Bool, thread: String = "main") {
        currentClient?.crash?.recordManagedError(type: type, reason: reason, frames: frames,
                                                 fatal: fatal, threadName: thread)
    }
}
