import Foundation

/// Google OAuth for an installed app (PKCE, iOS client type, no client secret).
/// Token refresh and authorization-code redemption live here. The system-browser
/// sign-in stays in the app, because it needs AppKit.
public enum GmailAuth {
    /// The OAuth client ID the user created in their own Google Cloud project (see docs/gmail-api.md).
    public static var clientID: String {
        get { UserDefaults.standard.string(forKey: "gmailClientID") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "gmailClientID") }
    }
    public static var isConfigured: Bool { clientID.hasSuffix(".apps.googleusercontent.com") }
    public static let scopes = [
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "openid",
    ]

    public static var redirectScheme: String {
        "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }
    public static var redirectURI: String { "\(redirectScheme):/oauth2redirect" }

    public struct Token {
        public let accessToken: String
        public let refreshToken: String?
        public let expiresAt: Date

        public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
        }
    }

    public enum AuthError: LocalizedError {
        case cancelled
        case denied(String)
        case badResponse(String)

        public var errorDescription: String? {
            switch self {
            case .cancelled: "已取消登录"
            case .denied(let reason): "Google 拒绝了请求:\(reason)"
            case .badResponse(let detail): "Google 返回了意外的内容:\(detail)"
            }
        }
    }

    // MARK: - Refresh

    public static func refresh(_ refreshToken: String) async throws -> Token {
        try await tokenRequest([
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
    }

    /// Redeems an authorization code from the interactive sign-in, or refreshes a token.
    public static func tokenRequest(_ form: [String: String]) async throws -> Token {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        struct Response: Decodable {
            let access_token: String?
            let refresh_token: String?
            let expires_in: Double?
            let error: String?
            let error_description: String?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        if let error = response.error {
            throw AuthError.denied([error, response.error_description].compactMap { $0 }.joined(separator: ": "))
        }
        guard let access = response.access_token else { throw AuthError.badResponse("没有 access_token") }
        return Token(
            accessToken: access,
            refreshToken: response.refresh_token,
            expiresAt: Date().addingTimeInterval((response.expires_in ?? 3600) - 60)
        )
    }

    public static func userEmail(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        struct Info: Decodable { let email: String? }
        guard let email = try JSONDecoder().decode(Info.self, from: data).email else {
            throw AuthError.badResponse("没有取到邮箱地址")
        }
        return email.lowercased()
    }
}

private extension CharacterSet {
    /// Everything except the characters that are special inside a form value.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
