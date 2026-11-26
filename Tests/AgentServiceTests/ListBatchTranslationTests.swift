import XCTest
@testable import PigiCore

@MainActor
final class ListBatchTranslationTests: XCTestCase {
    private let chinese = "这是一封中文邮件，请查看附件并回复，谢谢。"

    func testVisibleBoundaryDropsOffscreenAndRowsOutsideTheCurrentList() {
        let frames = [
            ListRowFrame(id: "below", minY: 100, maxY: 140),
            ListRowFrame(id: "partial-top", minY: -8, maxY: 6),
            ListRowFrame(id: "above", minY: -40, maxY: 0),
            ListRowFrame(id: "inside", minY: 20, maxY: 48),
            ListRowFrame(id: "partial-bottom", minY: 96, maxY: 110),
            ListRowFrame(id: "inside", minY: 20, maxY: 48),
        ]
        let ids = ListViewport.visibleIDs(frames, viewportMinY: 0, viewportMaxY: 100)
        XCTAssertEqual(ids, ["partial-top", "inside", "partial-bottom"])
        XCTAssertEqual(ListViewport.visibleIDs(frames, viewportMinY: 0, viewportMaxY: 0), [])

        let candidates = ["partial-top", "inside", "below", "filtered-out"].map { row($0) }
        let selected = ListViewport.rows(ids: ids, candidates: candidates)
        XCTAssertEqual(selected.map(\.id), ["partial-top", "inside"])
        XCTAssertFalse(selected.contains { $0.id == "below" || $0.id == "filtered-out" || $0.id == "partial-bottom" })
    }

    func testMixedAccountsSkipDisabledRows() async {
        let allowed = row("visible", account: "allowed@example.invalid", subject: "Quarterly report", snippet: "Please review the attached document.")
        let disabled = row("hidden", account: "disabled@example.invalid", subject: "Hidden roadmap", snippet: "Do not send this row.")
        let proton = row("proton", account: "proton@example.invalid", subject: "Encrypted note", snippet: "Still skip the whole row.")
        let translator = RecordingTranslator()
        var confirmed = false
        let outcome = await ListBatchTranslator().run(
            rows: [allowed, disabled, proton],
            policy: FixedPolicy(decisions: [
                allowed.accountID: .allowed,
                disabled.accountID: .disabled,
                proton.accountID: .needsAccountConsent,
            ]),
            configuration: configuration(),
            cache: SQLiteTranslationCache(path: ":memory:"),
            translator: translator,
            confirm: { sending, skipped in
                confirmed = true
                XCTAssertEqual(sending, 1)
                XCTAssertEqual(skipped, 2)
                return true
            })
        XCTAssertTrue(confirmed)
        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(outcome.requestCount, 1)
        XCTAssertEqual(outcome.skipped.map(\.mailID), ["hidden", "proton"])
        XCTAssertEqual(outcome.translations[allowed.id]?.subject, "译:" + allowed.subject)
        XCTAssertNil(outcome.translations[disabled.id])
        XCTAssertNil(outcome.translations[proton.id])
        let sent = translator.calls.flatMap { $0.map(\.text) }
        XCTAssertEqual(translator.calls.count, 1)
        XCTAssertEqual(sent, [allowed.subject, allowed.snippet])
        XCTAssertFalse(sent.contains(disabled.subject) || sent.contains(proton.subject) || sent.contains(disabled.accountID))
    }

    func testCancelledConfirmationSendsNothing() async throws {
        let rows = [row("one", subject: "Hello", snippet: "World"), row("two", subject: "Invoice", snippet: "Due Friday")]
        let translator = RecordingTranslator()
        let cache = SQLiteTranslationCache(path: ":memory:")
        var confirmed = false
        let outcome = await ListBatchTranslator().run(
            rows: rows,
            policy: FixedPolicy(decisions: ["allowed@example.invalid": .allowed]),
            configuration: configuration(),
            cache: cache,
            translator: translator,
            confirm: { _, _ in
                confirmed = true
                return false
            })
        XCTAssertTrue(confirmed)
        XCTAssertEqual(outcome.status, .cancelled)
        XCTAssertEqual(outcome.requestCount, 0)
        XCTAssertTrue(outcome.translations.isEmpty)
        XCTAssertTrue(translator.calls.isEmpty)
        let stored = try await cache.get(ListTranslationCache.key(row: rows[0], configuration: configuration()))
        XCTAssertNil(stored)
        XCTAssertEqual(rows.map(\.subject), ["Hello", "Invoice"])
    }

