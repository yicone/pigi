import Foundation

struct ProtonSyncMetadata: Codable, Sendable {
    let id: String
    let subject: String
    let time: Int
    let unread: Bool
    let sender_name: String
    let sender_email: String
    let labels: [String]
    let size: Int

    var mappedLabels: [String] {
        let system = ["0": "INBOX", "1": "DRAFT", "2": "SENT", "3": "TRASH", "4": "SPAM",
                      "5": "ALL", "6": "ARCHIVE", "7": "SENT", "8": "DRAFT", "10": "STARRED"]
        var result = labels.map { system[$0] ?? "proton:" + $0 }
        if unread { result.append("UNREAD") }
        return Array(Set(result)).sorted()
    }
}

public struct ProtonLabel: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let parent: String
    public let type: Int

    public init(id: String, name: String, parent: String, type: Int) {
        self.id = id
        self.name = name
        self.parent = parent
        self.type = type
    }
}
struct ProtonEventPage: Codable, Sendable {
    struct Change: Codable, Sendable { let id: String; let deleted: Bool }
    let cursor: String
    let more: Bool
    let reset: Bool
    let changes: [Change]
}

protocol ProtonSyncRemote: AnyObject, Sendable {
    func latest() async throws -> String
    func labels() async throws -> [ProtonLabel]
    func snapshot(after: String) async throws -> [String]
    func metadata(id: String) async throws -> ProtonSyncMetadata
    func decrypt(id: String) async throws -> ProtonMessageBody
    func events(cursor: String) async throws -> ProtonEventPage
}

// Secrets travel through private pipes and the application Keychain only.
// Login/OTP passwords are never persisted. The derived unlock secret is as
// sensitive as a password and is deliberately part of the same Keychain item.
final class ProtonSession: ProtonSyncRemote, @unchecked Sendable {
    struct Secret: Codable {
        let uid: String
        let access: String
        let refresh: String
        let salted: String
        let email: String
    }
    struct Empty: Encodable {}
    let client: ProtonHelperClient
    let email: String
    private let credentials: CredentialStore
    private let lock = NSLock()
    private var active = true
    private var initialSecret: Secret?

    func deactivate() { lock.lock(); active = false; lock.unlock() }
    func reactivate() { lock.lock(); active = true; lock.unlock() }
    func persistInitial() throws {
        guard let secret = initialSecret else { throw ProtonHelperError.protocolViolation }
        try persist(secret)
        initialSecret = nil
    }
    static func key(_ email: String) -> String { "proton-session-" + email }

    init(client: ProtonHelperClient, email: String, credentials: CredentialStore = CredentialStore(), initialSecret: Secret? = nil) {
        self.client = client
        self.email = email
        self.credentials = credentials
        self.initialSecret = initialSecret
    }

    static func signIn(username: String, password: String, mailboxPassword: String, otp: String, interaction: ProtonLoginInteraction? = nil) async throws -> ProtonSession {
        let client = try ProtonHelperClient.bundled()
        do {
            try await client.loginInteractively(username: username, password: password, mailboxPassword: mailboxPassword, otp: otp, interaction: interaction)
            let secret: Secret = try await client.syncRequest("session", Empty())
            guard secret.email.contains("@") else { throw ProtonHelperError.protocolViolation }
            let session = ProtonSession(client: client, email: secret.email.lowercased())
            session.initialSecret = secret
            return session
        } catch {
            do { try await client.logout() } catch { throw ProtonHelperError.cleanupFailed }
            throw error
        }
    }

    static func fromKeychain(_ email: String) throws -> ProtonSession {
        guard let json = try Keychain.get(key(email)), let secret = try? JSONDecoder().decode(Secret.self, from: Data(json.utf8)),
              secret.email.lowercased() == email else { throw ProtonHelperError.credentials }
        let session = ProtonSession(client: try ProtonHelperClient.bundled(), email: email)
        session.initialSecret = secret
        return session
    }

