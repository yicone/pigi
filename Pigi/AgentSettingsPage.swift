import SwiftUI
#if canImport(PigiCore)
import PigiCore
#endif

struct AgentSettingsPage: View {
    let engine: LocalEngine

    init(engine: LocalEngine = .shared) { self.engine = engine }
    @State private var accounts: [AgentAccountAccess] = []
    @State private var actions: [AgentAction] = []
    @State private var failure: String?
    @State private var saving = false
    @State private var offset = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Agent 权限与审计", note: "按邮箱限制本地服务与 MCP。发送邮件始终关闭。")
                Text("默认允许读取与起草，整理默认关闭。起草和整理权限仅预留；当前服务只提供读取方法。Agent 无法删除邮箱、访问凭据或修改 OAuth client。")
                    .font(.caption).foregroundStyle(.secondary)
                if accounts.isEmpty { Text("暂无邮箱").foregroundStyle(.secondary).accessibilityIdentifier("agent.emptyAccounts") }
                ForEach(accounts) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.account).font(.headline).textSelection(.enabled)
                        HStack {
                            permissionToggle("读取", .read, item)
                            permissionToggle("起草", .draft, item)
                            permissionToggle("整理", .organize, item)
                        }
                        .disabled(saving)
                    }
                }
                Divider()
                HStack {
                    Text("动作审计").font(.headline)
                    Spacer()
                    Button("刷新") { Task { await reload() } }.accessibilityIdentifier("agent.refresh")
                }
                Text("账号、目标与参数均为本机密钥摘要，不保存邮件内容、凭据、原始参数或错误详情。MCP 的工具调用日志仍单独记录传输结果。")
                    .font(.caption).foregroundStyle(.secondary)
                if let failure { Text(failure).foregroundStyle(.red).font(.caption).accessibilityIdentifier("agent.failure") }
                if actions.isEmpty { Text("暂无记录").foregroundStyle(.secondary).accessibilityIdentifier("agent.emptyAudit") }
                ForEach(actions) { action in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(Date(timeIntervalSince1970: Double(action.ts) / 1000), style: .date)
                            Text(Date(timeIntervalSince1970: Double(action.ts) / 1000), style: .time)
                            Text(action.tool).monospaced()
                            Spacer()
                            Text(action.result).monospaced().accessibilityIdentifier("agent.audit.result.\(action.id)")
                        }
                        Text("账号：\(action.account ?? "全部 / 无")\n目标：\(action.target ?? "无")\n参数：\(action.argsHash)")
                            .font(.caption2).monospaced().foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Divider()
                    }
                    .font(.caption)
                }
                HStack {
                    Button("上一页") { offset = max(0, offset - 100); Task { await reload() } }
                        .disabled(offset == 0).accessibilityIdentifier("agent.previous")
                    Text("第 \(offset / 100 + 1) 页").font(.caption).accessibilityIdentifier("agent.page")
                    Button("下一页") { offset += 100; Task { await reload() } }
                        .disabled(actions.count < 100).accessibilityIdentifier("agent.next")
                }
            }
            .padding(32)
        }
        .task { await reload() }
    }

    private func permissionToggle(_ title: String, _ capability: AgentCapability, _ item: AgentAccountAccess) -> some View {
        Toggle(title, isOn: Binding(get: { item.permissions[capability] }, set: { value in
            saving = true
            var permissions = item.permissions
            permissions[capability] = value
            Task {
                do {
                    try await engine.setAgentPermissions(account: item.account, permissions: permissions)
                    await reload()
                } catch { failure = "权限保存失败，请重试。" }
                saving = false
            }
        })).accessibilityIdentifier("agent.\(capability.rawValue).\(item.account)")
    }

    private func reload() async {
        do {
            accounts = try await engine.agentAccountAccess()
            actions = try await engine.agentActions(offset: offset)
            failure = nil
        } catch { failure = "权限或审计加载失败，请重试。" }
    }
}
