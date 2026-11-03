import SwiftUI
#if canImport(PigiCore)
import PigiCore
#endif

struct AddProtonSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var mailboxPassword = ""
    @State private var otp = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var prompt = ProtonLoginPrompt()
    @State private var loginTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加 / 重新登录 Proton").font(.title2)
            Text("只读同步，不改变已读状态。登录后会话保存在本机钥匙串；解密正文保存在本机邮件库。")
                .font(.callout).foregroundStyle(.secondary)
            if let challenge = prompt.pending {
                if let error = challenge.failure { Text(error.localizedDescription).foregroundStyle(.red) }
                switch challenge.stage {
                case "captcha":
                    Text("请在官方 Proton 验证页面完成人机验证。")
                    if let raw = challenge.webURL, let token = challenge.challenge,
                       let url = ProtonVerificationPolicy.url(raw, challenge: token) {
                        ProtonVerificationView(url: url, challenge: token) { result in
                            prompt.finish(result.mapError { $0 as Error })
                        }.id(token).frame(width: 500, height: 430)
                    }
                case "totp":
                    Text("输入验证器中当前的 6 位验证码")
                    SecureField("两步验证码", text: $prompt.answer)
                case "mailbox":
                    Text("输入独立邮箱密码以解锁邮箱")
                    SecureField("独立邮箱密码", text: $prompt.answer)
                default: EmptyView()
                }
            } else {
                Form {
                    TextField("用户名或邮箱", text: $username).textContentType(.username)
                    SecureField("登录密码", text: $password)
                    SecureField("独立邮箱密码（如有）", text: $mailboxPassword)
                    SecureField("两步验证码（如有）", text: $otp)
                }.textFieldStyle(.roundedBorder).disabled(busy)
            }
            if let failure { Text(failure).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消", role: .cancel) {
                    prompt.cancel(); loginTask?.cancel(); clearSecrets(); dismiss()
                }.disabled(busy && prompt.pending == nil)
                if let pending = prompt.pending {
                    if pending.stage != "captcha" {
                        Button("继续") { prompt.submit() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(prompt.answer.isEmpty)
                    }
                } else {
                    Button {
                        busy = true; failure = nil
                        loginTask = Task { await add() }
                    } label: {
                        if busy { ProgressView().controlSize(.small) } else { Text("登录") }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                }
            }
        }
        .padding(28)
        .frame(width: prompt.pending?.stage == "captcha" ? 556 : 460)
        .interactiveDismissDisabled(busy)
        .onDisappear { prompt.cancel(); loginTask?.cancel(); clearSecrets() }
    }
    private func clearSecrets() { password = ""; mailboxPassword = ""; otp = "" }
    @MainActor private func add() async {
        defer { busy = false; clearSecrets() }
        do {
            try await state.addProtonAccount(username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                                             password: password, mailboxPassword: mailboxPassword, otp: otp,
                                             interaction: { challenge in try await prompt.request(challenge) })
            dismiss()
        } catch is CancellationError {
            // User closed the flow; the core revokes the provisional session.
        } catch {
            failure = (error as? ProtonHelperError)?.localizedDescription ?? "Proton 登录未完成，请检查账号或钥匙串权限后重试"
        }
    }
}