    func testBatchSuccessCachesListPreviewAndLeavesOriginals() async throws {
        let both = row("both", subject: "Quarterly report", snippet: "Please review the attached document.")
        let subjectOnly = row("subject", subject: "Hello team", snippet: chinese)
        let originals = [both, subjectOnly]
        let indexed = originals.map { $0.subject + "\n" + $0.snippet }
        let cache = SQLiteTranslationCache(path: ":memory:")
        let config = configuration()
        let wholeKey = TranslationCacheKey(accountID: both.accountID, mailID: both.id, bodyHash: "whole-body", configuration: config)
        let whole = CachedTranslation(subject: "整封主题", body: "整封正文不会被列表译文替换")
        try await cache.put(whole, for: try await cache.begin(wholeKey), validated: true)
        let translator = RecordingTranslator()
        let outcome = await ListBatchTranslator().run(
            rows: originals,
            policy: FixedPolicy(decisions: [both.accountID: .allowed]),
            configuration: config,
            cache: cache,
            translator: translator,
            confirm: { sending, skipped in
                XCTAssertEqual(sending, 2)
                XCTAssertEqual(skipped, 0)
                return true
            })
        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(outcome.requestCount, 1)
        XCTAssertEqual(outcome.translations[both.id]?.subject, "译:" + both.subject)
        XCTAssertEqual(outcome.translations[both.id]?.snippet, "译:" + both.snippet)
        XCTAssertEqual(outcome.translations[subjectOnly.id]?.subject, "译:" + subjectOnly.subject)
        XCTAssertEqual(outcome.translations[subjectOnly.id]?.snippet, chinese)
        let sent = translator.calls.flatMap { $0.map(\.text) }
        XCTAssertEqual(sent, [both.subject, both.snippet, subjectOnly.subject])
        XCTAssertFalse(sent.contains(chinese))
        XCTAssertFalse(sent.contains(both.accountID))
        XCTAssertEqual(indexed, originals.map { $0.subject + "\n" + $0.snippet })
        let preserved = try await cache.get(wholeKey)
        XCTAssertEqual(preserved, whole)
        let listHit = try await cache.get(ListTranslationCache.key(row: both, configuration: config))
        XCTAssertEqual(listHit, CachedTranslation(subject: "译:" + both.subject, body: "译:" + both.snippet))
        let realMailWithListHash = TranslationCacheKey(accountID: both.accountID, mailID: both.id,
            bodyHash: ListTranslationCache.sourceHash(subject: both.subject, snippet: both.snippet), configuration: config)
        let leaked = try await cache.get(realMailWithListHash)
        XCTAssertNil(leaked)
        let shown = ListTranslationDisplay.text(subject: both.subject, snippet: both.snippet, translation: outcome.translations[both.id])
        XCTAssertTrue(shown.translated)
        XCTAssertEqual(shown.subject, "译:" + both.subject)
        let stale = ListTranslationDisplay.text(subject: both.subject, snippet: "changed snippet", translation: outcome.translations[both.id])
        XCTAssertFalse(stale.translated)
        XCTAssertEqual(stale.subject, both.subject)
        XCTAssertEqual(stale.snippet, "changed snippet")
    }

    func testFailedAndMisalignedBatchesDoNotWriteCache() async throws {
        let sample = row("mail", subject: "Hello", snippet: "World")
        let config = configuration()
        let failing = RecordingTranslator()
        failing.error = .http(status: 503, message: "unavailable")
        let failedCache = SQLiteTranslationCache(path: ":memory:")
        let failed = await ListBatchTranslator().run(
            rows: [sample], policy: FixedPolicy(decisions: [sample.accountID: .allowed]), configuration: config,
            cache: failedCache, translator: failing, confirm: { _, _ in true })
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.requestCount, 1)
        XCTAssertEqual(failed.failure, .http(status: 503, message: "unavailable"))
        XCTAssertTrue(failed.translations.isEmpty)
        let failedStored = try await failedCache.get(ListTranslationCache.key(row: sample, configuration: config))
        XCTAssertNil(failedStored)

