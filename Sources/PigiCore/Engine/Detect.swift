import Foundation

/// Mail-content heuristics: verification codes, unsubscribe links, address parsing.
enum Detect {
    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let codeWords = regex(
        "验证码|校验码|动态码|确认码|安全码|认证码|驗證碼|verification code|security code|confirmation code|"
        + "one[- ]time (?:pass(?:word|code)|code|pin)|login code|sign[- ]?in code|log[- ]?in code|passcode|\\botp\\b|"
        + "your code|code is|code:|verify your", .caseInsensitive)
    private static let codeToken = regex(
        "(?<![\\w.@/-])(?:[A-Z]-)?(\\d{3}[ -]\\d{3}|\\d{4,8}|(?=[A-Z0-9]*\\d)[A-Z0-9]{5,8})(?![\\w@/-])")
    private static let year = regex("^(19|20)\\d\\d$")

    /// The verification code in a mail: the token nearest to a "code" keyword.
    static func extractCode(subject: String?, text: String?) -> String? {
        let body = "\(subject ?? "")\n\(String((text ?? "").prefix(3000)))" as NSString
        var best: (score: Int, value: String)?
        let full = NSRange(location: 0, length: body.length)
        for kw in codeWords.matches(in: body as String, range: full) {
            let start = max(0, kw.range.location - 40)
            let end = min(body.length, NSMaxRange(kw.range) + 80)
            let window = NSRange(location: start, length: end - start)
            for tok in codeToken.matches(in: body as String, options: [.withTransparentBounds], range: window) {
                let value = body.substring(with: tok.range(at: 1)).replacingOccurrences(of: "[ -]", with: "", options: .regularExpression)
                let overlaps = tok.range.location < NSMaxRange(kw.range) && NSMaxRange(tok.range) > kw.range.location
                let gap = overlaps ? 0 : min(abs(tok.range.location - NSMaxRange(kw.range)), abs(kw.range.location - NSMaxRange(tok.range)))
                if year.firstMatch(in: value, range: NSRange(location: 0, length: value.utf16.count)) != nil, gap > 8 { continue }
                if value.allSatisfy(\.isLetter) { continue }
                let score = gap + (tok.range.location >= NSMaxRange(kw.range) ? 0 : 6)
                if best == nil || score < best!.score { best = (score, value) }
            }
        }
        return best?.value
    }

    private static let unsubLink = regex("<a\\b[^>]*?href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>", [.caseInsensitive, .dotMatchesLineSeparators])
    private static let unsubWords = regex(
        "unsubscribe|opt[- ]?out|退订|取消订阅|退訂|取消訂閱|订阅设置|manage (?:your )?(?:email )?preferences", .caseInsensitive)
    private static let angle = regex("<([^>]+)>")

    struct Unsub: Codable {
        var url: String?
        var mailto: String?
        var oneClick: Bool
    }

    /// What we know about leaving a mailing list: (kind, info) with kind one_click, link or mailto.
    static func unsubInfo(headers: [String: String], html: String) -> (kind: String, info: Unsub)? {
        var urls: [String] = []
        var mailto: String?
        let header = (headers["list-unsubscribe"] ?? "") as NSString
        for m in angle.matches(in: header as String, range: NSRange(location: 0, length: header.length)) {
            let part = header.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let lower = part.lowercased()
            if lower.hasPrefix("https://") || lower.hasPrefix("http://") { urls.append(part) }
            else if lower.hasPrefix("mailto:") { mailto = part }
        }
        let oneClick = (headers["list-unsubscribe-post"] ?? "").lowercased().contains("one-click")
        if let first = urls.first {
            let kind = oneClick && first.lowercased().hasPrefix("https://") ? "one_click" : "link"
            return (kind, Unsub(url: first, mailto: mailto, oneClick: kind == "one_click"))
        }
        let nsHTML = html as NSString
        for m in unsubLink.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)) {
            let href = nsHTML.substring(with: m.range(at: 1))
            let label = nsHTML.substring(with: m.range(at: 2)).replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            let probe = label + " " + href
            if href.lowercased().hasPrefix("http"), unsubWords.firstMatch(in: probe, range: NSRange(location: 0, length: probe.utf16.count)) != nil {
                return ("link", Unsub(url: href.replacingOccurrences(of: "&amp;", with: "&"), mailto: mailto, oneClick: false))
            }
        }
        if let mailto { return ("mailto", Unsub(url: nil, mailto: mailto, oneClick: false)) }
        return nil
    }

    /// Splits a From header into (display name, lowercased address).
    static func parseAddress(_ raw: String) -> (name: String, address: String) {
        let pattern = regex("\\s*\"?([^\"<]*?)\"?\\s*<([^>]+)>")
        let ns = raw as NSString
        if let m = pattern.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let addr = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            return (name.isEmpty ? addr : name, addr.lowercased())
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return (trimmed, trimmed.lowercased())
    }

    static func stripTags(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<(script|style|head)[^>]*>[\\s\\S]*?</\\1>", with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, value) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True for an http(s) URL that is not aimed at this machine or the local network.
    static func isPublicURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".internal") || !host.contains(".") && !host.contains(":") { return false }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            let (a, b) = (parts[0], parts[1])
            if a == 10 || a == 127 || a == 0 || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) { return false }
        }
        if host.contains(":") { return false }
        return true
    }
}
