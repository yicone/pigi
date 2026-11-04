import XCTest
import Security
@testable import PigiCore

/// Uses only synthetic data under a fresh service in the file-based login keychain.
/// Any macOS authorization dialog must be handled by the user.
final class LoginKeychainIntegrationTests: XCTestCase {
    func testLoginKeychainMigrationReadbackAndProcessCache() throws {
        let service = "one.yic.pigi.tests." + UUID().uuidString
        var login: SecKeychain?
        let path = NSHomeDirectory() + "/Library/Keychains/login.keychain-db"
        let opened = SecKeychainOpen(path, &login)
        XCTAssertEqual(opened, errSecSuccess)
        let keychain = try XCTUnwrap(login)
        var cleanup = KeychainQuery.item(service: service, account: "unused")
        cleanup.removeValue(forKey: kSecAttrAccount as String)
        cleanup[kSecMatchSearchList as String] = [keychain]
        defer {
            let status = SecItemDelete(cleanup as CFDictionary)
            XCTAssertTrue(status == errSecSuccess || status == errSecItemNotFound)
        }

        let records = [
            "gmail-refresh-synthetic@example.test": "synthetic-refresh",
            "imap-synthetic@example.test": "synthetic-password",
            "proton-session-synthetic@example.test": "synthetic-session",
        ]
        for (account, value) in records {
            var add = KeychainQuery.item(service: service, account: account)
            add[kSecUseKeychain as String] = keychain
            add[kSecValueData as String] = Data(value.utf8)
            XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)
        }
        let backend = ObservedLoginBackend(service: service)
        XCTAssertEqual(try backend.loadAll(service: service).count, records.count)
        let vault = KeychainVault(backend: backend, service: service)
        try vault.warmSync()
        XCTAssertTrue(backend.verifiedBeforeDelete)
        XCTAssertEqual(backend.deleted, records.count)
        let calls = backend.calls
        for _ in 0..<10 {
            for (account, value) in records {
                XCTAssertEqual(try vault.read(account), value)
            }
        }
        XCTAssertEqual(backend.calls, calls, "Cached reads must not access the keychain")
        XCTAssertEqual(vault.startupCopyMatchingCount(), 1)
        let stored = try backend.loadAll(service: service)
        XCTAssertEqual(stored.map(\.account), [KeychainQuery.vaultAccount])
        XCTAssertNotNil(try backend.read(service: service, account: KeychainQuery.vaultAccount))
        var loginVault = KeychainQuery.item(service: service, account: KeychainQuery.vaultAccount)
        loginVault[kSecMatchSearchList as String] = [keychain]
        loginVault[kSecReturnData as String] = true
        loginVault[kSecMatchLimit as String] = kSecMatchLimitOne
        var loginData: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(loginVault as CFDictionary, &loginData), errSecSuccess)
        XCTAssertEqual(loginData as? Data, stored.first?.data)
        let restarted = KeychainVault(backend: backend, service: service)
        try restarted.warmSync()
        for (account, value) in records {
            XCTAssertEqual(try restarted.read(account), value)
        }
        // The integration backend can never be used against the app's service.
        XCTAssertThrowsError(try backend.read(service: "one.yic.pigi", account: "vault-v1"))
    }
}

private final class ObservedLoginBackend: KeychainBackend, @unchecked Sendable {
    let backend: SecurityKeychainBackend
    var calls = 0
    var deleted = 0
    var verifiedBeforeDelete = true
    private var expected: Data?
    private var verified = false

    init(service: String) { backend = SecurityKeychainBackend(integrationTestService: service) }

    func loadAll(service: String) throws -> [KeychainRecord] {
        calls += 1
        return try backend.loadAll(service: service)
    }

    func read(service: String, account: String) throws -> Data? {
        calls += 1
        let data = try backend.read(service: service, account: account)
        if account == KeychainQuery.vaultAccount, let expected { verified = data == expected }
        return data
    }

    func upsert(service: String, account: String, data: Data) throws {
        calls += 1
        try backend.upsert(service: service, account: account, data: data)
        expected = data
        verified = false
    }

    func delete(service: String, account: String) throws {
        calls += 1
        verifiedBeforeDelete = verifiedBeforeDelete && verified
        try backend.delete(service: service, account: account)
        deleted += 1
    }
}
