import XCTest
@testable import PigiCore

private extension LocalEngine {
    func seedTranslationDeletion(cache: SQLiteTranslationCache) throws {
        translationCache = cache
        let memory = try Store(path: ":memory:")
        for sql in Self.schema { try memory.run(sql) }
        try memory.run("INSERT INTO accounts(email,kind) VALUES('a@example.invalid','imap')")
        store = memory
    }

    func translationFixtureAccountExists() throws -> Bool {
        try account("a@example.invalid") != nil
    }
}

final class TranslationPrivacyTests: XCTestCase {
    private let value = CachedTranslation(subject: "主题", body: "正文")
    private func key(account: String = "a@example.invalid", mail: String = "same", hash: String = "body1",
                     model: String = "m", prompt: Int = 1, language: String = "zh-Hans") -> TranslationCacheKey {
        .init(accountID: account, mailID: mail, bodyHash: hash, model: model, promptVersion: prompt, targetLanguage: language)
    }

    func testKeyDimensionsAndAccountIsolation() async throws {
        let cache = SQLiteTranslationCache(path: ":memory:")
        let ticket = try await cache.begin(key())
        try await cache.put(value, for: ticket, validated: true)
        let hit = try await cache.get(key())
        XCTAssertEqual(hit, value)
        for different in [key(account: "b@example.invalid"), key(mail: "other"), key(hash: "body2"),
                          key(model: "m2"), key(prompt: 2), key(language: "ja")] {
            let miss = try await cache.get(different)
            XCTAssertNil(miss)
        }
        let uppercase = try await cache.get(key(account: "A@EXAMPLE.INVALID"))
        XCTAssertEqual(uppercase, value)
    }

    func testSourceRevisionInvalidation() async throws {
        let cache = SQLiteTranslationCache(path: ":memory:")
        for revision in [key(), key(hash: "new")] {
            let ticket = try await cache.begin(revision)
            try await cache.put(value, for: ticket, validated: true)
        }
        let old = try await cache.get(key())
        let current = try await cache.get(key(hash: "new"))
        XCTAssertNil(old)
        XCTAssertEqual(current, value)
        let hash = TranslationCacheKey.sourceHash(subject: "A", body: "B", isHTML: false)
        XCTAssertNotEqual(hash, TranslationCacheKey.sourceHash(subject: "AA", body: "B", isHTML: false))
        XCTAssertNotEqual(hash, TranslationCacheKey.sourceHash(subject: "A", body: "BB", isHTML: false))
        XCTAssertNotEqual(hash, TranslationCacheKey.sourceHash(subject: "A", body: "B", isHTML: true))
        let fingerprint = TranslationCacheKey.promptFingerprint(version: 1, systemPrompt: "p", temperature: nil, endpoint: "https://a.invalid")
        for (version, prompt, temperature, endpoint) in [(2, "p", nil as Double?, "https://a.invalid"),
            (1, "other", nil, "https://a.invalid"), (1, "p", 0.2, "https://a.invalid"), (1, "p", nil, "https://b.invalid")] {
            XCTAssertNotEqual(fingerprint, TranslationCacheKey.promptFingerprint(version: version, systemPrompt: prompt, temperature: temperature, endpoint: endpoint))
        }
    }

    func testFailedValidationAndCancellationNeverWrite() async throws {
        let cache = SQLiteTranslationCache(path: ":memory:")
        let ticket = try await cache.begin(key())
        do { try await cache.put(value, for: ticket, validated: false); XCTFail("accepted invalid result") }
        catch SQLiteTranslationCache.Failure.invalidResult {} catch { XCTFail("unexpected error") }
        let task = Task { [value] in
            withUnsafeCurrentTask { $0?.cancel() }
            try await cache.put(value, for: ticket, validated: true)
        }
        do { try await task.value; XCTFail("accepted cancelled result") }
        catch is CancellationError {} catch { XCTFail("unexpected error") }
        let miss = try await cache.get(key())
        XCTAssertNil(miss)
    }

    func testClearAndPurgeRejectLateResultsAndPreserveOtherAccounts() async throws {
        let cache = SQLiteTranslationCache(path: ":memory:")
        let a = try await cache.begin(key())
        let bKey = key(account: "b@example.invalid")
        let b = try await cache.begin(bKey)
        try await cache.put(value, for: a, validated: true)
        try await cache.put(value, for: b, validated: true)
        try await cache.purge(accountID: "A@EXAMPLE.INVALID")
        do { try await cache.put(value, for: a, validated: true); XCTFail("late purge write") }
        catch SQLiteTranslationCache.Failure.invalidated {} catch { XCTFail("unexpected error") }
        let removed = try await cache.get(key())
        let preserved = try await cache.get(bKey)
        XCTAssertNil(removed)
        XCTAssertEqual(preserved, value)
        try await cache.clear()
        do { try await cache.put(value, for: b, validated: true); XCTFail("late clear write") }
        catch SQLiteTranslationCache.Failure.invalidated {} catch { XCTFail("unexpected error") }
        let empty = try await cache.get(bKey)
        XCTAssertNil(empty)
        let fresh = try await cache.begin(bKey)
        try await cache.put(value, for: fresh, validated: true)
    }

    func testTicketCannotBeUsedWithAnotherCache() async throws {
        let a = SQLiteTranslationCache(path: ":memory:")
        let b = SQLiteTranslationCache(path: ":memory:")
        let ticket = try await a.begin(key())
        do { try await b.put(value, for: ticket, validated: true); XCTFail("foreign ticket") }
        catch SQLiteTranslationCache.Failure.invalidated {} catch { XCTFail("unexpected error") }
    }

