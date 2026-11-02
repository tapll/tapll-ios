import XCTest
@testable import Tapll

final class LegacyMigrationTests: XCTestCase {
    private var cleanup: [() -> Void] = []
    override func tearDown() { cleanup.forEach { $0() }; cleanup = []; super.tearDown() }

    // MARK: UserDefaults

    private func suites() -> (old: String, new: String) {
        let id = UUID().uuidString
        let names = ("test.union.\(id)", "test.tapll.\(id)")
        cleanup.append {
            UserDefaults().removePersistentDomain(forName: names.0)
            UserDefaults().removePersistentDomain(forName: names.1)
        }
        return names
    }

    func testDefaultsOldOnlyIsMovedAndOldRemoved() {
        let s = suites()
        UserDefaults(suiteName: s.old)!.set("sess", forKey: "session")
        LegacyMigration.migrateDefaults(oldSuite: s.old, newSuite: s.new)
        XCTAssertEqual(UserDefaults(suiteName: s.new)!.string(forKey: "session"), "sess")
        XCTAssertTrue((UserDefaults(suiteName: s.old)!.persistentDomain(forName: s.old) ?? [:]).isEmpty)
    }

    func testDefaultsBothPresentNewWinsOldRemoved() {
        let s = suites()
        UserDefaults(suiteName: s.old)!.set("old", forKey: "session")
        UserDefaults(suiteName: s.old)!.set("kept", forKey: "only_old")
        UserDefaults(suiteName: s.new)!.set("new", forKey: "session")
        LegacyMigration.migrateDefaults(oldSuite: s.old, newSuite: s.new)
        XCTAssertEqual(UserDefaults(suiteName: s.new)!.string(forKey: "session"), "new")
        XCTAssertEqual(UserDefaults(suiteName: s.new)!.string(forKey: "only_old"), "kept")
        XCTAssertTrue((UserDefaults(suiteName: s.old)!.persistentDomain(forName: s.old) ?? [:]).isEmpty)
    }

    func testDefaultsNeitherDoesNothing() {
        let s = suites()
        LegacyMigration.migrateDefaults(oldSuite: s.old, newSuite: s.new)
        XCTAssertTrue((UserDefaults(suiteName: s.new)!.persistentDomain(forName: s.new) ?? [:]).isEmpty)
    }

    // MARK: Application Support directory (queue + crash reports)

    private func base() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tapll-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        cleanup.append { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

    func testDirectoryOldOnlyIsMoved() throws {
        let b = try base()
        try write("queued", b.appendingPathComponent("Union/h/queue.ndjson"))
        try write("crash", b.appendingPathComponent("Union/h/crash/a.ucr"))
        LegacyMigration.migrateSupportDirectory(in: b)
        XCTAssertEqual(read(b.appendingPathComponent("Tapll/h/queue.ndjson")), "queued")
        XCTAssertEqual(read(b.appendingPathComponent("Tapll/h/crash/a.ucr")), "crash")
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.appendingPathComponent("Union").path))
    }

    func testDirectoryBothPresentNewWinsOldRemoved() throws {
        let b = try base()
        try write("old-queue", b.appendingPathComponent("Union/h/queue.ndjson"))
        try write("old-crash", b.appendingPathComponent("Union/h/crash/a.ucr"))
        try write("new-queue", b.appendingPathComponent("Tapll/h/queue.ndjson"))
        LegacyMigration.migrateSupportDirectory(in: b)
        XCTAssertEqual(read(b.appendingPathComponent("Tapll/h/queue.ndjson")), "new-queue")
        XCTAssertEqual(read(b.appendingPathComponent("Tapll/h/crash/a.ucr")), "old-crash", "files only the old side has are kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.appendingPathComponent("Union").path))
    }

    func testDirectoryNeitherDoesNothing() throws {
        let b = try base()
        LegacyMigration.migrateSupportDirectory(in: b)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: b.path).isEmpty)
    }

    func testDirectoryMigrationIsIdempotent() throws {
        let b = try base()
        try write("queued", b.appendingPathComponent("Union/h/queue.ndjson"))
        LegacyMigration.migrateSupportDirectory(in: b)
        LegacyMigration.migrateSupportDirectory(in: b)
        XCTAssertEqual(read(b.appendingPathComponent("Tapll/h/queue.ndjson")), "queued")
    }

    // MARK: Keychain

    #if canImport(Security)
    private func keychainStores() -> (old: KeychainIdentityStore, new: KeychainIdentityStore) {
        let id = UUID().uuidString
        let old = KeychainIdentityStore(service: "test.union.\(id)", legacyService: nil)
        let new = KeychainIdentityStore(service: "test.tapll.\(id)", legacyService: "test.union.\(id)")
        cleanup.append { old.wipe(); new.wipe() }
        return (old, new)
    }

    private func requireKeychain(_ s: KeychainIdentityStore) throws {
        s.save(Identity(installId: "probe"))
        guard s.load().installId == "probe" else { throw XCTSkip("Keychain unavailable in this environment") }
        s.wipe()
    }

    func testKeychainOldOnlyIsMovedAndOldRemoved() throws {
        let k = keychainStores()
        try requireKeychain(k.old)
        k.old.save(Identity(installId: "11111111-1111-1111-1111-111111111111", userId: "u1", traits: ["name": "Ada"]))
        let loaded = k.new.load()
        XCTAssertEqual(loaded.installId, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(loaded.userId, "u1")
        XCTAssertEqual(loaded.traits, ["name": "Ada"])
        XCTAssertNil(k.old.load().installId)
    }

    func testKeychainBothPresentNewWinsOldRemoved() throws {
        let k = keychainStores()
        try requireKeychain(k.old)
        k.old.save(Identity(installId: "old-id", userId: "old-user"))
        k.new.save(Identity(installId: "new-id"))
        let loaded = k.new.load()
        XCTAssertEqual(loaded.installId, "new-id")
        XCTAssertEqual(loaded.userId, "old-user", "an account only the old service had is carried over")
        XCTAssertNil(k.old.load().installId)
        XCTAssertNil(k.old.load().userId)
    }

    func testKeychainNeitherDoesNothing() throws {
        let k = keychainStores()
        try requireKeychain(k.old)
        let loaded = k.new.load()
        XCTAssertNil(loaded.installId)
        XCTAssertNil(loaded.userId)
    }
    #endif
}
