import Foundation
import Observation

/// Ephemeral reading state. Translations never replace the stored mail body.
@MainActor
@Observable
public final class MailTranslationReader {
    /// Reads a whole-mail translation through the engine's cached path.
    public typealias MailTranslationAction = @Sendable (_ account: String, _ id: String) async throws -> CachedTranslation

    public private(set) var isAvailable = false
    public private(set) var isTranslating = false
    public private(set) var translatedBody: String?
    public private(set) var translatedSubject: String?
    public private(set) var showingTranslation = false
    public private(set) var errorMessage: String?
    public private(set) var isEnabled = false
    public private(set) var mailID: String?
    public private(set) var pendingConsent: ConsentRequest?

    public struct ConsentRequest: Equatable {
        public let account: String
        public let endpoint: String
        public let permission: TranslationPermission
        public let requiresAccountConsent: Bool
        fileprivate let remoteID: String
        fileprivate let mailID: String
        fileprivate let isProton: Bool
        fileprivate let configuration: TranslationConfig
    }

    public var bannerTitle: String {
        if isTranslating { return "正在翻译成简体中文…" }
        if showingTranslation { return "已翻译为简体中文 · 显示原文" }
        if translatedBody != nil { return "当前显示原文 · 显示译文" }
        return "翻译成简体中文"
    }

    public func bannerMessage(signatureFailed: Bool) -> String {
        let message = errorMessage ?? bannerTitle
        return signatureFailed ? message + (message.hasSuffix("。") ? "" : "。") + "签名未通过，译文同样不能当成原信" : message
    }

    @ObservationIgnored private let store: TranslationConfigStore
    @ObservationIgnored private let keyStore: any KeyStore
    @ObservationIgnored private let translate: MailTranslationAction
    @ObservationIgnored private let privacy: TranslationPrivacySettings
    @ObservationIgnored private var config = TranslationConfig()
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    public init(
        store: TranslationConfigStore = TranslationConfigStore(),
        keyStore: any KeyStore = KeychainKeyStore(),
        privacy: TranslationPrivacySettings? = nil,
        translate: @escaping MailTranslationAction = { try await ArchiveClient().translateMail(account: $0, id: $1) }
    ) {
        self.store = store
        self.keyStore = keyStore
        self.translate = translate
        self.privacy = privacy ?? .shared
    }

    public func refreshConfiguration() {
        let updated = store.load()
        let key = updated.enabled ? ((try? keyStore.apiKey()) ?? nil) : nil
        let available = updated.enabled && updated.isConfigured(hasKey: !(key ?? "").isEmpty)
        if updated != config || available != isAvailable { reset() }
        config = updated
        isAvailable = available
        isEnabled = updated.enabled
    }

    public func permission(account: String, isProton: Bool) -> TranslationPermission {
        privacy.policy(accountID: account, isProton: isProton, globalEnabled: isEnabled,
                       configured: isAvailable, endpoint: config.baseURL)
    }

    public func actionTitle(account: String, isProton: Bool) -> String {
        if showingTranslation { return "显示原文" }
        if translatedBody != nil { return "显示译文" }
        switch permission(account: account, isProton: isProton) {
        case .needsServiceConsent, .needsAccountConsent: return "同意并翻译…"
        default: return "翻译成简体中文"
        }
    }

    /// Each detail view owns its reader. A late disappearance can cancel only its own mail.
    public func select(mailID: String) {
        guard self.mailID != mailID else { return }
        reset()
        self.mailID = mailID
    }

    public func cancel(mailID: String) {
        guard self.mailID == mailID else { return }
        reset()
        self.mailID = nil
    }

