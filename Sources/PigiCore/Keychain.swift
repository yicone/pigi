import Foundation
import Security
import os

/// One generic-password item (`vault-v1`) for Gmail refresh tokens, IMAP
/// passwords, Proton sessions, and a reserved translation API key.
///
/// Startup reads the service once and keeps the document in memory. Writes go
/// through `KeychainVault`: isolated methods queue async callers, and the
/// synchronous API enters the same mutation under `memory`'s lock. Proton
/// saves stay synchronous because they run inside the database transaction;
/// hopping onto the cooperative thread pool here deadlocks when many
/// mailboxes touch the keychain together.
public enum Keychain {
    /// Matches `PRODUCT_BUNDLE_IDENTIFIER` so this fork does not share the upstream app's items.
    static let service = Bundle.main.bundleIdentifier ?? "one.yic.pigi"

    /// Reads the vault once. Later lookups in this process stay in memory.
    public static func warm() throws { try KeychainVault.shared.warmSync() }

    public static func get(_ key: String) throws -> String? { try KeychainVault.shared.read(key) }

    @discardableResult
    public static func set(_ key: String, _ value: String) -> Bool { KeychainVault.shared.write(key, value) }

    /// Reserved for a future translation feature. Stored in `vault-v1`, not a second item.
    public static func translationAPIKey() throws -> String? { try KeychainVault.shared.readTranslationAPIKey() }

    @discardableResult
    public static func setTranslationAPIKey(_ value: String) -> Bool { KeychainVault.shared.writeTranslationAPIKey(value) }
}

