import XCTest
@testable import PigiCore

final class CredentialReadRegressionTests: XCTestCase {
    private let email = "synthetic@example.test"
    private let password = "synthetic-password"

    private var failedReads: [(String) throws -> String?] {
        [ { _ in nil }, { _ in "" }, { _ in throw NSError(domain: "synthetic-backend", code: -50) } ]
    }

    func testGmailReadFailuresStopBeforeRefreshAndPersistKeychainError() async throws {
        for read in failedReads {
            let credentials = CredentialStore(read: read)
            let engine = LocalEngine(credentials: credentials)
            try await engine.prepareReadRegression(email, kind: "gmail")
            // Exercise the engine-created session too: it must use the injected store.
            let created = await engine.session(email)
            do {
                _ = try await created.call("profile")
                XCTFail("Expected local credential failure")
            } catch {
                XCTAssertEqual(error as? CredentialPersistenceError, .readFailed)
            }
            let session = GmailSession(email: email, credentials: credentials, refreshToken: { _ in
                XCTFail("A missing credential must never reach Google refresh")
                throw GmailAuth.AuthError.denied("invalid_grant")
            })
            await engine.installReadRegression(session, email: email)
            let delay = await engine.syncGmail(email)
            XCTAssertEqual(delay, 120)
            try await assertStoredError(engine, kind: .keychain, message: CredentialPersistenceError.readFailed.localizedDescription)
        }
    }

    func testGmailServerInvalidGrantRemainsAuthError() async throws {
        let engine = LocalEngine()
        try await engine.prepareReadRegression(email, kind: "gmail")
        let session = GmailSession(email: email, credentials: CredentialStore(read: { _ in "synthetic-refresh" }), refreshToken: { value in
            XCTAssertEqual(value, "synthetic-refresh")
            throw GmailAuth.AuthError.denied("invalid_grant")
        })
        await engine.installReadRegression(session, email: email)
        let delay = await engine.syncGmail(email)
        XCTAssertEqual(delay, 3600)
        try await assertStoredError(engine, kind: .auth, message: GmailRevoked().localizedDescription)
    }

    func testIMAPReadFailuresStopBeforeConnectionAndPersistKeychainError() async throws {
        for read in failedReads {
            let engine = LocalEngine(credentials: CredentialStore(read: read))
            try await engine.prepareReadRegression(email, kind: "imap")
            await engine.setReadRegressionAuthentication { _, _, _ in
                XCTFail("A missing password must never open or LOGIN to IMAP")
                throw ImapError(message: "登录失败: synthetic refusal")
            }
            let delay = await engine.syncIMAP(email)
            XCTAssertEqual(delay, 300)
            try await assertStoredError(engine, kind: .keychain, message: CredentialPersistenceError.readFailed.localizedDescription)
        }
    }

    func testIMAPServerRefusalRemainsAuthError() async throws {
        let email = self.email
        let password = self.password
        let engine = LocalEngine(credentials: CredentialStore(read: { _ in password }))
        try await engine.prepareReadRegression(email, kind: "imap")
        let message = "登录失败: synthetic refusal"
        await engine.setReadRegressionAuthentication { _, user, suppliedPassword in
            XCTAssertEqual(user, email)
            XCTAssertEqual(suppliedPassword, password)
            throw ImapError(message: message)
        }
        let delay = await engine.syncIMAP(email)
        XCTAssertEqual(delay, 300)
        try await assertStoredError(engine, kind: .auth, message: message)
    }

    private func assertStoredError(_ engine: LocalEngine, kind: AccountErrorKind, message: String) async throws {
        let row = try await engine.account(email)
        XCTAssertEqual(row?["last_error_kind"]?.text, kind.rawValue)
        XCTAssertEqual(row?["last_error"]?.text, message)
        if kind == .keychain {
            XCTAssertFalse(message.contains("授权已失效"))
            XCTAssertFalse(message.contains("登录失败"))
            XCTAssertFalse(message.contains(email))
            XCTAssertFalse(message.contains(password))
            XCTAssertFalse(message.contains("synthetic-backend"))
        }
    }
}

private extension LocalEngine {
    func prepareReadRegression(_ email: String, kind: String) throws {
        let memory = try Store(path: ":memory:")
        for sql in Self.schema { try memory.run(sql) }
        store = memory
        try memory.run("INSERT INTO accounts(email,kind,imap_host,imap_port) VALUES(?,?,?,?)",
                       [.text(email), .text(kind), .text("fixture.invalid"), .int(993)])
    }

    func installReadRegression(_ session: GmailSession, email: String) { sessions[email] = session }

    func setReadRegressionAuthentication(_ authenticate: @escaping @Sendable (ImapConnection, String, String) async throws -> Void) {
        imapAuthenticate = authenticate
    }
}
