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
    public private(set) var showingTranslation = false
    public private(set) var errorMessage: String?

    @ObservationIgnored private let store: TranslationConfigStore
    @ObservationIgnored private let keyStore: any KeyStore
    @ObservationIgnored private let translate: MailTranslationAction
    @ObservationIgnored private var config = TranslationConfig()
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    public init(
        store: TranslationConfigStore = TranslationConfigStore(),
        keyStore: any KeyStore = KeychainKeyStore(),
        translate: @escaping MailTranslationAction = { try await ArchiveClient().translateMail(account: $0, id: $1) }
    ) {
        self.store = store
        self.keyStore = keyStore
        self.translate = translate
    }

    public func refreshConfiguration() {
        let updated = store.load()
        let key = updated.enabled ? ((try? keyStore.apiKey()) ?? nil) : nil
        let available = updated.enabled && updated.isConfigured(hasKey: !(key ?? "").isEmpty)
        if updated != config || available != isAvailable { reset() }
        config = updated
        isAvailable = available
    }

    public func reset() {
        task?.cancel()
        task = nil
        generation = UUID()
        isTranslating = false
        translatedBody = nil
        showingTranslation = false
        errorMessage = nil
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
