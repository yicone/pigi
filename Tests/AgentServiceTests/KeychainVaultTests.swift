import XCTest
@testable import PigiCore

final class KeychainVaultTests: XCTestCase {
    private let gmailSecret = "gmail-sentinel-813"
    private let imapSecret = "imap-sentinel-813"
    private let protonSecret = #"{"uid":"u","access":"proton-sentinel-813","refresh":"r","salted":"s","email":"c@example.test"}"#
    private let orphanSecret = "orphan-sentinel-813"
    private let orphanUserSecret = "orphan-user-sentinel-813"
    private let translationSecret = "translation-sentinel-813"
    private let sentinels = [
        "gmail-sentinel-813", "imap-sentinel-813", "proton-sentinel-813",
        "orphan-sentinel-813", "orphan-user-sentinel-813", "translation-sentinel-813",
    ]

    func testLoadQueryIsLimitedToOneService() throws {
        let query = KeychainQuery.loadAll(service: "one.yic.pigi")
        XCTAssertEqual(query[kSecAttrService as String] as? String, "one.yic.pigi")
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitAll as String)
        XCTAssertNil(query[kSecReturnData as String])
        XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
        XCTAssertEqual(query.count, 4)
        XCTAssertNil(query[kSecMatchSearchList as String])
        XCTAssertNil(query[kSecAttrAccessGroup as String])
        let item = KeychainQuery.item(service: "one.yic.pigi", account: KeychainQuery.vaultAccount)
        XCTAssertEqual(item[kSecAttrAccount as String] as? String, "vault-v1")
        XCTAssertEqual(item[kSecAttrService as String] as? String, "one.yic.pigi")
        XCTAssertEqual(item.count, 3)
    }

    func testMigrationKeepsAccountsAndRemovesLegacyItems() throws {
        let backend = MemoryKeychainBackend()
        let log = CapturingKeychainLog()
        backend.seed([
            "gmail-refresh-A@Example.Test": Data(gmailSecret.utf8),
            "imap-b@example.test": Data(imapSecret.utf8),
            "proton-session-c@example.test": Data(protonSecret.utf8),
            "proton-session": Data(orphanSecret.utf8),
            "proton-session-not-an-email": Data(orphanUserSecret.utf8),
            "translation-api-key": Data(translationSecret.utf8),
        ])
        let vault = makeVault(backend, log)
        try vault.warmSync()
        for _ in 0..<12 {
            XCTAssertEqual(try vault.read("gmail-refresh-a@example.test"), gmailSecret)
            XCTAssertEqual(try vault.read("imap-b@example.test"), imapSecret)
            XCTAssertEqual(try vault.read("proton-session-c@example.test"), protonSecret)
            XCTAssertEqual(try vault.read("translation-api-key"), translationSecret)
        }
        XCTAssertNil(try vault.read("proton-session"))
        XCTAssertNil(try vault.read("proton-session-not-an-email"))
        XCTAssertEqual(vault.startupCopyMatchingCount(), 1)
        XCTAssertEqual(backend.loadCalls, 1)
        XCTAssertEqual(Set(backend.snapshot().keys), ["vault-v1"])
        XCTAssertEqual(backend.serviceNames(), ["one.yic.pigi"])
        let stored = try json(backend)
        XCTAssertEqual(stored["gmailRefresh"] as? [String: String], ["a@example.test": gmailSecret])
        XCTAssertEqual(stored["imap"] as? [String: String], ["b@example.test": imapSecret])
        XCTAssertEqual(stored["protonSession"] as? [String: String], ["c@example.test": protonSecret])
        XCTAssertEqual(stored["translationAPIKey"] as? String, translationSecret)
        let blob = String(decoding: backend.snapshot()["vault-v1"] ?? Data(), as: UTF8.self)
        XCTAssertFalse(blob.contains(orphanSecret))
        XCTAssertFalse(blob.contains(orphanUserSecret))
        assertLogsHideSecrets(log)
        XCTAssertEqual(log.snapshot().filter { $0.contains("SecItemCopyMatching=") }, ["keychain vault loaded SecItemCopyMatching=1"])
    }

    func testExistingVaultWinsAndStillDeletesLegacyItems() throws {
        let backend = MemoryKeychainBackend()
        let current = try VaultJSON.object([
            "version": 1,
            "gmailRefresh": ["a@example.test": "current-gmail"],
            "futureTranslationRegion": "zh",
            "translationAPIKey": NSNull(),
        ])
        backend.seed([
            "vault-v1": current,
            "gmail-refresh-a@example.test": Data("stale-gmail-sentinel-813".utf8),
            "proton-session": Data(orphanSecret.utf8),
        ])
        let vault = makeVault(backend, CapturingKeychainLog())
        try vault.warmSync()
        XCTAssertEqual(try vault.read("gmail-refresh-a@example.test"), "current-gmail")
        XCTAssertEqual(Set(backend.snapshot().keys), ["vault-v1"])
        XCTAssertEqual(vault.startupCopyMatchingCount(), 1)
        let stored = try json(backend)
        XCTAssertEqual(stored["futureTranslationRegion"] as? String, "zh")
        XCTAssertTrue(stored["translationAPIKey"] is NSNull)
        XCTAssertFalse(String(decoding: backend.snapshot()["vault-v1"] ?? Data(), as: UTF8.self).contains("stale-gmail-sentinel-813"))
    }

    func testFailedMigrationKeepsLegacyItemsAndRetries() throws {
        let backend = MemoryKeychainBackend()
        let log = CapturingKeychainLog()
        backend.seed(["gmail-refresh-a@example.test": Data(gmailSecret.utf8), "proton-session": Data(orphanSecret.utf8)])
        backend.setFailUpserts(1)
        let vault = makeVault(backend, log)
        XCTAssertFalse(vault.write("imap-b@example.test", imapSecret))
        XCTAssertEqual(Set(backend.snapshot().keys), ["gmail-refresh-a@example.test", "proton-session"])
        XCTAssertEqual(vault.startupCopyMatchingCount(), 1)
        XCTAssertTrue(vault.write("imap-b@example.test", imapSecret))
        XCTAssertEqual(try vault.read("gmail-refresh-a@example.test"), gmailSecret)
        XCTAssertEqual(try vault.read("imap-b@example.test"), imapSecret)
        XCTAssertNil(try vault.read("proton-session"))
        XCTAssertEqual(Set(backend.snapshot().keys), ["vault-v1"])
        XCTAssertEqual(vault.startupCopyMatchingCount(), 2)
        let stored = try json(backend)
        XCTAssertEqual(stored["gmailRefresh"] as? [String: String], ["a@example.test": gmailSecret])
        XCTAssertEqual(stored["imap"] as? [String: String], ["b@example.test": imapSecret])
        assertLogsHideSecrets(log)
    }

    func testFailedLegacyDeleteRetriesWithoutAnotherCopy() throws {
        let backend = MemoryKeychainBackend()
        backend.seed([
            "gmail-refresh-a@example.test": Data(gmailSecret.utf8),
            "proton-session": Data(orphanSecret.utf8),
        ])
        backend.setFailDeletes(["proton-session"])
        let vault = makeVault(backend, CapturingKeychainLog())
        try vault.warmSync()
        XCTAssertEqual(Set(backend.snapshot().keys), ["vault-v1", "proton-session"])
        XCTAssertEqual(try vault.read("gmail-refresh-a@example.test"), gmailSecret)
        XCTAssertEqual(vault.startupCopyMatchingCount(), 1)
        backend.setFailDeletes([])
        try vault.warmSync()
        XCTAssertEqual(Set(backend.snapshot().keys), ["vault-v1"])
        XCTAssertEqual(vault.startupCopyMatchingCount(), 1)
        XCTAssertEqual(backend.loadCalls, 1)
    }

    func testUnreadableVaultIsNotOverwritten() throws {
        let backend = MemoryKeychainBackend()
        let log = CapturingKeychainLog()
        backend.seed([
            "vault-v1": Data("not-json".utf8),
            "gmail-refresh-a@example.test": Data(gmailSecret.utf8),
        ])
        let vault = makeVault(backend, log)
        XCTAssertThrowsError(try vault.read("gmail-refresh-a@example.test"))
        XCTAssertThrowsError(try vault.read("gmail-refresh-a@example.test"))
        XCTAssertFalse(vault.write("gmail-refresh-a@example.test", "replacement"))
        XCTAssertEqual(Set(backend.snapshot().keys), ["vault-v1", "gmail-refresh-a@example.test"])
        XCTAssertEqual(backend.snapshot()["vault-v1"], Data("not-json".utf8))
        XCTAssertEqual(vault.startupCopyMatchingCount(), 1)
        XCTAssertEqual(log.snapshot().filter { $0 == "keychain vault decode failed" }.count, 1)
        assertLogsHideSecrets(log)
    }

    func testTranslationKeySharesTheVaultItem() throws {
        let backend = MemoryKeychainBackend()
        let vault = makeVault(backend, CapturingKeychainLog())
        XCTAssertTrue(vault.write("gmail-refresh-a@example.test", gmailSecret))
        XCTAssertTrue(vault.writeTranslationAPIKey(translationSecret))
        XCTAssertEqual(try vault.readTranslationAPIKey(), translationSecret)
        XCTAssertEqual(Set(backend.snapshot().keys), ["vault-v1"])
        XCTAssertEqual(try vault.read("gmail-refresh-a@example.test"), gmailSecret)
        let stored = try json(backend)
        XCTAssertEqual(stored["translationAPIKey"] as? String, translationSecret)
        XCTAssertTrue(vault.writeTranslationAPIKey(""))
        XCTAssertNil(try vault.readTranslationAPIKey())
        XCTAssertTrue(try json(backend)["translationAPIKey"] is NSNull)
        XCTAssertFalse(vault.write("imap-missing@example.test", ""))
    }

    func testStartupSyncReadsOnce() throws {
        let backend = MemoryKeychainBackend()
        backend.seed([
            "gmail-refresh-a@example.test": Data(gmailSecret.utf8),
            "imap-b@example.test": Data(imapSecret.utf8),
            "proton-session-c@example.test": Data(protonSecret.utf8),
        ])
        let vault = makeVault(backend, CapturingKeychainLog())
        try vault.warmSync()
        for email in ["a@example.test", "b@example.test", "c@example.test"] {
            for _ in 0..<8 {
                _ = try vault.read("gmail-refresh-\(email)")
                _ = try vault.read("imap-\(email)")
                _ = try vault.read("proton-session-\(email)")
            }
        }
        XCTAssertEqual(backend.loadCalls, 1)
        XCTAssertEqual(vault.startupCopyMatchingCount(), 1)
    }

    func testConcurrentProtonWritesKeepEveryAccount() async throws {
        let backend = MemoryKeychainBackend()
        let vault = makeVault(backend, CapturingKeychainLog())
        XCTAssertTrue(vault.write("gmail-refresh-keep@example.test", gmailSecret))
        let count = 32
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask {
                    let email = "user\(index)@example.test"
                    let secret = "proton-sentinel-813-\(index)"
                    let saved = await vault.set("proton-session-\(email)", secret)
                    XCTAssertTrue(saved)
                }
            }
        }
        for index in 0..<count {
            let saved = try await vault.get("proton-session-user\(index)@example.test")
            XCTAssertEqual(saved, "proton-sentinel-813-\(index)")
        }
        let kept = try await vault.get("gmail-refresh-keep@example.test")
        XCTAssertEqual(kept, gmailSecret)
        XCTAssertEqual(Set(backend.snapshot().keys), ["vault-v1"])
        XCTAssertEqual(backend.loadCalls, 1)
    }

    func testConcurrentSynchronousWritesDoNotDropSessions() throws {
        let backend = MemoryKeychainBackend()
        let vault = makeVault(backend, CapturingKeychainLog())
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            XCTAssertTrue(vault.write("proton-session-sync\(index)@example.test", "proton-sentinel-813-sync-\(index)"))
        }
        for index in 0..<24 {
            XCTAssertEqual(try vault.read("proton-session-sync\(index)@example.test"), "proton-sentinel-813-sync-\(index)")
        }
        XCTAssertEqual(Set(backend.snapshot().keys), ["vault-v1"])
        XCTAssertEqual(backend.loadCalls, 1)
    }

    func testReadFailureIsLoggedAndThrownWithoutCachingEmptyVault() throws {
        let backend = MemoryKeychainBackend()
        let log = CapturingKeychainLog()
        backend.seed(["imap-test@example.test": Data("synthetic".utf8)])
        backend.failLoads = true
        let vault = makeVault(backend, log)
        XCTAssertThrowsError(try vault.warmSync())
        XCTAssertThrowsError(try vault.read("imap-test@example.test"))
        XCTAssertFalse(log.snapshot().isEmpty)
        XCTAssertEqual(backend.snapshot().count, 1)
        backend.failLoads = false
        XCTAssertEqual(try vault.read("imap-test@example.test"), "synthetic")
    }

    func testMigrationReadbackFailurePreservesLegacyUntilVerified() throws {
        let backend = MemoryKeychainBackend()
        backend.seed(["imap-test@example.test": Data("synthetic".utf8)])
        backend.failReads = true
        let vault = makeVault(backend, CapturingKeychainLog())
        XCTAssertThrowsError(try vault.warmSync())
        XCTAssertNotNil(backend.snapshot()["imap-test@example.test"])
        XCTAssertThrowsError(try vault.warmSync())
        XCTAssertNotNil(backend.snapshot()["imap-test@example.test"])
        backend.failReads = false
        try vault.warmSync()
        XCTAssertEqual(try vault.read("imap-test@example.test"), "synthetic")
        XCTAssertEqual(Set(backend.snapshot().keys), ["vault-v1"])
    }

    func testMigrationReadbackMismatchPreservesLegacy() throws {
        let backend = MemoryKeychainBackend()
        backend.seed(["imap-test@example.test": Data("synthetic".utf8)])
        backend.mismatchReads = true
        let vault = makeVault(backend, CapturingKeychainLog())
        XCTAssertThrowsError(try vault.warmSync())
        XCTAssertThrowsError(try vault.warmSync())
        XCTAssertNotNil(backend.snapshot()["imap-test@example.test"])
        backend.mismatchReads = false
        try vault.warmSync()
        XCTAssertEqual(try vault.read("imap-test@example.test"), "synthetic")
    }

    private func makeVault(_ backend: MemoryKeychainBackend, _ log: CapturingKeychainLog) -> KeychainVault {
        KeychainVault(backend: backend, service: "one.yic.pigi", log: log)
    }

    private func json(_ backend: MemoryKeychainBackend) throws -> [String: Any] {
        let data = try XCTUnwrap(backend.snapshot()["vault-v1"])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertLogsHideSecrets(_ log: CapturingKeychainLog, file: StaticString = #filePath, line: UInt = #line) {
        for entry in log.snapshot() {
            for secret in sentinels {
                XCTAssertFalse(entry.contains(secret), entry, file: file, line: line)
            }
        }
    }
}