    func resume() async throws {
        guard let secret = initialSecret else { throw ProtonHelperError.protocolViolation }
        initialSecret = nil
        struct Result: Decodable { let authenticated: Bool }
        do {
            let result: Result = try await client.syncRequest("resume", secret)
            guard result.authenticated else { throw ProtonHelperError.protocolViolation }
            try await saveSecret()
        } catch {
            // A refresh may precede a failed network/key request. Preserve it.
            do { try await saveSecret() }
            catch { throw CredentialPersistenceError.recoveryFailed }
            throw error
        }
    }

    private func persist(_ secret: Secret) throws {
        lock.lock()
        defer { lock.unlock() }
        // Removed/replaced sessions cannot resurrect or overwrite a Keychain item.
        guard active else { return }
        guard secret.email.lowercased() == email else { throw ProtonHelperError.credentials }
        let json = String(decoding: try JSONEncoder().encode(secret), as: UTF8.self)
        try credentials.save(Self.key(email), json)
    }
    func saveSecret() async throws {
        let secret: Secret = try await client.syncRequest("session", Empty())
        try persist(secret)
    }
    private func request<P: Encodable, R: Decodable>(_ method: String, _ params: P) async throws -> R {
        do {
            let result: R = try await client.syncRequest(method, params)
            try await saveSecret()
            return result
        } catch {
            do { try await saveSecret() }
            catch { throw CredentialPersistenceError.recoveryFailed }
            throw error
        }
    }
    func latest() async throws -> String {
        struct Result: Decodable { let cursor: String }
        let result: Result = try await request("latest", Empty())
        return result.cursor
    }
    func labels() async throws -> [ProtonLabel] { try await request("labels", Empty()) }
    func snapshot(after: String) async throws -> [String] {
        struct Params: Encodable { let after: String; let limit = 100 }
        return try await request("snapshot", Params(after: after))
    }
    func metadata(id: String) async throws -> ProtonSyncMetadata {
        struct Params: Encodable { let id: String }
        return try await request("metadata", Params(id: id))
    }
    func decrypt(id: String) async throws -> ProtonMessageBody {
        struct Params: Encodable { let id: String }
        return try await request("decrypt", Params(id: id))
    }
    func events(cursor: String) async throws -> ProtonEventPage {
        struct Params: Encodable { let cursor: String }
        return try await request("events", Params(cursor: cursor))
    }
}

extension ProtonHelperError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidParams: "验证未完成或输入格式不正确，请重试"
        case .credentials: "账号、密码或验证码不正确，请检查后重试"
        case .notAuthenticated: "Proton 会话失效，请重新登录"
        case .cleanupFailed: "临时登录会话清理未完成，请稍后重试"
        case .humanVerificationRequired: "此验证方式暂不支持，请重新开始登录"
        case .loginExpired: "验证已超时，请重新开始登录"
        case .unsupportedFactor: "当前仅支持 TOTP，请使用支持的验证方式"
        case .secondFactorRequired: "请输入当前的两步验证码"
        case .key: "Proton 密钥解锁失败，请检查独立邮箱密码或钥匙串权限"
        case .keyMissing: "此邮件的地址密钥缺失，请重新登录以加载最新密钥"
        case .keyFormat: "Proton 加密数据格式无法识别，请更新应用后重试"
        case .keyDecryption: "Proton 邮件解密失败，密钥可能已轮换，请重新登录"
        case .apiVersion: "Proton 已拒绝当前 API 版本，请更新应用"
        case .proxy: "代理需要认证，请检查系统代理设置"
        case .network: "无法连接 Proton，请检查网络与系统代理后重试"
        case .timeout: "Proton 请求超时，请稍后重试"
        case .rateLimited: "Proton 请求过于频繁，请至少等待两分钟后重试"
        default: "Proton 操作失败（\(rawValue)）"
        }
    }
}
