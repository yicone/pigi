import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
#if canImport(PigiCore)
import PigiCore
#endif

extension GmailAuth {
    /// System browser sign-in with PKCE. Token refresh stays in PigiCore.
    @MainActor
    static func signIn() async throws -> (email: String, token: Token) {
        guard isConfigured else { throw AuthError.badResponse("请先在 设置 › 邮箱管理 里填入你自己的 Google OAuth 客户端 ID") }
        let verifier = randomString(byteCount: 48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = randomString(byteCount: 16)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            // Always show the account chooser (several accounts are added one by one)
            // and force consent so a refresh token is issued every time.
            .init(name: "prompt", value: "select_account consent"),
        ]

        let callback = try await WebSession.run(url: components.url!, scheme: redirectScheme)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let error = value("error") {
            throw error == "access_denied" ? AuthError.cancelled : AuthError.denied(error)
        }
        guard value("state") == state, let code = value("code") else {
            throw AuthError.badResponse("授权回调缺少 code 或 state 不匹配")
        }

        let token = try await tokenRequest([
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
        ])
        let email = try await userEmail(accessToken: token.accessToken)
        return (email, token)
    }

    private static func randomString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URL
    }
}

/// Bridges ASWebAuthenticationSession to async/await.
@MainActor
private final class WebSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    static func run(url: URL, scheme: String) async throws -> URL {
        let runner = WebSession()
        return try await runner.start(url: url, scheme: scheme)
    }

    private func start(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: GmailAuth.AuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? GmailAuth.AuthError.cancelled)
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                continuation.resume(throwing: GmailAuth.AuthError.badResponse("无法打开登录窗口"))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