/// Async entry to the same vault document. Concurrent Proton session writes
/// that `await` these methods cannot overwrite each other's accounts.
public actor KeychainVault {
    public static let shared = KeychainVault(backend: SecurityKeychainBackend(), service: Keychain.service)

    private nonisolated let backend: any KeychainBackend
    private nonisolated let service: String
    private nonisolated let log: any KeychainLogging
    private nonisolated let memory: Locked<VaultMemory>

    init(backend: any KeychainBackend, service: String, log: any KeychainLogging = KeychainOSLog()) {
        self.backend = backend
        self.service = service
        self.log = log
        self.memory = Locked(VaultMemory())
    }

    public func warm() throws { try warmSync() }
    public func get(_ key: String) async throws -> String? { try read(key) }
    public func set(_ key: String, _ value: String) async -> Bool { write(key, value) }
    public func translationAPIKey() async throws -> String? { try readTranslationAPIKey() }
    public func setTranslationAPIKey(_ value: String) async -> Bool { writeTranslationAPIKey(value) }
    public nonisolated func startupCopyMatchingCount() -> Int { memory.withLock { $0.copyMatchingCount } }

    nonisolated func warmSync() throws {
        try memory.withLock { state in try ensureLoaded(&state) }
    }

    nonisolated func read(_ key: String) throws -> String? {
        try memory.withLock { state -> String? in
            try ensureLoaded(&state)
            return state.document.value(for: key)
        }
    }

    @discardableResult
    nonisolated func write(_ key: String, _ value: String) -> Bool {
        memory.withLock { state -> Bool in
            do { try ensureLoaded(&state) } catch { return false }
            if state.unreadable { return false }
            var document = state.document
            switch document.apply(key, value) {
            case .missing, .rejected:
                return false
            case .unchanged:
                return true
            case .stored, .deleted:
                do {
                    try backend.upsert(service: service, account: KeychainQuery.vaultAccount, data: try document.encoded())
                } catch {
                    log.error("keychain vault write failed \(Self.statusText(error))")
                    return false
                }
                state.document = document
                deletePending(&state)
                return true
            }
        }
    }

    nonisolated func readTranslationAPIKey() throws -> String? { try read(KeychainQuery.translationAccount) }
    nonisolated func writeTranslationAPIKey(_ value: String) -> Bool { write(KeychainQuery.translationAccount, value) }

    private nonisolated func ensureLoaded(_ state: inout VaultMemory) throws {
        if let expected = state.unverifiedMigration {
            do {
                guard try backend.read(service: service, account: KeychainQuery.vaultAccount) == expected else {
                    throw KeychainBackendError(code: errSecDecode)
                }
                state.unverifiedMigration = nil
            } catch {
                log.error("keychain vault verification failed \(Self.statusText(error))")
                throw error
            }
        }
        if state.unreadable { throw KeychainBackendError(code: errSecDecode) }
        if state.loaded {
            if !state.pendingDeletes.isEmpty { deletePending(&state) }
            return
        }
        state.copyMatchingCount += 1
        let items: [KeychainRecord]
        do {
            items = try backend.loadAll(service: service)
        } catch {
            log.error("keychain vault read failed \(Self.statusText(error))")
            throw error
        }
        if let vault = items.first(where: { $0.account == KeychainQuery.vaultAccount }) {
            do {
                state.document = try VaultDocument(json: vault.data)
            } catch {
                if !state.loggedDecodeFailure {
                    log.error("keychain vault decode failed")
                    state.loggedDecodeFailure = true
                }
                state.unreadable = true
                state.loaded = true
                throw error
            }
            state.pendingDeletes = items.map(\.account).filter { $0 != KeychainQuery.vaultAccount }
            state.loaded = true
            deletePending(&state)
            logLoaded(state)
            return
        }
        var document = VaultDocument()
        var pending: [String] = []
        var skippedOpaque = false
        for item in items.sorted(by: { $0.account < $1.account }) {
            guard let text = String(data: item.data, encoding: .utf8) else {
                skippedOpaque = true
                continue
            }
            switch VaultKey(item.account) {
            case .gmail(let email):
                document.gmailRefresh[email] = text
                pending.append(item.account)
            case .imap(let email):
                document.imap[email] = text
                pending.append(item.account)
            case .proton(let email):
                document.protonSession[email] = text
                pending.append(item.account)
            case .translation:
                document.translationAPIKey = text.isEmpty ? nil : text
                pending.append(item.account)
            case .extra(let key):
                document.extra[key] = text
                pending.append(item.account)
            case .discard:
                pending.append(item.account)
            }
        }
        if skippedOpaque { log.error("keychain legacy item is not utf8") }
        guard !pending.isEmpty else {
            state.document = document
            state.loaded = true
            logLoaded(state)
            return
        }
        do {
            let encoded = try document.encoded()
            try backend.upsert(service: service, account: KeychainQuery.vaultAccount, data: encoded)
            state.unverifiedMigration = encoded
            guard try backend.read(service: service, account: KeychainQuery.vaultAccount) == encoded else {
                throw KeychainBackendError(code: errSecDecode)
            }
            state.unverifiedMigration = nil
        } catch {
            log.error("keychain vault write failed \(Self.statusText(error))")
            throw error
        }
        state.document = document
        state.pendingDeletes = pending
        state.loaded = true
        deletePending(&state)
        logLoaded(state)
    }

    private nonisolated func deletePending(_ state: inout VaultMemory) {
        var remain: [String] = []
        for account in state.pendingDeletes where account != KeychainQuery.vaultAccount {
            do {
                try backend.delete(service: service, account: account)
            } catch {
                if state.loggedDeleteFailures.insert(account).inserted {
                    log.error("keychain legacy delete failed \(Self.statusText(error))")
                }
                remain.append(account)
            }
        }
        state.pendingDeletes = remain
    }

    private nonisolated func logLoaded(_ state: VaultMemory) {
        log.info("keychain vault loaded SecItemCopyMatching=\(state.copyMatchingCount)")
    }

    private nonisolated static func statusText(_ error: Error) -> String {
        guard let status = error as? KeychainBackendError else { return "status=unknown" }
        return "status=\(status.code)"
    }
}

enum KeychainQuery {
    static let vaultAccount = "vault-v1"
    static let translationAccount = "translation-api-key"

    static func loadAll(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
    }

