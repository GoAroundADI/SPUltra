import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isDonationVisible = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HSplitView {
                if model.isSessionManagerVisible { SessionSidebar().frame(minWidth: 205, idealWidth: 235, maxWidth: 310) }
                VSplitView {
                    workspace
                        .frame(minHeight: 420)
                    bottomPanel
                        .frame(minHeight: 170, idealHeight: 220, maxHeight: 340)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.isQuickConnectVisible) { QuickConnectView() }
        .sheet(item: $model.editingSession) { session in SessionEditorView(profile: session) }
        .sheet(item: $model.passwordPromptSession) { session in PasswordPromptView(session: session) }
        .sheet(item: $model.remoteRenameRequest) { request in RemoteRenameView(request: request) }
        .sheet(item: $model.remotePermissionsRequest) { request in RemotePermissionsView(request: request) }
        .sheet(item: $model.remoteTextDocument) { document in RemoteTextEditorView(document: document) }
        .sheet(isPresented: $isDonationVisible) { DonationView() }
        .alert(
            "SP Ultra",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .alert(item: $model.hostKeyConflict) { conflict in
            Alert(
                title: Text("主机身份已变化"),
                message: Text("旧指纹：\n\(conflict.previousFingerprint)\n\n新指纹：\n\(conflict.presentedFingerprint)"),
                primaryButton: .destructive(Text("信任新指纹"), action: model.trustChangedHostKey),
                secondaryButton: .cancel(Text("取消"), action: model.rejectChangedHostKey)
            )
        }
        .confirmationDialog(
            "重置全部主机指纹？",
            isPresented: $model.isHostKeyResetConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("备份并重置", role: .destructive) { model.resetHostKeyStore() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅在指纹库损坏或已确认主机更换后使用。原数据库会先备份，不会直接删除。")
        }
        .onChange(of: model.showHiddenFiles) { _, _ in model.refreshLocal() }
        #if DEBUG
            .onAppear {
                DebugCapture.scheduleIfRequested(model: model)
            }
        #endif
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                model.isSessionManagerVisible.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("显示或隐藏会话管理器")

            Button {
                model.isQuickConnectVisible = true
            } label: {
                Label("快速连接", systemImage: "bolt.horizontal.circle")
            }
            .buttonStyle(.borderedProminent)

            Button {
                isDonationVisible = true
            } label: {
                Label("捐赠", systemImage: "heart.fill")
            }
            .buttonStyle(.bordered)
            .tint(.purple)
            .help("支持 SP Ultra")

            Spacer()
            HStack(spacing: 7) {
                Circle().fill(stateColor).frame(width: 8, height: 8)
                Text(model.connectionState.label).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()

            Button {
                model.refreshLocal()
                if model.isConnected { model.refreshRemote() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }.help("刷新")
            if model.isConnected {
                Button("断开") { model.disconnect() }
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.top, 30)
        .padding(.bottom, 9)
        .background(.bar)
    }

    private var stateColor: Color {
        switch model.connectionState {
        case .disconnected: return .secondary
        case .connecting: return .orange
        case .connected: return .green
        case .failed: return .red
        }
    }

    private var workspace: some View {
        HSplitView {
            FilePane(
                title: "本地 · \(model.localHostName)",
                systemImage: "laptopcomputer",
                path: model.localPath.path,
                isLoading: model.isLoadingLocal,
                onParent: model.goLocalParent,
                onChoosePath: model.chooseLocalFolder,
                onRefresh: model.refreshLocal,
                onSubmitPath: model.navigateLocal
            ) {
                LocalFileTable()
            }
            .frame(minWidth: 390)

            FilePane(
                title: model.selectedSession?.name ?? "远程",
                systemImage: "server.rack",
                path: model.remotePath,
                isEnabled: model.isConnected,
                isLoading: model.isLoadingRemote,
                onParent: model.goRemoteParent,
                onChoosePath: model.createRemoteFolder,
                onRefresh: model.refreshRemote,
                onSubmitPath: model.navigateRemote
            ) {
                RemoteFileTable()
            }
            .frame(minWidth: 390)
        }
    }

    /// 底部区域：传输队列 + 连接日志并排，日志不再遮挡远程文件列表。
    private var bottomPanel: some View {
        HSplitView {
            TransferQueueView()
                .frame(minWidth: 420)
            if model.isConsoleVisible {
                LogConsole()
                    .frame(minWidth: 280, idealWidth: 420)
            }
        }
    }
}

struct FilePane<Content: View>: View {
    let title: String
    let systemImage: String
    let path: String
    var isEnabled = true
    var isLoading = false
    let onParent: () -> Void
    let onChoosePath: () -> Void
    var onRefresh: (() -> Void)? = nil
    let onSubmitPath: (String) -> Void
    @ViewBuilder let content: Content
    @State private var draftPath = ""
    @FocusState private var isPathFocused: Bool

    init(
        title: String, systemImage: String, path: String, isEnabled: Bool = true,
        isLoading: Bool = false,
        onParent: @escaping () -> Void, onChoosePath: @escaping () -> Void,
        onRefresh: (() -> Void)? = nil,
        onSubmitPath: @escaping (String) -> Void = { _ in },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.path = path
        self.isEnabled = isEnabled
        self.isLoading = isLoading
        self.onParent = onParent
        self.onChoosePath = onChoosePath
        self.onRefresh = onRefresh
        self.onSubmitPath = onSubmitPath
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(title, systemImage: systemImage).font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12).frame(height: 35).background(Color.accentColor.opacity(0.16))
            Divider()
            HStack(spacing: 6) {
                pathBarButton("chevron.up", help: "返回上一层", action: onParent)
                Image(systemName: "folder").foregroundStyle(.secondary)
                TextField("输入路径后回车前往", text: $draftPath)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .focused($isPathFocused)
                    .disabled(!isEnabled)
                    .onSubmit {
                        onSubmitPath(draftPath)
                        isPathFocused = false
                    }
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.85)
                        .help("正在载入目录…")
                }
                if let onRefresh {
                    pathBarButton("arrow.clockwise", help: "刷新当前目录", action: onRefresh)
                }
                pathBarButton(
                    systemImage == "laptopcomputer" ? "folder.badge.gearshape" : "folder.badge.plus",
                    help: systemImage == "laptopcomputer" ? "选择本地文件夹" : "新建远程文件夹",
                    action: onChoosePath
                )
            }
            .padding(.horizontal, 10).frame(height: 38).background(Color(nsColor: .controlBackgroundColor))
            Divider()
            content.opacity(isEnabled ? 1 : 0.45).allowsHitTesting(isEnabled)
        }
        .onAppear { draftPath = path }
        .onChange(of: path) { _, newValue in
            if !isPathFocused { draftPath = newValue }
        }
    }

    /// 路径栏按钮：扩大点击热区，避免图标太小难点中。
    private func pathBarButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
        .help(help)
    }
}

