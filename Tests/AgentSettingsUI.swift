import AppKit
import Darwin
import SwiftUI

// The production keychain implementation is NOT linked into this executable.
// Any accidental call is a test failure, never a real read/write or fake success.
enum Keychain {
    static func warm() throws { fatalError("Fixture attempted keychain access") }
    static func get(_ key: String) throws -> String? { fatalError("Fixture attempted keychain access") }
    static func set(_ key: String, _ value: String) -> Bool { fatalError("Fixture attempted keychain access") }
    static func translationAPIKey() throws -> String? { fatalError("Fixture attempted keychain access") }
    static func setTranslationAPIKey(_ value: String) -> Bool { fatalError("Fixture attempted keychain access") }
}

private enum FixtureError: Error { case failed(String) }
private func require(_ condition: Bool, _ description: String) throws {
    guard condition else { throw FixtureError.failed(description) }
}

private extension LocalEngine {
    func openSettingsFixture(_ path: String) throws {
        let fixture = try Store(path: path)
        for statement in Self.schema { try fixture.run(statement) }
        store = fixture
    }

    func settingsFixtureScenario(_ name: String) throws {
        let s = try db()
        if name == "recover" {
            try s.run("DROP TRIGGER IF EXISTS fixture_save_failure")
            if try s.query("SELECT name FROM sqlite_master WHERE name='fixture_hidden_audit'").count == 1 {
                try s.run("ALTER TABLE fixture_hidden_audit RENAME TO agent_actions")
            }
        } else if name == "saveFailure" {
            try s.run("CREATE TRIGGER IF NOT EXISTS fixture_save_failure BEFORE INSERT ON agent_permissions BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
        } else if name == "loadFailure" {
            try s.run("ALTER TABLE agent_actions RENAME TO fixture_hidden_audit")
        } else if name == "seed" || name == "empty" {
            try settingsFixtureScenario("recover")
            for table in ["accounts", "agent_permissions", "agent_actions"] { try s.run("DELETE FROM \(table)") }
            if name == "seed" {
                try s.run("INSERT INTO accounts(email,kind) VALUES('fixture@example.invalid','imap')")
                for _ in 0..<205 { _ = try agentRead(.init(id: "synthetic", method: "list")) }
            }
        } else if name == "append" {
            _ = try agentRead(.init(id: "synthetic", method: "list"))
        }
    }

    func closeSettingsFixture() { store = nil }
}

@MainActor
private struct FixtureAXNode {
    let object: NSObject
    func value(_ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }
    func boolean(_ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let implementation = object.method(for: selector) else { return false }
        typealias Method = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(implementation, to: Method.self)(object, selector)
    }
    var identifier: String? {
        (value("accessibilityIdentifier") as? String)
            ?? (object as? NSCell)?.controlView?.accessibilityIdentifier()
    }
    var children: [Any] { value("accessibilityChildren") as? [Any] ?? [] }
    func accessibilityValue() -> AnyObject? { value("accessibilityValue") }
    func isAccessibilityEnabled() -> Bool { boolean("isAccessibilityEnabled") }
    func accessibilityPerformPress() -> Bool {
        if let button = (object as? NSCell)?.controlView as? NSButton {
            button.performClick(nil)
            return true
        }
        return boolean("accessibilityPerformPress")
    }
}

@MainActor
private final class FixtureHost: NSObject, NSWindowDelegate {
    let path: String
    var engine = LocalEngine()
    let window: NSWindow
    var host: NSHostingView<AgentSettingsPage>!
    var busy = false
    var fixtureFailure: String?

    init(path: String) {
        self.path = path
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1060, height: 800),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Pigi Agent Settings — SYNTHETIC ONLY"
        window.delegate = self
        window.isReleasedWhenClosed = false
    }

    func open() async throws {
        try await engine.openSettingsFixture(path)
        try await engine.settingsFixtureScenario("seed")
        rebuild()
        window.makeKeyAndOrderFront(nil)
    }

