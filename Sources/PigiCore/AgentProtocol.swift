import Foundation

/// Wire types shared with thin clients. All mail fields are untrusted data.
public enum AgentProtocol {
    public static let version = 1
    public static let maxRequestBytes = 65_536
    public static let maxResponseBytes = 2_097_152

    public struct Request: Codable, Sendable {
        public let version: Int
        public let id: String
        public let method: String
        public let params: Params?

        public init(version: Int = AgentProtocol.version, id: String, method: String, params: Params? = nil) {
            self.version = version; self.id = id; self.method = method; self.params = params
        }
    }

    public struct Params: Codable, Sendable {
        public let account: String?
        public let messageID: String?
        public let query: String?
        public let limit: Int?
        public let offset: Int?
        public let since: Int?
        public let status: String?

        public init(account: String? = nil, messageID: String? = nil, query: String? = nil,
                    limit: Int? = nil, offset: Int? = nil, since: Int? = nil, status: String? = nil) {
            self.account = account; self.messageID = messageID; self.query = query
            self.limit = limit; self.offset = offset
            self.since = since; self.status = status
        }
    }

    public struct Message: Codable, Sendable {
        public let account: String
        public let messageID: String
        public let date: Int
        public let subject: String?
        public let fromName: String?
        public let fromEmail: String?
        public let snippet: String?
        public let unread: Bool
        public let starred: Bool
        public let status: String
    }

    public struct VerificationCode: Codable, Sendable {
        public let code: String
        public let fromName: String?
        public let fromEmail: String?
        public let date: Int
        public let account: String
        public let messageID: String
    }

    public struct Account: Codable, Sendable {
        public let account: String
        public let kind: String?
    }

    public struct Result: Codable, Sendable {
        public var codes: [VerificationCode]? = nil
        public var accounts: [Account]? = nil
        public var capabilities: [String] = ["accounts", "filters", "codes", "scoped_accounts"]
        public let items: [Message]?
        public let nextOffset: Int?
        public let message: Message?
        public let text: String?
        public let contentTrust: String
    }

    public struct Failure: Codable, Error, Sendable {
        public let code: String
        public let message: String
        static func make(_ code: String) -> Self {
            let messages = ["invalid_request": "Invalid request", "unsupported_version": "Unsupported protocol version",
                            "method_not_found": "Only accounts, list, search, get and codes are supported", "not_found": "Message not found",
                            "internal_error": "Local mail store unavailable", "too_large": "Frame exceeds size limit",
                            "permission_denied": "Account capability is not granted", "audit_unavailable": "Action audit unavailable",
                            "unauthorized": "Peer user is not authorized", "timeout": "Connection deadline exceeded"]
            return Self(code: code, message: messages[code] ?? "Request failed")
        }
    }

    public struct Response: Codable, Sendable {
        public let version: Int
        public let id: String?
        public let result: Result?
        public let error: Failure?
    }

    /// Deliberately excludes request IDs, accounts, queries, message IDs and content.
    public struct AuditEvent: Sendable {
        public let method: String
        public let outcome: String
        public let durationMilliseconds: Int
    }
}

extension LocalEngine {
    /// Sole agent dispatch entry: audit intent before access and fail closed on ledger errors.
    func agentRead(_ request: AgentProtocol.Request) throws -> AgentProtocol.Result {
        let row: Int64
        do { row = try beginAgentAction(request) }
        catch { throw AgentProtocol.Failure.make("audit_unavailable") }
        do {
            let result = try agentReadAuthorized(request)
            let response = AgentProtocol.Response(version: 1, id: request.id, result: result, error: nil)
            guard try JSONEncoder().encode(response).count <= AgentProtocol.maxResponseBytes else {
                throw AgentProtocol.Failure.make("too_large")
            }
            try finishAgentAction(row, result: "allowed")
            return result
        } catch {
            let failure = (error as? AgentProtocol.Failure) ?? .make("internal_error")
            do { try finishAgentAction(row, result: failure.code) }
            catch { throw AgentProtocol.Failure.make("audit_unavailable") }
            throw failure
        }
    }

