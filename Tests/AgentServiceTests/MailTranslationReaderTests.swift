import XCTest
@testable import PigiCore

@MainActor
final class MailTranslationReaderTests: XCTestCase {
    private let account = "a@example.invalid"
    private let mailID = "one"

    private func fixture(enabled: Bool = true, key: String? = "fixture-key", baseURL: String = "https://translation.test/v1",
                         model: String = "fixture-model", recorder: TranslateRecorder = TranslateRecorder())
        -> (MailTranslationReader, TranslationConfigStore, TranslateRecorder) {
        let defaults = UserDefaults(suiteName: "pigi-reader-tests.\(UUID().uuidString)")!
        let store = TranslationConfigStore(defaults: defaults)
        store.save(TranslationConfig(enabled: enabled, baseURL: baseURL, model: model))
        return (MailTranslationReader(store: store, keyStore: ReaderKeyStore(key: key), translate: recorder.action), store, recorder)
    }

    func testGateRequiresEnabledURLModelAndNonemptyKey() async {
        for (enabled, key, base, model) in [
            (false, "key", "https://translation.test", "model"),
            (true, "", "https://translation.test", "model"),
            (true, "key", "invalid", "model"),
            (true, "key", "https://translation.test", " ")
        ] {
            let (reader, _, recorder) = fixture(enabled: enabled, key: key, baseURL: base, model: model)
            reader.refreshConfiguration()
            XCTAssertFalse(reader.isAvailable)
            reader.toggle(account: account, id: mailID)
            XCTAssertFalse(reader.isTranslating)
            let count = await recorder.count
            XCTAssertEqual(count, 0)
        }
        let (reader, _, _) = fixture()
        reader.refreshConfiguration()
        XCTAssertTrue(reader.isAvailable)
    }

    func testKeyReadFailureHidesEntry() async {
        let (_, store, recorder) = fixture()
        let reader = MailTranslationReader(store: store, keyStore: ReaderKeyStore(key: nil, fails: true), translate: recorder.action)
        reader.refreshConfiguration()
        XCTAssertFalse(reader.isAvailable)
        reader.toggle(account: account, id: mailID)
        let count = await recorder.count
        XCTAssertEqual(count, 0)
    }

