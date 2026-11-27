import Foundation

/// One list row the user can see. Subject and snippet are the only fields that may be sent.
public struct ListTranslationRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let accountID: String
    public let subject: String
    public let snippet: String

    public init(id: String, accountID: String, subject: String, snippet: String) {
        self.id = id
        self.accountID = accountID
        self.subject = subject
        self.snippet = snippet
    }
}

/// Vertical span of a row in the list's viewport coordinate space.
public struct ListRowFrame: Sendable, Equatable, Identifiable {
    public let id: String
    public let minY: Double
    public let maxY: Double

    public init(id: String, minY: Double, maxY: Double) {
        self.id = id
        self.minY = minY
        self.maxY = maxY
    }
}

public enum ListViewport {
    /// A row is visible when its original point span overlaps the viewport, including a partial edge.
    /// A row that only touches the boundary, or sits fully outside, is not visible.
    public static func overlapsViewport(_ frame: ListRowFrame, viewportMinY: Double, viewportMaxY: Double) -> Bool {
        frame.maxY > frame.minY && frame.minY < viewportMaxY && frame.maxY > viewportMinY
    }

    /// True when an edge lies on the viewport boundary and the row does not overlap it.
    public static func touchesViewportBoundary(_ frame: ListRowFrame, viewportMinY: Double, viewportMaxY: Double) -> Bool {
        guard frame.maxY > frame.minY, viewportMaxY > viewportMinY else { return false }
        let touches = frame.minY == viewportMaxY || frame.maxY == viewportMinY
        return touches && !overlapsViewport(frame, viewportMinY: viewportMinY, viewportMaxY: viewportMaxY)
    }

    public static func visibleIDs(_ frames: [ListRowFrame], viewportMinY: Double, viewportMaxY: Double) -> [String] {
        guard viewportMaxY > viewportMinY else { return [] }
        var seen = Set<String>()
        return frames
            .filter { overlapsViewport($0, viewportMinY: viewportMinY, viewportMaxY: viewportMaxY) }
            .sorted { lhs, rhs in
                if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
                return lhs.id < rhs.id
            }
            .compactMap { frame in
                guard seen.insert(frame.id).inserted else { return nil }
                return frame.id
            }
    }

    /// Keep viewport order. Ids that are not in the current list are dropped.
    public static func rows(ids: [String], candidates: [ListTranslationRow]) -> [ListTranslationRow] {
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted, let row = byID[id] else { return nil }
            return row
        }
    }
}

/// Display copy for one row. `sourceHash` binds it to the subject and snippet it was made from.
public struct ListRowTranslation: Sendable, Equatable {
    public let subject: String
    public let snippet: String
    public let sourceHash: String

    public init(subject: String, snippet: String, sourceHash: String) {
        self.subject = subject
        self.snippet = snippet
        self.sourceHash = sourceHash
    }
}

public struct ListTranslationSkip: Sendable, Equatable {
    public let mailID: String
    public let accountID: String
    public let permission: TranslationPermission

    public init(mailID: String, accountID: String, permission: TranslationPermission) {
        self.mailID = mailID
        self.accountID = accountID
        self.permission = permission
    }
}

public struct ListBatchOutcome: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case completed
        case cancelled
        case failed
        case empty
    }

    public var status: Status
    public var translations: [String: ListRowTranslation]
    public var skipped: [ListTranslationSkip]
    public var requestCount: Int
    public var failure: TranslationError?

    public init(status: Status, translations: [String: ListRowTranslation] = [:], skipped: [ListTranslationSkip] = [],
                requestCount: Int = 0, failure: TranslationError? = nil) {
        self.status = status
        self.translations = translations
        self.skipped = skipped
        self.requestCount = requestCount
        self.failure = failure
    }
}

/// List previews use their own cache mail id so a write cannot delete the whole-mail translation.
public enum ListTranslationCache {
    public static let mailIDPrefix = "list-preview:"

    public static func cacheMailID(_ mailID: String) -> String { mailIDPrefix + mailID }

    public static func sourceHash(subject: String, snippet: String) -> String {
        TranslationCacheKey.sourceHash(subject: subject, body: snippet, isHTML: false)
    }

    public static func key(row: ListTranslationRow, configuration: TranslationConfig) -> TranslationCacheKey {
        TranslationCacheKey(accountID: row.accountID, mailID: cacheMailID(row.id),
            bodyHash: sourceHash(subject: row.subject, snippet: row.snippet), configuration: configuration)
    }
}

