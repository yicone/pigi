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

    static let pixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

    /// The reader view, with remote images off, paints the cid image and leaves the https image unloaded.
    static func proveEmbeddedCID() async throws {
        let body = "<img id=\"cid\" alt=\"\" src=\"cid:pixel@example.test\"><img id=\"remote\" alt=\"\" src=\"https://127.0.0.1:9/blocked.png\">"
        let images = [MailInlineImage(contentID: "pixel@example.test", mime: "image/png", data: pixelPNG)]
        let mail = Mail(id: "cid-fixture", accountID: "reader@example.com", remoteID: "cid-fixture",
                        senderName: "测试发件人", senderEmail: "sender@example.com", subject: "内嵌图片",
                        snippet: "", body: body, date: Date(), isUnread: false, isStarred: false,
                        bodyLoaded: true, isHTML: true)
        state.testingStoreInlineImages(mail.id, images)
        let html = MailHTMLView.document(body: body, isHTML: true, allowRemote: false, inlineImages: images)
        precondition(html.contains("content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'\""))
        precondition(html.contains("data:image/png;base64,"))
        precondition(!html.contains("cid:"))
        let host = NSHostingView(rootView: MailDetailContent(mail: mail).environment(state).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        var widths: [String: Int] = [:]
        for _ in 0..<80 {
            if let web = webView(in: host), !web.isLoading,
               let raw = try? await web.evaluateJavaScript("""
                JSON.stringify({
                    cid: document.getElementById('cid') ? document.getElementById('cid').naturalWidth : -1,
                    remote: document.getElementById('remote') ? document.getElementById('remote').naturalWidth : -1
                })
                """) as? String,
               let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
                widths = object.compactMapValues { value in
                    (value as? NSNumber)?.intValue
                }
                if widths["cid"] == 1 && widths["remote"] == 0 { break }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        window.orderOut(nil)
        precondition(widths["cid"] == 1, "cid image did not paint while remote images were off")
        precondition(widths["remote"] == 0, "remote image painted while remote images were off")
        print("PASS: cid image paints from a data URL while remote images are off; CSP stays img-src data")
    }

    static func concludeRemoteImages() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        await reportFetch(session, URL(string: "http://example.com/")!, "http://example.com")
        await reportFetch(session, URL(string: "https://example.com/")!, "https://example.com")
        if let server = try? LocalPNGServer(png: pixelPNG) {
            defer { server.stop() }
            let local = URL(string: "http://127.0.0.1:\(server.port)/pixel.png")!
            await reportFetch(session, local, "http://127.0.0.1")
            let width = await webImageWidth(src: local.absoluteString, allowRemote: true)
            print("REMOTE webkit image \(local.absoluteString) naturalWidth=\(width.map(String.init) ?? "unread") allowRemote=true")
        } else {
            print("REMOTE local http server did not start")
        }
        print("REMOTE webkit main-frame http://example.com \(await webNavigation(URL(string: "http://example.com/")!))")
        print("REMOTE webkit main-frame https://example.com \(await webNavigation(URL(string: "https://example.com/")!))")
        let httpsImage = "https://upload.wikimedia.org/wikipedia/commons/c/ca/1x1.png"
        let on = await webImageWidth(src: httpsImage, allowRemote: true)
        let off = await webImageWidth(src: httpsImage, allowRemote: false)
        print("REMOTE https image naturalWidth allowRemote=true \(on.map(String.init) ?? "unread") allowRemote=false \(off.map(String.init) ?? "unread")")
        if let on, on > 0 {
            precondition(off == 0, "https image ignored the remote-image switch")
            print("PASS: https remote image follows the switch")
        } else {
            print("UNVERIFIED: public https image did not load in this run; img-src still drops https when the switch is off")
        }
    }

    static func reportFetch(_ session: URLSession, _ url: URL, _ label: String) async {
        do {
            let (_, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("REMOTE URLSession \(label) status=\(status)")
        } catch {
            print("REMOTE URLSession \(label) \(transportDescription(error))")
        }
    }

    static func webImageWidth(src: String, allowRemote: Bool) async -> Int? {
        let html = MailHTMLView.document(body: "<img id=\"probe\" alt=\"\" src=\"\(src)\">", isHTML: true, allowRemote: allowRemote)
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        web.loadHTMLString(html, baseURL: nil)
        var width: Int?
        for _ in 0..<40 {
            if !web.isLoading, let raw = try? await web.evaluateJavaScript("document.getElementById('probe') ? document.getElementById('probe').naturalWidth : -1") {
                if let number = raw as? NSNumber { width = number.intValue }
                if let width, width > 0 { return width }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return width
    }

    static func webNavigation(_ url: URL) async -> String {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let probe = NavigationProbe()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), configuration: configuration)
        web.navigationDelegate = probe
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        web.load(URLRequest(url: url, timeoutInterval: 4))
        for _ in 0..<45 where !probe.finished {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let error = probe.error { return transportDescription(error) }
        return probe.finished ? "finished" : "timeout"
    }

    static func transportDescription(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorAppTransportSecurityRequiresSecureConnection {
            return "ATS -1022"
        }
        return "error \(ns.domain) \(ns.code)"
    }

    static func main() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
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
                precondition(!escaped.contains("cid:"))
                let remotePolicy = MailHTMLView.document(body: "", isHTML: true, allowRemote: true)
                precondition(remotePolicy.contains("img-src data: https: http:;"))
                precondition(!remotePolicy.contains("cid:") && !remotePolicy.contains("img-src *"))

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
                try await proveEmbeddedCID()
                await concludeRemoteImages()
                exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }
}

final class NavigationProbe: NSObject, WKNavigationDelegate {
    var error: Error?
    var finished = false

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error
        finished = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error
        finished = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
    }
}

final class LocalPNGServer: @unchecked Sendable {
    private var listenFD: Int32 = -1
    let port: UInt16
    private let png: Data

    init(png: Data) throws {
        self.png = png
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        listenFD = fd
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw URLError(.cannotConnectToHost)
        }
        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &resolved) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else {
            close(fd)
            throw URLError(.cannotConnectToHost)
        }
        port = CFSwapInt16BigToHost(resolved.sin_port)
        Thread { [weak self] in self?.serve() }.start()
    }

    func stop() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
    }

    private func serve() {
        while listenFD >= 0 {
            var clientAddress = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &clientAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listenFD, $0, &length) }
            }
            if client < 0 { break }
            var buffer = [UInt8](repeating: 0, count: 512)
            _ = read(client, &buffer, buffer.count)
            var response = Data("HTTP/1.0 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(png.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(png)
            response.withUnsafeBytes { raw in
                if let base = raw.baseAddress { _ = write(client, base, raw.count) }
            }
            close(client)
        }
    }
}
