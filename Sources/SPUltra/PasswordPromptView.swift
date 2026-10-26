import SwiftUI

/// 会话没有可用钥匙串凭据时，在应用内询问 SSH 密码或私钥口令。
struct PasswordPromptView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let session: SessionProfile
    @State private var password = ""
    @State private var savePassword = true
    @State private var isSubmitting = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(isPrivateKey ? "输入私钥口令" : "输入 SSH 密码", systemImage: "key.fill").font(.title3.bold())
                Spacer()
                Button(action: cancel) {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text("\(session.username)@\(session.host):\(session.port) · \(session.protocolKind.rawValue)")
                .font(.callout).foregroundStyle(.secondary)

            Text(isPrivateKey ? "此私钥已加密，且钥匙串中没有可用口令。" : "没有找到这个会话在钥匙串中的密码，请输入后连接。")
                .font(.caption).foregroundStyle(.secondary)

            SecureField(isPrivateKey ? "私钥口令" : "SSH 密码", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(submit)

            Toggle(isPrivateKey ? "将私钥口令安全保存到钥匙串" : "将密码安全保存到钥匙串", isOn: $savePassword)

            HStack {
                Spacer()
                Button("取消") { cancel() }.keyboardShortcut(.cancelAction)
                Button("连接") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty || isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { isFocused = true }
    }

    private var isPrivateKey: Bool {
        session.authentication == .publicKey || !session.privateKeyPath.isEmpty
    }

    private func submit() {
        guard !password.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        let entered = password
        let save = savePassword
        password = ""
        model.passwordPromptSession = nil
        dismiss()
        model.connect(profile: session, password: entered, savePassword: save)
    }

    private func cancel() {
        model.passwordPromptSession = nil
        dismiss()
    }
}
