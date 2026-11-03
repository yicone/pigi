import Foundation

/// Wire types shared with thin clients. All mail fields are untrusted data.
public enum AgentProtocol {
    public static let version = 1
    public static let maxRequestBytes = 65_536
    public static let maxResponseBytes = 2_097_152

    public struct Request: Codable {
        public let version: Int
        public let id: String
        public let method: String
        public let params: Params?

        public init(version: Int = AgentProtocol.version, id: String, method: String, params: Params? = nil) {
            self.version = version; self.id = id; self.method = method; self.params = params
        }
    }

    public struct Params: Codable {
        public let account: String?
        public let messageID: String?
        public let query: String?
        public let limit: Int?
        public let offset: Int?

        public init(account: String? = nil, messageID: String? = nil, query: String? = nil,
                    limit: Int? = nil, offset: Int? = nil) {
            self.account = account; self.messageID = messageID; self.query = query
            self.limit = limit; self.offset = offset
        }
    }

    public struct Message: Codable {
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

    public struct Result: Codable {
        public let items: [Message]?
        public let nextOffset: Int?
        public let message: Message?
        public let text: String?
        public let contentTrust: String
    }

    public struct Failure: Codable, Error {
        public let code: String
        public let message: String
        static func make(_ code: String) -> Self {
            let messages = ["invalid_request": "Invalid request", "unsupported_version": "Unsupported protocol version",
                            "method_not_found": "Only list, search and get are supported", "not_found": "Message not found",
                            "internal_error": "Local mail store unavailable", "too_large": "Frame exceeds size limit",
                            "unauthorized": "Peer user is not authorized", "timeout": "Connection deadline exceeded"]
            return Self(code: code, message: messages[code] ?? "Request failed")
        }
    }

    public struct Response: Codable {
        public let version: Int
        public let id: String?
        public let result: Result?
        public let error: Failure?
    }

    /// Deliberately excludes request IDs, accounts, queries, message IDs and content.
    public struct AuditEvent {
        public let method: String
        public let outcome: String
        public let durationMilliseconds: Int
    }
}

extension LocalEngine {
    /// Runs entirely on the same actor and SQLite connection used by UI and sync.
    func agentRead(_ request: AgentProtocol.Request) throws -> AgentProtocol.Result {
        typealias Failure = AgentProtocol.Failure
        guard request.version == AgentProtocol.version else { throw Failure.make("unsupported_version") }
        guard !request.id.isEmpty, request.id.utf8.count <= 128 else { throw Failure.make("invalid_request") }
        guard ["list", "search", "get"].contains(request.method) else { throw Failure.make("method_not_found") }
        let p = request.params
        let limit = p?.limit ?? 50, offset = p?.offset ?? 0
        guard (1...100).contains(limit), (0...1_000_000).contains(offset),
              (p?.account?.utf8.count ?? 0) <= 1024,
              (p?.messageID?.utf8.count ?? 0) <= 4096 else { throw Failure.make("invalid_request") }

        let columns = "m.account,m.id,m.date,m.subject,m.from_name,m.from_email,m.snippet,m.unread,m.starred,m.status"
        func message(_ r: SQLRow) -> AgentProtocol.Message {
            .init(account: r["account"]?.text ?? "", messageID: r["id"]?.text ?? "", date: r["date"]?.int ?? 0,
                  subject: r["subject"]?.text, fromName: r["from_name"]?.text, fromEmail: r["from_email"]?.text,
                  snippet: r["snippet"]?.text, unread: r["unread"]?.int == 1, starred: r["starred"]?.int == 1,
                  status: r["status"]?.text ?? "")
        }
        if request.method == "get" {
            guard let account = p?.account, !account.isEmpty, let id = p?.messageID, !id.isEmpty,
                  p?.query == nil, p?.limit == nil, p?.offset == nil else { throw Failure.make("invalid_request") }
            guard let row = try db().query("SELECT \(columns) FROM messages m WHERE m.account=? AND m.id=? AND m.status!='deleted'",
                                          [.text(account), .text(id)]).first else { throw Failure.make("not_found") }
            // Plain text only: never render HTML, fetch remote resources, mark read or execute content.
            let text = try db().query("SELECT body FROM fts WHERE rowid=(SELECT rowid FROM messages WHERE account=? AND id=?)",
                                      [.text(account), .text(id)]).first?["body"]?.text ?? ""
            return .init(items: nil, nextOffset: nil, message: message(row), text: text, contentTrust: "untrusted")
        }
        guard p?.messageID == nil else { throw Failure.make("invalid_request") }
        var sql = "SELECT \(columns) FROM messages m"
        var conditions = ["m.status!='deleted'"]
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
        sql += " WHERE " + conditions.joined(separator: " AND ") + " ORDER BY m.date DESC,m.account,m.id LIMIT ? OFFSET ?"
        let rows = try db().query(sql, values + [.int(limit + 1), .int(offset)])
        return .init(items: rows.prefix(limit).map(message), nextOffset: rows.count > limit ? offset + limit : nil,
                     message: nil, text: nil, contentTrust: "untrusted")
    }
}
