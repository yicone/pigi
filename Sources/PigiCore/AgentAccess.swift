import CryptoKit
import Foundation

public enum AgentCapability: String, CaseIterable, Identifiable, Sendable {
    case read, draft, organize
    public var id: String { rawValue }
}

/// Account grants, owned by the human-facing app. They cannot be changed over the socket.
/// A grant never enables a method absent from the protocol whitelist.
public struct AgentPermissions: Equatable, Sendable {
    public var read: Bool
    public var draft: Bool
    public var organize: Bool
    public static let defaults = Self(read: true, draft: true, organize: false)
    public static let canSend = false

    public init(read: Bool, draft: Bool, organize: Bool) {
        self.read = read; self.draft = draft; self.organize = organize
    }

    public subscript(_ capability: AgentCapability) -> Bool {
        get {
            switch capability { case .read: read; case .draft: draft; case .organize: organize }
        }
        set {
            switch capability { case .read: read = newValue; case .draft: draft = newValue; case .organize: organize = newValue }
        }
    }
}

public struct AgentAccountAccess: Identifiable, Sendable {
    public let account: String
    public let permissions: AgentPermissions
    public var id: String { account }
}

/// Only keyed digests identify accounts, targets and arguments. No mail, credential,
/// request ID, arbitrary method string or raw error is retained in the action ledger.
public struct AgentAction: Identifiable, Sendable {
    public let id: Int64
    public let ts: Int
    public let tool: String
    public let account: String?
    public let target: String?
    public let argsHash: String
    public let result: String
}

extension LocalEngine {
    static let agentReadableAccountSQL = """
        COALESCE((SELECT read FROM agent_permissions WHERE account=accounts.email),1)=1
        """
    static let agentReadableMessageSQL = """
        EXISTS(SELECT 1 FROM accounts WHERE email=m.account AND \(agentReadableAccountSQL))
        """

    /// UI-only API. Never include this or credential/account administration in agent dispatch.
    public func agentAccountAccess() throws -> [AgentAccountAccess] {
        try db().query("SELECT email FROM accounts ORDER BY email").compactMap { row in
            guard let account = row["email"]?.text else { return nil }
            return .init(account: account, permissions: try agentPermissions(account: account))
        }
    }

    public func agentPermissions(account: String) throws -> AgentPermissions {
        guard try self.account(account) != nil else { throw AgentProtocol.Failure.make("permission_denied") }
        guard let row = try db().query("SELECT read,draft,organize FROM agent_permissions WHERE account=?", [.text(account)]).first else {
            return .defaults
        }
        return .init(read: row["read"]?.int == 1, draft: row["draft"]?.int == 1, organize: row["organize"]?.int == 1)
    }

    public func setAgentPermissions(account: String, permissions: AgentPermissions) throws {
        guard try self.account(account) != nil else { throw AgentProtocol.Failure.make("permission_denied") }
        try db().run("INSERT OR REPLACE INTO agent_permissions(account,read,draft,organize) VALUES(?,?,?,?)",
                     [.text(account), .int(permissions.read ? 1 : 0), .int(permissions.draft ? 1 : 0), .int(permissions.organize ? 1 : 0)])
    }

    func requireAgentCapability(_ capability: AgentCapability, account: String) throws {
        guard try agentPermissions(account: account)[capability] else { throw AgentProtocol.Failure.make("permission_denied") }
    }

    /// Human-facing bounded audit view; never exposed as an agent tool.
    public func agentActions(limit: Int = 100, offset: Int = 0) throws -> [AgentAction] {
        guard (1...200).contains(limit), (0...1_000_000).contains(offset) else { throw AgentProtocol.Failure.make("invalid_request") }
        return try db().query("SELECT rowid,ts,tool,account,target,args_hash,result FROM agent_actions ORDER BY rowid DESC LIMIT ? OFFSET ?",
                              [.int(limit), .int(offset)]).map {
            .init(id: Int64($0["rowid"]?.int ?? 0), ts: $0["ts"]?.int ?? 0, tool: $0["tool"]?.text ?? "invalid",
                  account: $0["account"]?.text, target: $0["target"]?.text,
                  argsHash: $0["args_hash"]?.text ?? "", result: $0["result"]?.text ?? "internal_error")
        }
    }

    private func auditKey() throws -> SymmetricKey {
        let s = try db()
        if let key = try s.query("SELECT key FROM agent_audit_key WHERE id=1").first?["key"]?.blob {
            guard key.count == 32 else { throw AgentProtocol.Failure.make("audit_unavailable") }
            return SymmetricKey(data: key)
        }
        let key = SymmetricKey(size: .bits256)
        try s.run("INSERT INTO agent_audit_key(id,key) VALUES(1,?)", [.blob(key.withUnsafeBytes { Data($0) })])
        return key
    }

    func beginAgentAction(_ request: AgentProtocol.Request) throws -> Int64 {
        let key = try auditKey()
        func digest(_ domain: String, _ value: Data) -> String {
            let mac = HMAC<SHA256>.authenticationCode(for: Data((domain + "\u{0}").utf8) + value, using: key)
            return mac.map { String(format: "%02x", $0) }.joined()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let args = try encoder.encode(request.params)
        let tool = ["accounts", "list", "search", "get", "codes"].contains(request.method) ? request.method : "invalid"
        return try db().run("INSERT INTO agent_actions(ts,tool,account,target,args_hash,result) VALUES(?,?,?,?,?,'started')",
                            [.int(Int(Date().timeIntervalSince1970 * 1000)), .text(tool),
                             .opt(request.params?.account.map { digest("account", Data($0.utf8)) }),
                             .opt(request.params?.messageID.map { digest("target", Data($0.utf8)) }),
                             .text(digest("args", args))])
    }

    func finishAgentAction(_ row: Int64, result: String) throws {
        // Only callers with fixed protocol outcome codes reach here.
        try db().run("UPDATE agent_actions SET result=? WHERE rowid=?", [.text(result), .int(Int(row))])
    }

    /// Retains malformed/oversized frame and peer-auth failures without retaining input bytes.
    func auditAgentTransportFailure(_ code: String) throws {
        let allowed = ["invalid_request", "too_large", "unauthorized", "timeout", "internal_error"]
        let row = try beginAgentAction(.init(id: "", method: "invalid"))
        try finishAgentAction(row, result: allowed.contains(code) ? code : "internal_error")
    }
}