    func rebuild() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1060, height: 800))
        host = NSHostingView(rootView: AgentSettingsPage(engine: engine))
        host.frame = NSRect(x: 0, y: 0, width: 1060, height: 744)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.frame = NSRect(x: 12, y: 750, width: 1036, height: 40)
        toolbar.autoresizingMask = [.width, .minYMargin]
        for (id, title) in [("seed", "合成数据"), ("empty", "空数据"), ("saveFailure", "保存失败"),
                            ("loadFailure", "加载失败"), ("recover", "恢复"), ("append", "追加审计"), ("reopen", "关闭重开")] {
            let button = NSButton(title: title, target: self, action: #selector(scenario(_:)))
            button.identifier = .init(id)
            button.setAccessibilityIdentifier("fixture." + id)
            toolbar.addArrangedSubview(button)
        }
        container.addSubview(toolbar)
        window.contentView = container
    }

    @objc func scenario(_ sender: NSButton) {
        guard !busy, let name = sender.identifier?.rawValue else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                if name == "reopen" {
                    // Destroy the old view AND engine/connection. Only the temporary file survives.
                    window.contentView = nil
                    host = nil
                    await engine.closeSettingsFixture()
                    engine = LocalEngine()
                    try await engine.openSettingsFixture(path)
                    rebuild()
                } else {
                    try await engine.settingsFixtureScenario(name)
                    if name == "seed" || name == "empty" { rebuild() }
                }
            } catch { fixtureFailure = "Synthetic scenario failed: \(name)" }
        }
    }

    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

    // Enumerate only our own window's native accessibility objects. No system AX permission,
    // global input, another process, direct Binding invocation or backend "click" substitute.
    func element(_ id: String) -> FixtureAXNode? {
        func walk(_ object: Any, depth: Int) -> FixtureAXNode? {
            guard depth < 30, let object = object as? NSObject else { return nil }
            let node = FixtureAXNode(object: object)
            if node.identifier == id { return node }
            for child in node.children {
                if let found = walk(child, depth: depth + 1) { return found }
            }
            return nil
        }
        return walk(window, depth: 0)
    }

    func wait(_ description: String, _ ready: () -> Bool) async throws {
        for _ in 0..<120 {
            host?.layoutSubtreeIfNeeded()
            if let failure = fixtureFailure { throw FixtureError.failed(failure) }
            if ready() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        func dump(_ object: Any, _ depth: Int) {
            guard depth < 8, let object = object as? NSObject else { return }
            let node = FixtureAXNode(object: object)
            print("AX: \(depth) \(type(of: object)) id=\(node.identifier ?? "nil") value=\(String(describing: node.accessibilityValue()))")
            for child in node.children.prefix(15) { dump(child, depth + 1) }
        }
        dump(window, 0)
        throw FixtureError.failed("Timed out: " + description)
    }

    func press(_ id: String) async throws {
        try await wait(id) { element(id) != nil && !busy }
        let node = element(id)!
        try require(node.isAccessibilityEnabled(), "Control disabled: " + id)
        try require(node.accessibilityPerformPress(), "Native control did not accept press: " + id)
        print("PRESS: \(id)")
        // Allow the native action and its asynchronous save/reload to enter the main run loop.
        try await Task.sleep(for: .milliseconds(100))
        try await wait("fixture action") { !busy }
    }

    func checked(_ capability: String) -> Bool? {
        (element("agent.\(capability).fixture@example.invalid")?.accessibilityValue() as? NSNumber)?.boolValue
    }

    func page(_ value: Int) -> Bool {
        (element("agent.page")?.accessibilityValue() as? String) == "第 \(value) 页"
    }

    func test() async throws {
        try await wait("initial page") { checked("read") == true && checked("draft") == true && checked("organize") == false }
        try await press("agent.read.fixture@example.invalid")
        try await wait("read saved") { checked("read") == false }
        try await press("agent.draft.fixture@example.invalid")
        try await wait("draft saved") { checked("draft") == false }
        try await press("agent.organize.fixture@example.invalid")
        try await wait("organize saved") { checked("organize") == true }
        try await press("fixture.reopen")
        try await wait("persistent controls after reopen") { checked("read") == false && checked("draft") == false && checked("organize") == true }
        let persisted = try await engine.agentPermissions(account: "fixture@example.invalid")
        try require(persisted == .init(read: false, draft: false, organize: true), "Persistence mismatch")
        print("PASS: real permission controls save all three bits; new view/engine reopens persisted file")

        try await wait("audit page 1") { page(1) && element("agent.audit.result.205") != nil }
        try await press("agent.next")
        try await wait("audit page 2") { page(2) && element("agent.audit.result.105") != nil && element("agent.audit.result.205") == nil }
        try await press("agent.next")
        try await wait("audit page 3") { page(3) && element("agent.audit.result.5") != nil }
        try require(element("agent.next")?.isAccessibilityEnabled() == false, "Last page must disable next")
        try await press("agent.previous")
        try await wait("back to page 2") { page(2) }
        try await press("agent.previous")
        try await wait("back to page 1") { page(1) }
        try require(element("agent.previous")?.isAccessibilityEnabled() == false, "First page must disable previous")
        try await press("fixture.append")
        try require(element("agent.audit.result.206") == nil, "Audit must await refresh")
        try await press("agent.refresh")
        try await wait("fresh audit row") { element("agent.audit.result.206") != nil }
        print("PASS: native audit refresh and forward/back pagination, including disabled boundaries")

        try await press("fixture.saveFailure")
        try await press("agent.read.fixture@example.invalid")
        try await wait("save failure message") { element("agent.failure") != nil }
        try require(checked("read") == false, "Failed save changed control")
        try await press("fixture.recover")
        try await press("agent.read.fixture@example.invalid")
        try await wait("save recovered") { checked("read") == true && element("agent.failure") == nil }
        print("PASS: save error is visible, prior value retained, retry recovers")

        try await press("fixture.loadFailure")
        try await press("agent.refresh")
        try await wait("load failure message") { element("agent.failure") != nil }
        try await press("fixture.recover")
        try await press("agent.refresh")
        try await wait("load recovered") { element("agent.failure") == nil && element("agent.audit.result.206") != nil }
        print("PASS: load error is visible and refresh recovers")

        try await press("fixture.empty")
        try await wait("empty accounts and audit") { element("agent.emptyAccounts") != nil && element("agent.emptyAudit") != nil }
        try require(element("agent.next")?.isAccessibilityEnabled() == false, "Empty audit must disable next")
        try await press("fixture.seed")
        try await wait("empty state recovered") { checked("read") == true && element("agent.emptyAccounts") == nil && element("agent.emptyAudit") == nil }
        print("PASS: empty accounts/audit and restoration through native controls")
    }
}