    static func item(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

struct KeychainRecord: Sendable, Equatable {
    var account: String
    var data: Data
}

protocol KeychainBackend: Sendable {
    func loadAll(service: String) throws -> [KeychainRecord]
    func read(service: String, account: String) throws -> Data?
    func upsert(service: String, account: String, data: Data) throws
    func delete(service: String, account: String) throws
}

struct KeychainBackendError: Error {
    var code: OSStatus
}

struct SecurityKeychainBackend: KeychainBackend {
    private let testService: String?

    init() { testService = nil }

    init(integrationTestService: String) {
        precondition(integrationTestService.hasPrefix("one.yic.pigi.tests.") && integrationTestService.count > 24)
        testService = integrationTestService
    }

    func loadAll(service: String) throws -> [KeychainRecord] {
        try refuseTestHost(service: service)
        guard !service.isEmpty else { throw KeychainBackendError(code: errSecParam) }
        let query = KeychainQuery.loadAll(service: service)
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainBackendError(code: status) }
        guard let rows = item as? [[String: Any]] else {
            throw KeychainBackendError(code: errSecDecode)
        }
        return try rows.map { row in
            guard let account = row[kSecAttrAccount as String] as? String,
                  let data = try read(service: service, account: account) else {
                throw KeychainBackendError(code: errSecItemNotFound)
            }
            return KeychainRecord(account: account, data: data)
        }
    }

    func read(service: String, account: String) throws -> Data? {
        try refuseTestHost(service: service)
        guard !service.isEmpty, !account.isEmpty else { throw KeychainBackendError(code: errSecParam) }
        var query = KeychainQuery.item(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainBackendError(code: status) }
        guard let data = item as? Data else { throw KeychainBackendError(code: errSecDecode) }
        return data
    }

    func upsert(service: String, account: String, data: Data) throws {
        try refuseTestHost(service: service)
        guard !service.isEmpty, !account.isEmpty else { throw KeychainBackendError(code: errSecParam) }
        let query = KeychainQuery.item(service: service, account: account)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainBackendError(code: updated) }
        var add = query
        add[kSecValueData as String] = data
        let created = SecItemAdd(add as CFDictionary, nil)
        if created == errSecDuplicateItem {
            let again = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard again == errSecSuccess else { throw KeychainBackendError(code: again) }
            return
        }
        guard created == errSecSuccess else { throw KeychainBackendError(code: created) }
    }

    func delete(service: String, account: String) throws {
        try refuseTestHost(service: service)
        guard !service.isEmpty, !account.isEmpty else { throw KeychainBackendError(code: errSecParam) }
        let status = SecItemDelete(KeychainQuery.item(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainBackendError(code: status) }
    }

    private func refuseTestHost(service: String) throws {
        if let testService {
            guard service == testService else { throw KeychainBackendError(code: errSecParam) }
            return
        }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            throw KeychainBackendError(code: errSecInteractionNotAllowed)
        }
    }
}

protocol KeychainLogging: Sendable {
    func info(_ message: String)
    func error(_ message: String)
}

struct KeychainOSLog: KeychainLogging {
    private let logger = Logger(subsystem: "one.yic.pigi", category: "keychain")
    func info(_ message: String) { logger.info("\(message, privacy: .public)") }
    func error(_ message: String) { logger.error("\(message, privacy: .public)") }
}

private struct VaultMemory: Sendable {
    var unverifiedMigration: Data?
    var loaded = false
    var unreadable = false
    var loggedDecodeFailure = false
    var document = VaultDocument()
    var pendingDeletes: [String] = []
    var loggedDeleteFailures: Set<String> = []
    var copyMatchingCount = 0
}

private struct VaultDocument: Sendable {
    var version = 1
    var gmailRefresh: [String: String] = [:]
    var imap: [String: String] = [:]
    var protonSession: [String: String] = [:]
    var translationAPIKey: String?
    var extra: [String: String] = [:]
    var unknownJSON: Data?

    init() {}