struct LocalFileTable: View {
    @EnvironmentObject private var model: AppModel
    @State private var isDropTargeted = false
    @State private var pendingDeletion: [FileItem]?

    var body: some View {
        Table(model.localItems, selection: $model.localSelection) {
            TableColumn("名称") { item in
                // 拖拽热区只覆盖图标和文件名，名称列空白处交给 Table 原生行选中，
                // 否则在空白处按下会被 SwiftUI 命中但不会选中整行。
                HStack(spacing: 0) {
                    Label(item.name, systemImage: item.isSymbolicLink ? "link" : (item.isDirectory ? "folder.fill" : "doc.fill"))
                        .foregroundStyle(item.isDirectory ? Color.accentColor : .primary)
                        .contentShape(Rectangle())
                        .draggable(item.url)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }.width(min: 140, ideal: 300)
            TableColumn("大小") { item in
                Text(item.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
            }
            .width(min: 60, ideal: 90, max: 120)
            TableColumn("修改日期") { item in Text(item.modifiedAt?.formatted(date: .numeric, time: .shortened) ?? "—") }
                .width(min: 95, ideal: 145)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty {
                Button("上传") { model.uploadSelection() }.disabled(!model.isConnected)
                Button("删除", role: .destructive) {
                    pendingDeletion = model.localItems.filter { ids.contains($0.id) }
                }
                Divider()
            }
            Button("新建文件") { model.createLocalFile() }
            Button("新建文件夹") { model.createLocalFolder() }
            if !ids.isEmpty {
                Divider()
                Button("在 Finder 中显示") {
                    if let id = model.localSelection.first { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: id)]) }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let item = model.localItems.first(where: { $0.id == id }) { model.openLocal(item) }
        }
        .alert(
            "移到废纸篓",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            )
        ) {
            Button("移到废纸篓", role: .destructive) {
                if let items = pendingDeletion { model.deleteLocalItems(items) }
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: {
            let items = pendingDeletion ?? []
            Text("确定要把 \(items.count) 个项目移到废纸篓吗？\n\(items.prefix(5).map(\.name).joined(separator: "、"))\(items.count > 5 ? " 等" : "")")
        }
        // 从远程面板拖入 = 下载到当前本地目录
        .onDrop(of: [.spUltraRemoteItem], isTargeted: $isDropTargeted) { providers in
            loadRemoteDragItems(providers) { items in model.downloadRemoteDragItems(items) }
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .allowsHitTesting(false)
            }
        }
    }

    private func loadRemoteDragItems(_ providers: [NSItemProvider], completion: @escaping @MainActor ([RemoteDragItem]) -> Void) {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.spUltraRemoteItem.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.spUltraRemoteItem.identifier) { data, _ in
                guard let data, let item = try? JSONDecoder().decode(RemoteDragItem.self, from: data) else { return }
                Task { @MainActor in completion([item]) }
            }
        }
    }
}

