import Foundation

public struct MailTranslationPipeline: Sendable {
    static func hasContent(body: String, isHTML: Bool) throws -> Bool {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let document = try TranslationDocument(body: body, isHTML: isHTML, limit: 7_000)
        return document.slots.contains { !$0.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public let maxCharacters: Int
    public let maxItems: Int
    public let concurrency: Int

    public init(maxCharacters: Int = 7_000, maxItems: Int = 80, concurrency: Int = 3) throws {
        guard maxCharacters > 0, maxItems > 0, maxItems <= 80, (1...3).contains(concurrency) else {
            throw MailTranslationError.invalidLimits
        }
        self.maxCharacters = maxCharacters
        self.maxItems = maxItems
        self.concurrency = concurrency
    }

    /// Returns the complete body only after every chunk has validated. HTML remains
    /// HTML; plain text remains plain text for MailHTMLView's existing pre-wrap path.
    public func translate(body: String, isHTML: Bool, using translator: any MailTextTranslator) async throws -> String {
        let document = try TranslationDocument(body: body, isHTML: isHTML, limit: maxCharacters)
        let groups = document.groups
        guard !groups.isEmpty else { return body }
        var chunks: [[TranslationItem]] = []
        var chunk: [TranslationItem] = []
        var count = 0
        for (id, group) in groups.enumerated() {
            if !chunk.isEmpty && (count + group.sourceCount > maxCharacters || chunk.count == maxItems) {
                chunks.append(chunk); chunk = []; count = 0
            }
            chunk.append(TranslationItem(i: id, t: group.payload))
            count += group.sourceCount
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        // Capture only Sendable JSON values across child tasks, never XML nodes.
        let batches = chunks
        let translations = try await withThrowingTaskGroup(of: [Int: String].self) { tasks in
            var next = 0
            func enqueue(_ index: Int) {
                let items = batches[index]
                tasks.addTask {
                    try Task.checkCancellation()
                    let request = try TranslationRequest(items: items)
                    return try request.decode(await translator.translate(request), expected: items)
                }
            }
            while next < min(concurrency, batches.count) { enqueue(next); next += 1 }
            var result: [Int: String] = [:]
            while let completed = try await tasks.next() {
                result.merge(completed) { first, _ in first }
                if next < batches.count { enqueue(next); next += 1 }
            }
            return result
        }
        try Task.checkCancellation()
        return try document.render(translations)
    }
}

private final class TranslationDocument {
    struct Slot {
        let node: XMLNode?
        let original: String
    }
    struct Piece {
        let slot: Int
        let text: String
    }
    struct Group {
        let pieces: [Piece]
        let markers: [String]
        var sourceCount: Int { pieces.reduce(0) { $0 + $1.text.count } }
        var payload: String {
            if pieces.count == 1 { return pieces[0].text }
            return pieces.enumerated().map { markers[$0.offset] + $0.element.text }.joined() + markers.last!
        }
        func decode(_ value: String) throws -> [String] {
            guard pieces.count > 1 else { return [value] }
            var remainder = value[...]
            var result: [String] = []
            guard remainder.hasPrefix(markers[0]) else { throw MailTranslationError.alignmentFailed }
            remainder = remainder.dropFirst(markers[0].count)
            for marker in markers.dropFirst() {
                guard let range = remainder.range(of: marker) else { throw MailTranslationError.alignmentFailed }
                let fragment = String(remainder[..<range.lowerBound])
                guard !fragment.contains("⟦pigi:") else { throw MailTranslationError.alignmentFailed }
                result.append(fragment)
                remainder = remainder[range.upperBound...]
            }
            // The closing boundary already ended the final text node. Providers
            // sometimes append text outside it; discard that text, never render it.
            // Extra or truncated markers still mean ambiguous/corrupt alignment.
            guard !remainder.contains("⟦pigi:") else { throw MailTranslationError.alignmentFailed }
            return result
        }
    }

    var slots: [Slot] = []
    var groups: [Group] = []
    let xml: XMLDocument?
    let nonce = UUID().uuidString

    init(body: String, isHTML: Bool, limit: Int) throws {
        if isHTML {
            xml = try XMLDocument(xmlString: body, options: [.documentTidyHTML, .nodePreserveAll, .nodeLoadExternalEntitiesNever])
            var pending: [Piece] = []
            let blocks: Set<String> = ["html", "body", "div", "p", "section", "article", "header", "footer", "table", "thead", "tbody", "tr", "td", "th", "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "br", "hr"]
            let excluded: Set<String> = ["head", "style", "script", "code", "pre", "noscript", "svg", "math", "textarea"]
            func flush() { append(pending, limit: limit); pending = [] }
            func visit(_ node: XMLNode) {
                let name = node.name?.lowercased() ?? ""
                if excluded.contains(name) { flush(); return }
                let boundary = blocks.contains(name)
                if boundary { flush() }
                if node.kind == .text {
                    let text = node.stringValue ?? ""
                    let slot = slots.count
                    slots.append(Slot(node: node, original: text))
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    // A protected node must never be reintroduced when adjacent
                    // English makes the combined paragraph translatable.
                    if !trimmed.isEmpty && !TranslationLanguage.shouldTranslate(text) {
                        flush()
                    } else { pending.append(Piece(slot: slot, text: text)) }
                } else { for child in node.children ?? [] { visit(child) } }
                if boundary { flush() }
            }
            if let root = xml?.rootElement() { visit(root) }
            flush()
        } else {
            xml = nil
            // Keep paragraph separators byte-for-byte, including CRLF mail bodies.
            let regex = try NSRegularExpression(pattern: "(?:\\r?\\n[\\t ]*){2,}")
            let source = body as NSString
            var start = 0
            for match in regex.matches(in: body, range: NSRange(location: 0, length: source.length)) {
                addPlain(source.substring(with: NSRange(location: start, length: match.range.location - start)), limit: limit)
                slots.append(Slot(node: nil, original: source.substring(with: match.range)))
                start = NSMaxRange(match.range)
            }
            addPlain(source.substring(from: start), limit: limit)
        }
    }

    private func addPlain(_ text: String, limit: Int) {
        let slot = slots.count
        slots.append(Slot(node: nil, original: text))
        append([Piece(slot: slot, text: text)], limit: limit)
    }

    private func append(_ pieces: [Piece], limit: Int) {
        guard TranslationLanguage.shouldTranslate(pieces.map(\.text).joined()) else { return }
        var batch: [Piece] = []
        var size = 0
        func flush() {
            guard !batch.isEmpty else { return }
            let prefix = "⟦pigi:\(nonce):\(groups.count):"
            groups.append(Group(pieces: batch, markers: (0...batch.count).map { prefix + "\($0)⟧" }))
            batch = []; size = 0
        }
        for piece in pieces {
            var rest = piece.text[...]
            while !rest.isEmpty {
                if size == limit { flush() }
                let part = String(rest.prefix(limit - size))
                batch.append(Piece(slot: piece.slot, text: part))
                size += part.count
                rest = rest.dropFirst(part.count)
            }
        }
        flush()
    }

    func render(_ translations: [Int: String]) throws -> String {
        var replacements: [Int: String] = [:]
        for (id, group) in groups.enumerated() {
            guard let translated = translations[id] else { throw MailTranslationError.alignmentFailed }
            let fragments = try group.decode(translated)
            for (piece, fragment) in zip(group.pieces, fragments) {
                replacements[piece.slot, default: ""] += fragment
            }
        }
        if let xml {
            for (slot, text) in replacements {
                // XMLNode escapes text on serialization; output never becomes markup.
                slots[slot].node?.stringValue = text
            }
            return xml.xmlString(options: [.nodePreserveAll])
        }
        return slots.enumerated().map { replacements[$0.offset] ?? $0.element.original }.joined()
    }
}
