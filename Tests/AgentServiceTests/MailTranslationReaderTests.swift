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

    private func policyFixture() -> (MailTranslationReader, TranslationConfigStore, TranslationPrivacySettings, TranslateRecorder) {
        let (_, store, recorder) = fixture()
        let defaults = UserDefaults(suiteName: "pigi-reader-privacy.\(UUID().uuidString)")!
        let privacy = TranslationPrivacySettings(defaults: defaults)
        let reader = MailTranslationReader(store: store, keyStore: ReaderKeyStore(key: "fixture-key"),
                                           privacy: privacy, translate: recorder.action)
        reader.refreshConfiguration()
        return (reader, store, privacy, recorder)
    }

    func testBannerStatesAndSubjectFollowLocalToggle() async {
        let (reader, _, recorder) = fixture()
        XCTAssertEqual(reader.bannerTitle, "翻译成简体中文")
        reader.toggle(account: account, id: mailID)
        XCTAssertEqual(reader.bannerTitle, "正在翻译成简体中文…")
        await reader.task?.value
        XCTAssertEqual(reader.translatedSubject, "译文主题")
        XCTAssertEqual(reader.bannerTitle, "已翻译为简体中文 · 显示原文")
        reader.toggle(account: account, id: mailID)
        XCTAssertEqual(reader.bannerTitle, "当前显示原文 · 显示译文")
        reader.toggle(account: account, id: mailID)
        XCTAssertEqual(reader.bannerTitle, "已翻译为简体中文 · 显示原文")
        let count = await recorder.count
        XCTAssertEqual(count, 1)
        XCTAssertTrue(reader.bannerMessage(signatureFailed: true).hasSuffix("签名未通过，译文同样不能当成原信"))
        reader.reset()
        XCTAssertNil(reader.translatedSubject)
    }

    func testDisabledAndNotConfiguredNeverOfferConsentOrSend() async {
        let (reader, store, privacy, recorder) = policyFixture()
        reader.activate(account: account, id: mailID, mailID: "ui-one", isProton: false)
        XCTAssertNil(reader.pendingConsent)
        XCTAssertEqual(reader.actionTitle(account: account, isProton: false), "翻译成简体中文")
        XCTAssertTrue(reader.errorMessage?.contains("此邮箱未开启") == true)
        privacy.setEnabled(true, accountID: account, isProton: false)
        var config = store.load(); config.model = ""; store.save(config)
        reader.activate(account: account, id: mailID, mailID: "ui-one", isProton: false)
        XCTAssertNil(reader.pendingConsent)
        XCTAssertTrue(reader.errorMessage?.contains("配置翻译服务") == true)
        let count = await recorder.count
        XCTAssertEqual(count, 0)
    }

    func testExplicitConsentThenTranslationAndDismissalDoesNotGrant() async {
        let (reader, store, privacy, recorder) = policyFixture()
        privacy.setEnabled(true, accountID: account, isProton: false)
        XCTAssertEqual(reader.actionTitle(account: account, isProton: false), "同意并翻译…")
        reader.activate(account: account, id: mailID, mailID: "ui-one", isProton: false)
        XCTAssertEqual(reader.pendingConsent?.permission, .needsServiceConsent)
        reader.dismissConsent()
        XCTAssertFalse(privacy.hasServiceConsent(endpoint: store.load().baseURL))
        reader.activate(account: account, id: mailID, mailID: "ui-one", isProton: false)
        reader.confirmConsent()
        await reader.task?.value
        XCTAssertTrue(reader.showingTranslation)
        XCTAssertTrue(privacy.hasServiceConsent(endpoint: store.load().baseURL))
        XCTAssertEqual(reader.actionTitle(account: account, isProton: false), "显示原文")
        let count = await recorder.count
        XCTAssertEqual(count, 1)
    }

    func testConsentIsBoundToMailEndpointAndCurrentPolicy() async {
        for change in ["mail", "endpoint", "disabled"] {
            let (reader, store, privacy, recorder) = policyFixture()
            privacy.setEnabled(true, accountID: account, isProton: false)
            let originalEndpoint = store.load().baseURL
            reader.activate(account: account, id: mailID, mailID: "ui-one", isProton: false)
            if change == "mail" { reader.select(mailID: "ui-two") }
            if change == "endpoint" {
                var config = store.load(); config.baseURL = "https://different.test"; store.save(config)
            }
            if change == "disabled" { privacy.setEnabled(false, accountID: account, isProton: false) }
            reader.confirmConsent()
            XCTAssertFalse(privacy.hasServiceConsent(endpoint: originalEndpoint))
            XCTAssertFalse(privacy.hasServiceConsent(endpoint: store.load().baseURL))
            let count = await recorder.count
            XCTAssertEqual(count, 0)
        }
    }

    func testProtonConsentIsSeparateFromServiceConsent() async {
        let (reader, store, privacy, recorder) = policyFixture()
        // Simulate an enabled account whose kind changed from IMAP to Proton.
        privacy.setEnabled(true, accountID: account, isProton: false)
        privacy.grantServiceConsent(endpoint: store.load().baseURL)
        reader.activate(account: account, id: mailID, mailID: "ui-one", isProton: true)
        XCTAssertEqual(reader.pendingConsent?.permission, .needsAccountConsent)
        XCTAssertFalse(privacy.hasAccountConsent(accountID: account))
        reader.confirmConsent()
        await reader.task?.value
        XCTAssertTrue(privacy.hasAccountConsent(accountID: account))
        XCTAssertTrue(reader.showingTranslation)
        let count = await recorder.count
        XCTAssertEqual(count, 1)
    }

    func testCombinedServiceAndProtonConsentIsExplicitAndStartsOnce() async {
        let (reader, store, privacy, recorder) = policyFixture()
        privacy.setEnabled(true, accountID: account, isProton: false)
        reader.activate(account: account, id: mailID, mailID: "ui-one", isProton: true)
        XCTAssertEqual(reader.pendingConsent?.permission, .needsServiceConsent)
        XCTAssertEqual(reader.pendingConsent?.requiresAccountConsent, true)
        XCTAssertFalse(privacy.hasAccountConsent(accountID: account))
        reader.confirmConsent()
        await reader.task?.value
        XCTAssertTrue(privacy.hasServiceConsent(endpoint: store.load().baseURL))
        XCTAssertTrue(privacy.hasAccountConsent(accountID: account))
        XCTAssertNil(reader.pendingConsent)
        XCTAssertTrue(reader.showingTranslation)
        let count = await recorder.count
        XCTAssertEqual(count, 1)
    }

    func testSameMailInTwoWindowsHasIndependentCancellation() async {
        let held = TranslateRecorder(hold: true)
        let (main, _, _) = fixture(recorder: held)
        let (panel, _, _) = fixture()
        main.select(mailID: "same-ui-id")
        panel.select(mailID: "same-ui-id")
        main.toggle(account: account, id: mailID)
        let pending = main.task
        await held.waitUntilStarted()
        panel.toggle(account: account, id: mailID)
        await panel.task?.value
        main.cancel(mailID: "another-mail")
        XCTAssertTrue(main.isTranslating)
        main.cancel(mailID: "same-ui-id")
        await held.release()
        await pending?.value
        XCTAssertNil(main.translatedBody)
        XCTAssertTrue(panel.showingTranslation)
        XCTAssertEqual(panel.translatedSubject, "译文主题")
        main.select(mailID: "new-mail")
        main.cancel(mailID: "same-ui-id")
        XCTAssertEqual(main.mailID, "new-mail")
    }

    func testActivateSwitchesMailAndLateOldResponseCannotReplaceNewResult() async {
        let (_, store, privacy, _) = policyFixture()
        privacy.setEnabled(true, accountID: account, isProton: false)
        privacy.grantServiceConsent(endpoint: store.load().baseURL)
        let old = TranslateRecorder(hold: true, result: CachedTranslation(subject: "old subject", body: "old body"))
        let reader = MailTranslationReader(store: store, keyStore: ReaderKeyStore(key: "fixture-key"), privacy: privacy,
            translate: { account, id in
                if id == "old" { return try await old.action(account, id) }
                return CachedTranslation(subject: "new subject", body: "new body")
            })
        reader.activate(account: account, id: "old", mailID: "ui-old", isProton: false)
        let pending = reader.task
        await old.waitUntilStarted()
        reader.activate(account: account, id: "new", mailID: "ui-new", isProton: false)
        await reader.task?.value
        reader.cancel(mailID: "ui-old")
        await old.release()
        await pending?.value
        XCTAssertEqual(reader.mailID, "ui-new")
        XCTAssertEqual(reader.translatedSubject, "new subject")
        XCTAssertEqual(reader.translatedBody, "new body")
        XCTAssertTrue(reader.showingTranslation)
    }

    func testEmptyContentHasDistinctFailureWithSignatureSuffix() async {
        let recorder = TranslateRecorder(error: MailTranslationError.noContent)
        let (reader, _, _) = fixture(recorder: recorder)
        reader.toggle(account: account, id: mailID)
        await reader.task?.value
        XCTAssertEqual(reader.errorMessage, "邮件没有可翻译的内容。")
        XCTAssertTrue(reader.bannerMessage(signatureFailed: true).contains("签名未通过，译文同样不能当成原信"))
        XCTAssertNil(reader.translatedSubject)
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
