import SwiftUI

struct AddProtonSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var mailboxPassword = ""
    @State private var otp = ""
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加 / 重新登录 Proton").font(.title2)
            Text("只读同步，不改变已读状态。登录后会话保存在本机钥匙串；解密正文保存在本机邮件库。")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("用户名或邮箱", text: $username)
                    .textContentType(.username)
                SecureField("登录密码", text: $password)
                SecureField("独立邮箱密码（如有）", text: $mailboxPassword)
                SecureField("两步验证码（如有）", text: $otp)
            }
            .textFieldStyle(.roundedBorder)
            if let failure { Text(failure).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { clearSecrets(); dismiss() }.disabled(busy)
                Button {
                    busy = true
                    Task { await add() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("登录") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
            }
        }
        .padding(28)
        .frame(width: 460)
        .interactiveDismissDisabled(busy)
        .onDisappear { clearSecrets() }
    }
    private func clearSecrets() { password = ""; mailboxPassword = ""; otp = "" }
    @MainActor private func add() async {
        defer { busy = false; clearSecrets() }
        do {
            try await state.addProtonAccount(username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                                             password: password, mailboxPassword: mailboxPassword, otp: otp)
            dismiss()
        } catch {
            failure = (error as? ProtonHelperError)?.localizedDescription ?? "Proton 登录未完成，请检查账号或钥匙串权限后重试"
        }
    }
}
