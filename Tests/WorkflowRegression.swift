import AppKit
import SwiftUI
import UserNotifications

enum MailCache {
    static func load() -> [Mail] { [] }
    static func save(_ mails: [Mail]) {}
    static func saveChecked(_ mails: [Mail]) throws {}
    static func clear() {}
}
enum Keychain {
    static func warm() {}
    static func get(_ key: String) -> String? { "fixture-token" }
    static func set(_ key: String, _ value: String) -> Bool { true }
}
@MainActor enum MainWindow { static func show() {} }

@main @MainActor
struct WorkflowRegression {
    static func mail(_ id: String, account: String = "a@example.com", code: String? = nil) -> Mail {
        Mail(id: id, accountID: account, remoteID: id, senderName: "Test sender", senderEmail: "sender@example.com",
             subject: "Test message", snippet: "", body: "", date: Date(), isUnread: true, isStarred: false,
             bodyLoaded: false, isHTML: false, code: code)
    }
    static func account(_ id: String = "a", _ timestamp: Int?, error: String? = nil) -> ArchiveAccount {
        ArchiveAccount(email: id, backfillDone: 1, total: 1, lastSync: timestamp, lastError: error, stored: 1, kind: "imap")
    }
    static func main() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 25) { fputs("FAIL: workflow timeout\n", stderr); _exit(124) }
        // SwiftUI App.init can run before NSApp exists.
        AppAppearance.system.apply()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        UserDefaults.standard.setVolatileDomain([
            "gmailAccounts": [String](), "imapAccounts": [String](),
            "archiveURL": "http://pigi-workflow.invalid", "archiveCursor": 42,
            "archiveCursorWindow": 30, "archiveCursorSchema": ArchiveSettings.schema,
        ], forName: UserDefaults.argumentDomain)
        Task { @MainActor in
            do {
                precondition(AppAppearance.system.colorScheme == nil)
                precondition(AppAppearance.light.colorScheme == .light && AppAppearance.dark.colorScheme == .dark)
                AppAppearance.dark.apply()
                precondition(app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
                AppAppearance.light.apply()
                precondition(app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
                AppAppearance.system.apply()
                precondition(app.appearance == nil)
                print("PASS: app appearance dark/light/system")

                var polls = 0, pokes = 0, pulls = 0
                try await MailRefresher(accounts: {
                    polls += 1
                    return [account("a", polls < 3 ? 100 : 101), account("b", polls < 4 ? 100 : 101)]
                }, poke: { pokes += 1 }, pull: { pulls += 1 }, pause: {}, attempts: 5).run()
                precondition(polls == 4 && pokes == 1 && pulls == 4)
                print("PASS: refresh waits for every mailbox and pulls after completion")

                do {
                    try await MailRefresher(accounts: { [account("a", 100)] }, poke: {}, pull: {}, pause: {}, attempts: 2).run()
                    fatalError("Unchanged engine status reported success")
                } catch { precondition(error.localizedDescription.contains("仍在同步")) }
                print("PASS: refresh timeout is reported")

                do {
                    try await MailRefresher(accounts: { [] }, poke: { throw ArchiveClient.Failure(message: "poke failed") },
                                            pull: {}, pause: {}).run()
                    fatalError("Poke error was swallowed")
                } catch { precondition(error.localizedDescription == "poke failed") }
                print("PASS: refresh propagates network errors")

                var failedPolls = 0, failedPulls = 0
                do {
                    try await MailRefresher(accounts: {
                        failedPolls += 1
                        return [account("a", 100, error: failedPolls > 1 ? "login failed" : nil)]
                    }, poke: {}, pull: { failedPulls += 1 }, pause: {}).run()
                    fatalError("Account failure reported success")
                } catch { precondition(error.localizedDescription.contains("login failed")) }
                precondition(failedPulls == 2)
                print("PASS: account errors surfaced after pulling available mail")

                let requests = MailNotifier.requests(for: (0..<5).map { mail("ordinary\($0)") }
                                                    + [mail("code1", code: "123456"), mail("code2", code: " 091234 ")])
                precondition(requests.count == 3)
                let codes = requests.filter { $0.content.categoryIdentifier == MailNotifier.codeCategory }
                precondition(codes.count == 2 && Set(codes.map(\.identifier)) == ["code1", "code2"])
                precondition(codes.first { $0.identifier == "code2" }!.content.userInfo[MailNotifier.codeKey] as? String == "091234")
                precondition(MailNotifier.requests(for: [mail("empty", code: " ")]).first!.content.categoryIdentifier.isEmpty)
                let action = MailNotifier.categories.first!.actions.first!
                precondition(action.identifier == MailNotifier.copyCodeAction && action.options.contains(.authenticationRequired))
                print("PASS: batched mail retains individual verification-code actions")

                let pasteboard = NSPasteboard(name: NSPasteboard.Name("pigi-regression-\(UUID().uuidString)"))
                precondition(MailNotifier.copyVerificationCode(from: [MailNotifier.codeKey: "001234"], to: pasteboard))
                precondition(pasteboard.string(forType: .string) == "001234")
                precondition(!MailNotifier.copyVerificationCode(from: [:], to: pasteboard))
                precondition(pasteboard.string(forType: .string) == "001234")
                print("PASS: notification code copy preserves leading zeros and ignores missing payload")

                exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }
}
