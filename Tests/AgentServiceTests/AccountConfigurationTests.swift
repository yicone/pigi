import XCTest
@testable import PigiCore

final class AccountConfigurationTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var path: String { directory.appendingPathComponent("Library/Application Support/pigi/mail.db").path }
    private var config: AccountConfiguration { AccountConfiguration(path: path) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        suite = "pigi.config.tests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }

    func testMigrationPreservesRowsAndLegacyValuesWithoutResurrectingDeletedAccounts() throws {
        defaults.set(["Legacy@Example.test", "Legacy@Example.test"], forKey: "gmailAccounts")
        defaults.set(["stale@example.test"], forKey: "imapAccounts")
        defaults.set(" legacy.apps.googleusercontent.com \n", forKey: "gmailClientID")
        try config.setGmailClientID("new.apps.googleusercontent.com")
        let db = try Store(path: path)
        try db.run("INSERT INTO accounts(email,kind,imap_host,imap_port) VALUES('imap@example.test','imap','imap.invalid',993)")
        try config.migrateLegacy(defaults: defaults)
        XCTAssertEqual(try config.emails(kind: "gmail"), ["legacy@example.test"])
        XCTAssertEqual(try config.emails(kind: "imap"), ["imap@example.test"])
        XCTAssertEqual(try config.gmailClientID(), "new.apps.googleusercontent.com")
        XCTAssertEqual(try db.query("SELECT imap_host FROM accounts WHERE kind='imap'").first?["imap_host"]?.text, "imap.invalid")
        XCTAssertEqual(defaults.stringArray(forKey: "gmailAccounts"), ["Legacy@Example.test", "Legacy@Example.test"])
        XCTAssertEqual(defaults.string(forKey: "gmailClientID"), " legacy.apps.googleusercontent.com \n")
        try db.run("DELETE FROM accounts WHERE kind='gmail'")
        try config.setGmailClientID("")
        try config.migrateLegacy(defaults: defaults)
        XCTAssertEqual(try config.emails(kind: "gmail"), [])
        XCTAssertEqual(try config.gmailClientID(), "")
    }

    func testFreshMigrationImportsClientIDAndIsAtomicAndRetryable() throws {
        defaults.set(["a@example.test", "b@example.test"], forKey: "gmailAccounts")
        defaults.set(" fixture.apps.googleusercontent.com ", forKey: "gmailClientID")
        _ = try config.emails(kind: "gmail")
        let db = try Store(path: path)
        try db.run("CREATE TRIGGER reject_account BEFORE INSERT ON accounts WHEN NEW.email='b@example.test' BEGIN SELECT RAISE(ABORT,'fixture'); END")
        XCTAssertThrowsError(try config.migrateLegacy(defaults: defaults))
        XCTAssertEqual(try config.emails(kind: "gmail"), [])
        XCTAssertEqual(try config.gmailClientID(), "")
        try db.run("DROP TRIGGER reject_account")
        try config.migrateLegacy(defaults: defaults)
        XCTAssertEqual(try config.emails(kind: "gmail"), ["a@example.test", "b@example.test"])
        XCTAssertEqual(try config.gmailClientID(), "fixture.apps.googleusercontent.com")
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testFailedAccountInsertCompensatesCredentialsAndReportsFailedRecovery() throws {
        _ = try config.emails(kind: "gmail")
        let db = try Store(path: path)
        try db.run("CREATE TRIGGER reject_account BEFORE INSERT ON accounts BEGIN SELECT RAISE(ABORT,'fixture'); END")
        for rejectRecovery in [false, true] {
            var token = "old-synthetic"
            var writes = 0
            let credentials = CredentialStore(read: { _ in token }, write: { _, value in
                writes += 1
                if rejectRecovery && writes == 2 { return false }
                token = value
                return true
            })
            XCTAssertThrowsError(try config.addGmail("a@example.test", refreshToken: "new-synthetic", credentials: credentials)) {
                if rejectRecovery { XCTAssertEqual($0 as? CredentialPersistenceError, .recoveryFailed) }
            }
            XCTAssertEqual(writes, 2)
            if !rejectRecovery { XCTAssertEqual(token, "old-synthetic") }
            XCTAssertEqual(try config.emails(kind: "gmail"), [])
        }
    }

    func testIndependentCLIReadsSameConfigurationAndSeesUpdates() throws {
        defaults.set(["gmail@example.test"], forKey: "gmailAccounts")
        defaults.set("fixture.apps.googleusercontent.com", forKey: "gmailClientID")
        try config.migrateLegacy(defaults: defaults)
        let db = try Store(path: path)
        try db.run("INSERT INTO accounts(email,kind,imap_host,imap_port) VALUES('imap@example.test','imap','imap.invalid',993)")
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/pigi-config")
        func readCLI(useDefault: Bool = false) throws -> [String: Any] {
            let process = Process()
            process.executableURL = executable
            process.arguments = useDefault ? [] : ["--database", path]
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = directory.path
            env["CFFIXED_USER_HOME"] = directory.path
            env["PIGI_REGRESSION"] = "1"
            process.environment = env
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let first = try readCLI()
        XCTAssertEqual(first["gmail"] as? [String], ["gmail@example.test"])
        XCTAssertEqual(first["imap"] as? [String], ["imap@example.test"])
        XCTAssertEqual(first["gmailClientID"] as? String, "fixture.apps.googleusercontent.com")
        try config.setGmailClientID("updated.apps.googleusercontent.com")
        try db.run("DELETE FROM accounts WHERE kind='gmail'")
        let next = try readCLI(useDefault: true)
        XCTAssertEqual(next["gmail"] as? [String], [])
        XCTAssertEqual(next["gmailClientID"] as? String, "updated.apps.googleusercontent.com")
    }

    func testMixedCaseLegacyAndSyncedRowKeepCacheAndCredentialAliasThenDeleteAndRestart() async throws {
        defaults.set(["Legacy@Example.test"], forKey: "gmailAccounts")
        _ = try config.emails(kind: "gmail")
        let db = try Store(path: path)
        try db.run("INSERT INTO accounts(email,kind,history_id,page_token,total) VALUES('legacy@example.test','gmail','history-123','page-456',42)")
        try db.run("INSERT INTO messages(account,id,html) VALUES('legacy@example.test','cached',?)", [.blob(Data("cached-body".utf8))])
        let rowid = try XCTUnwrap(db.query("SELECT rowid FROM messages").first?["rowid"]?.int)
        try db.run("INSERT INTO fts(rowid,subject) VALUES(?,'retained')", [.int(rowid)])
        var secrets = ["gmail-refresh-Legacy@Example.test": "synthetic-original"]
        let credentials = CredentialStore(read: { secrets[$0] }, write: { key, value in
            secrets[key] = value.isEmpty ? nil : value; return true
        })
        try config.migrateLegacy(defaults: defaults)
        XCTAssertEqual(try config.emails(kind: "gmail"), ["legacy@example.test"])
        XCTAssertEqual(try config.refreshToken(for: "legacy@example.test", credentials: credentials), "synthetic-original")
        XCTAssertEqual(try db.query("SELECT history_id FROM accounts").first?["history_id"]?.text, "history-123")
        XCTAssertEqual(try db.query("SELECT page_token FROM accounts").first?["page_token"]?.text, "page-456")
        XCTAssertEqual(try db.query("SELECT rowid FROM messages").first?["rowid"]?.int, rowid)
        XCTAssertEqual(try db.query("SELECT subject FROM fts WHERE rowid=?", [.int(rowid)]).first?["subject"]?.text, "retained")
        try config.replaceRefreshToken("synthetic-rotated", for: "legacy@example.test", credentials: credentials)
        XCTAssertEqual(secrets["gmail-refresh-Legacy@Example.test"], "synthetic-rotated")
        XCTAssertNil(secrets["gmail-refresh-legacy@example.test"])
        let engine = LocalEngine(credentials: credentials)
        try await engine.installConfigurationFixture(path: path)
        let privacySuite = suite!
        let privacy = await MainActor.run { TranslationPrivacySettings(defaults: UserDefaults(suiteName: privacySuite)!) }
        try await engine.deleteAccount("legacy@example.test", privacy: privacy)
        let restarted = AccountConfiguration(path: path)
        try restarted.migrateLegacy(defaults: defaults)
        XCTAssertEqual(try restarted.emails(kind: "gmail"), [])
        XCTAssertTrue(try db.query("SELECT * FROM messages").isEmpty)
        XCTAssertTrue(try db.query("SELECT * FROM fts").isEmpty)
        XCTAssertTrue(try db.query("SELECT * FROM gmail_credential_aliases").isEmpty)
        XCTAssertTrue(try db.query("SELECT * FROM gmail_legacy_state").isEmpty)
        XCTAssertTrue(secrets.isEmpty)
    }

    func testRejectedAliasDeletionThrowsAndPreservesRetryRecords() async throws {
        let fixture = try makeDeletionFixture()
        fixture.rejected.insert("gmail-refresh-Legacy@Example.test")
        let engine = LocalEngine(credentials: fixture.credentials)
        try await engine.installConfigurationFixture(path: path)
        let privacy = await deletionPrivacy()
        do {
            try await engine.deleteAccount("legacy@example.test", privacy: privacy)
            XCTFail("Credential rejection must be returned to the caller")
        } catch {
            XCTAssertEqual(error as? CredentialPersistenceError, .deleteFailed)
            XCTAssertFalse(error.localizedDescription.contains("Legacy@"))
            XCTAssertFalse(error.localizedDescription.contains("synthetic"))
        }
        try assertDeletionRetryRecordsRetained()
        XCTAssertEqual(fixture.secrets.count, 3)
    }

    func testDeletionRetryCompletesAfterPartialCredentialCleanupRecovers() async throws {
        let fixture = try makeDeletionFixture()
        fixture.rejected.insert("gmail-refresh-LEGACY@example.test")
        let engine = LocalEngine(credentials: fixture.credentials)
        try await engine.installConfigurationFixture(path: path)
        let privacy = await deletionPrivacy()
        do {
            try await engine.deleteAccount("legacy@example.test", privacy: privacy)
            XCTFail("Expected partial credential cleanup failure")
        } catch { XCTAssertEqual(error as? CredentialPersistenceError, .deleteFailed) }
        XCTAssertNil(fixture.secrets["gmail-refresh-Legacy@Example.test"], "Never restore a secret already removed by the user")
        XCTAssertEqual(fixture.secrets.count, 2)
        try assertDeletionRetryRecordsRetained()
        fixture.rejected.removeAll()
        try await engine.deleteAccount("legacy@example.test", privacy: privacy)
        try assertDeletionCompleted(fixture)
        XCTAssertGreaterThan(fixture.attempts.filter { $0 == "gmail-refresh-Legacy@Example.test" }.count, 1,
                             "Retry must safely revisit aliases whose secrets were already removed")
    }

    func testFailedCredentialDeletionCanBeRetriedAfterEngineAndConfigurationRestart() async throws {
        let fixture = try makeDeletionFixture()
        fixture.rejected.insert("gmail-refresh-Legacy@Example.test")
        let first = LocalEngine(credentials: fixture.credentials)
        try await first.installConfigurationFixture(path: path)
        let privacy = await deletionPrivacy()
        do {
            try await first.deleteAccount("legacy@example.test", privacy: privacy)
            XCTFail("Expected deletion failure")
        } catch { XCTAssertEqual(error as? CredentialPersistenceError, .deleteFailed) }
        // Reopen the on-disk configuration and a new engine connection. No
        // in-memory pending-deletion list is needed to recover the alias keys.
        let restarted = AccountConfiguration(path: path)
        try restarted.migrateLegacy(defaults: defaults)
        try assertDeletionRetryRecordsRetained()
        XCTAssertEqual(try restarted.refreshToken(for: "legacy@example.test", credentials: fixture.credentials), "synthetic-original")
        fixture.rejected.removeAll()
        let second = LocalEngine(credentials: fixture.credentials)
        try await second.installConfigurationFixture(path: path)
        try await second.deleteAccount("legacy@example.test", privacy: privacy)
        try assertDeletionCompleted(fixture)
        let finalRestart = AccountConfiguration(path: path)
        try finalRestart.migrateLegacy(defaults: defaults)
        XCTAssertEqual(try finalRestart.emails(kind: "gmail"), [])
    }

    func testDatabaseDeleteFailureKeepsAliasRecordsForRetryWithoutRestoringSecrets() async throws {
        let fixture = try makeDeletionFixture()
        let db = try Store(path: path)
        try db.run("CREATE TRIGGER reject_delete BEFORE DELETE ON accounts BEGIN SELECT RAISE(ABORT,'synthetic database failure'); END")
        let engine = LocalEngine(credentials: fixture.credentials)
        try await engine.installConfigurationFixture(path: path)
        let privacy = await deletionPrivacy()
        do {
            try await engine.deleteAccount("legacy@example.test", privacy: privacy)
            XCTFail("Expected database deletion failure")
        } catch { XCTAssertTrue(error is SQLError) }
        XCTAssertTrue(fixture.secrets.isEmpty)
        try assertDeletionRetryRecordsRetained()
        try db.run("DROP TRIGGER reject_delete")
        try await engine.deleteAccount("legacy@example.test", privacy: privacy)
        try assertDeletionCompleted(fixture)
    }

    func testOtherMailboxKindsAlsoReportCredentialDeletionFailureBeforeRemovingRows() async throws {
        _ = try config.emails(kind: "gmail")
        let db = try Store(path: path)
        let privacy = await deletionPrivacy()
        for kind in ["imap", "proton"] {
            let email = "\(kind)@example.test"
            let key = kind == "imap" ? "imap-\(email)" : ProtonSession.key(email)
            try db.run("INSERT INTO accounts(email,kind) VALUES(?,?)", [.text(email), .text(kind)])
            var reject = true
            var secret: String? = "synthetic"
            var attempted: [String] = []
            let credentials = CredentialStore(read: { _ in secret }, write: { actual, value in
                attempted.append(actual)
                guard !reject else { return false }
                secret = value.isEmpty ? nil : value
                return true
            })
            let engine = LocalEngine(credentials: credentials)
            try await engine.installConfigurationFixture(path: path)
            do {
                try await engine.deleteAccount(email, privacy: privacy)
                XCTFail("Expected rejected \(kind) credential cleanup")
            } catch { XCTAssertEqual(error as? CredentialPersistenceError, .deleteFailed) }
            XCTAssertEqual(try config.emails(kind: kind), [email])
            XCTAssertNotNil(secret)
            reject = false
            try await engine.deleteAccount(email, privacy: privacy)
            XCTAssertEqual(try config.emails(kind: kind), [])
            XCTAssertNil(secret)
            XCTAssertEqual(attempted, [key, key], "Do not clear credentials belonging to a different account kind")
        }
    }

    private func makeDeletionFixture() throws -> DeletionCredentials {
        defaults.set(["Legacy@Example.test", "LEGACY@example.test"], forKey: "gmailAccounts")
        _ = try config.emails(kind: "gmail")
        let db = try Store(path: path)
        try db.run("INSERT INTO accounts(email,kind,history_id,page_token) VALUES('legacy@example.test','gmail','retained-history','retained-page')")
        try db.run("INSERT INTO messages(account,id,html) VALUES('legacy@example.test','cached',?)", [.blob(Data("retained-body".utf8))])
        let rowid = try XCTUnwrap(db.query("SELECT rowid FROM messages").first?["rowid"]?.int)
        try db.run("INSERT INTO fts(rowid,subject) VALUES(?,'retained')", [.int(rowid)])
        try config.migrateLegacy(defaults: defaults)
        return DeletionCredentials()
    }

    private func deletionPrivacy() async -> TranslationPrivacySettings {
        let privacySuite = suite!
        return await MainActor.run { TranslationPrivacySettings(defaults: UserDefaults(suiteName: privacySuite)!) }
    }

    private func assertDeletionRetryRecordsRetained() throws {
        let db = try Store(path: path)
        XCTAssertEqual(try config.emails(kind: "gmail"), ["legacy@example.test"])
        XCTAssertEqual(try db.query("SELECT * FROM gmail_credential_aliases").count, 3)
        XCTAssertEqual(try db.query("SELECT * FROM gmail_legacy_state").count, 1)
        XCTAssertEqual(try db.query("SELECT html FROM messages").first?["html"]?.blob, Data("retained-body".utf8))
        XCTAssertEqual(try db.query("SELECT * FROM fts").count, 1)
        XCTAssertEqual(try db.query("SELECT history_id FROM accounts").first?["history_id"]?.text, "retained-history")
        XCTAssertEqual(try db.query("SELECT page_token FROM accounts").first?["page_token"]?.text, "retained-page")
    }

    private func assertDeletionCompleted(_ fixture: DeletionCredentials) throws {
        let db = try Store(path: path)
        XCTAssertEqual(try config.emails(kind: "gmail"), [])
        for table in ["gmail_credential_aliases", "gmail_legacy_state", "messages", "fts"] {
            XCTAssertTrue(try db.query("SELECT * FROM \(table)").isEmpty)
        }
        XCTAssertTrue(fixture.secrets.isEmpty)
    }

    func testDuplicateCaseCachesMergeWithoutLosingRowsFTSOrCursorMetadata() throws {
        defaults.set(["Legacy@Example.test", "LEGACY@example.test"], forKey: "gmailAccounts")
        _ = try config.emails(kind: "gmail")
        let db = try Store(path: path)
        for (id, history) in [("legacy@example.test", "canonical-history"), ("Legacy@Example.test", "other-history")] {
            try db.run("INSERT INTO accounts(email,kind,history_id) VALUES(?,'gmail',?)", [.text(id), .text(history)])
        }
        try db.run("INSERT INTO messages(account,id,subject) VALUES('legacy@example.test','shared','canonical')")
        try db.run("INSERT INTO messages(account,id,html) VALUES('Legacy@Example.test','shared',?)", [.blob(Data("body".utf8))])
        try db.run("INSERT INTO messages(account,id,subject) VALUES('Legacy@Example.test','unique','unique')")
        for row in try db.query("SELECT rowid FROM messages") {
            try db.run("INSERT INTO fts(rowid,subject) VALUES(?,'searchable')", [.int(row["rowid"]!.int!)])
        }
        try db.run("DELETE FROM fts WHERE rowid=(SELECT rowid FROM messages WHERE account='legacy@example.test' AND id='shared')")
        try db.run("UPDATE fts SET body='needle' WHERE rowid=(SELECT rowid FROM messages WHERE account='Legacy@Example.test' AND id='shared')")
        try db.run("INSERT INTO agent_permissions VALUES('legacy@example.test',1,1,1)")
        try db.run("INSERT INTO agent_permissions VALUES('Legacy@Example.test',0,1,0)")
        try config.migrateLegacy(defaults: defaults)
        XCTAssertEqual(try config.emails(kind: "gmail"), ["legacy@example.test"])
        XCTAssertEqual(try db.query("SELECT history_id FROM accounts").first?["history_id"]?.text, "canonical-history")
        XCTAssertEqual(try db.query("SELECT * FROM messages WHERE account='legacy@example.test'").count, 2)
        XCTAssertEqual(try db.query("SELECT html FROM messages WHERE id='shared'").first?["html"]?.blob, Data("body".utf8))
        XCTAssertEqual(try db.query("SELECT * FROM fts").count, 2)
        XCTAssertEqual(try db.query("SELECT * FROM fts WHERE fts MATCH 'needle'").count, 1)
        let saved = try XCTUnwrap(db.query("SELECT metadata FROM gmail_legacy_state WHERE identifier='Legacy@Example.test'").first?["metadata"]?.blob)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: saved)["history_id"], "other-history")
        XCTAssertEqual(try db.query("SELECT read FROM agent_permissions").first?["read"]?.int, 0)
        let credentials = CredentialStore(read: { $0 == "gmail-refresh-LEGACY@example.test" ? "synthetic-fallback" : nil }, write: { _, _ in XCTFail("Migration must never rewrite secrets"); return false })
        XCTAssertEqual(try config.refreshToken(for: "legacy@example.test", credentials: credentials), "synthetic-fallback")
    }

    func testCollisionMergeFailureRollsBackAndCanRetry() throws {
        defaults.set(["Legacy@Example.test"], forKey: "gmailAccounts")
        _ = try config.emails(kind: "gmail")
        let db = try Store(path: path)
        try db.run("INSERT INTO accounts(email,kind,history_id) VALUES('legacy@example.test','gmail','keep'),('Legacy@Example.test','gmail','also-keep')")
        try db.run("INSERT INTO messages(account,id) VALUES('Legacy@Example.test','cached')")
        try db.run("CREATE TRIGGER reject_merge BEFORE INSERT ON account_config WHEN NEW.key='legacy-v2' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
        XCTAssertThrowsError(try config.migrateLegacy(defaults: defaults))
        XCTAssertEqual(try config.emails(kind: "gmail").count, 2)
        XCTAssertEqual(try db.query("SELECT account FROM messages").first?["account"]?.text, "Legacy@Example.test")
        XCTAssertTrue(try db.query("SELECT * FROM gmail_credential_aliases").isEmpty)
        XCTAssertTrue(try db.query("SELECT * FROM gmail_legacy_state").isEmpty)
        XCTAssertTrue(try db.query("SELECT * FROM account_config WHERE key LIKE 'legacy-%'").isEmpty)
        try db.run("DROP TRIGGER reject_merge")
        try config.migrateLegacy(defaults: defaults)
        XCTAssertEqual(try config.emails(kind: "gmail"), ["legacy@example.test"])
        XCTAssertEqual(try db.query("SELECT account FROM messages").first?["account"]?.text, "legacy@example.test")
    }

    func testVersionOneRepairMergesButDoesNotReimportDeletedMailboxes() throws {
        defaults.set(["Legacy@Example.test", "deleted@example.test"], forKey: "gmailAccounts")
        _ = try config.emails(kind: "gmail")
        let db = try Store(path: path)
        try db.run("INSERT INTO account_config VALUES('legacy-v1','1')")
        try db.run("INSERT INTO accounts(email,kind) VALUES('legacy@example.test','gmail'),('Legacy@Example.test','gmail')")
        try config.migrateLegacy(defaults: defaults)
        XCTAssertEqual(try config.emails(kind: "gmail"), ["legacy@example.test"])
        try db.run("DELETE FROM accounts")
        try config.migrateLegacy(defaults: defaults)
        XCTAssertEqual(try config.emails(kind: "gmail"), [])
    }

    func testPreferenceOnlyAndDatabaseOnlyVariantsUseOneLogicalMailbox() throws {
        defaults.set(["Upper@Example.test", "upper@example.test"], forKey: "gmailAccounts")
        _ = try config.emails(kind: "gmail")
        let db = try Store(path: path)
        try db.run("INSERT INTO accounts(email,kind,history_id) VALUES('Other@Example.test','gmail','preserved')")
        try config.migrateLegacy(defaults: defaults)
        XCTAssertEqual(Set(try config.emails(kind: "gmail")), ["upper@example.test", "other@example.test"])
        XCTAssertEqual(try db.query("SELECT history_id FROM accounts WHERE email='other@example.test'").first?["history_id"]?.text, "preserved")
    }

    func testPopulatedVariantSuppliesCursorToEmptyCanonicalShell() throws {
        _ = try config.emails(kind: "gmail")
        let db = try Store(path: path)
        try db.run("INSERT INTO accounts(email,kind) VALUES('legacy@example.test','gmail')")
        try db.run("INSERT INTO accounts(email,kind,history_id,page_token,backfill_done) VALUES('Legacy@Example.test','gmail','kept-history','kept-page',1)")
        try config.migrateLegacy(defaults: defaults)
        let row = try XCTUnwrap(db.query("SELECT * FROM accounts").first)
        XCTAssertEqual(row["history_id"]?.text, "kept-history")
        XCTAssertEqual(row["page_token"]?.text, "kept-page")
        XCTAssertEqual(row["backfill_done"]?.int, 1)
    }

    func testCrossKindCollisionFailsWithoutChangingIMAPOrCredentials() throws {
        defaults.set(["Imap@Example.test"], forKey: "gmailAccounts")
        _ = try config.emails(kind: "gmail")
        let db = try Store(path: path)
        try db.run("INSERT INTO accounts(email,kind,imap_host,imap_port) VALUES('imap@example.test','imap','keep.invalid',993)")
        XCTAssertThrowsError(try config.migrateLegacy(defaults: defaults))
        XCTAssertEqual(try config.emails(kind: "imap"), ["imap@example.test"])
        XCTAssertEqual(try db.query("SELECT imap_host FROM accounts").first?["imap_host"]?.text, "keep.invalid")
        XCTAssertTrue(try db.query("SELECT * FROM account_config WHERE key LIKE 'legacy-%'").isEmpty)
    }

    func testUnreadableConfigurationThrowsWithoutTouchingCredentials() throws {
        let invalid = AccountConfiguration(path: directory.appendingPathComponent("missing/mail.db").path)
        var reads = 0
        var writes = 0
        let credentials = CredentialStore(read: { _ in reads += 1; return nil }, write: { _, _ in writes += 1; return true })
        XCTAssertThrowsError(try invalid.addGmail("a@example.test", refreshToken: "synthetic", credentials: credentials))
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(writes, 0)
    }
}

private extension LocalEngine {
    func installConfigurationFixture(path: String) throws {
        store = try Store(path: path)
        translationCache = SQLiteTranslationCache(path: ":memory:")
    }
}

private final class DeletionCredentials {
    var secrets = ["gmail-refresh-Legacy@Example.test": "synthetic-original",
                   "gmail-refresh-LEGACY@example.test": "synthetic-second",
                   "gmail-refresh-legacy@example.test": "synthetic-canonical"]
    var rejected: Set<String> = []
    var attempts: [String] = []
    var credentials: CredentialStore {
        CredentialStore(read: { self.secrets[$0] }, write: { key, value in
            self.attempts.append(key)
            if value.isEmpty && self.rejected.contains(key) { return false }
            self.secrets[key] = value.isEmpty ? nil : value
            return true
        })
    }
}
