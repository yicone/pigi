import SwiftUI
import WebKit
#if canImport(PigiCore)
import PigiCore
#endif

/// Renders a mail body in a script-free web view. Remote content is blocked by
/// a CSP meta tag unless the reader asks for it.
struct MailHTMLView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let body: String
    let isHTML: Bool
    let allowRemoteContent: Bool
    var inlineImages: [MailInlineImage] = []
    var horizontalInset: CGFloat = 26

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Explicitly follow the SwiftUI appearance, including overrides on the
        // menu bar panel. WebKit updates media queries without reloading mail.
        webView.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        webView.underPageBackgroundColor = .textBackgroundColor
        let html = Self.document(body: body, isHTML: isHTML, allowRemote: allowRemoteContent,
                                 horizontalInset: horizontalInset, inlineImages: inlineImages)
        guard html != context.coordinator.lastHTML else { return }
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    static func document(body: String, isHTML: Bool, allowRemote: Bool, horizontalInset: CGFloat = 26, inlineImages: [MailInlineImage] = []) -> String {
        // cid: bytes become data: URLs, which img-src already allows. The policy
        // stays closed: no cid/blob/* scheme, and remote http/https only when asked.
        // The app Info.plist has no ATS exception, so cleartext http still fails there.
        let csp = allowRemote
            ? "default-src 'none'; img-src data: https: http:; style-src 'unsafe-inline' https:; font-src data: https:"
            : "default-src 'none'; img-src data:; style-src 'unsafe-inline'"
        let content = isHTML
            ? InlineImages.embed(body, images: inlineImages)
            : "<div style=\"white-space:pre-wrap\">\(RemoteMapping.escapeHTML(body))</div>"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <style>
        :root { color-scheme: light dark; --pigi-background: #fff; --pigi-text: #1d1d1f; --pigi-link: #06c; }
        @media (prefers-color-scheme: dark) {
            :root { --pigi-background: #1e1e1e; --pigi-text: #ececec; --pigi-link: #8ab4f8; }
        }
        body { font: 14px/1.55 -apple-system, BlinkMacSystemFont, sans-serif; margin: 22px \(horizontalInset)px;
               color: var(--pigi-text); background: var(--pigi-background); overflow-wrap: anywhere; }
        img { max-width: 100%; height: auto; }
        pre { white-space: pre-wrap; }
        </style></head><body>\(content)
        <style>
        /* Apply after sender styles, including hard-coded white newsletter tables.
           Keep image/SVG artwork intact rather than inverting the whole message. */
        @media (prefers-color-scheme: dark) {
            html { color-scheme: dark !important; background-color: var(--pigi-background) !important; }
            html body, html body :where(*:not(img):not(svg):not(svg *)) {
                color: var(--pigi-text) !important;
                background-color: transparent !important;
                border-color: #555 !important;
            }
            html body { background-color: var(--pigi-background) !important; }
            html body a, html body a * { color: var(--pigi-link) !important; }
        }
        </style></body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML = ""

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
