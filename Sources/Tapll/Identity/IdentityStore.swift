import Foundation
#if canImport(Security)
import Security
#endif

/// Persists the pseudonymous install id and the optional customer user id.
protocol IdentityStore: Sendable {
    func load() -> Identity
    func save(_ identity: Identity)
    func wipe()
}

/// strict_anonymous: nothing is ever written; batches carry `identity: {}`.
struct NoopIdentityStore: IdentityStore {
    func load() -> Identity { .anonymous }
    func save(_ identity: Identity) {}
    func wipe() {}
}

final class InMemoryIdentityStore: IdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var identity = Identity()
    func load() -> Identity { lock.lock(); defer { lock.unlock() }; return identity }
    func save(_ identity: Identity) { lock.lock(); self.identity = identity; lock.unlock() }
    func wipe() { save(Identity()) }
}

#if canImport(Security)
/// Keychain, this-device-only, after-first-unlock, no iCloud sync. Survives reinstall, which is how
/// `$app_install { reinstall: true }` is detected (Keychain id present but no stored app version).
struct KeychainIdentityStore: IdentityStore {
    let service: String
    private let installKey = "install_id"
    private let userKey = "user_id"
    private let traitsKey = "traits"

    /// Service the 0.4.x SDK wrote under; `nil` disables the one-time migration (tests).
    let legacyService: String?

    init(service: String = "app.tapll.sdk", legacyService: String? = LegacyNames.service) {
        self.service = service
        self.legacyService = legacyService
    }

    /// Moves items written by the pre-rename SDK to the current service, so the install id survives the
    /// upgrade. For each account: old present and new absent → copied; both present → new wins; the old
    /// item is removed either way. Idempotent, and a no-op (a few cheap lookups) once nothing is left.
    func migrateLegacy() {
        guard let legacyService, legacyService != service else { return }
        for account in [installKey, userKey, traitsKey] {
            var q = query(account, service: legacyService)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { continue }
            if read(account) == nil, let value = String(data: data, encoding: .utf8) { write(account, value) }
            SecItemDelete(query(account, service: legacyService) as CFDictionary)
        }
    }

    func load() -> Identity {
        migrateLegacy()
        return Identity(installId: read(installKey), userId: read(userKey), traits: readTraits())
    }

    func save(_ identity: Identity) {
        write(installKey, identity.installId)
        write(userKey, identity.userId)
        // Same protection class as the ids: traits can name a real person, so they never go to a
        // plist and never sync to iCloud.
        write(traitsKey, identity.traits.flatMap { t in
            (try? JSONEncoder().encode(t)).map { String(decoding: $0, as: UTF8.self) }
        })
    }

    func wipe() {
        write(installKey, nil)
        write(userKey, nil)
        write(traitsKey, nil)
    }

    private func readTraits() -> [String: String]? {
        guard let raw = read(traitsKey), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private func query(_ account: String, service: String? = nil) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service ?? self.service, kSecAttrAccount as String: account]
    }

    private func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ account: String, _ value: String?) {
        let q = query(account)
        guard let value, let data = value.data(using: .utf8) else {
            SecItemDelete(q as CFDictionary)
            return
        }
        let attrs: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            attrs.forEach { add[$0.key] = $0.value }
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
#endif