        let misaligned = RecordingTranslator()
        misaligned.replacement = [TranslationSegment(id: 99, text: "错位")]
        let misalignedCache = SQLiteTranslationCache(path: ":memory:")
        let broken = await ListBatchTranslator().run(
            rows: [sample], policy: FixedPolicy(decisions: [sample.accountID: .allowed]), configuration: config,
            cache: misalignedCache, translator: misaligned, confirm: { _, _ in true })
        XCTAssertEqual(broken.status, .failed)
        XCTAssertEqual(broken.failure, .misaligned)
        XCTAssertEqual(broken.requestCount, 1)
        let brokenStored = try await misalignedCache.get(ListTranslationCache.key(row: sample, configuration: config))
        XCTAssertNil(brokenStored)
        XCTAssertEqual(sample.subject, "Hello")
        XCTAssertEqual(sample.snippet, "World")
    }

    func testCancellingTheRequestDoesNotWriteCache() async throws {
        let sample = row("mail", subject: "Hello", snippet: "World")
        let started = expectation(description: "translate started")
        let translator = CancelAfterStartTranslator(started: started)
        let cache = SQLiteTranslationCache(path: ":memory:")
        let task = Task {
            await ListBatchTranslator().run(
                rows: [sample], policy: FixedPolicy(decisions: [sample.accountID: .allowed]), configuration: configuration(),
                cache: cache, translator: translator, confirm: { _, _ in true })
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome.status, .cancelled)
        XCTAssertEqual(outcome.requestCount, 1)
        XCTAssertTrue(outcome.translations.isEmpty)
        let stored = try await cache.get(ListTranslationCache.key(row: sample, configuration: configuration()))
        XCTAssertNil(stored)
    }

    func testStaleGenerationAfterConfirmationSendsNothing() async throws {
        let sample = row("mail", subject: "Hello", snippet: "World")
        let cache = SQLiteTranslationCache(path: ":memory:")
        let translator = RecordingTranslator()
        var current = true
        let outcome = await ListBatchTranslator().run(
            rows: [sample], policy: FixedPolicy(decisions: [sample.accountID: .allowed]), configuration: configuration(),
            cache: cache, translator: translator,
            confirm: { _, _ in
                current = false
                return true
            },
            isCurrent: { current })
        XCTAssertEqual(outcome.status, .cancelled)
        XCTAssertEqual(outcome.requestCount, 0)
        XCTAssertTrue(outcome.translations.isEmpty)
        XCTAssertTrue(translator.calls.isEmpty)
        let stored = try await cache.get(ListTranslationCache.key(row: sample, configuration: configuration()))
        XCTAssertNil(stored)
    }

    func testStaleGenerationAfterResponseWritesNothingAndReturnsNothing() async throws {
        let sample = row("mail", subject: "Hello", snippet: "World")
        let cache = SQLiteTranslationCache(path: ":memory:")
        let current = CurrentFlag()
        let translator = InvalidateOnTranslate { current.value = false }
        let outcome = await ListBatchTranslator().run(
            rows: [sample], policy: FixedPolicy(decisions: [sample.accountID: .allowed]), configuration: configuration(),
            cache: cache, translator: translator, confirm: { _, _ in true },
            isCurrent: { current.value })
        XCTAssertEqual(outcome.status, .cancelled)
        XCTAssertEqual(outcome.requestCount, 1)
        XCTAssertTrue(outcome.translations.isEmpty)
        XCTAssertEqual(translator.calls.count, 1)
        let stored = try await cache.get(ListTranslationCache.key(row: sample, configuration: configuration()))
        XCTAssertNil(stored)
        XCTAssertEqual(sample.subject, "Hello")
        XCTAssertEqual(sample.snippet, "World")
    }

    func testCacheHitSkipsTheRequest() async throws {
        let sample = row("mail", subject: "Hello", snippet: "World")
        let config = configuration()
        let cache = SQLiteTranslationCache(path: ":memory:")
        let key = ListTranslationCache.key(row: sample, configuration: config)
        try await cache.put(CachedTranslation(subject: "你好", body: "世界"), for: try await cache.begin(key), validated: true)
        let translator = RecordingTranslator()
        var confirmed = false
        let outcome = await ListBatchTranslator().run(
            rows: [sample], policy: FixedPolicy(decisions: [sample.accountID: .allowed]), configuration: config,
            cache: cache, translator: translator, confirm: { _, _ in
                confirmed = true
                return true
            })
        XCTAssertFalse(confirmed)
        XCTAssertTrue(translator.calls.isEmpty)
        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(outcome.requestCount, 0)
        XCTAssertEqual(outcome.translations[sample.id]?.subject, "你好")
        XCTAssertEqual(outcome.translations[sample.id]?.snippet, "世界")
    }

    func testBatchWriteFailureAndCancellationLeaveNoPartialCache() async throws {
        let kept = row("kept", subject: "Keep me", snippet: "Existing")
        let first = row("first", subject: "Hello first", snippet: "World first")
        let second = row("second", subject: "Hello second", snippet: "World second")
        let config = configuration()
        let keptValue = CachedTranslation(subject: "已有主题", body: "已有摘要")
        let oldFirst = CachedTranslation(subject: "旧主题", body: "旧摘要")
        for fault in [SQLiteTranslationCache.BatchFault.errorAfterInserts(1), .cancelAfterInserts(1)] {
            let cache = SQLiteTranslationCache(path: ":memory:")
            let keptKey = ListTranslationCache.key(row: kept, configuration: config)
            let firstKey = ListTranslationCache.key(row: first, configuration: config)
            try await cache.put(keptValue, for: try await cache.begin(keptKey), validated: true)
            try await cache.put(oldFirst, for: try await cache.begin(firstKey), validated: true)
            await cache.testingInjectBatchFault(fault)
            let outcome = await ListBatchTranslator().run(
                rows: [first, second], policy: FixedPolicy(decisions: [first.accountID: .allowed]), configuration: config,
                cache: cache, translator: RecordingTranslator(), confirm: { _, _ in true })
            let failed = if case .errorAfterInserts = fault { true } else { false }
            XCTAssertEqual(outcome.status, failed ? .failed : .cancelled)
            XCTAssertEqual(outcome.requestCount, 1)
            XCTAssertTrue(outcome.translations.isEmpty)
            let keptHit = try await cache.get(keptKey)
            let firstHit = try await cache.get(firstKey)
            let secondHit = try await cache.get(ListTranslationCache.key(row: second, configuration: config))
            XCTAssertEqual(keptHit, keptValue)
            XCTAssertEqual(firstHit, oldFirst)
            XCTAssertNil(secondHit)
        }
    }

    func testPutAllRejectionWritesNothingAndSkipsRowPuts() async throws {
        let rows = [row("first", subject: "Hello first", snippet: "World first"), row("second", subject: "Hello second", snippet: "World second")]
        let config = configuration()
        for cancel in [false, true] {
            let cache = RejectingBatchCache(cancel: cancel)
            let prior = CachedTranslation(subject: "原缓存", body: "不能丢")
            let priorKey = ListTranslationCache.key(row: rows[0], configuration: config)
            try await cache.seed(prior, for: priorKey)
            let outcome = await ListBatchTranslator().run(
                rows: rows, policy: FixedPolicy(decisions: [rows[0].accountID: .allowed]), configuration: config,
                cache: cache, translator: RecordingTranslator(), confirm: { _, _ in true })
            XCTAssertEqual(outcome.status, cancel ? .cancelled : .failed)
            XCTAssertEqual(outcome.requestCount, 1)
            XCTAssertTrue(outcome.translations.isEmpty)
            let rowPuts = await cache.rowPuts
            let batchPuts = await cache.batchPuts
            XCTAssertEqual(rowPuts, 0)
            XCTAssertEqual(batchPuts, 1)
            let stored = try await cache.get(priorKey)
            XCTAssertEqual(stored, prior)
            let second = try await cache.get(ListTranslationCache.key(row: rows[1], configuration: config))
            XCTAssertNil(second)
        }
    }

    func testDefaultOffAndMissingConsentSkipWithoutGranting() async throws {
        let suite = "list-translation-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let privacy = TranslationPrivacySettings(defaults: defaults)
        let endpoint = "https://translate.example.invalid/v1"
        let open = "open@example.invalid"
        let proton = "proton@example.invalid"
        XCTAssertEqual(privacy.setEnabled(true, accountID: open, isProton: false), .allowed)
        XCTAssertEqual(privacy.setEnabled(true, accountID: proton, isProton: true), .needsAccountConsent)
        let policy = StoredTranslationPolicy(
            accounts: [(open, false), (proton, true)],
            globalEnabled: true, configured: true, endpoint: endpoint, privacy: privacy)
        XCTAssertEqual(policy.permission(forAccount: open), .needsServiceConsent)
        XCTAssertEqual(policy.permission(forAccount: proton), .disabled)
        let translator = RecordingTranslator()
        var confirmed = false
        let outcome = await ListBatchTranslator().run(
            rows: [row("open", account: open, subject: "Hello", snippet: "World"),
                   row("proton", account: proton, subject: "Encrypted", snippet: "Body")],
            policy: policy, configuration: configuration(), cache: SQLiteTranslationCache(path: ":memory:"),
            translator: translator, confirm: { _, _ in
                confirmed = true
                return true
            })
        XCTAssertFalse(confirmed)
        XCTAssertTrue(translator.calls.isEmpty)
        XCTAssertEqual(outcome.status, .empty)
        XCTAssertEqual(outcome.requestCount, 0)
        XCTAssertEqual(Set(outcome.skipped.map(\.permission)), [.needsServiceConsent, .disabled])
        XCTAssertFalse(privacy.hasServiceConsent(endpoint: endpoint))
        XCTAssertFalse(privacy.isEnabled(accountID: proton))
        XCTAssertFalse(privacy.hasAccountConsent(accountID: proton))
    }

    private func configuration() -> TranslationConfig {
        TranslationConfig(enabled: true, baseURL: "https://translate.example.invalid/v1", model: "fixture-model",
                          systemPrompt: "fixture prompt")
    }

    private func row(_ id: String, account: String = "allowed@example.invalid", subject: String = "Hello", snippet: String = "World") -> ListTranslationRow {
        ListTranslationRow(id: id, accountID: account, subject: subject, snippet: snippet)
    }
}