/// Production uses the keychain and shared cache. A regression process can install a stand-in first.
public struct ListTranslationSession: Sendable {
    public var credentialConfigured: @Sendable () -> Bool
    public var makeTranslator: @Sendable (TranslationConfig) -> any SegmentTranslator
    public var cache: any TranslationCache

    public init(credentialConfigured: @escaping @Sendable () -> Bool,
                makeTranslator: @escaping @Sendable (TranslationConfig) -> any SegmentTranslator,
                cache: any TranslationCache) {
        self.credentialConfigured = credentialConfigured
        self.makeTranslator = makeTranslator
        self.cache = cache
    }

    public static func production() -> ListTranslationSession {
        ListTranslationSession(
            credentialConfigured: { ((try? KeychainKeyStore().apiKey()) ?? nil)?.isEmpty == false },
            makeTranslator: { OpenAICompatibleTranslator(config: $0, keyStore: KeychainKeyStore()) },
            cache: SQLiteTranslationCache.shared)
    }
}

public enum ListTranslationDisplay {
    /// Stale cache (the subject or snippet changed) stays off the row. The stored mail is unchanged.
    public static func text(subject: String, snippet: String, translation: ListRowTranslation?) -> (subject: String, snippet: String, translated: Bool) {
        guard let translation, translation.sourceHash == ListTranslationCache.sourceHash(subject: subject, snippet: snippet) else {
            return (subject, snippet, false)
        }
        return (translation.subject, translation.snippet, true)
    }
}

/// Translates the subject and snippet of rows the caller already decided are visible.
/// Nothing is sent until `confirm` returns true. A cancelled confirmation performs no request.
/// `isCurrent` is the caller's generation check. Once it is false, a finished response is not stored or returned.
@MainActor
public struct ListBatchTranslator {
    public init() {}