struct RemoteFileTable: View {
    @EnvironmentObject private var model: AppModel
    @State private var isDropTargeted = false
    @State private var pendingDeletion: [RemoteItem]?

    var body: some View {
        Table(model.remoteItems, selection: $model.remoteSelection) {
            TableColumn("名称") { item in
                // 名称列空白处保持 Table 原生行选中；拖拽从图标/文件名开始即可。
                HStack(spacing: 0) {
                    Label(item.name, systemImage: item.isDirectory ? "folder.fill" : (item.isSymbolicLink ? "link" : "doc.fill"))
                        .foregroundStyle(item.isDirectory ? Color.accentColor : .primary)
                        .contentShape(Rectangle())
                        .draggable(RemoteDragItem(item: item))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }.width(min: 130, ideal: 280)
            TableColumn("大小") { item in
                Text(item.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
            }
            .width(min: 60, ideal: 90, max: 120)
            TableColumn("权限") { item in Text(item.permissions).font(.system(.caption, design: .monospaced)) }
                .width(min: 70, ideal: 100)
            TableColumn("修改日期") { item in Text(item.modifiedText) }.width(min: 95, ideal: 140)
        }
        .overlay {
            if !model.isConnected {
                ContentUnavailableView("尚未连接", systemImage: "network.slash", description: Text("点击“快速连接”连接 SFTP 或 SCP 主机"))
            } else if model.isLoadingRemote && model.remoteItems.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("正在载入目录…").font(.callout).foregroundStyle(.secondary)
                }
            } else if model.remoteItems.isEmpty {
                ContentUnavailableView("此文件夹为空", systemImage: "folder")
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty {
                Button("下载") { model.downloadSelection() }
                if ids.count == 1, let item = model.remoteItems.first(where: { ids.contains($0.id) }) {
                    Divider()
                    Button("重命名…") { model.requestRemoteRename(item) }
                    Button("编辑权限…") { model.requestRemotePermissions(item) }
                    if !item.isDirectory {
                        Button(model.loadingEditorPath == item.path ? "正在打开…" : "在线编辑…") {
                            model.openRemoteTextEditor(item)
                        }
                        .disabled(model.loadingEditorPath != nil || item.size > 4 * 1024 * 1024)
                    }
                }
                Divider()
                Button("删除", role: .destructive) {
                    pendingDeletion = model.remoteItems.filter { ids.contains($0.id) }
                }
                Divider()
            }
            Button("新建文件") { model.createRemoteFile() }.disabled(!model.isConnected)
            Button("新建文件夹") { model.createRemoteFolder() }.disabled(!model.isConnected)
        } primaryAction: { ids in
            if let id = ids.first, let item = model.remoteItems.first(where: { $0.id == id }) { model.openRemote(item) }
        }
        .alert(
            "删除远程项目",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            )
        ) {
            Button("删除", role: .destructive) {
                if let items = pendingDeletion { model.deleteRemoteItems(items) }
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: {
            let items = pendingDeletion ?? []
            Text(
                "确定要删除 \(items.count) 个项目吗？\n\(items.prefix(5).map(\.name).joined(separator: "、"))\(items.count > 5 ? " 等" : "")\n此操作不可撤销。")
        }
        // 从本地面板或 Finder 拖入 = 上传到当前远程目录
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            loadDroppedFileURLs(providers) { urls in model.uploadLocalURLs(urls) }
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .allowsHitTesting(false)
            }
        }
    }

    private func loadDroppedFileURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in completion([url]) }
            }
        }
    }
}
