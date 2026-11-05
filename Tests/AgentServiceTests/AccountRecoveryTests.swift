import XCTest
@testable import PigiCore

private extension LocalEngine {
    func seedAccount(email: String, kind: String) throws {
        let memory = try Store(path: ":memory:")
        for statement in Self.schema { try memory.run(statement) }
        store = memory
        try memory.run("INSERT INTO accounts(email,kind) VALUES(?,?)", [.text(email), .text(kind)])
    }

    func installSession(_ session: GmailSession, email: String) { sessions[email] = session }
}

final class AccountRecoveryTests: XCTestCase {
    func testIsSameMailbox() {
        XCTAssertTrue(GmailStore.isSameMailbox("A@Example.com", " a@example.COM "))
        XCTAssertTrue(GmailStore.isSameMailbox("demo@example.com", "demo@example.com"))
        XCTAssertFalse(GmailStore.isSameMailbox("a@example.com", "b@example.com"))
        XCTAssertFalse(GmailStore.isSameMailbox("a@example.com", "a@example.com.evil"))
    }

    /// An unknown mailbox must be refused before the keychain is touched.
    func testReplaceRefreshTokenRefusesUnknownMailbox() {
        let key = "gmailAccounts"
        let defaults = UserDefaults.standard
        let saved = defaults.stringArray(forKey: key)
        defer { defaults.set(saved, forKey: key) }
        defaults.set(["a@example.test"], forKey: key)
        XCTAssertFalse(GmailStore.replaceRefreshToken("token", for: "b@example.test"))
        XCTAssertFalse(GmailStore.replaceRefreshToken("token", for: "a@example.test "))
    }

    /// A different or token-less sign-in is refused before any keychain write.
    func testApplyReauthorizationRefusesBeforeWriting() {
        XCTAssertEqual(GmailStore.applyReauthorization(authorizedEmail: "b@example.test", refreshToken: "t", for: "a@example.test"), .differentMailbox)
        XCTAssertEqual(GmailStore.applyReauthorization(authorizedEmail: "a@example.test", refreshToken: nil, for: "a@example.test"), .noRefreshToken)
    }

    /// Password rotation must stop at the guards: no connection, no keychain write.
    func testUpdateIMAPPasswordGuards() async throws {
        let engine = LocalEngine()
        try await engine.seedAccount(email: "a@example.test", kind: "gmail")
        await assertUpdateFails(engine, email: "a@example.test", password: "x", expected: "没有这个 IMAP 邮箱")
        await assertUpdateFails(engine, email: "ghost@example.test", password: "x", expected: "没有这个 IMAP 邮箱")
        await assertUpdateFails(engine, email: "a@example.test", password: "", expected: "密码不能为空")
    }

    /// Re-auth drops the cached session so the next sync re-reads the refresh token.
    func testResetGmailSessionDropsCachedSession() async throws {
        let engine = LocalEngine()
        try await engine.seedAccount(email: "a@example.test", kind: "gmail")
        await engine.installSession(GmailSession(email: "a@example.test"), email: "a@example.test")
        let cached = await engine.sessions["a@example.test"]
        XCTAssertNotNil(cached)
        await engine.resetGmailSession("a@example.test")
        let dropped = await engine.sessions["a@example.test"]
        XCTAssertNil(dropped)
    }

    private func assertUpdateFails(_ engine: LocalEngine, email: String, password: String, expected: String,
                                   file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await engine.updateIMAPPassword(email: email, password: password)
            XCTFail("expected '\(expected)'", file: file, line: line)
        } catch let error as ArchiveClient.Failure {
            XCTAssertEqual(error.message, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}
