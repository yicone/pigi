import Foundation

/// A named bucket in the sidebar. Accounts can be dragged between groups and the groups reordered.
struct AccountGroup: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var accountIDs: [String]

    static let gmailID = "group-gmail"
    static let imapID = "group-imap"
    static let protonID = "group-proton"

    static var defaults: [AccountGroup] {
        [
            AccountGroup(id: gmailID, name: "Gmail", accountIDs: []),
            AccountGroup(id: imapID, name: "IMAP", accountIDs: []),
        ]
    }

    private static let key = "sidebarGroups"

    static func load() -> [AccountGroup] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let groups = try? JSONDecoder().decode([AccountGroup].self, from: data), !groups.isEmpty
        else { return defaults }
        return groups
    }

    static func save(_ groups: [AccountGroup]) {
        if let data = try? JSONEncoder().encode(groups) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// A group together with its live accounts, ready to draw.
struct SidebarGroup: Identifiable {
    let group: AccountGroup
    let accounts: [Account]
    var id: String { group.id }
}

extension AppState {
    /// Groups with accounts filled in: vanished accounts dropped, new ones placed in the group for their kind.
    var sidebarGroups: [SidebarGroup] {
        let (groups, byID) = normalizedGroups()
        return groups.map { group in
            SidebarGroup(group: group, accounts: group.accountIDs.compactMap { byID[$0] }.filter { !hiddenAccounts.contains($0.id) })
        }
    }

    private func normalizedGroups() -> ([AccountGroup], [String: Account]) {
        let byID = Dictionary(allAccounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = groups
        if allAccounts.contains(where: { $0.kind == .proton }), !result.contains(where: { $0.id == AccountGroup.protonID }) {
            result.append(AccountGroup(id: AccountGroup.protonID, name: "Proton", accountIDs: []))
        }
        var seen = Set<String>()
        for index in result.indices {
            result[index].accountIDs = result[index].accountIDs.filter { byID[$0] != nil && seen.insert($0).inserted }
        }
        for account in allAccounts where !seen.contains(account.id) {
            let target = account.kind == .proton ? AccountGroup.protonID : (account.kind == .gmail ? AccountGroup.gmailID : AccountGroup.imapID)
            let index = result.firstIndex { $0.id == target } ?? 0
            result[index].accountIDs.append(account.id)
        }
        return (result, byID)
    }

    /// An empty name takes the alias away again.
    func setAlias(_ name: String, for accountID: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { accountAliases[accountID] = nil } else { accountAliases[accountID] = trimmed }
    }

    func toggleGroup(_ id: String) {
        if collapsedGroups.contains(id) { collapsedGroups.remove(id) } else { collapsedGroups.insert(id) }
    }

    /// Appends an empty group and returns its id.
    @discardableResult
    func addGroup(named name: String) -> String {
        var list = normalizedGroups().0
        let group = AccountGroup(id: "group-" + UUID().uuidString, name: name, accountIDs: [])
        list.append(group)
        groups = list
        return group.id
    }

    func removeGroupIfEmpty(_ id: String) {
        let list = normalizedGroups().0
        guard let group = list.first(where: { $0.id == id }), group.accountIDs.isEmpty, list.count > 1 else { return }
        groups = list.filter { $0.id != id }
        collapsedGroups.remove(id)
    }

    func renameGroup(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var list = normalizedGroups().0
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].name = trimmed
        groups = list
    }

    /// Puts a group where `target` is (above it when dragged up, below it when dragged down).
    func moveGroup(_ id: String, onto target: String) {
        var list = normalizedGroups().0
        guard id != target, let from = list.firstIndex(where: { $0.id == id }),
              let to = list.firstIndex(where: { $0.id == target }) else { return }
        list.insert(list.remove(at: from), at: to)
        groups = list
    }

    /// Moves an account into a group, in front of `target` or at the end when there is none.
    func moveAccount(_ accountID: String, toGroup groupID: String, onto target: String? = nil) {
        var list = normalizedGroups().0
        guard accountID != target,
              let fromGroup = list.firstIndex(where: { $0.accountIDs.contains(accountID) }),
              let toGroup = list.firstIndex(where: { $0.id == groupID }),
              let fromIndex = list[fromGroup].accountIDs.firstIndex(of: accountID) else { return }
        let targetIndex = target.flatMap { list[toGroup].accountIDs.firstIndex(of: $0) }
        list[fromGroup].accountIDs.remove(at: fromIndex)
        var insert = target.flatMap { list[toGroup].accountIDs.firstIndex(of: $0) } ?? list[toGroup].accountIDs.count
        if fromGroup == toGroup, let targetIndex, fromIndex < targetIndex { insert += 1 }
        list[toGroup].accountIDs.insert(accountID, at: insert)
        groups = list
    }

    /// Records where a freshly added account should appear.
    func place(_ accountID: String, inGroup groupID: String) {
        moveAccount(accountID, toGroup: groupID)
    }
}