    /// Policy is checked before prompting and again before dispatching to the cached engine path.
    public func activate(account: String, id: String, mailID: String, isProton: Bool) {
        select(mailID: mailID)
        refreshConfiguration()
        guard !isTranslating else { return }
        let decision = permission(account: account, isProton: isProton)
        switch decision {
        case .needsServiceConsent, .needsAccountConsent:
            pendingConsent = ConsentRequest(account: account, endpoint: config.baseURL, permission: decision,
                requiresAccountConsent: isProton && !privacy.hasAccountConsent(accountID: account),
                remoteID: id, mailID: mailID, isProton: isProton, configuration: config)
        case .notConfigured, .disabled:
            errorMessage = Self.message(for: TranslationPermissionError(permission: decision))
        case .allowed:
            toggle(account: account, id: id)
        }
    }

    public func dismissConsent() { pendingConsent = nil }

    public func confirmConsent() {
        guard let request = pendingConsent else { return }
        pendingConsent = nil
        refreshConfiguration()
        guard mailID == request.mailID, config == request.configuration,
              permission(account: request.account, isProton: request.isProton) == request.permission else { return }
        switch request.permission {
        case .needsServiceConsent:
            privacy.grantServiceConsent(endpoint: request.endpoint)
            if request.requiresAccountConsent {
                privacy.setEnabled(true, accountID: request.account, isProton: true, confirmingProtonConsent: true)
            }
        case .needsAccountConsent:
            privacy.setEnabled(true, accountID: request.account, isProton: request.isProton, confirmingProtonConsent: true)
        default: return
        }
        activate(account: request.account, id: request.remoteID, mailID: request.mailID, isProton: request.isProton)
    }

    public func reset() {
        task?.cancel()
        task = nil
        generation = UUID()
        isTranslating = false
        translatedBody = nil
        translatedSubject = nil
        showingTranslation = false
        errorMessage = nil
        pendingConsent = nil
    }

    /// `account` is the engine account id and `id` the remote mail id, not the UI composite `Mail.id`.
    public func toggle(account: String, id: String) {
        refreshConfiguration()
        guard isAvailable, !isTranslating else { return }
        if translatedBody != nil {
            showingTranslation.toggle()
            return
        }
        errorMessage = nil
        isTranslating = true
        let current = generation
        let translate = self.translate
        task = Task { [weak self] in
            do {
                let result = try await translate(account, id)
                try Task.checkCancellation()
                guard let self, self.generation == current else { return }
                self.translatedBody = result.body
                self.translatedSubject = result.subject
                self.showingTranslation = true
                self.isTranslating = false
                self.task = nil
            } catch {
                guard let self, self.generation == current else { return }
                self.isTranslating = false
                self.task = nil
                self.errorMessage = Self.message(for: error)
            }
        }
    }

    /// Short display strings only: never provider response bodies, mail content or account names.
    /// nil means the failure is silent (cancellation).
    static func message(for error: Error) -> String? {
        if error is CancellationError || (error as? TranslationError) == .cancelled { return nil }
        if let permission = error as? TranslationPermissionError {
            switch permission.permission {
            case .disabled: return "此邮箱未开启翻译，请在设置中为它开启。"
            case .notConfigured: return "请先在设置中配置翻译服务地址、模型和密钥。"
            case .needsServiceConsent: return "请在设置中确认向此翻译服务外发后再试。"
            case .needsAccountConsent: return "Proton 邮箱默认不翻译，请在设置中单独确认后再试。"
            case .allowed: break
            }
        }
        if error is SQLiteTranslationCache.Failure { return "翻译缓存刚被清空或账号已变更，请重试。" }
        if error is ArchiveClient.Failure { return "邮件不存在或暂时无法读取，无法翻译。" }
        if (error as? MailTranslationError) == .noContent { return "邮件没有可翻译的内容。" }
        if (error as? MailTranslationError) == .alignmentFailed || (error as? TranslationError) == .misaligned {
            return "译文与原文片段未能对齐，请重试翻译。"
        }
        switch error as? TranslationError {
        case .timeout: return "翻译超时，请重试或在设置中调大超时。"
        case .notConfigured, .invalidBaseURL: return "请检查翻译设置中的服务地址、模型和密钥。"
        case .http(let status, _): return "翻译服务返回 HTTP \(status)，请检查设置后重试。"
        default: return "翻译失败，请检查网络与服务设置后重试。"
        }
    }
}
