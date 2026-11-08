import Foundation

/// One decoded `cid:` image kept with the message. The stored HTML is left
/// unchanged so translation and search never receive the bytes.
public struct MailInlineImage: Sendable, Equatable, Hashable {
    public let contentID: String
    public let mime: String
    public let data: Data

    public init(contentID: String, mime: String, data: Data) {
        self.contentID = contentID
        self.mime = mime
        self.data = data
    }
}

/// Rewrites `cid:` URLs to `data:` URLs for raster images the message actually
/// contains. SVG and other types stay untouched: a data URL of those types can
/// carry markup, and the web view's CSP already allows `data:` images.
public enum InlineImages {
    public static let maxBytes = 5 * 1024 * 1024

    public static func embed(_ html: String, images: [MailInlineImage]) -> String {
        guard !html.isEmpty, !images.isEmpty else { return html }
        var urls: [String: String] = [:]
        for image in images {
            let key = normalizeContentID(image.contentID)
            guard !key.isEmpty, urls[key] == nil, let url = dataURL(mime: image.mime, data: image.data) else { continue }
            urls[key] = url
        }
        guard !urls.isEmpty else { return html }
        var result = ""
        result.reserveCapacity(html.utf8.count)
        var index = html.startIndex
        while index < html.endIndex {
            if isCID(html, at: index), isURLContext(html, at: index) {
                let tokenEnd = scanToken(html, from: html.index(index, offsetBy: 4))
                let key = normalizeContentID(String(html[html.index(index, offsetBy: 4)..<tokenEnd]))
                if let url = urls[key] {
                    result += url
                    index = tokenEnd
                    continue
                }
            }
            result.append(html[index])
            index = html.index(after: index)
        }
        return result
    }

    /// `<Pixel@Example.Test>`, `cid:Pixel%40Example.Test` and the bare id match.
    public static func normalizeContentID(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("cid:") { text = String(text.dropFirst(4)) }
        text = text.replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
            .replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
            .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<"), let end = text.lastIndex(of: ">"), end > text.startIndex {
            text = String(text[text.index(after: text.startIndex)..<end])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let decoded = text.removingPercentEncoding, !decoded.isEmpty { text = decoded }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Raster types WebKit can paint as an image without parsing markup.
    public static func canonicalMime(_ mime: String) -> String? {
        switch baseMime(mime) {
        case "image/jpeg", "image/jpg", "image/pjpeg": return "image/jpeg"
        case "image/png", "image/x-png": return "image/png"
        case "image/gif": return "image/gif"
        case "image/webp": return "image/webp"
        case "image/bmp", "image/x-ms-bmp": return "image/bmp"
        case "image/avif": return "image/avif"
        case "image/heic": return "image/heic"
        case "image/heif": return "image/heif"
        default: return nil
        }
    }

    public static func declaredMime(_ mime: String) -> String {
        canonicalMime(mime) ?? baseMime(mime)
    }

    public static func dataURL(mime: String, data: Data) -> String? {
        guard let mime = canonicalMime(mime), !data.isEmpty, data.count <= maxBytes else { return nil }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    private static func baseMime(_ mime: String) -> String {
        mime.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
    }

    private static func isCID(_ html: String, at index: String.Index) -> Bool {
        if index > html.startIndex {
            let previous = html[html.index(before: index)]
            if previous.isLetter || previous.isNumber { return false }
        }
        var cursor = index
        for expected in ["c", "i", "d", ":"] {
            guard cursor < html.endIndex, String(html[cursor]).lowercased() == expected else { return false }
            cursor = html.index(after: cursor)
        }
        return true
    }

    /// Only URL positions: `src=`, `url(`, or the next candidate in a srcset list.
    private static func isURLContext(_ html: String, at index: String.Index) -> Bool {
        var cursor = index
        if cursor > html.startIndex {
            let previous = html[html.index(before: cursor)]
            if previous == "\"" || previous == "'" { cursor = html.index(before: cursor) }
        }
        while cursor > html.startIndex {
            let previous = html[html.index(before: cursor)]
            if previous == " " || previous == "\n" || previous == "\r" || previous == "\t" {
                cursor = html.index(before: cursor)
                continue
            }
            return previous == "=" || previous == "(" || previous == ","
        }
        return false
    }

    private static func scanToken(_ html: String, from index: String.Index) -> String.Index {
        var cursor = index
        while cursor < html.endIndex {
            let character = html[cursor]
            if character == "\"" || character == "'" || character == "(" || character == ")"
                || character == "<" || character == ">" || character == "," || character == "\\"
                || character == " " || character == "\n" || character == "\r" || character == "\t" {
                break
            }
            cursor = html.index(after: cursor)
        }
        return cursor
    }
}