    init(json: Data) throws {
        let raw = try JSONSerialization.jsonObject(with: json)
        guard var object = raw as? [String: Any] else { throw KeychainBackendError(code: errSecDecode) }
        if let versionValue = object.removeValue(forKey: "version") {
            guard let number = versionValue as? NSNumber else { throw KeychainBackendError(code: errSecDecode) }
            version = number.intValue
        }
        gmailRefresh = try Self.stringMap(object.removeValue(forKey: "gmailRefresh"))
        imap = try Self.stringMap(object.removeValue(forKey: "imap"))
        protonSession = try Self.stringMap(object.removeValue(forKey: "protonSession"))
        extra = try Self.stringMap(object.removeValue(forKey: "extra"))
        if let translation = object.removeValue(forKey: "translationAPIKey"), !(translation is NSNull) {
            guard let string = translation as? String else { throw KeychainBackendError(code: errSecDecode) }
            translationAPIKey = string.isEmpty ? nil : string
        }
        unknownJSON = object.isEmpty ? nil : try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func value(for key: String) -> String? {
        switch VaultKey(key) {
        case .gmail(let email): gmailRefresh[email]
        case .imap(let email): imap[email]
        case .proton(let email): protonSession[email]
        case .translation: translationAPIKey
        case .extra(let account): extra[account]
        case .discard: nil
        }
    }

    mutating func apply(_ key: String, _ value: String) -> VaultWrite {
        switch VaultKey(key) {
        case .discard:
            return .rejected
        case .translation:
            let stored = value.isEmpty ? nil : value
            if translationAPIKey == stored { return value.isEmpty ? .missing : .unchanged }
            translationAPIKey = stored
            return value.isEmpty ? .deleted : .stored
        case .gmail(let email):
            return Self.assign(&gmailRefresh, email, value)
        case .imap(let email):
            return Self.assign(&imap, email, value)
        case .proton(let email):
            return Self.assign(&protonSession, email, value)
        case .extra(let account):
            return Self.assign(&extra, account, value)
        }
    }

    func encoded() throws -> Data {
        var object: [String: Any] = [:]
        if let unknownJSON, let leftover = try JSONSerialization.jsonObject(with: unknownJSON) as? [String: Any] {
            object = leftover
        }
        object["version"] = version
        object["gmailRefresh"] = gmailRefresh
        object["imap"] = imap
        object["protonSession"] = protonSession
        object["extra"] = extra
        object["translationAPIKey"] = translationAPIKey ?? NSNull()
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func assign(_ map: inout [String: String], _ key: String, _ value: String) -> VaultWrite {
        if value.isEmpty {
            return map.removeValue(forKey: key) == nil ? .missing : .deleted
        }
        if map[key] == value { return .unchanged }
        map[key] = value
        return .stored
    }

    private static func stringMap(_ value: Any?) throws -> [String: String] {
        guard let value else { return [:] }
        guard let dict = value as? [String: Any] else { throw KeychainBackendError(code: errSecDecode) }
        var map: [String: String] = [:]
        for (key, item) in dict {
            guard let string = item as? String else { throw KeychainBackendError(code: errSecDecode) }
            map[key] = string
        }
        return map
    }
}

private enum VaultWrite {
    case stored, unchanged, deleted, missing, rejected
}

private enum VaultKey {
    case gmail(String)
    case imap(String)
    case proton(String)
    case translation
    case extra(String)
    case discard

    init(_ account: String) {
        if account == KeychainQuery.translationAccount {
            self = .translation
            return
        }
        if account == "proton-session" {
            self = .discard
            return
        }
        if let email = Self.mailbox(account, prefix: "proton-session-") {
            self = .proton(email)
            return
        }
        if account.hasPrefix("proton-session-") {
            self = .discard
            return
        }
        if let email = Self.mailbox(account, prefix: "gmail-refresh-") {
            self = .gmail(email)
            return
        }
        if let email = Self.mailbox(account, prefix: "imap-") {
            self = .imap(email)
            return
        }
        self = .extra(account)
    }

    private static func mailbox(_ account: String, prefix: String) -> String? {
        guard account.hasPrefix(prefix) else { return nil }
        let email = account.dropFirst(prefix.count).lowercased()
        guard email.contains("@") else { return nil }
        return email
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
