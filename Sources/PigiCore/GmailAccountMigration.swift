import Foundation

/// Runs inside the caller's SQLite transaction. Credentials stay under their
/// original vault keys; aliases join them to one canonical cache identity.
enum GmailAccountMigration {
    static func identity(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func run(_ store: Store, legacy: [String], importLegacy: Bool) throws {
        let allAccounts = try store.query("SELECT * FROM accounts")
        let rows = allAccounts.filter { $0["kind"]?.text == "gmail" }
        var groups = Dictionary(grouping: rows, by: { identity($0["email"]!.text!) })
        if importLegacy {
            for email in legacy where !identity(email).isEmpty { groups[identity(email), default: []] += [] }
        }
        for canonical in groups.keys.sorted() {
            let rows = groups[canonical]!
            let originals = rows.compactMap { $0["email"]?.text }
            let preferences = legacy.filter { identity($0) == canonical }
            // Fail closed on a collision with another account kind.
            if allAccounts.contains(where: { identity($0["email"]!.text!) == canonical && $0["kind"]?.text != "gmail" }) {
                throw SQLError(message: "邮箱连接方式冲突，账号配置未迁移")
            }
            var aliases: [String] = []
            for id in preferences + originals.sorted() + [canonical] where !aliases.contains(id) { aliases.append(id) }
            for (priority, alias) in aliases.enumerated() {
                try store.run("INSERT OR IGNORE INTO gmail_credential_aliases(account,identifier,priority) VALUES(?,?,?)",
                              [.text(canonical), .text(alias), .int(priority)])
            }
            // Keep all prior cursor metadata, including non-winning duplicate
            // rows. The canonical cache's cursor remains active when present.
            for row in rows {
                var metadata: [String: String] = [:]
                for (key, value) in row {
                    if let text = value.text { metadata[key] = text }
                    else if let number = value.int { metadata[key] = String(number) }
                }
                try store.run("INSERT OR IGNORE INTO gmail_legacy_state(account,identifier,metadata) VALUES(?,?,?)",
                              [.text(canonical), .text(row["email"]!.text!), .blob(try JSONEncoder().encode(metadata))])
            }
            if !originals.contains(canonical) {
                // Prefer an already synchronized row over a newly imported shell.
                let preferred = rows.sorted {
                    let left = $0["last_sync"]?.int ?? ($0["history_id"]?.text == nil ? -1 : 0)
                    let right = $1["last_sync"]?.int ?? ($1["history_id"]?.text == nil ? -1 : 0)
                    return left == right ? $0["email"]!.text! < $1["email"]!.text! : left > right
                }.first?["email"]?.text
                if let preferred {
                    try store.run("UPDATE accounts SET email=? WHERE email=?", [.text(canonical), .text(preferred)])
                } else {
                    try store.run("INSERT INTO accounts(email,kind,added_at) VALUES(?,'gmail',?)",
                                  [.text(canonical), .int(Int(Date().timeIntervalSince1970))])
                }
            }
            if let current = rows.first(where: { $0["email"]?.text == canonical }),
               current["history_id"]?.text == nil, current["page_token"]?.text == nil, current["last_sync"]?.int == nil,
               let synced = rows.first(where: { $0["history_id"]?.text != nil || $0["page_token"]?.text != nil || $0["last_sync"]?.int != nil }) {
                // Adopt a populated cursor as a unit; never combine cursor pieces
                // from separate synchronization states.
                for column in ["history_id", "page_token", "backfill_done", "last_sync", "last_error", "last_error_kind"] {
                    if let value = synced[column] {
                        try store.run("UPDATE accounts SET \(column)=? WHERE email=?", [value, .text(canonical)])
                    }
                }
            }
            for original in originals where original != canonical {
                for table in ["messages", "attachments", "inline_images", "muted", "account_labels", "proton_snapshot", "agent_permissions"] {
                    try merge(table, from: original, into: canonical, store: store)
                }
                try store.run("DELETE FROM accounts WHERE email=?", [.text(original)])
            }
            // The canonical row owns the unified message set, not the old count.
            try store.run("UPDATE accounts SET total=MAX(COALESCE(total,0),(SELECT COUNT(*) FROM messages WHERE account=?)) WHERE email=?",
                          [.text(canonical), .text(canonical)])
        }
    }

    private static func merge(_ table: String, from source: String, into target: String, store: Store) throws {
        // Table/column identifiers come exclusively from our fixed schema.
        let columns = try store.query("PRAGMA table_info(\(table))")
        let keys = columns.filter { ($0["pk"]?.int ?? 0) > 0 && $0["name"]?.text != "account" }.compactMap { $0["name"]?.text }
        let match = (["src.account=?"] + keys.map { "src.\($0)=dst.\($0)" }).joined(separator: " AND ")
        for column in columns where column["name"]?.text != "account" && (column["pk"]?.int ?? 0) == 0 {
            let name = column["name"]!.text!
            let other = "(SELECT src.\(name) FROM \(table) src WHERE \(match))"
            // Duplicate permission rows may only narrow access, never widen it.
            let value = table == "agent_permissions" ? "MIN(dst.\(name),COALESCE(\(other),dst.\(name)))" : "COALESCE(dst.\(name),\(other))"
            try store.run("UPDATE \(table) AS dst SET \(name)=\(value) WHERE dst.account=?", [.text(source), .text(target)])
        }
        if table == "messages" {
            for row in try store.query("SELECT src.rowid AS source,dst.rowid AS target FROM messages src JOIN messages dst ON src.id=dst.id WHERE src.account=? AND dst.account=?", [.text(source), .text(target)]) {
                try store.run("INSERT INTO fts(rowid,subject,sender,body) SELECT ?,subject,sender,body FROM fts WHERE rowid=? AND NOT EXISTS(SELECT 1 FROM fts WHERE rowid=?)",
                              [.int(row["target"]!.int!), .int(row["source"]!.int!), .int(row["target"]!.int!)])
                for column in ["subject", "sender", "body"] {
                    try store.run("UPDATE fts SET \(column)=COALESCE(NULLIF(\(column),''),(SELECT \(column) FROM fts WHERE rowid=?)) WHERE rowid=?",
                                  [.int(row["source"]!.int!), .int(row["target"]!.int!)])
                }
            }
            try store.run("DELETE FROM fts WHERE rowid IN (SELECT src.rowid FROM messages src JOIN messages dst ON src.id=dst.id WHERE src.account=? AND dst.account=?)",
                          [.text(source), .text(target)])
        }
        // Non-colliding messages keep their rowid, and therefore their FTS rows.
        try store.run("UPDATE OR IGNORE \(table) SET account=? WHERE account=?", [.text(target), .text(source)])
        try store.run("DELETE FROM \(table) WHERE account=?", [.text(source)])
    }
}
