import XCTest
@testable import PigiCore

final class CredentialPersistenceTests: XCTestCase {
    private let email = "synthetic@example.test"

    func testGmailFailedWriteDoesNotRegisterOrReplaceAccount() throws {
        let suite = "pigi.credential-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = CredentialFixture()
        fixture.rejectWrites = true
        defaults.set(["existing@example.test"], forKey: "gmailAccounts")
        for address in [email, "existing@example.test"] {
            XCTAssertThrowsError(try GmailStore.add(address, refreshToken: "synthetic-new", defaults: defaults, credentials: fixture.store)) {
                XCTAssertEqual($0 as? CredentialPersistenceError, .writeFailed)
            }
            XCTAssertEqual(defaults.stringArray(forKey: "gmailAccounts"), ["existing@example.test"])
        }
        XCTAssertTrue(fixture.values.isEmpty)
        fixture.rejectWrites = false
        try GmailStore.add(email, refreshToken: "synthetic-new", defaults: defaults, credentials: fixture.store)
        try GmailStore.add(email, refreshToken: "synthetic-replaced", defaults: defaults, credentials: fixture.store)
        XCTAssertEqual(defaults.stringArray(forKey: "gmailAccounts"), ["existing@example.test", email])
        XCTAssertEqual(fixture.values[GmailStore.keychainKey(email)], "synthetic-replaced")
    }

    func testIMAPFailedWriteDoesNotRegisterOrQueueSync() async throws {
        let fixture = CredentialFixture()
        let engine = LocalEngine(credentials: fixture.store)
        try await engine.prepareCredentialTest()
        fixture.rejectWrites = true
        do {
            try await engine.saveIMAPAccount(email, password: "synthetic-password", host: "fixture.invalid", port: 993)
            XCTFail("Expected credential save failure")
        } catch {
            XCTAssertEqual(error as? CredentialPersistenceError, .writeFailed)
        }
        let missing = try await engine.account(email)
        let queued = await engine.due[email]
        XCTAssertNil(missing)
        XCTAssertNil(queued)
        fixture.rejectWrites = false
        try await engine.saveIMAPAccount(email, password: "synthetic-password", host: "fixture.invalid", port: 993)
        let saved = try await engine.account(email)
        let scheduled = await engine.due[email]
        XCTAssertEqual(saved?["kind"]?.text, "imap")
        XCTAssertNotNil(scheduled)
    }

    func testProtonFailedInitialWriteRollsBackAccountAndKeepsPreviousSession() async throws {
        let fixture = CredentialFixture()
        let engine = LocalEngine(credentials: fixture.store)
        try await engine.prepareCredentialTest()
        fixture.rejectWrites = true
        let remote = session(fixture, refresh: "synthetic-new")
        do {
            try await engine.installProton(remote)
            XCTFail("Expected credential save failure")
        } catch {
            XCTAssertEqual(error as? CredentialPersistenceError, .writeFailed)
        }
        let missing = try await engine.account(email)
        let queued = await engine.due[email]
        XCTAssertNil(missing)
        XCTAssertNil(queued)

        fixture.rejectWrites = false
        let previous = session(fixture, refresh: "synthetic-old")
        try await engine.installProton(previous)
        let original = fixture.values
        fixture.rejectWrites = true
        do {
            try await engine.installProton(session(fixture, refresh: "synthetic-new"))
            XCTFail("Expected credential replacement failure")
        } catch {
            XCTAssertEqual(error as? CredentialPersistenceError, .writeFailed)
        }
        XCTAssertEqual(fixture.values, original)
        let kept = await engine.protonSessions[email]
        XCTAssertTrue(kept === previous)
    }

    func testProtonDatabaseCommitFailureChecksCompensation() async throws {
        for rejectRollback in [false, true] {
            let fixture = CredentialFixture()
            let key = ProtonSession.key(email)
            fixture.values[key] = "synthetic-old"
            fixture.rejectRollback = rejectRollback
            let engine = LocalEngine(credentials: fixture.store)
            try await engine.prepareCredentialTest(failCommit: true)
            do {
                try await engine.installProton(session(fixture, refresh: "synthetic-new"))
                XCTFail("Expected database commit failure")
            } catch {
                if rejectRollback {
                    XCTAssertEqual(error as? CredentialPersistenceError, .recoveryFailed)
                } else {
                    XCTAssertFalse(error is CredentialPersistenceError)
                }
            }
            XCTAssertEqual(fixture.writeCount, 2, "A saved secret must be compensated after the transaction fails")
            if !rejectRollback { XCTAssertEqual(fixture.values[key], "synthetic-old") }
            let missing = try await engine.account(email)
            let cached = await engine.protonSessions[email]
            let queued = await engine.due[email]
            XCTAssertNil(missing)
            XCTAssertNil(cached)
            XCTAssertNil(queued)
        }
    }

    func testCredentialErrorsAreExplicitAndRedacted() {
        for error in [CredentialPersistenceError.writeFailed, .recoveryFailed] {
            XCTAssertTrue(error.localizedDescription.contains("失败"))
            XCTAssertTrue(error.localizedDescription.contains("钥匙串"))
            XCTAssertFalse(error.localizedDescription.contains(email))
            XCTAssertFalse(error.localizedDescription.contains("synthetic-password"))
        }
    }

    private func session(_ fixture: CredentialFixture, refresh: String) -> ProtonSession {
        ProtonSession(client: ProtonHelperClient(executable: URL(fileURLWithPath: "/nonexistent-fixture-helper")),
                      email: email, credentials: fixture.store,
                      initialSecret: .init(uid: "synthetic", access: "synthetic", refresh: refresh, salted: "synthetic", email: email))
    }
}

private final class CredentialFixture {
    var values: [String: String] = [:]
    var rejectWrites = false
    var rejectRollback = false
    var writeCount = 0
    var store: CredentialStore {
        CredentialStore(read: { self.values[$0] }, write: { key, value in
            self.writeCount += 1
            guard !self.rejectWrites, !(self.rejectRollback && self.writeCount > 1) else { return false }
            self.values[key] = value.isEmpty ? nil : value
            return true
        })
    }
}

private extension LocalEngine {
    func prepareCredentialTest(failCommit: Bool = false) throws {
        let memory = try Store(path: ":memory:")
        for sql in Self.schema { try memory.run(sql) }
        if failCommit {
            // A deferred FK fails COMMIT after the keychain save, not INSERT.
            try memory.run("PRAGMA foreign_keys=ON")
            try memory.run("CREATE TABLE parent(id INTEGER PRIMARY KEY)")
            try memory.run("CREATE TABLE child(id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED)")
            try memory.run("CREATE TRIGGER fail_commit AFTER INSERT ON accounts BEGIN INSERT INTO child VALUES(1); END")
        }
        store = memory
    }
}
