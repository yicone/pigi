import Foundation

/// A small RFC 5322 / MIME reader: enough to pull headers, text, html and attachment names out of a raw message.
struct ParsedMail {
    var headers: [String: String] = [:]
    var text = ""
    var html = ""
    var attachments: [(name: String, mime: String, size: Int)] = []
}

enum MIME {
    static func parse(_ raw: Data) -> ParsedMail {
        var result = ParsedMail()
        walk(raw, into: &result, top: true)
        return result
    }

    // MARK: structure

    private static func split(_ data: Data) -> (head: Data, body: Data) {
        let crlf = Data("\r\n\r\n".utf8), lf = Data("\n\n".utf8)
        let a = data.range(of: crlf), b = data.range(of: lf)
        let range: Range<Data.Index>?
        switch (a, b) {
        case let (x?, y?): range = x.lowerBound <= y.lowerBound ? x : y
        case let (x?, nil): range = x
        case let (nil, y?): range = y
        default: range = nil
        }
        guard let range else { return (data, Data()) }
        return (data[data.startIndex..<range.lowerBound], data[range.upperBound...])
    }

    private static func headers(_ head: Data) -> [String: String] {
        let text = String(decoding: head, as: UTF8.self)
        var unfolded: [String] = []
        for line in text.components(separatedBy: "\n") {
            let clean = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if (clean.hasPrefix(" ") || clean.hasPrefix("\t")), !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += " " + clean.trimmingCharacters(in: .whitespaces)
            } else if !clean.isEmpty {
                unfolded.append(clean)
            }
        }
        var out: [String: String] = [:]
        for line in unfolded {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if out[name] == nil { out[name] = value }
        }
        return out
    }

    private static func walk(_ data: Data, into result: inout ParsedMail, top: Bool) {
        let (head, body) = split(data)
        let h = headers(head)
        if top { result.headers = h.mapValues(decodeWords) }
        let type = h["content-type"] ?? "text/plain"
        let mime = type.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "text/plain"
        let params = parameters(type)
        if mime.hasPrefix("multipart/"), let boundary = params["boundary"] {
            for part in parts(of: body, boundary: boundary) { walk(part, into: &result, top: false) }
            return
        }
        let disposition = h["content-disposition"] ?? ""
        let filename = parameters(disposition)["filename"] ?? params["name"]
        let decoded = transferDecoded(body, encoding: (h["content-transfer-encoding"] ?? "").lowercased())
        if disposition.lowercased().hasPrefix("attachment") || (filename != nil && !mime.hasPrefix("text/")) {
            result.attachments.append((decodeWords(filename ?? "attachment"), mime, decoded.count))
        } else if mime == "text/html" || mime == "text/plain" {
            let text = string(decoded, charset: params["charset"])
            if mime == "text/html" { result.html += (result.html.isEmpty ? "" : "\n") + text }
            else { result.text += (result.text.isEmpty ? "" : "\n") + text }
        } else if let filename {
            result.attachments.append((decodeWords(filename), mime, decoded.count))
        }
    }

    private static func parts(of body: Data, boundary: String) -> [Data] {
        let marker = Data("--\(boundary)".utf8)
        var pieces: [Data] = []
        var cursor = body.startIndex
        var ranges: [Range<Data.Index>] = []
        while let r = body.range(of: marker, in: cursor..<body.endIndex) {
            ranges.append(r)
            cursor = r.upperBound
        }
        for (i, r) in ranges.enumerated() {
            var start = r.upperBound
            if body[start...].starts(with: Data("--".utf8)) { break }
            while start < body.endIndex, body[start] == 13 || body[start] == 10 {
                start += 1
                if body[start - 1] == 10 { break }
            }
            var end = i + 1 < ranges.count ? ranges[i + 1].lowerBound : body.endIndex
            while end > start, body[end - 1] == 10 || body[end - 1] == 13 { end -= 1 }
            if start < end { pieces.append(body[start..<end]) }
        }
        return pieces
    }

    private static func parameters(_ header: String) -> [String: String] {
        var out: [String: String] = [:]
        let pieces = header.split(separator: ";").dropFirst()
        for piece in pieces {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            var name = piece[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            if name.hasSuffix("*") {  // RFC 2231: filename*=utf-8''%E4%B8%AD
                name.removeLast()
                if let quote = value.range(of: "''") { value = String(value[quote.upperBound...]).removingPercentEncoding ?? value }
            }
            out[name] = value
        }
        return out
    }

    // MARK: decoding

    private static func transferDecoded(_ body: Data, encoding: String) -> Data {
        switch encoding {
        case "base64":
            let text = String(decoding: body, as: UTF8.self).filter { !$0.isWhitespace }
            return Data(base64Encoded: text, options: .ignoreUnknownCharacters) ?? body
        case "quoted-printable": return quotedPrintable(body)
        default: return body
        }
    }

    static func quotedPrintable(_ data: Data, underscoreIsSpace: Bool = false) -> Data {
        var out = Data()
        let bytes = Array(data)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 61 {  // "="
                if i + 1 < bytes.count, bytes[i + 1] == 10 { i += 2; continue }
                if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { i += 3; continue }
                if i + 2 < bytes.count, let v = UInt8(String(decoding: bytes[i + 1...i + 2], as: UTF8.self), radix: 16) {
                    out.append(v); i += 3; continue
                }
            }
            out.append(underscoreIsSpace && b == 95 ? 32 : b)
            i += 1
        }
        return out
    }

    static func string(_ data: Data, charset: String?) -> String {
        let name = (charset ?? "utf-8").trimmingCharacters(in: .whitespaces)
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        if cf != kCFStringEncodingInvalidId {
            let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            if let s = String(data: data, encoding: enc) { return s }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes RFC 2047 encoded words ("=?utf-8?B?...?=") inside a header value.
    static func decodeWords(_ value: String) -> String {
        guard value.contains("=?"), let pattern = try? NSRegularExpression(pattern: "=\\?([^?]+)\\?([bBqQ])\\?([^?]*)\\?=") else { return value }
        let ns = value as NSString
        var out = ""
        var cursor = 0
        var lastWasWord = false
        for m in pattern.matches(in: value, range: NSRange(location: 0, length: ns.length)) {
            let gap = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            if !(lastWasWord && gap.allSatisfy(\.isWhitespace)) { out += gap }
            let charset = ns.substring(with: m.range(at: 1)).components(separatedBy: "*").first
            let payload = ns.substring(with: m.range(at: 3))
            let data: Data
            if ns.substring(with: m.range(at: 2)).lowercased() == "b" {
                data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) ?? Data()
            } else {
                data = quotedPrintable(Data(payload.utf8), underscoreIsSpace: true)
            }
            out += string(data, charset: charset)
            cursor = NSMaxRange(m.range)
            lastWasWord = true
        }
        out += ns.substring(from: cursor)
        return out
    }
}
