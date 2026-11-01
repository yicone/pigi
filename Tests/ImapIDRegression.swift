import Foundation

@main
struct ImapIDRegression {
    static func main() async throws {
        let port = Int(CommandLine.arguments[1])!
        let operation = CommandLine.arguments[2]
        let expectedError = CommandLine.arguments[3]
        let connection = ImapConnection(host: "127.0.0.1", port: port)
        defer { connection.close() }
        try await connection.open()
        do {
            try await connection.login(user: "fixture@example.com", password: "fixture-password")
            precondition(expectedError.isEmpty, "Login should have failed")
        } catch {
            guard !expectedError.isEmpty, error.localizedDescription.contains(expectedError) else { throw error }
            return
        }
        switch operation {
        case "probe": break
        case "sync":
            let validity = try await connection.select("INBOX")
            precondition(validity == "123")
            let uids = try await connection.search("ALL")
            precondition(uids == [1])
            let messages = try await connection.fetch(uids, items: "UID FLAGS")
            precondition(messages.count == 1 && messages[0].flags.contains("\\seen"))
        case "flags":
            _ = try await connection.select("INBOX")
            try await connection.command("UID STORE 1 +FLAGS (\\Seen)")
            let folders = try await connection.folders()
            precondition(folders.map(\.name) == ["INBOX"])
        default: fatalError("Unknown operation")
        }
        await connection.logout()
    }
}