    @MainActor
    func testEngineDeletionCleanupAndStorageFailure() async throws {
        let cache = SQLiteTranslationCache(path: ":memory:")
        let engine = LocalEngine()
        try await engine.seedTranslationDeletion(cache: cache)
        let suite = "translation-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let privacy = TranslationPrivacySettings(defaults: defaults)
        privacy.setEnabled(true, accountID: "a@example.invalid", isProton: true, confirmingProtonConsent: true)
        let ticket = try await cache.begin(key())
        try await cache.put(value, for: ticket, validated: true)
        try await engine.purgeTranslationData(accountID: "a@example.invalid", privacy: privacy)
        let miss = try await cache.get(key())
        XCTAssertNil(miss)
        XCTAssertFalse(privacy.isEnabled(accountID: "a@example.invalid"))
        XCTAssertFalse(privacy.hasAccountConsent(accountID: "a@example.invalid"))
        let retained = try await engine.translationFixtureAccountExists()
        XCTAssertTrue(retained) // Translation cleanup itself never edits original mail.

        let bad = SQLiteTranslationCache(path: "/nonexistent-" + UUID().uuidString + "/translations.db")
        try await engine.seedTranslationDeletion(cache: bad)
        // Fails at cache cleanup before touching the real keychain or deleting the account.
        do { try await engine.deleteAccount("a@example.invalid"); XCTFail("ignored storage failure") }
        catch is SQLError {} catch { XCTFail("unexpected failure: \(error)") }
        let stillRetained = try await engine.translationFixtureAccountExists()
        XCTAssertTrue(stillRetained)
    }

    func testDiskPersistencePermissionsAndClear() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("translations.db").path
        let cache = SQLiteTranslationCache(path: path)
        let ticket = try await cache.begin(key())
        try await cache.put(value, for: ticket, validated: true)
        let reopened = SQLiteTranslationCache(path: path)
        let hit = try await reopened.get(key())
        XCTAssertEqual(hit, value)
        for candidate in [path, path + "-wal", path + "-shm"] where FileManager.default.fileExists(atPath: candidate) {
            let mode = try FileManager.default.attributesOfItem(atPath: candidate)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o600)
        }
        try await cache.clear()
        let miss = try await reopened.get(key())
        XCTAssertNil(miss)
    }

    @MainActor
    func testPolicyConsentPersistenceAndAccountRemoval() throws {
        let suite = "translation-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TranslationPrivacySettings(defaults: defaults)
        let account = "test@example.invalid"
        let endpoint = "https://api.example.invalid/v1"
        func policy(enabled: Bool = true, configured: Bool = true, proton: Bool = true) -> TranslationPermission {
            settings.policy(accountID: account, isProton: proton, globalEnabled: enabled, configured: configured, endpoint: endpoint)
        }
        XCTAssertFalse(settings.isEnabled(accountID: account))
        XCTAssertEqual(policy(enabled: false), .notConfigured)
        XCTAssertEqual(policy(configured: false), .notConfigured)
        XCTAssertEqual(policy(), .disabled)
        XCTAssertEqual(settings.setEnabled(true, accountID: account, isProton: true), .needsAccountConsent)
        XCTAssertFalse(settings.isEnabled(accountID: account))
        settings.setEnabled(true, accountID: account, isProton: true, confirmingProtonConsent: true)
        XCTAssertEqual(policy(), .needsServiceConsent)
        settings.grantServiceConsent(endpoint: endpoint)
        XCTAssertEqual(policy(), .allowed)
        let snapshot = StoredTranslationPolicy(accounts: [(account, true)], globalEnabled: true,
            configured: true, endpoint: endpoint, privacy: settings)
        XCTAssertEqual(snapshot.permission(forAccount: account), .allowed)
        XCTAssertEqual(snapshot.permission(forAccount: "unknown@example.invalid"), .disabled)
        XCTAssertFalse(settings.hasServiceConsent(endpoint: "https://other.example.invalid/v1"))
        XCTAssertFalse(settings.hasServiceConsent(endpoint: endpoint + "/other"))
        let reloaded = TranslationPrivacySettings(defaults: defaults)
        XCTAssertTrue(reloaded.isEnabled(accountID: account.uppercased()))
        XCTAssertTrue(reloaded.hasAccountConsent(accountID: account))
        XCTAssertTrue(reloaded.hasServiceConsent(endpoint: "https://API.example.invalid:443/v1/"))
        settings.setEnabled(false, accountID: account, isProton: true)
        XCTAssertEqual(policy(), .disabled)
        settings.setEnabled(true, accountID: account, isProton: true)
        XCTAssertEqual(policy(), .allowed)
        settings.removeAccount(account)
        XCTAssertFalse(settings.hasAccountConsent(accountID: account))
        XCTAssertEqual(policy(), .disabled)
        XCTAssertEqual(TranslationPermission.evaluate(globalEnabled: true, configured: true, accountEnabled: true,
            serviceConsent: true, isProton: true, accountConsent: false), .needsAccountConsent)
    }

    @MainActor
    func testInvalidEndpointNeverGrantsConsent() {
        for endpoint in ["", "ftp://api.example.invalid", "https://user:secret@api.example.invalid", "https://api.example.invalid?key=secret"] {
            XCTAssertNil(TranslationPrivacySettings.serviceIdentity(endpoint))
        }
    }
}
