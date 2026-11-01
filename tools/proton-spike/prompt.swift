import AppKit
import Security
import WebKit
import JavaScriptCore

// Proton Verify broadcasts JSON strings; legacy API HTML used a different
// object shape. Do not forward ERROR payloads (which may contain private data).
let verificationParser = """
function parseProtonVerification(raw) {
  let d;
  try { d = typeof raw === 'string' ? JSON.parse(raw) : raw; } catch (_) { return null; }
  if (!d || typeof d !== 'object') return null;
  if (d.type === 'LOADED') return {kind:'loaded'};
  if (d.type === 'ERROR') return {kind:'error'};
  if (d.type === 'CLOSE') return {kind:'close'};
  if (d.type === 'HUMAN_VERIFICATION_SUCCESS' && d.payload && d.payload.type === 'captcha'
      && typeof d.payload.token === 'string' && d.payload.token.length > 0)
    return {kind:'captcha', token:d.payload.token};
  return null;
}
"""

func captchaDiagnostic(_ event: String) {
    FileHandle.standardError.write(Data(("PROTON_SPIKE:" + event + "\n").utf8))
}

// Hosts and message types are restricted; this bridge receives only the result
// of a CAPTCHA the user solves in the unmodified official Proton page.
final class CaptchaBridge: NSObject, WKScriptMessageHandler, NSWindowDelegate, WKNavigationDelegate {
    var token: String?
    var preview = false
    let hosts = Set(["verify.proton.me"])
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              hosts.contains(message.frameInfo.securityOrigin.host),
              let value = message.body as? [String: String], let kind = value["kind"] else { return }
        if kind == "loaded" { captchaDiagnostic("widget_loaded"); return }
        if kind == "error" {
            captchaDiagnostic("widget_error")
            if !preview { NSApplication.shared.abortModal() }
            return
        }
        if kind == "close" { NSApplication.shared.abortModal(); return }
        guard !preview, kind == "captcha", let result = value["token"], !result.isEmpty else { return }
        token = result
        captchaDiagnostic("callback_received")
        NSApplication.shared.stopModal()
    }
    func windowWillClose(_ notification: Notification) {
        captchaDiagnostic("window_closed")
        NSApplication.shared.abortModal()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        captchaDiagnostic("page_loaded")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        captchaDiagnostic("navigation_failed")
        NSApplication.shared.abortModal()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        captchaDiagnostic("navigation_failed")
        NSApplication.shared.abortModal()
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse {
            captchaDiagnostic("http_status:" + String(http.statusCode))
            if http.statusCode >= 400 {
                decisionHandler(.cancel)
                NSApplication.shared.abortModal()
                return
            }
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.targetFrame?.isMainFrame == true, let url = action.request.url {
            let allowed = url.scheme == "https" && hosts.contains(url.host ?? "")
            if !allowed { captchaDiagnostic("navigation_blocked"); NSApplication.shared.abortModal() }
            decisionHandler(allowed ? .allow : .cancel)
        } else { decisionHandler(.allow) }
    }
}

// Only this helper handles the private Keychain item. Secret stdout is captured
// by the Go parent, never inherited by a terminal or written to a file.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let args = CommandLine.arguments
guard args.count == 3 else { exit(2) }
let mode = args[1], item = args[2]
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "one.yic.pigi",
    kSecAttrAccount as String: item,
    kSecAttrSynchronizable as String: false]
