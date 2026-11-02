import Foundation

/// Names the SDK persisted under before the Union → Tapll rename (0.4.x). Read only by the migration.
enum LegacyNames {
    /// Keychain service and `UserDefaults` suite.
    static let service = "app.union.sdk"
    static let defaultsSuite = "app.union.sdk"
    /// Directory under Application Support holding `<keyHash>/queue.ndjson` and `<keyHash>/crash/`.
    static let supportDirectory = "Union"
}

/// One-time, idempotent move of state persisted under the old name to the new one, run at `configure`
/// before any store opens. Without it every upgraded install would mint a new install id (a new
/// person server-side) and drop the queued events and unsent crash reports of the previous launch.
///
/// Rule everywhere: old present, new absent → moved; both present → the new one wins and the old is
/// removed; neither → nothing happens. The Keychain half lives in `KeychainIdentityStore.migrateLegacy()`.
enum LegacyMigration {
    /// Copies every key of the old `UserDefaults` suite the new one does not already have, then drops
    /// the old suite's domain.
    static func migrateDefaults(oldSuite: String = LegacyNames.defaultsSuite, newSuite: String = "app.tapll.sdk") {
        guard oldSuite != newSuite, let old = UserDefaults(suiteName: oldSuite),
              let legacy = old.persistentDomain(forName: oldSuite), !legacy.isEmpty,
              let new = UserDefaults(suiteName: newSuite) else { return }
        for (key, value) in legacy where new.object(forKey: key) == nil {
            new.set(value, forKey: key)
        }
        old.removePersistentDomain(forName: oldSuite)
    }

    /// `Application Support/Union` → `Application Support/Tapll`, merged file by file (queue, crash
    /// records and their sidecars keep their relative paths).
    static func migrateSupportDirectory(in base: URL? = nil, oldName: String = LegacyNames.supportDirectory, newName: String = "Tapll") {
        let fm = FileManager.default
        guard oldName != newName,
              let base = base ?? (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
        else { return }
        let old = base.appendingPathComponent(oldName, isDirectory: true)
        guard fm.fileExists(atPath: old.path) else { return }
        let new = base.appendingPathComponent(newName, isDirectory: true)
        if !fm.fileExists(atPath: new.path) {
            // Whole directory in one rename; keeps the backup-exclusion flag set on the key directories.
            if (try? fm.moveItem(at: old, to: new)) != nil { return }
        }
        merge(old, into: new)
    }

    private static func merge(_ source: URL, into destination: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                if fm.fileExists(atPath: target.path) { merge(item, into: target) } else { try? fm.moveItem(at: item, to: target) }
            } else if !fm.fileExists(atPath: target.path) {
                try? fm.moveItem(at: item, to: target)
            }
        }
        try? fm.removeItem(at: source) // whatever is left lost to a newer file of the same name
    }
}
