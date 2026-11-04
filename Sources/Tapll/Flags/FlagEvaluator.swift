import Foundation

/*
 * Feature flags — the ruleset `GET /v1/flags` serves, and its evaluation.
 *
 * This file is a port of `tapll-panel/packages/contract/src/flags.ts` (ADR 0006). It must produce the
 * same bucket and variant for every case in `Tests/TapllTests/Fixtures/flag-vectors.v1.json`, which is
 * copied from the contract, never edited by hand: an install lands in the same variant on iOS,
 * Android and the web, or the panel's results compare two different populations.
 */

let flagBuckets = 10_000

struct FlagRuleset: Codable, Sendable, Equatable {
    var version: String
    var flags: [String: FlagDefinition]

    static let empty = FlagRuleset(version: "0", flags: [:])
}

struct FlagSlice: Codable, Sendable, Equatable {
    var variant: String
    var weight: Int
}

struct FlagDefinition: Codable, Sendable, Equatable {
    var kind: String
    var variants: [String]
    var salt: String
    var enabled: Bool
    var defaultVariant: String
    var rules: [FlagRule]
    var rollout: [FlagSlice]
}

struct FlagRule: Codable, Sendable, Equatable {
    var when: [FlagCondition]
    var serve: FlagServe
}

/// `{ variant }` or `{ split }`, as the contract's union.
enum FlagServe: Codable, Sendable, Equatable {
    case variant(String)
    case split([FlagSlice])

    private enum Keys: String, CodingKey { case variant, split }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let v = try c.decodeIfPresent(String.self, forKey: .variant) { self = .variant(v); return }
        self = .split(try c.decode([FlagSlice].self, forKey: .split))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .variant(let v): try c.encode(v, forKey: .variant)
        case .split(let s): try c.encode(s, forKey: .split)
        }
    }
}

/// One condition, discriminated by `attribute`. An attribute this SDK does not know never matches —
/// a newer panel can add one without an older build serving the wrong variant from it.
struct FlagCondition: Codable, Sendable, Equatable {
    var attribute: String
    var values: [String]?
    var op: String?
    var value: String?
    var key: String?

    private enum Keys: String, CodingKey { case attribute, `in`, op, value, key }

    init(attribute: String, values: [String]? = nil, op: String? = nil, value: String? = nil, key: String? = nil) {
        self.attribute = attribute
        self.values = values
        self.op = op
        self.value = value
        self.key = key
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        attribute = try c.decode(String.self, forKey: .attribute)
        values = try c.decodeIfPresent([String].self, forKey: .in)
        op = try c.decodeIfPresent(String.self, forKey: .op)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        key = try c.decodeIfPresent(String.self, forKey: .key)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(attribute, forKey: .attribute)
        try c.encodeIfPresent(values, forKey: .in)
        try c.encodeIfPresent(op, forKey: .op)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(key, forKey: .key)
    }
}

/// What the device knows about itself when it evaluates.
struct FlagContext: Sendable, Equatable {
    /// `user_id` after identify, else `install_id`; `nil` in strict anonymous.
    var bucketId: String?
    var platform: String = "ios"
    var appVersion: String?
    var locale: String?
    var traits: [String: String] = [:]
}

/// Why the device got its variant; travels on `$flag_exposure`.
public enum FlagReason: String, Sendable, Equatable {
    case off, rule, rollout, `default`
}

struct FlagEvaluation: Sendable, Equatable {
    var variant: String
    var reason: FlagReason
}

enum FlagEvaluator {
    /// FNV-1a, 32 bit, over UTF-8.
    static func fnv1a32(_ input: String) -> UInt32 {
        var hash: UInt32 = 0x811c_9dc5
        for byte in input.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash
    }

    static func bucket(salt: String, bucketId: String) -> Int {
        Int(fnv1a32("\(salt):\(bucketId)") % UInt32(flagBuckets))
    }

    /// One slice with all the weight needs no bucket; a real split without one is `nil`.
    static func allocate(_ allocation: [FlagSlice], bucket: Int?) -> String? {
        let live = allocation.filter { $0.weight > 0 }
        if live.count == 1 { return live[0].variant }
        guard let bucket else { return nil }
        var edge = 0
        for slice in allocation {
            edge += slice.weight
            if bucket < edge { return slice.variant }
        }
        return allocation.last?.variant
    }

    /// Dotted numeric versions; missing or non-numeric parts are 0.
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".", omittingEmptySubsequences: false).map { Int(leadingDigits($0)) ?? 0 }
        let pb = b.split(separator: ".", omittingEmptySubsequences: false).map { Int(leadingDigits($0)) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    /// `parseInt` semantics: the leading run of digits, so `"3-beta"` is 3.
    private static func leadingDigits(_ s: Substring) -> String {
        String(s.prefix { $0.isASCII && $0.isNumber })
    }

    static func matches(_ c: FlagCondition, _ ctx: FlagContext) -> Bool {
        switch c.attribute {
        case "platform":
            return c.values?.contains(ctx.platform) ?? false
        case "app_version":
            guard let version = ctx.appVersion, !version.isEmpty, let value = c.value else { return false }
            let cmp = compareVersions(version, value)
            return c.op == "gte" ? cmp >= 0 : c.op == "lt" ? cmp < 0 : false
        case "locale":
            let locale = (ctx.locale ?? "").lowercased().replacingOccurrences(of: "_", with: "-")
            guard !locale.isEmpty else { return false }
            return (c.values ?? []).contains { p in
                let prefix = p.lowercased()
                return locale == prefix || locale.hasPrefix(prefix + "-")
            }
        case "trait":
            guard let key = c.key, let value = ctx.traits[key] else { return false }
            return c.values?.contains(value) ?? false
        default:
            return false
        }
    }

    static func evaluate(_ def: FlagDefinition, _ ctx: FlagContext) -> FlagEvaluation {
        if !def.enabled { return FlagEvaluation(variant: def.defaultVariant, reason: .off) }
        let bucket = ctx.bucketId.flatMap { $0.isEmpty ? nil : self.bucket(salt: def.salt, bucketId: $0) }
        func known(_ v: String?) -> String? { v.flatMap { def.variants.contains($0) ? $0 : nil } }
        for rule in def.rules where rule.when.allSatisfy({ matches($0, ctx) }) {
            let variant: String?
            switch rule.serve {
            case .variant(let v): variant = v
            case .split(let s): variant = allocate(s, bucket: bucket)
            }
            if let v = known(variant) { return FlagEvaluation(variant: v, reason: .rule) }
            return FlagEvaluation(variant: def.defaultVariant, reason: .default)
        }
        if let v = known(allocate(def.rollout, bucket: bucket)) { return FlagEvaluation(variant: v, reason: .rollout) }
        return FlagEvaluation(variant: def.defaultVariant, reason: .default)
    }
}
