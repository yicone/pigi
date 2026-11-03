import AppKit
import SwiftUI

// Test replacements keep layout regression runs away from real mail and sync.
enum MailCache {
    static func load() -> [Mail] {
        let unread = Int(CommandLine.arguments[1])!
        return (0..<120).map { index in
            Mail(id: "fixture#\(index)", accountID: "fixture@example.com", remoteID: "\(index)",
                 senderName: "Test sender", senderEmail: "sender@example.com",
                 subject: "Message \(index)", snippet: "Layout regression fixture", body: "",
                 date: Date().addingTimeInterval(-Double(index) * 60), isUnread: index < unread,
                 isStarred: false, bodyLoaded: false, isHTML: false)
        }
    }

    static func save(_ mails: [Mail]) {}
    static func saveChecked(_ mails: [Mail]) throws {}
    static func clear() {}
}

@MainActor
enum MainWindow {
    static func show() {}
}

extension LocalEngine {
    func installLayoutFixture() throws {
        let fixture = try Store(path: ":memory:")
        for statement in Self.schema { try fixture.run(statement) }
        store = fixture
    }
}

@main
@MainActor
struct PanelLayoutRegression {
    static func main() {
        // The original bug never returns to the main run loop. Fail from another
        // queue so a recurrence cannot hang the test runner indefinitely.
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            fputs("FAIL: menu panel blocked the main thread\n", stderr)
            _exit(124)
        }

        let scope = CommandLine.arguments[2]
        UserDefaults.standard.setVolatileDomain([
            "panelScope": scope == "account" ? "fixture@example.com" : "all",
            "gmailAccounts": ["fixture@example.com"],
            "imapAccounts": [String](),
            "hiddenAccounts": [String](),
            "gmailAvatars": [String: String](),
            "accountAliases": [String: String](),
            "archiveURL": "",
        ], forName: UserDefaults.argumentDomain)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
        do { try await LocalEngine.shared.installLayoutFixture() }
        catch { fputs("FAIL: fixture database unavailable\n", stderr); exit(1) }
        let state = AppState()
        let host = NSHostingView(rootView: MenuPanel().environment(state).environment(LayoutState()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 454, height: 680),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            host.layoutSubtreeIfNeeded()
            precondition(host.bounds.width > 0 && host.bounds.height > 0)
            print("PASS: \(CommandLine.arguments[1]) unread, \(scope) scope; panel laid out and main loop responsive")
            window.orderOut(nil)
            exit(0)
        }
        }
        app.run()
    }
}