    public func run(
        rows: [ListTranslationRow],
        policy: any TranslationPolicy,
        configuration: TranslationConfig,
        cache: any TranslationCache,
        translator: any SegmentTranslator,
        confirm: @escaping @MainActor (_ sending: Int, _ skipped: Int) async -> Bool,
        isCurrent: (@MainActor () -> Bool)? = nil
    ) async -> ListBatchOutcome {
        var skipped: [ListTranslationSkip] = []
        var pending: [Pending] = []
        var seen = Set<String>()
        for row in rows {
            guard seen.insert(row.id).inserted else { continue }
            let permission = policy.permission(forAccount: row.accountID)
            guard permission == .allowed else {
                skipped.append(ListTranslationSkip(mailID: row.id, accountID: row.accountID, permission: permission))
                continue
            }
            let translateSubject = TranslationLanguage.shouldTranslate(row.subject)
            let translateSnippet = TranslationLanguage.shouldTranslate(row.snippet)
            guard translateSubject || translateSnippet else { continue }
            let key = ListTranslationCache.key(row: row, configuration: configuration)
            let hit: CachedTranslation?
            do {
                hit = try await cache.get(key)
            } catch is CancellationError {
                return ListBatchOutcome(status: .cancelled, skipped: skipped)
            } catch {
                return ListBatchOutcome(status: .failed, skipped: skipped, failure: .network("缓存读取失败"))
            }
            let cached = hit.map {
                ListRowTranslation(subject: $0.subject, snippet: $0.body, sourceHash: key.bodyHash)
            }
            pending.append(Pending(row: row, translateSubject: translateSubject, translateSnippet: translateSnippet,
                                   key: key, cached: cached))
        }

        let misses = pending.filter { $0.cached == nil }
        if misses.isEmpty {
            let translations = Dictionary(uniqueKeysWithValues: pending.compactMap { item -> (String, ListRowTranslation)? in
                guard let cached = item.cached else { return nil }
                return (item.row.id, cached)
            })
            guard !translations.isEmpty else { return ListBatchOutcome(status: .empty, skipped: skipped) }
            return ListBatchOutcome(status: .completed, translations: translations, skipped: skipped)
        }

        let allowed = await confirm(misses.count, skipped.count)
        if !allowed || Task.isCancelled || isCurrent?() == false {
            return ListBatchOutcome(status: .cancelled, skipped: skipped)
        }

        var segments: [TranslationSegment] = []
        var bindings: [Binding] = []
        var nextID = 1
        for item in misses {
            if item.translateSubject {
                segments.append(TranslationSegment(id: nextID, text: item.row.subject))
                bindings.append(Binding(mailID: item.row.id, field: .subject, segmentID: nextID))
                nextID += 1
            }
            if item.translateSnippet {
                segments.append(TranslationSegment(id: nextID, text: item.row.snippet))
                bindings.append(Binding(mailID: item.row.id, field: .snippet, segmentID: nextID))
                nextID += 1
            }
        }
        guard !segments.isEmpty else {
            return ListBatchOutcome(status: .empty, skipped: skipped)
        }

        // Take tickets before the request so a clear or purge during the call cannot be overwritten.
        var tickets: [String: SQLiteTranslationCache.Ticket] = [:]
        var requested = false
        let translated: [TranslationSegment]
        do {
            for item in misses {
                try Task.checkCancellation()
                if isCurrent?() == false { throw CancellationError() }
                tickets[item.row.id] = try await cache.begin(item.key)
            }
            if isCurrent?() == false { throw CancellationError() }
            requested = true
            translated = try await translator.translate(segments)
            try Task.checkCancellation()
            if isCurrent?() == false { throw CancellationError() }
        } catch is CancellationError {
            return ListBatchOutcome(status: .cancelled, skipped: skipped, requestCount: requested ? 1 : 0)
        } catch let error as TranslationError {
            if case .cancelled = error {
                return ListBatchOutcome(status: .cancelled, skipped: skipped, requestCount: requested ? 1 : 0, failure: error)
            }
            return ListBatchOutcome(status: .failed, skipped: skipped, requestCount: requested ? 1 : 0, failure: error)
        } catch {
            return ListBatchOutcome(status: .failed, skipped: skipped, requestCount: requested ? 1 : 0,
                                    failure: .network(requested ? "请求失败" : "缓存读取失败"))
        }

        let byID = Dictionary(translated.map { ($0.id, $0.text) }, uniquingKeysWith: { _, latest in latest })
        guard byID.count == translated.count, Set(byID.keys) == Set(segments.map(\.id)) else {
            return ListBatchOutcome(status: .failed, skipped: skipped, requestCount: 1, failure: .misaligned)
        }

        var fresh: [String: ListRowTranslation] = [:]
        for item in misses {
            let subjectID = bindings.first { $0.mailID == item.row.id && $0.field == .subject }?.segmentID
            let snippetID = bindings.first { $0.mailID == item.row.id && $0.field == .snippet }?.segmentID
            let subject = subjectID.flatMap { byID[$0] } ?? item.row.subject
            let snippet = snippetID.flatMap { byID[$0] } ?? item.row.snippet
            fresh[item.row.id] = ListRowTranslation(subject: subject, snippet: snippet, sourceHash: item.key.bodyHash)
        }

        let entries: [(value: CachedTranslation, ticket: SQLiteTranslationCache.Ticket)]
        do {
            entries = try misses.map { item in
                guard let value = fresh[item.row.id], let ticket = tickets[item.row.id] else { throw TranslationError.misaligned }
                return (CachedTranslation(subject: value.subject, body: value.snippet), ticket)
            }
            try Task.checkCancellation()
            if isCurrent?() == false { throw CancellationError() }
            // One commit. A later row failing or a cancellation rolls the whole batch back.
            // A stale generation is rejected above and never reaches this commit.
            try await cache.putAll(entries, validated: true)
        } catch is CancellationError {
            return ListBatchOutcome(status: .cancelled, skipped: skipped, requestCount: 1)
        } catch let error as TranslationError {
            return ListBatchOutcome(status: .failed, skipped: skipped, requestCount: 1, failure: error)
        } catch {
            return ListBatchOutcome(status: .failed, skipped: skipped, requestCount: 1, failure: .network("缓存写入失败"))
        }

        var translations: [String: ListRowTranslation] = [:]
        for item in pending {
            if let cached = item.cached { translations[item.row.id] = cached }
            if let value = fresh[item.row.id] { translations[item.row.id] = value }
        }
        return ListBatchOutcome(status: .completed, translations: translations, skipped: skipped, requestCount: 1)
    }
}

private struct Pending {
    let row: ListTranslationRow
    let translateSubject: Bool
    let translateSnippet: Bool
    let key: TranslationCacheKey
    let cached: ListRowTranslation?
}

private struct Binding {
    enum Field { case subject, snippet }
    let mailID: String
    let field: Field
    let segmentID: Int
}
