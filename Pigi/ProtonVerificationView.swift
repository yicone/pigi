import SwiftUI
import WebKit
#if canImport(PigiCore)
import PigiCore
#endif

struct ProtonVerificationView: NSViewRepresentable {
    let url: URL
    let challenge: String
    let completion: (Result<String, ProtonHelperError>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(challenge: challenge, completion: completion) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "protonVerification")
        config.userContentController.addUserScript(WKUserScript(source: ProtonVerificationPolicy.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "protonVerification")
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let challenge: String
        let completion: (Result<String, ProtonHelperError>) -> Void
        var finished = false
        init(challenge: String, completion: @escaping (Result<String, ProtonHelperError>) -> Void) {
            self.challenge = challenge; self.completion = completion
        }
        func finish(_ value: Result<String, ProtonHelperError>) { guard !finished else { return }; finished = true; completion(value) }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            let origin = message.frameInfo.securityOrigin
            guard message.frameInfo.isMainFrame, origin.protocol == "https", origin.host == "verify.proton.me",
                  origin.port == 0 || origin.port == 443,
                  let body = message.body as? [String: Any] else { return }
            if body["error"] as? Bool == true { finish(.failure(.invalidParams)); return }
            guard let token = body["token"] as? String, ProtonVerificationPolicy.result(token, challenge: challenge) else { return }
            finish(.success(token))
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.targetFrame != nil else { decisionHandler(.cancel); return }
            if action.targetFrame?.isMainFrame == true {
                guard let url = action.request.url, url.scheme == "https", url.host == "verify.proton.me", url.port == nil, url.user == nil else {
                    decisionHandler(.cancel); finish(.failure(.invalidParams)); return
                }
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
                decisionHandler(.cancel); finish(.failure(.network)); return
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(.network)) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(.network)) }
    }
}