func fail() -> Never { exit(1) }
func modal(_ alert: NSAlert) -> NSApplication.ModalResponse {
    app.activate(ignoringOtherApps: true)
    // Do not leave an orphaned credential prompt after the run ends.
    DispatchQueue.main.asyncAfter(deadline: .now() + 240) { app.abortModal() }
    return alert.runModal()
}
switch mode {
case "verification-parser-selftest":
    let context = JSContext()!
    context.evaluateScript(verificationParser)
    let result = context.evaluateScript("""
      (function() {
        const bad = ['not-json', '{}', '{"type":"HUMAN_VERIFICATION_SUCCESS","payload":{"type":"payment","token":"synthetic"}}'];
        if (bad.some(x => parseProtonVerification(x) !== null)) return false;
        const good = parseProtonVerification(JSON.stringify({type:'HUMAN_VERIFICATION_SUCCESS',payload:{type:'captcha',token:'synthetic:response'}}));
        const error = parseProtonVerification({type:'ERROR',payload:{private:'never forwarded'}});
        return good.kind === 'captcha' && good.token === 'synthetic:response'
          && Object.keys(error).length === 1 && error.kind === 'error'
          && parseProtonVerification({type:'LOADED'}).kind === 'loaded';
      })();
      """)
    guard result?.toBool() == true, context.exception == nil else { fail() }
    print("official verification message parser tests passed")
case "captcha", "captcha-preview":
    let preview = mode == "captcha-preview"
    let input = preview ? Data("https://verify.proton.me/?methods=captcha&token=diagnostic-invalid-challenge&embed=1".utf8)
                        : FileHandle.standardInput.readDataToEndOfFile()
    guard let raw = String(data: input, encoding: .utf8),
          let url = URLComponents(string: raw), url.scheme == "https", url.host == "verify.proton.me",
          url.port == nil, url.user == nil, url.password == nil, url.fragment == nil,
          url.path == "" || url.path == "/", url.url != nil else { fail() }
    let bridge = CaptchaBridge()
    bridge.preview = preview
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.userContentController.add(bridge, name: "protonHumanVerification")
    config.userContentController.addUserScript(WKUserScript(source: verificationParser + """
      window.addEventListener('message', function(event) {
        if (event.origin !== 'https://verify.proton.me') return;
        const result = parseProtonVerification(event.data);
        if (result) window.webkit.messageHandlers.protonHumanVerification.postMessage(result);
      });
      """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = preview ? "ACM-769 · 官方验证页无凭据预览（无法用于登录）" : "ACM-769 · Proton 官方人机验证（请手动完成）"
    window.delegate = bridge
    let web = WKWebView(frame: window.contentView!.bounds, configuration: config)
    web.autoresizingMask = [.width, .height]
    web.navigationDelegate = bridge
    window.contentView!.addSubview(web)
    web.load(URLRequest(url: url.url!))
    window.center(); window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    let timeout = Timer(timeInterval: preview ? 45 : 240, repeats: false) { _ in
        captchaDiagnostic("timeout")
        app.abortModal()
    }
    RunLoop.main.add(timeout, forMode: .modalPanel)
    app.runModal(for: window)
    timeout.invalidate()
    web.stopLoading(); window.orderOut(nil)
    guard let token = bridge.token else { fail() }
    FileHandle.standardOutput.write(Data(token.utf8))
case "selftest":
    let expected = Data("synthetic-keychain-lifecycle-test".utf8)
    var add = query
    add[kSecValueData as String] = expected
    add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { fail() }
    var get = query
    get[kSecReturnData as String] = true
    var result: CFTypeRef?
    let status = SecItemCopyMatching(get as CFDictionary, &result)
    let deleted = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess, (result as? Data) == expected,
          deleted == errSecSuccess else { fail() }
    print("synthetic Keychain write/read/delete passed")
case "collect":
    let alert = NSAlert()
    alert.messageText = "ACM-769 · Proton 免费账号验证"
    alert.informativeText = "在此本机窗口输入。凭据临时保存在 one.yic.pigi 钥匙串，结束时删除。只列收件箱并解密一封，不发信、不改已读状态。"
    alert.addButton(withTitle: "登录并验证")
    alert.addButton(withTitle: "取消")
    let view = NSStackView()
    view.orientation = .vertical; view.alignment = .leading; view.spacing = 8
    let username = NSTextField(); username.placeholderString = "Proton 用户名或邮箱"
    let password = NSSecureTextField(); password.placeholderString = "登录密码"
    let mailbox = NSSecureTextField(); mailbox.placeholderString = "邮箱密码（仅双密码账号填写）"
    let free = NSButton(checkboxWithTitle: "我确认此账号为免费计划，并允许读取一封非敏感邮件", target: nil, action: nil)
    for field in [username, password, mailbox] {
        field.frame.size = NSSize(width: 440, height: 26)
        field.widthAnchor.constraint(equalToConstant: 440).isActive = true
        view.addArrangedSubview(field)
    }
    view.addArrangedSubview(free)
    view.frame = NSRect(origin: .zero, size: view.fittingSize)
    alert.accessoryView = view
    alert.window.initialFirstResponder = username
    guard modal(alert) == .alertFirstButtonReturn,
          free.state == .on, !username.stringValue.isEmpty, !password.stringValue.isEmpty else { fail() }
    let data = try! JSONSerialization.data(withJSONObject: ["username": username.stringValue,
        "password": password.stringValue, "mailbox": mailbox.stringValue, "free_confirmed": true])
    var add = query
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { fail() }
    print("ok")
case "read":
    var get = query
    get[kSecReturnData as String] = true
    get[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(get as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data else { fail() }
    FileHandle.standardOutput.write(data)
case "delete":
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { fail() }
    print("ok")
case "otp":
    let alert = NSAlert()
    alert.messageText = "ACM-769 · Proton TOTP"
    alert.informativeText = "在本机输入当前验证码。不会持久化。安全密钥或人机验证请回到 Proton 官方页面完成。"
    alert.addButton(withTitle: "继续"); alert.addButton(withTitle: "取消")
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
    alert.accessoryView = field; alert.window.initialFirstResponder = field
    guard modal(alert) == .alertFirstButtonReturn else { fail() }
    FileHandle.standardOutput.write(Data(field.stringValue.utf8))
case "show":
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else { fail() }
    let alert = NSAlert()
    alert.messageText = "ACM-769 · 本机解密结果"
    alert.informativeText = "请核对下方正文是否与 Proton 中的非敏感测试邮件一致。正文只显示在本机，不写入日志。HTML 按原文显示，不加载远程内容。"
    alert.addButton(withTitle: "正文一致"); alert.addButton(withTitle: "无法确认")
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    scroll.hasVerticalScroller = true
    let textView = NSTextView(frame: scroll.bounds)
    textView.isEditable = false; textView.isRichText = false; textView.string = text
    scroll.documentView = textView; alert.accessoryView = scroll
    guard modal(alert) == .alertFirstButtonReturn else { fail() }
    print("confirmed")
default: fail()
}
