import Foundation

public struct GmailFailure: LocalizedError {
    public let status: Int
    public let detail: String
    public var errorDescription: String? { "Gmail \(status) \(detail.prefix(200))" }
    public init(status: Int, detail: String) {
        self.status = status
        self.detail = detail
    }
}

public struct GmailRevoked: LocalizedError {
    public init() {}
    public var errorDescription: String? { "授权已失效,请在 邮箱管理 里点该邮箱行的「重新授权」图标" }
}

/// Authorized calls to the Gmail REST API for one mailbox, with retry on quota errors and token refresh.
actor GmailSession {
    let email: String
    private var access: String?
    private var expires = Date.distantPast
    private var nextSlot = Date.distantPast

    // Internal seam for credential-free engine regression fixtures.
    typealias Fixture = @Sendable (String, [(String, String)]) async throws -> Data
    private let fixture: Fixture?
    init(email: String, fixture: Fixture? = nil) {
        self.email = email
        self.fixture = fixture
    }

    private func token(force: Bool = false) async throws -> String {
        if !force, let access, expires > Date() { return access }
        guard let refresh = Keychain.get(GmailStore.keychainKey(email)), !refresh.isEmpty else { throw GmailRevoked() }
        do {
            let fresh = try await GmailAuth.refresh(refresh)
            access = fresh.accessToken
            expires = fresh.expiresAt
            return fresh.accessToken
        } catch GmailAuth.AuthError.denied(let reason) where reason.contains("invalid_grant") {
            throw GmailRevoked()
        }
    }

    /// Spaces requests so a backfill stays under Gmail's per-user quota (about 8 per second).
    private func pace() async {
        let now = Date()
        let at = max(now, nextSlot)
        nextSlot = at.addingTimeInterval(0.125)
        if at > now { try? await Task.sleep(for: .seconds(at.timeIntervalSince(now))) }
    }

    func call(_ path: String, query: [(String, String)] = [], body: [String: Any]? = nil) async throws -> Data {
        if let fixture { return try await fixture(path, query) }
        var parts = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/" + path)!
        if !query.isEmpty { parts.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        var refreshed = false
        for attempt in 0..<6 {
            await pace()
            var request = URLRequest(url: parts.url!, timeoutInterval: 60)
            request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
            if let body {
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) { return data }
                let detail = String(decoding: data, as: UTF8.self)
                if status == 401, !refreshed {
                    refreshed = true
                    _ = try await token(force: true)
                    continue
                }
                let quota = (status == 429 || status == 403) && ["quota", "rate limit", "ratelimit"].contains { detail.lowercased().contains($0) }
                guard quota || [500, 502, 503, 504].contains(status), attempt < 5 else { throw GmailFailure(status: status, detail: detail) }
                let retry = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                try await Task.sleep(for: .seconds(retry ?? (quota ? 65 : min(pow(2, Double(attempt)), 60))))
            } catch let error as URLError where attempt < 5 && error.code != .cancelled {
                try await Task.sleep(for: .seconds(min(pow(2, Double(attempt)), 30)))
            }
        }
        throw GmailFailure(status: 0, detail: "请求多次失败")
    }

    func json(_ path: String, query: [(String, String)] = [], body: [String: Any]? = nil) async throws -> [String: Any] {
        let data = try await call(path, query: query, body: body)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