    func testClickTranslatesOnceAndTogglesOriginalWithoutAnotherCall() async {
        let (reader, _, recorder) = fixture()
        reader.toggle(account: account, id: mailID)
        XCTAssertTrue(reader.isTranslating)
        await reader.task?.value
        XCTAssertFalse(reader.isTranslating)
        XCTAssertEqual(reader.translatedBody, "你好 world")
        XCTAssertTrue(reader.showingTranslation)
        reader.toggle(account: account, id: mailID)
        XCTAssertFalse(reader.showingTranslation)
        reader.toggle(account: account, id: mailID)
        XCTAssertTrue(reader.showingTranslation)
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.account, account)
        XCTAssertEqual(calls.first?.id, mailID)
    }

    func testFailureKeepsOriginalAndAllowsRetryWithoutLeakingResponse() async {
        let recorder = TranslateRecorder(error: TranslationError.http(status: 503, message: "private-response"))
        let (reader, _, _) = fixture(recorder: recorder)
        reader.toggle(account: account, id: mailID)
        await reader.task?.value
        XCTAssertNil(reader.translatedBody)
        XCTAssertFalse(reader.showingTranslation)
        XCTAssertTrue(reader.errorMessage?.contains("503") == true)
        XCTAssertFalse(reader.errorMessage?.contains("private-response") == true)
        await recorder.setError(nil)
        reader.toggle(account: account, id: mailID)
        await reader.task?.value
        XCTAssertTrue(reader.showingTranslation)
        XCTAssertNil(reader.errorMessage)
    }

    func testPermissionErrorsMapToShortMessages() async {
        for (permission, expected) in [
            (TranslationPermission.disabled, "此邮箱未开启翻译，请在设置中为它开启。"),
            (.notConfigured, "请先在设置中配置翻译服务地址、模型和密钥。"),
            (.needsServiceConsent, "请在设置中确认向此翻译服务外发后再试。"),
            (.needsAccountConsent, "Proton 邮箱默认不翻译，请在设置中单独确认后再试。")
        ] {
            let recorder = TranslateRecorder(error: TranslationPermissionError(permission: permission))
            let (reader, _, _) = fixture(recorder: recorder)
            reader.toggle(account: account, id: mailID)
            await reader.task?.value
            XCTAssertEqual(reader.errorMessage, expected)
            XCTAssertFalse(reader.errorMessage?.contains(account) == true)
        }
    }

    func testAlignmentFailuresKeepOriginalAndUseDistinctRetryMessage() async {
        let alignmentMessage = "译文与原文片段未能对齐，请重试翻译。"
        for error in [MailTranslationError.alignmentFailed as Error, TranslationError.misaligned as Error] {
            let recorder = TranslateRecorder(error: error)
            let (reader, _, _) = fixture(recorder: recorder)
            reader.toggle(account: account, id: mailID)
            await reader.task?.value
            XCTAssertEqual(reader.errorMessage, alignmentMessage)
            XCTAssertNil(reader.translatedBody)
            XCTAssertFalse(reader.showingTranslation)
            XCTAssertFalse(reader.isTranslating)
            await recorder.setError(nil)
            reader.toggle(account: account, id: mailID)
            await reader.task?.value
            XCTAssertTrue(reader.showingTranslation)
            XCTAssertNil(reader.errorMessage)
        }
        for (error, expected) in [
            (TranslationError.timeout, "翻译超时，请重试或在设置中调大超时。"),
            (.network("private-network-detail"), "翻译失败，请检查网络与服务设置后重试。"),
            (.http(status: 502, message: "private-response"), "翻译服务返回 HTTP 502，请检查设置后重试。"),
            (.notConfigured, "请检查翻译设置中的服务地址、模型和密钥。")
        ] {
            XCTAssertEqual(MailTranslationReader.message(for: error), expected)
            XCTAssertNotEqual(expected, alignmentMessage)
        }
    }

    func testEngineFailuresMapWithoutLeakingDetailsAndCancellationStaysSilent() async {
        for (error, expected) in [
            (SQLiteTranslationCache.Failure.invalidated, "翻译缓存刚被清空或账号已变更，请重试。"),
            (ArchiveClient.Failure(message: "secret-account@example.invalid detail"), "邮件不存在或暂时无法读取，无法翻译。")
        ] as [(Error, String)] {
            let recorder = TranslateRecorder(error: error)
            let (reader, _, _) = fixture(recorder: recorder)
            reader.toggle(account: account, id: mailID)
            await reader.task?.value
            XCTAssertEqual(reader.errorMessage, expected)
            XCTAssertFalse(reader.errorMessage?.contains("secret") == true)
        }
        for silent in [CancellationError() as Error, TranslationError.cancelled as Error] {
            let recorder = TranslateRecorder(error: silent)
            let (reader, _, _) = fixture(recorder: recorder)
            reader.toggle(account: account, id: mailID)
            await reader.task?.value
            XCTAssertNil(reader.errorMessage)
            XCTAssertFalse(reader.isTranslating)
        }
    }

    func testSwitchingMailDiscardsLateResponseAndDuplicateClicks() async {
        let recorder = TranslateRecorder(hold: true)
        let (reader, _, _) = fixture(recorder: recorder)
        reader.toggle(account: account, id: "old")
        let pending = reader.task
        await recorder.waitUntilStarted()
        reader.toggle(account: account, id: "new")
        let count = await recorder.count
        XCTAssertEqual(count, 1)
        reader.reset()
        await recorder.release()
        await pending?.value
        XCTAssertNil(reader.translatedBody)
        XCTAssertFalse(reader.showingTranslation)
        XCTAssertFalse(reader.isTranslating)
        XCTAssertNil(reader.errorMessage)
    }

    func testDisableOrChangeConfigurationCancelsPendingTranslation() async {
        for disable in [true, false] {
            let recorder = TranslateRecorder(hold: true)
            let (reader, store, _) = fixture(recorder: recorder)
            reader.toggle(account: account, id: mailID)
            let pending = reader.task
            await recorder.waitUntilStarted()
            var config = store.load()
            if disable { config.enabled = false } else { config.model = "different-model" }
            store.save(config)
            reader.refreshConfiguration()
            XCTAssertEqual(reader.isAvailable, !disable)
            XCTAssertFalse(reader.isTranslating)
            await recorder.release()
            await pending?.value
            XCTAssertNil(reader.translatedBody)
            XCTAssertFalse(reader.showingTranslation)
        }
    }
}

private struct ReaderKeyStore: KeyStore {
    let key: String?
    var fails = false
    func apiKey() throws -> String? {
        if fails { throw TranslationError.notConfigured }
        return key
    }
    func setAPIKey(_ value: String) -> Bool { false }
}

private actor TranslateRecorder {
    private(set) var calls: [(account: String, id: String)] = []
    private var error: Error?
    private var result: CachedTranslation
    private let hold: Bool
    private var held: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    init(error: Error? = nil, hold: Bool = false,
         result: CachedTranslation = CachedTranslation(subject: "译文主题", body: "你好 world")) {
        self.error = error
        self.hold = hold
        self.result = result
    }

    var count: Int { calls.count }
    nonisolated var action: MailTranslationReader.MailTranslationAction {
        { account, id in try await self.run(account: account, id: id) }
    }

    func setError(_ error: Error?) { self.error = error }
    func waitUntilStarted() async {
        if calls.isEmpty { await withCheckedContinuation { started = $0 } }
    }
    func release() { held?.resume(); held = nil }

    private func run(account: String, id: String) async throws -> CachedTranslation {
        calls.append((account, id))
        started?.resume(); started = nil
        // Intentionally ignores cancellation to exercise stale response protection.
        if hold { await withCheckedContinuation { held = $0 } }
        if let error { throw error }
        return result
    }
}
