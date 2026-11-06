import Foundation

/// Safe to show in the UI: never includes an account, key or secret value.
public enum CredentialPersistenceError: Error, LocalizedError, Equatable {
    case writeFailed
    case recoveryFailed
    case readFailed

    public var errorDescription: String? {
        switch self {
        case .writeFailed: "钥匙串写入失败，凭据未保存，请检查钥匙串权限后重试"
        case .recoveryFailed: "凭据补存或恢复失败，会话可能未保存，请检查钥匙串权限后重新登录"
        case .readFailed: "钥匙串读取失败，请检查钥匙串权限后重试"
        }
    }
}

/// Instance dependencies keep failure tests away from the application's keychain.
struct CredentialStore {
    var read: (String) throws -> String? = Keychain.get
    var write: (String, String) -> Bool = Keychain.set

    /// Normalize local read failures without exposing backend details or sending empty credentials.
    func readRequired(_ key: String) throws -> String {
        do {
            guard let value = try read(key), !value.isEmpty else {
                throw CredentialPersistenceError.readFailed
            }
            return value
        } catch {
            throw CredentialPersistenceError.readFailed
        }
    }

    func save(_ key: String, _ value: String) throws {
        guard write(key, value) else { throw CredentialPersistenceError.writeFailed }
    }
}
