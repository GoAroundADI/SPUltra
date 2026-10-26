import SwiftUI

struct RemoteRenameView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: RemoteRenameRequest
    @State private var name: String

    init(request: RemoteRenameRequest) {
        self.request = request
        _name = State(initialValue: request.item.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("重命名远程项目", systemImage: "pencil")
                .font(.title2.bold())
            Text(request.item.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            TextField("新名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("重命名", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == request.item.name)
            }
        }
        .padding(24)
        .frame(width: 460)
        .presentationBackground(.ultraThinMaterial)
    }

    private func submit() {
        model.renameRemoteItem(request.item, to: name)
    }
}

struct RemotePermissionsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: RemotePermissionsRequest
    @State private var mode: String

    init(request: RemotePermissionsRequest) {
        self.request = request
        _mode = State(initialValue: Self.octalMode(from: request.item.permissions))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("编辑远程权限", systemImage: "lock.shield")
                .font(.title2.bold())
            Text(request.item.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Text("八进制权限")
                TextField("例如 644 或 755", text: $mode)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .onSubmit(submit)
                Text(request.item.permissions).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text("支持 3 或 4 位八进制权限；修改只作用于当前项目。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("应用", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValidMode)
            }
        }
        .padding(24)
        .frame(width: 500)
        .presentationBackground(.ultraThinMaterial)
    }

    private var isValidMode: Bool {
        (3...4).contains(mode.count) && mode.allSatisfy { ("0"..."7").contains($0) }
    }

    private func submit() {
        guard isValidMode else { return }
        model.changeRemotePermissions(request.item, mode: mode)
    }

    private static func octalMode(from permissions: String) -> String {
        let characters = Array(permissions.suffix(9))
        guard characters.count == 9 else { return "644" }
        return stride(from: 0, to: 9, by: 3).map { index in
            let value =
                (characters[index] == "r" ? 4 : 0) + (characters[index + 1] == "w" ? 2 : 0)
                + (characters[index + 2] == "-" ? 0 : 1)
            return String(value)
        }.joined()
    }
}

struct RemoteTextEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let document: RemoteTextDocument
    @State private var text: String
    @State private var isSaving = false

    init(document: RemoteTextDocument) {
        self.document = document
        _text = State(initialValue: document.text)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(document.name, systemImage: "doc.text")
                    .font(.headline)
                Text(document.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(byteCountText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.bar)
            Divider()
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .padding(8)
            Divider()
            HStack {
                Text("UTF-8 · 最大 4 MB").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.disabled(isSaving)
                Button {
                    isSaving = true
                    Task {
                        if !(await model.saveRemoteText(document, text: text)) { isSaving = false }
                    }
                } label: {
                    if isSaving {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("保存中…")
                        }
                    } else {
                        Text("保存")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(isSaving || text == document.text || text.utf8.count > 4 * 1024 * 1024)
            }
            .padding(12)
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 500, idealHeight: 650)
        .presentationBackground(.ultraThinMaterial)
    }

    private var byteCountText: String {
        ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file)
    }
}
