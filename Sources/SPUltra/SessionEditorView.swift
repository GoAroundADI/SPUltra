import SwiftUI

/// 会话属性窗口：编辑已保存连接的完整配置（含密码、私钥、初始目录和旧版兼容）。
struct SessionEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private let original: SessionProfile
    @State private var profile: SessionProfile
    @State private var password = ""
    @State private var savePassword = false
    @State private var hasStoredPassword = false
    @State private var errorMessage: String?

    init(profile: SessionProfile) {
        original = profile
        _profile = State(initialValue: profile)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("会话属性", systemImage: "slider.horizontal.3").font(.title2.bold())
                    Text("\(original.protocolKind.rawValue) · \(original.username)@\(original.host):\(original.port)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(20).background(.bar)

            SessionForm(
                profile: $profile,
                password: $password,
                savePassword: $savePassword,
                passwordPrompt: hasStoredPassword ? "已保存到钥匙串；留空保持不变" : "密码（使用私钥认证时可留空）",
                hasStoredPassword: hasStoredPassword,
                showsSaveSession: false
            )

            Divider()
            HStack {
                Text(hint)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        profile.host.trimmingCharacters(in: .whitespaces).isEmpty
                            || profile.username.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding(16)
        }
        .frame(width: 620, height: 720)
        .onAppear {
            // 不主动访问钥匙串：仅打开属性窗口不应该触发系统授权弹窗。
            // 未知时按“已保存”处理，留空保存就不会误删密码。
            hasStoredPassword = model.passwordPresence(for: original) ?? true
            savePassword = hasStoredPassword
        }
        .alert(
            "无法保存会话",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var hint: String {
        if model.connectedSessionID == original.id {
            return "当前连接仍使用原有配置，断开并重新连接后生效。"
        }
        if hasStoredPassword {
            return savePassword
                ? "钥匙串中已有密码；留空将保持不变。"
                : "保存后将从钥匙串中移除已保存的密码。"
        }
        return password.isEmpty
            ? "密码留空时，连接需要另外提供密码或私钥。"
            : "输入的新密码会按“将密码安全保存到钥匙串”开关决定是否保存。"
    }

    private func save() {
        do {
            let validated = try profile.validated()
            try model.updateSession(
                validated,
                newPassword: password,
                savePassword: savePassword,
                hadStoredPassword: hasStoredPassword
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
