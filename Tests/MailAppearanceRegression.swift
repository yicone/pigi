import AppKit
import SwiftUI
import WebKit

enum MailCache {
    static func load() -> [Mail] { [] }
    static func save(_ mails: [Mail]) {}
    static func saveChecked(_ mails: [Mail]) throws {}
    static func clear() {}
}

@MainActor
enum MainWindow {
    static func show() {}
}

@main
@MainActor
struct MailAppearanceRegression {
    static let state = AppState()
    static let richBody = """
        <html><head><style>body { background: white; color: black; }</style></head>
        <body bgcolor="#ffffff"><table bgcolor="#ffffff" style="background-color:#fff;color:#111"><tr>
        <td id="copy" style="background-color: white; color: black">正文内容
        <a id="link" href="https://example.com">阅读详情</a>
        <img id="art" alt="原始图片" src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='20' height='20'%3E%3Crect width='20' height='20' fill='red'/%3E%3C/svg%3E">
        </td></tr></table></body></html>
        """

    static func detail(html: Bool, panel: Bool, scheme: ColorScheme) -> some View {
        let mail = Mail(id: "fixture", accountID: "reader@example.com", remoteID: "fixture",
                        senderName: "测试发件人", senderEmail: "sender@example.com", subject: "外观与详情布局验证",
                        snippet: "", body: html ? richBody : "纯文本邮件 <保留尖括号> & 内容\n第二行正文",
                        date: Date(), isUnread: false, isStarred: false, bodyLoaded: true, isHTML: html)
        return MailDetailContent(mail: mail, inset: panel ? 18 : 26, onBack: panel ? {} : nil)
            .environment(state)
            .environment(\.colorScheme, scheme)
    }

    static func webView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { webView(in: $0) }.first
    }

    static func inspect(_ web: WKWebView) async throws -> [String: Any] {
        let result = try await web.evaluateJavaScript("""
            JSON.stringify({
                ready: document.readyState,
                dark: matchMedia('(prefers-color-scheme: dark)').matches,
                background: getComputedStyle(document.body).backgroundColor,
                text: getComputedStyle(document.getElementById('copy') || document.body).color,
                cellBackground: document.getElementById('copy') ? getComputedStyle(document.getElementById('copy')).backgroundColor : '',
                imageFilter: document.getElementById('art') ? getComputedStyle(document.getElementById('art')).filter : '',
                linkColor: document.getElementById('link') ? getComputedStyle(document.getElementById('link')).color : '',
                inset: getComputedStyle(document.body).marginLeft,
                marker: window.appearanceTestMarker === true
            })
            """) as! String
        return try JSONSerialization.jsonObject(with: Data(result.utf8)) as! [String: Any]
    }

    static func main() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
            fputs("FAIL: detail appearance regression timed out\n", stderr)
            _exit(124)
        }
        UserDefaults.standard.setVolatileDomain([
            "gmailAccounts": [String](), "imapAccounts": [String](), "loadRemoteImages": false,
        ], forName: UserDefaults.argumentDomain)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        Task { @MainActor in
            do {
                let escaped = MailHTMLView.document(body: "<script>test</script>&", isHTML: false, allowRemote: false)
                precondition(escaped.contains("&lt;script&gt;test&lt;/script&gt;&amp;"))
                precondition(escaped.contains("img-src data:;"))
                precondition(MailHTMLView.document(body: "", isHTML: true, allowRemote: true).contains("img-src data: https: http:;"))

                for panel in [false, true] {
                    for html in [false, true] {
                        let host = NSHostingView(rootView: detail(html: html, panel: panel, scheme: .light))
                        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: panel ? 438 : 760, height: 664),
                                              styleMask: [.borderless], backing: .buffered, defer: false)
                        window.appearance = NSAppearance(named: .aqua)
                        window.contentView = host
                        window.orderFront(nil)
                        var web: WKWebView?
                        for _ in 0..<100 {
                            if let candidate = webView(in: host), !candidate.isLoading,
                               let value = try? await inspect(candidate), value["ready"] as? String == "complete" {
                                web = candidate
                                break
                            }
                            try await Task.sleep(for: .milliseconds(50))
                        }
                        guard let web else { fatalError("Detail WebView failed to load") }
                        let light = try await inspect(web)
                        precondition(light["dark"] as? Bool == false, "Light appearance did not reach WebKit")
                        precondition(light["background"] as? String == "rgb(255, 255, 255)")
                        precondition(light["inset"] as? String == (panel ? "18px" : "26px"))
                        _ = try await web.evaluateJavaScript("window.appearanceTestMarker = true")
                        print("PASS: \(panel ? "panel" : "desktop") \(html ? "HTML" : "plain") light")

                        window.appearance = NSAppearance(named: .darkAqua)
                        host.rootView = detail(html: html, panel: panel, scheme: .dark)
                        var dark: [String: Any] = [:]
                        for _ in 0..<100 {
                            try await Task.sleep(for: .milliseconds(50))
                            dark = try await inspect(web)
                            if dark["dark"] as? Bool == true, dark["background"] as? String == "rgb(30, 30, 30)" { break }
                        }
                        precondition(webView(in: host) === web, "Appearance switch replaced the WebView")
                        precondition(dark["marker"] as? Bool == true, "Appearance switch reloaded the message")
                        precondition(dark["dark"] as? Bool == true)
                        precondition(dark["background"] as? String == "rgb(30, 30, 30)")
                        precondition(dark["text"] as? String == "rgb(236, 236, 236)")
                        if html {
                            precondition(dark["cellBackground"] as? String == "rgba(0, 0, 0, 0)")
                            precondition(dark["imageFilter"] as? String == "none", "Images must not be inverted")
                            precondition(dark["linkColor"] as? String == "rgb(138, 180, 248)", "Links must remain distinguishable")
                        }
                        print("PASS: \(panel ? "panel" : "desktop") \(html ? "HTML" : "plain") dark; switched without reload")
                        if let directory = ProcessInfo.processInfo.environment["PIGI_APPEARANCE_SNAPSHOTS"] {
                            host.layoutSubtreeIfNeeded()
                            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                                host.cacheDisplay(in: host.bounds, to: bitmap)
                                let url = URL(fileURLWithPath: directory)
                                    .appendingPathComponent("\(panel ? "panel" : "desktop")-\(html ? "html" : "plain")-dark.png")
                                try bitmap.representation(using: .png, properties: [:])!.write(to: url)
                            }
                        }

                        window.appearance = NSAppearance(named: .aqua)
                        host.rootView = detail(html: html, panel: panel, scheme: .light)
                        var restored: [String: Any] = [:]
                        for _ in 0..<100 {
                            try await Task.sleep(for: .milliseconds(50))
                            restored = try await inspect(web)
                            if restored["dark"] as? Bool == false, restored["background"] as? String == "rgb(255, 255, 255)" { break }
                        }
                        precondition(restored["dark"] as? Bool == false)
                        precondition(restored["background"] as? String == "rgb(255, 255, 255)")
                        precondition(restored["marker"] as? Bool == true, "Switching back to light reloaded the message")
                        print("PASS: \(panel ? "panel" : "desktop") \(html ? "HTML" : "plain") restored light without reload")
                        window.orderOut(nil)
                    }
                }
                exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }
}
