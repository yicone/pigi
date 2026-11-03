import Foundation
import SQLite3

/// A value bound to or read from SQLite.
enum SQLValue {
    case int(Int)
    case text(String)
    case blob(Data)
    case null

    var int: Int? { if case .int(let v) = self { v } else { nil } }
    var text: String? { if case .text(let v) = self { v } else { nil } }
    var blob: Data? { if case .blob(let v) = self { v } else { nil } }
}

public struct SQLError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(message: String) { self.message = message }
}

typealias SQLRow = [String: SQLValue]

/// Thin wrapper over the system SQLite. Not thread safe: the engine actor owns the only instance.
final class Store {
    private var handle: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open(path, &handle) == SQLITE_OK else { throw SQLError(message: "无法打开数据库") }
        sqlite3_busy_timeout(handle, 30_000)
        try run("PRAGMA journal_mode=WAL")
        try run("PRAGMA synchronous=NORMAL")
        // Reduce deleted-page remnants. Historical WAL, FTS internals and backups
        // remain outside this logical deletion guarantee.
        try run("PRAGMA secure_delete=ON")
    }

    deinit { sqlite3_close(handle) }

    @discardableResult
    func run(_ sql: String, _ args: [SQLValue] = []) throws -> Int64 {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let code = sqlite3_step(stmt)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw failure() }
        return sqlite3_last_insert_rowid(handle)
    }

    func query(_ sql: String, _ args: [SQLValue] = []) throws -> [SQLRow] {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var rows: [SQLRow] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw failure() }
            var row: SQLRow = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = .int(Int(sqlite3_column_int64(stmt, i)))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, i))
                    row[name] = .blob(n == 0 ? Data() : Data(bytes: sqlite3_column_blob(stmt, i), count: n))
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    func transaction(_ body: () throws -> Void) throws {
        try run("BEGIN")
        do {
            try body()
            try run("COMMIT")
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ args: [SQLValue]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, arg) in args.enumerated() {
            let index = Int32(i + 1)
            switch arg {
            case .int(let v): sqlite3_bind_int64(stmt, index, Int64(v))
            case .text(let v): sqlite3_bind_text(stmt, index, v, -1, transient)
            case .blob(let v): _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(v.count), transient) }
            case .null: sqlite3_bind_null(stmt, index)
            }
        }
        return stmt
    }

    private func failure() -> SQLError {
        SQLError(message: String(cString: sqlite3_errmsg(handle)))
    }
}

extension SQLValue {
    static func opt(_ text: String?) -> SQLValue { text.map(SQLValue.text) ?? .null }
}
