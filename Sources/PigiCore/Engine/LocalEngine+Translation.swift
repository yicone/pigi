import Foundation

public struct TranslationPermissionError: Error, Sendable {
    public let permission: TranslationPermission
}

extension LocalEngine {
    /// Application request boundary. The optional dependencies are internal test seams;
    /// ArchiveClient uses persisted config, real account privacy, KeychainVault and URLSession.
    func translateMail(account email: String, id: String,
                       configStore: TranslationConfigStore = TranslationConfigStore(),
                       keyStore: any KeyStore = KeychainKeyStore(),
                       transport: any HTTPTransport = URLSessionTransport(),
                       privacy: TranslationPrivacySettings? = nil) async throws -> CachedTranslation {
        try Task.checkCancellation()
        let email = email.lowercased()
        guard let account = try account(email) else { throw TranslationPermissionError(permission: .disabled) }
        let configuration = configStore.load() // Exactly one snapshot for the entire request.
        let hasKey: Bool
        do { hasKey = !(try keyStore.apiKey() ?? "").isEmpty }
        catch { throw TranslationPermissionError(permission: .notConfigured) }
        let settings: TranslationPrivacySettings
        if let privacy { settings = privacy } else { settings = await TranslationPrivacySettings.shared }
        let permission = await settings.policy(accountID: email, isProton: account["kind"]?.text == "proton",
            globalEnabled: configuration.enabled, configured: configuration.isConfigured(hasKey: hasKey),
            endpoint: configuration.baseURL)
        try Task.checkCancellation()
        guard permission == .allowed else { throw TranslationPermissionError(permission: permission) }
        let original = try body(account: email, id: id)
        guard let row = try db().query("SELECT subject FROM messages WHERE account=? AND id=?",
            [.text(email), .text(id)]).first else { throw ArchiveClient.Failure(message: "邮件不存在") }
        let request = try CachedMailTranslator(configuration: configuration, cache: translationCache,
            keyStore: keyStore, transport: transport)
        return try await request.translate(accountID: email, mailID: id, subject: row["subject"]?.text ?? "",
            body: original.html ?? original.text, isHTML: original.html != nil)
    }
}