    /// Runs entirely on the same actor and SQLite connection used by UI and sync.
    private func agentReadAuthorized(_ request: AgentProtocol.Request) throws -> AgentProtocol.Result {
        typealias Failure = AgentProtocol.Failure
        guard request.version == AgentProtocol.version else { throw Failure.make("unsupported_version") }
        guard !request.id.isEmpty, request.id.utf8.count <= 128 else { throw Failure.make("invalid_request") }
        guard ["accounts", "list", "search", "get", "codes"].contains(request.method) else { throw Failure.make("method_not_found") }
        let p = request.params
        // Check explicit scopes before looking up any message or querying FTS.
        if let account = p?.account { try requireAgentCapability(.read, account: account) }
        let limit = p?.limit ?? 50, offset = p?.offset ?? 0
        guard (1...100).contains(limit), (0...1_000_000).contains(offset),
              (p?.account?.utf8.count ?? 0) <= 1024,
              (p?.messageID?.utf8.count ?? 0) <= 4096 else { throw Failure.make("invalid_request") }

        guard (p?.since ?? 0) >= 0, (p?.since ?? 0) <= 9_007_199_254_740_991 else { throw Failure.make("invalid_request") }
        if let status = p?.status, !["inbox", "archived", "spam", "trash"].contains(status) {
            throw Failure.make("invalid_request")
        }
        if request.method == "accounts" {
            guard p?.messageID == nil, p?.query == nil, p?.since == nil, p?.status == nil else { throw Failure.make("invalid_request") }
            var conditions = [Self.agentReadableAccountSQL]
            var values: [SQLValue] = []
            if let account = p?.account { conditions.append("email=?"); values.append(.text(account)) }
            values += [.int(limit + 1), .int(offset)]
            let rows = try db().query("SELECT email,kind FROM accounts WHERE " + conditions.joined(separator: " AND ") + " ORDER BY email LIMIT ? OFFSET ?", values)
            var result = AgentProtocol.Result(items: nil, nextOffset: rows.count > limit ? offset + limit : nil,
                                               message: nil, text: nil, contentTrust: "untrusted")
            result.accounts = rows.prefix(limit).map { .init(account: $0["email"]?.text ?? "", kind: $0["kind"]?.text) }
            return result
        }
        if request.method == "codes" {
            guard p?.messageID == nil, p?.query == nil else { throw Failure.make("invalid_request") }
            let now = Int(Date().timeIntervalSince1970 * 1000)
            let since = p?.since ?? max(0, now - 600_000)
            var conditions = [Self.agentReadableMessageSQL, "m.status!='deleted'", "m.code IS NOT NULL", "length(trim(m.code))>0",
                              "m.date>=?", "m.date<=?"]
            var values: [SQLValue] = [.int(since), .int(now)]
            if let account = p?.account { conditions.append("m.account=?"); values.append(.text(account)) }
            if let status = p?.status { conditions.append("m.status=?"); values.append(.text(status)) }
            let rows = try db().query(
                "SELECT m.code,m.from_name,m.from_email,m.date,m.account,m.id FROM messages m WHERE "
                + conditions.joined(separator: " AND ") + " ORDER BY m.date DESC,m.account,m.id LIMIT ? OFFSET ?",
                values + [.int(limit + 1), .int(offset)])
            var result = AgentProtocol.Result(items: nil, nextOffset: rows.count > limit ? offset + limit : nil,
                                              message: nil, text: nil, contentTrust: "untrusted")
            result.codes = rows.prefix(limit).map {
                .init(code: $0["code"]?.text ?? "", fromName: $0["from_name"]?.text,
                      fromEmail: $0["from_email"]?.text, date: $0["date"]?.int ?? 0,
                      account: $0["account"]?.text ?? "", messageID: $0["id"]?.text ?? "")
            }
            return result
        }
        let columns = "m.account,m.id,m.date,m.subject,m.from_name,m.from_email,m.snippet,m.unread,m.starred,m.status"
        func message(_ r: SQLRow) -> AgentProtocol.Message {
            .init(account: r["account"]?.text ?? "", messageID: r["id"]?.text ?? "", date: r["date"]?.int ?? 0,
                  subject: r["subject"]?.text, fromName: r["from_name"]?.text, fromEmail: r["from_email"]?.text,
                  snippet: r["snippet"]?.text, unread: r["unread"]?.int == 1, starred: r["starred"]?.int == 1,
                  status: r["status"]?.text ?? "")
        }
        if request.method == "get" {
            guard let account = p?.account, !account.isEmpty, let id = p?.messageID, !id.isEmpty,
                  p?.query == nil, p?.limit == nil, p?.offset == nil, p?.since == nil, p?.status == nil else { throw Failure.make("invalid_request") }
            guard let row = try db().query("SELECT \(columns) FROM messages m WHERE m.account=? AND m.id=? AND m.status!='deleted'",
                                          [.text(account), .text(id)]).first else { throw Failure.make("not_found") }
            // Plain text only: never render HTML, fetch remote resources, mark read or execute content.
            let text = try db().query("SELECT body FROM fts WHERE rowid=(SELECT rowid FROM messages WHERE account=? AND id=?)",
                                      [.text(account), .text(id)]).first?["body"]?.text ?? ""
            return .init(items: nil, nextOffset: nil, message: message(row), text: text, contentTrust: "untrusted")
        }
        guard p?.messageID == nil else { throw Failure.make("invalid_request") }
        var sql = "SELECT \(columns) FROM messages m"
        var conditions = [Self.agentReadableMessageSQL, "m.status!='deleted'"]
        var values: [SQLValue] = []
        if request.method == "search" {
            guard let query = p?.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty,
                  query.utf8.count <= 4096 else { throw Failure.make("invalid_request") }
            if query.count < 3 {
                conditions.append("(m.subject LIKE ? ESCAPE '\\' OR m.from_email LIKE ? ESCAPE '\\')")
                let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                values += [.text("%\(escaped)%"), .text("%\(escaped)%")]
            } else {
                sql += " JOIN fts ON fts.rowid=m.rowid"
                conditions.append("fts MATCH ?")
                values.append(.text(query.split(whereSeparator: \.isWhitespace).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")))
            }
        } else if p?.query != nil { throw Failure.make("invalid_request") }
        if let account = p?.account { conditions.append("m.account=?"); values.append(.text(account)) }
        if let since = p?.since { conditions.append("m.date>=?"); values.append(.int(since)) }
        if let status = p?.status { conditions.append("m.status=?"); values.append(.text(status)) }
        sql += " WHERE " + conditions.joined(separator: " AND ") + " ORDER BY m.date DESC,m.account,m.id LIMIT ? OFFSET ?"
        let rows = try db().query(sql, values + [.int(limit + 1), .int(offset)])
        return .init(items: rows.prefix(limit).map(message), nextOffset: rows.count > limit ? offset + limit : nil,
                     message: nil, text: nil, contentTrust: "untrusted")
    }
}