private struct FixedPolicy: TranslationPolicy, Sendable {
    var decisions: [String: TranslationPermission]
    func permission(forAccount accountID: String) -> TranslationPermission {
        decisions[accountID.lowercased()] ?? .disabled
    }
}

private final class RecordingTranslator: SegmentTranslator, @unchecked Sendable {
    private var stored: [[TranslationSegment]] = []
    var error: TranslationError?
    var replacement: [TranslationSegment]?
    var calls: [[TranslationSegment]] { stored }

    func translate(_ segments: [TranslationSegment]) async throws -> [TranslationSegment] {
        stored.append(segments)
        if let error { throw error }
        if let replacement { return replacement }
        return segments.map { TranslationSegment(id: $0.id, text: "译:" + $0.text) }
    }
}

private actor RejectingBatchCache: TranslationCache {
    let inner = SQLiteTranslationCache(path: ":memory:")
    let cancel: Bool
    var rowPuts = 0
    var batchPuts = 0
    init(cancel: Bool) { self.cancel = cancel }

    func seed(_ value: CachedTranslation, for key: TranslationCacheKey) async throws {
        try await inner.put(value, for: try await inner.begin(key), validated: true)
    }

    func get(_ key: TranslationCacheKey) async throws -> CachedTranslation? { try await inner.get(key) }
    func begin(_ key: TranslationCacheKey) async throws -> SQLiteTranslationCache.Ticket { try await inner.begin(key) }
    func put(_ value: CachedTranslation, for ticket: SQLiteTranslationCache.Ticket, validated: Bool) async throws {
        rowPuts += 1
        throw TranslationError.network("row put is not a batch commit")
    }
    func putAll(_ entries: [(value: CachedTranslation, ticket: SQLiteTranslationCache.Ticket)], validated: Bool) async throws {
        batchPuts += 1
        if cancel { throw CancellationError() }
        throw TranslationError.network("synthetic second cache write failure")
    }
    func clear() async throws { try await inner.clear() }
    func purge(accountID: String) async throws { try await inner.purge(accountID: accountID) }
}

private final class CurrentFlag: @unchecked Sendable {
    var value = true
}

private final class InvalidateOnTranslate: SegmentTranslator, @unchecked Sendable {
    private var stored: [[TranslationSegment]] = []
    var calls: [[TranslationSegment]] { stored }
    let invalidate: () -> Void
    init(invalidate: @escaping () -> Void) { self.invalidate = invalidate }

    func translate(_ segments: [TranslationSegment]) async throws -> [TranslationSegment] {
        stored.append(segments)
        invalidate()
        return segments.map { TranslationSegment(id: $0.id, text: "译:" + $0.text) }
    }
}

private final class CancelAfterStartTranslator: SegmentTranslator, @unchecked Sendable {
    let started: XCTestExpectation
    init(started: XCTestExpectation) { self.started = started }

    func translate(_ segments: [TranslationSegment]) async throws -> [TranslationSegment] {
        started.fulfill()
        try await Task.sleep(for: .seconds(5))
        return segments.map { TranslationSegment(id: $0.id, text: "译:" + $0.text) }
    }
}
