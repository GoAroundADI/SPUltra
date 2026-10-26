import AppKit
import SwiftUI

/// 快速连接与会话属性共用的表单，避免两处连接配置的字段和校验出现偏差。
struct SessionForm: View {
    @Binding var profile: SessionProfile
    @Binding var password: String
    @Binding var savePassword: Bool

    var passwordPrompt = "密码（使用私钥认证时可留空）"
    var hasStoredPassword = false
    var showsSaveSession = true
    @State private var favoritePaths = RemotePathFavorites.load()
    @State private var isAddingRemotePath = false
    @State private var newRemotePath = ""

    var body: some View {
        Form {
            Section {
                Picker("协议", selection: $profile.protocolKind) {
                    ForEach(TransferProtocol.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                TextField("会话名称", text: $profile.name)
                TextField("主机名 / IP", text: $profile.host)
                HStack {
                    TextField("用户名", text: $profile.username)
                    TextField("端口", value: $profile.port, format: .number).frame(width: 130)
                }
            } header: {
                Text("连接")
            }

            Section {
                Picker("认证方式", selection: $profile.authentication) {
                    ForEach(AuthenticationMethod.allCases) { Text($0.rawValue).tag($0) }
                }
                SecureField(
                    profile.authentication == .publicKey ? "私钥口令（未加密私钥可留空）" : passwordPrompt,
                    text: $password)
                Toggle(profile.authentication == .publicKey ? "将私钥口令安全保存到钥匙串" : "将密码安全保存到钥匙串", isOn: $savePassword)
                    .disabled((password.isEmpty && !hasStoredPassword) || (showsSaveSession && !profile.saveSession))
                    .help(showsSaveSession && !profile.saveSession ? "未勾选“保存此会话”时无法单独保存口令" : "口令仅保存在 macOS 钥匙串中")
                if profile.authentication == .publicKey || profile.authentication == .automatic {
                    HStack {
                        TextField("私钥路径（可选）", text: $profile.privateKeyPath)
                        Button("选择…", action: choosePrivateKey)
                    }
                }
            } header: {
                Text("认证")
            }

            Section {
                LabeledContent("初始远程目录") {
                    HStack(spacing: 8) {
                        RemotePathComboBox(path: $profile.initialRemotePath, paths: favoritePaths)
                            .frame(minWidth: 190, idealWidth: 240)
                            .help("输入路径，或从自己保存的路径列表选择")
                        Button("添加", systemImage: "plus") {
                            newRemotePath = profile.initialRemotePath
                            isAddingRemotePath = true
                        }
                        .help("把远程路径添加到列表")
                        Button("移除", systemImage: "minus") { removeCurrentPath() }
                            .labelStyle(.iconOnly)
                            .help("从列表移除当前路径")
                            .disabled(profile.initialRemotePath == "/" || !favoritePaths.contains(profile.initialRemotePath))
                    }
                }
                if showsSaveSession {
                    Toggle("保存此会话", isOn: $profile.saveSession)
                }
            } header: {
                Text("选项")
            } footer: {
                Text("默认列表只有 /。输入常用路径后点“添加”，以后可直接从列表选择；SFTP 可使用 . 表示登录目录。")
            }
        }
        .formStyle(.grouped)
        .alert("添加远程路径", isPresented: $isAddingRemotePath) {
            TextField("例如 /var/mobile", text: $newRemotePath)
            Button("取消", role: .cancel) {}
            Button("添加") { addRemotePath() }
                .disabled((try? RemotePathFavorites.validated(newRemotePath)) == nil)
        } message: {
            Text("路径将保存到 SP Ultra 的初始目录列表。")
        }
    }

    private func choosePrivateKey() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK { profile.privateKeyPath = panel.url?.path ?? "" }
    }

    private func addRemotePath() {
        guard let path = try? RemotePathFavorites.validated(newRemotePath) else { return }
        favoritePaths = RemotePathFavorites.load() + [path]
        RemotePathFavorites.save(favoritePaths)
        favoritePaths = RemotePathFavorites.load()
        profile.initialRemotePath = path
    }

    private func removeCurrentPath() {
        guard profile.initialRemotePath != "/" else { return }
        favoritePaths.removeAll { $0 == profile.initialRemotePath }
        RemotePathFavorites.save(favoritePaths)
        profile.initialRemotePath = "/"
    }
}

/// 可输入、可下拉选择常用目录的组合框。SwiftUI 的 TextField 在 macOS 表单里会右对齐文本，
/// 这里用 NSComboBox 保证路径左对齐，并加载用户自己保存的列表。
struct RemotePathComboBox: NSViewRepresentable {
    @Binding var path: String
    let paths: [String]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSComboBox {
        let combo = NSComboBox()
        combo.isEditable = true
        combo.completes = false
        combo.usesDataSource = false
        combo.numberOfVisibleItems = 8
        combo.addItems(withObjectValues: paths)
        combo.placeholderString = "/"
        combo.alignment = .left
        combo.controlSize = .regular
        combo.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        combo.delegate = context.coordinator
        combo.target = context.coordinator
        combo.action = #selector(Coordinator.commit(_:))
        combo.setContentHuggingPriority(.defaultLow, for: .horizontal)
        combo.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return combo
    }

    func updateNSView(_ combo: NSComboBox, context: Context) {
        context.coordinator.parent = self
        // 用户添加或移除路径后同步刷新组合框内容。
        let currentItems = (0..<combo.numberOfItems).compactMap { combo.itemObjectValue(at: $0) as? String }
        if currentItems != paths {
            combo.removeAllItems()
            combo.addItems(withObjectValues: paths)
        }
        if combo.stringValue != path { combo.stringValue = path }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: RemotePathComboBox

        init(_ parent: RemotePathComboBox) { self.parent = parent }

        @objc func commit(_ sender: NSComboBox) { parent.path = sender.stringValue }

        func controlTextDidChange(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox else { return }
            parent.path = combo.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox else { return }
            parent.path = combo.stringValue
        }
    }
}