@main @MainActor
struct AgentSettingsUI {
    static func peerFixture(_ root: URL, smoke: Bool) -> Never {
        Task { @MainActor in
            do {
                try require(geteuid() != 0, "Run the fixture server as the ordinary owner, never root")
                let engine = LocalEngine()
                try await engine.openSettingsFixture(root.appendingPathComponent("synthetic.sqlite3").path)
                let socket = root.appendingPathComponent("peer/agent.sock")
                let server = AgentSocketServer(engine: engine, url: socket)
                try server.start()
                defer { server.stop() }
                print("SYNTHETIC_SOCKET=\(socket.path)")
                fflush(stdout)
                if smoke {
                    let client = Process()
                    client.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    client.arguments = ["-B", root.appendingPathComponent("agent-peer-probe.py").path, socket.path, "--same-uid"]
                    try client.run()
                    client.waitUntilExit()
                    try require(client.terminationStatus == 0, "Synthetic same-UID probe failed")
                }
                for _ in 0..<450 {
                    if let last = try await engine.agentActions().first {
                        try require(last.result == (smoke ? "allowed" : "unauthorized"), "Unexpected peer audit result")
                        print(smoke ? "PASS: isolated peer fixture smoke; cross-UID NOT tested" : "PASS: peer UID rejection persisted in synthetic audit")
                        server.stop()
                        exit(0)
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                throw FixtureError.failed("No peer probe received within 45 seconds; no cross-UID evidence")
            } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        dispatchMain()
    }

    static func proveIsolation(_ root: URL) throws {
        let home = try String(contentsOf: root.appendingPathComponent("protected-home"), encoding: .utf8)
        let profile = try String(contentsOf: root.appendingPathComponent("runtime.sb"), encoding: .utf8)
        let quotedHome = String(data: try JSONEncoder().encode(home), encoding: .utf8)!.replacingOccurrences(of: "\\/", with: "/")
        try require(profile.contains("(deny file-read* file-write* (subpath " + quotedHome + "))"), "Missing real-home deny rule")
        let canary = root.appendingPathComponent("blocked-canary").path
        for flags in [O_RDONLY, O_WRONLY] {
            let fd = open(canary, flags)
            if fd >= 0 { close(fd); throw FixtureError.failed("Canary access was allowed") }
            try require(errno == EPERM, "Canary denial not EPERM")
        }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd >= 0 {
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(9).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let rc = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            try require(rc == -1 && errno == EPERM, "Network was not denied")
        } else { try require(errno == EPERM, "Unexpected socket failure") }
        try AppSupport.assertProcessSupportIsIsolated()
        print("PASS: BEFORE GUI — entire real home denied by runtime profile (no real file probe); synthetic canary read/write EPERM; network EPERM; production keychain not linked")
    }

    static func main() {
        do {
            guard CommandLine.arguments.count == 3, ["--test", "--manual", "--peer-smoke", "--peer-server"].contains(CommandLine.arguments[2]) else {
                throw FixtureError.failed("Use Tests/agent-settings-ui.sh [--test|--manual|--peer-smoke|--peer-server]")
            }
            let root = URL(fileURLWithPath: CommandLine.arguments[1])
            try proveIsolation(root)
            if CommandLine.arguments[2].hasPrefix("--peer-") {
                peerFixture(root, smoke: CommandLine.arguments[2] == "--peer-smoke")
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            // Enable accessibility only within this disposable process, without TCC or global settings.
            app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
            app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
            let fixture = FixtureHost(path: root.appendingPathComponent("synthetic.sqlite3").path)
            Task { @MainActor in
                do {
                    try await fixture.open()
                    if CommandLine.arguments[2] == "--test" {
                        try await fixture.test()
                        print("PASS: all synthetic settings UI interactions (author self-test only)")
                        exit(0)
                    }
                    print("MANUAL: synthetic fixture only; close window to stop and clean up")
                } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
            }
            if CommandLine.arguments[2] == "--test" {
                DispatchQueue.global().asyncAfter(deadline: .now() + 60) { _exit(124) }
            }
            app.run()
        } catch { fputs("FAIL before GUI: \(error)\n", stderr); exit(1) }
    }
}
