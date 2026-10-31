import Foundation
#if canImport(PigiCore)
import PigiCore
#endif

/// What the app still asks Google for directly: the account's profile picture.
/// Mail itself goes through the in-app LocalEngine.
actor GmailClient {
    let email: String
    private var token: GmailAuth.Token?

    init(email: String) { self.email = email }

    /// The account's profile picture; needs the userinfo.profile scope, so it is
    /// nil for accounts authorized before that scope was requested.
    func profilePictureURL() async -> URL? {
        struct Info: Decodable { let picture: String? }
        guard let access = await accessToken() else { return nil }
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let picture = try? JSONDecoder().decode(Info.self, from: data).picture
        else { return nil }
        return URL(string: picture)
    }

    private func accessToken() async -> String? {
        if let token, token.expiresAt > Date() { return token.accessToken }
        guard let refresh = Keychain.get(GmailStore.keychainKey(email)),
              let fresh = try? await GmailAuth.refresh(refresh) else { return nil }
        token = fresh
        return fresh.accessToken
    }
}
