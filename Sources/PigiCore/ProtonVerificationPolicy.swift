import Foundation

/// No fabricated verification page, response rewriting or CSP changes.
public enum ProtonVerificationPolicy {
    public static func url(_ raw: String, challenge: String) -> URL? {
        guard let c = URLComponents(string: raw), c.scheme == "https", c.host == "verify.proton.me",
              c.port == nil, c.user == nil, c.password == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/", !challenge.isEmpty else { return nil }
        let tokens = (c.queryItems ?? []).filter { $0.name == "token" }
        guard tokens.count == 1, tokens[0].value == challenge,
              (c.queryItems ?? []).filter({ $0.name == "methods" }).count == 1,
              c.queryItems?.contains(where: { $0.name == "methods" && ($0.value ?? "").split(separator: ",").contains("captcha") }) == true else { return nil }
        return c.url
    }
    public static func result(_ token: String, challenge: String) -> Bool {
        token.hasPrefix(challenge + ":") && token.count > challenge.count + 1 && token.utf8.count < 16384
    }
    public static let script = """
    window.addEventListener('message', function(event) {
      if (event.origin !== 'https://verify.proton.me') return;
      let d; try { d = typeof event.data === 'string' ? JSON.parse(event.data) : event.data; } catch (_) { return; }
      if (!d || typeof d !== 'object') return;
      if (d.type === 'ERROR' || d.type === 'CLOSE') { window.webkit.messageHandlers.protonVerification.postMessage({error:true}); return; }
      if (d.type === 'HUMAN_VERIFICATION_SUCCESS' && d.payload && d.payload.type === 'captcha'
          && typeof d.payload.token === 'string') window.webkit.messageHandlers.protonVerification.postMessage({token:d.payload.token});
    });
    """
}