private enum VaultJSON {
    static func object(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

final class MemoryKeychainBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var services: Set<String> = []
    private var failUpserts = 0
    private var failDeletes: Set<String> = []
    private(set) var loadCalls = 0
    var failLoads = false
    var failReads = false
    var mismatchReads = false

    func seed(_ items: [String: Data]) {
        lock.lock(); defer { lock.unlock() }
        self.items = items
    }

    func snapshot() -> [String: Data] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    func serviceNames() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return services
    }

    func setFailUpserts(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        failUpserts = count
    }

    func setFailDeletes(_ accounts: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        failDeletes = accounts
    }

    func loadAll(service: String) throws -> [KeychainRecord] {
        lock.lock(); defer { lock.unlock() }
        services.insert(service)
        loadCalls += 1
        if failLoads { throw KeychainBackendError(code: errSecAuthFailed) }
        return items.map { KeychainRecord(account: $0.key, data: $0.value) }
    }

    func read(service: String, account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if failReads { throw KeychainBackendError(code: errSecAuthFailed) }
        if mismatchReads { return Data("mismatch".utf8) }
        return items[account]
    }

    func upsert(service: String, account: String, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        services.insert(service)
        if failUpserts > 0 {
            failUpserts -= 1
            throw KeychainBackendError(code: errSecAuthFailed)
        }
        items[account] = data
    }

    func delete(service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        services.insert(service)
        if failDeletes.contains(account) { throw KeychainBackendError(code: errSecAuthFailed) }
        items.removeValue(forKey: account)
    }
}

private final class CapturingKeychainLog: KeychainLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func info(_ message: String) { append(message) }
    func error(_ message: String) { append(message) }
    private func append(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(message)
    }
    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}
