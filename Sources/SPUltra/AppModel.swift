import AppKit
import Foundation
import SwiftUI

/// 本地目录后台枚举结果，避免把 Error 跨线程传递。
enum LocalListingOutcome: Sendable {
    case success([FileItem])
    case failure(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var sessions: [SessionProfile] = []
    @Published var selectedSessionID: UUID?
    @Published var connectedSessionID: UUID?
    @Published var editingSession: SessionProfile?
    @Published var connectionState: ConnectionState = .disconnected
    @Published var localPath: URL
    @Published var localItems: [FileItem] = []
    @Published var localSelection: Set<String> = []
    @Published var remotePath = "."
    @Published var remoteItems: [RemoteItem] = []
    @Published var remoteSelection: Set<String> = []
    @Published var jobs: [TransferJob] = []
    @Published var logs: [LogEntry] = []
    @Published var showHiddenFiles = false
    @Published var isSessionManagerVisible = true
    @Published var isConsoleVisible = true
    @Published var isQuickConnectVisible = false
    @Published var passwordPromptSession: SessionProfile?
    @Published var isLoadingLocal = false
    @Published var isLoadingRemote = false
    @Published var alertMessage: String?
    @Published var hostKeyConflict: HostKeyConflict?
    @Published var remoteRenameRequest: RemoteRenameRequest?
    @Published var remotePermissionsRequest: RemotePermissionsRequest?
    @Published var remoteTextDocument: RemoteTextDocument?
    @Published var loadingEditorPath: String?
    @Published var isHostKeyResetConfirmationPresented = false

    /// 本机名称只解析一次：Host.current() 可能触发反向解析，放在视图 body 里会拖慢每次点击。
    let localHostName: String = Host.current().localizedName ?? "Mac"

    private let remoteService: RemoteFileService
    private let sessionStore: SessionStore
    private let credentialStore: CredentialStoring
    private var activeConfiguration: SSHConfiguration?
    private var connectionTask: Task<Void, Never>?
    private var connectionAttemptID: UUID?
    private var queueTask: Task<Void, Never>?
    private var pendingConnection: (profile: SessionProfile, password: String, savePassword: Bool)?
    private var localRequestSerial = 0
    private var remoteRequestSerial = 0

    /// 从钥匙串读取成功后缓存在内存：同一次启动内断开重连不再反复触发系统钥匙串授权弹窗。
    private var passwordCache: [UUID: String] = [:]
    /// 已知是否存在钥匙串密码；nil 表示未知。未知时不去访问钥匙串，避免仅打开属性窗口就弹授权。
    private var knownPasswordPresence: [UUID: Bool] = [:]

    /// 已浏览过的远程目录，切回时先即时显示旧内容，再在后台刷新，避免每次双击都等待网络。
    private var remoteListingCache: [String: [RemoteItem]] = [:]

    init(
        sessionStore: SessionStore = SessionStore(),
        credentialStore: CredentialStoring = CredentialStore(),
        remoteService: RemoteFileService = RemoteFileService(),
        localPath: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.sessionStore = sessionStore
        self.credentialStore = credentialStore
        self.remoteService = remoteService
        self.localPath = localPath
        sessions = sessionStore.load()
        refreshLocal()
        appendLog("SP Ultra 已就绪。使用应用内 SwiftNIO SSH；主机指纹与系统 known_hosts 完全隔离。")
    }

    var selectedSession: SessionProfile? {
        sessions.first { $0.id == selectedSessionID }
    }

    var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    var isConnecting: Bool {
        if case .connecting = connectionState { return true }
        return false
    }

    /// 只使用内存中已经知道的状态；nil 表示尚未读取过，属性窗口按“已保存”处理以免误删。
    func passwordPresence(for session: SessionProfile) -> Bool? {
        if passwordCache[session.id] != nil { return true }
        return knownPasswordPresence[session.id]
    }

    /// 读取一次密码后缓存；系统钥匙串授权弹窗只应在每个 App 启动周期出现一次。
    private func storedPassword(for id: UUID) -> String? {
        if let cached = passwordCache[id] { return cached }
        guard let password = credentialStore.password(for: id) else {
            knownPasswordPresence[id] = false
            return nil
        }
        passwordCache[id] = password
        knownPasswordPresence[id] = true
        return password
    }

    func editSession(_ session: SessionProfile) {
        editingSession = session
    }

    /// 本地目录枚举移到后台线程；大目录（下载、项目目录）不再阻塞主线程。
    func refreshLocal() {
        localRequestSerial &+= 1
        let serial = localRequestSerial
        let path = localPath
        let showHidden = showHiddenFiles
        isLoadingLocal = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> LocalListingOutcome in
                do { return .success(try LocalFileService().contents(of: path, showHidden: showHidden)) } catch {
                    return .failure(error.localizedDescription)
                }
            }.value
            guard serial == self.localRequestSerial else { return }
            self.isLoadingLocal = false
            switch outcome {
            case .success(let items): self.localItems = items
            case .failure(let message): self.present(AppFailure.commandFailed(message))
            }
        }
    }

    func openLocal(_ item: FileItem) {
        guard item.isDirectory else { return }
        localPath = item.url.standardizedFileURL
        localSelection.removeAll()
        refreshLocal()
    }

    func goLocalParent() {
        let parent = localPath.deletingLastPathComponent()
        guard parent.path != localPath.path else { return }
        localPath = parent
        localSelection.removeAll()
        refreshLocal()
    }

    /// 路径栏回车跳转：仅在目标确实是本地文件夹时切换，否则提示并还原显示。
    func navigateLocal(to path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != localPath.path else { return }
        var isDirectory: ObjCBool = false
        let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            present(AppFailure.validation("本地路径不存在或不是文件夹：\(trimmed)"))
            return
        }
        localPath = url
        localSelection.removeAll()
        refreshLocal()
    }

    /// 路径栏回车跳转远程目录；失败时恢复原路径并提示。
    func navigateRemote(to path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard isConnected, !trimmed.isEmpty, trimmed != remotePath else { return }
        let previous = remotePath
        remotePath = trimmed
        remoteSelection.removeAll()
        showCachedRemoteListing(for: trimmed)
        Task {
            do { try await refreshRemoteThrowing() } catch {
                remotePath = previous
                showCachedRemoteListing(for: previous)
                do {
                    try await refreshRemoteThrowing()
                } catch {
                    // 保持现状
                }
                present(AppFailure.validation("无法打开远程目录：\(trimmed)（\(error.localizedDescription)）"))
            }
        }
    }

    /// 已浏览过的目录先用缓存立即渲染，随后 refreshRemoteThrowing 在后台更新。
    private func showCachedRemoteListing(for path: String) {
        if let cached = remoteListingCache[path] {
            remoteItems = cached
        } else {
            // 首次进入的目录没有缓存，先清空旧列表，让加载指示出现而不是显示上一个目录的内容。
            remoteItems = []
        }
    }

    func connect(profile: SessionProfile, password: String, savePassword: Bool) {
        // SecureField 的 onSubmit 与默认按钮在同一个回车事件中都可能触发。
        // 同一份连接请求已经排队时直接忽略，避免重复握手和重复钥匙串授权。
        if connectionAttemptID != nil, let pendingConnection,
            pendingConnection.profile == profile,
            pendingConnection.password == password,
            pendingConnection.savePassword == savePassword
        {
            return
        }
        connectionTask?.cancel()
        hostKeyConflict = nil
        remoteService.cancelAll()
        connectedSessionID = nil
        remoteRequestSerial &+= 1
        remoteListingCache.removeAll()
        remoteItems = []
        remoteSelection.removeAll()
        isLoadingRemote = false
        let attemptID = UUID()
        connectionAttemptID = attemptID
        pendingConnection = (profile, password, savePassword)
        connectionTask = Task {
            defer {
                if connectionAttemptID == attemptID {
                    connectionTask = nil
                    connectionAttemptID = nil
                }
            }
            do {
                var valid = try profile.validated()
                // 同一主机/端口/用户名/协议的会话复用同一个 id，避免快速连接或 iOS 窗口
                // 反复生成新会话后找不到原来保存在钥匙串里的密码。
                if let existing = reusableSession(for: valid), existing.id != valid.id {
                    let incomingName = valid.name
                    valid.id = existing.id
                    if incomingName == valid.host || incomingName == "新建会话" || incomingName.isEmpty {
                        valid.name = existing.name
                    }
                }
                connectionState = .connecting
                appendLog("正在连接 \(valid.destination):\(valid.port)…")
                let secret: String?
                if password.isEmpty {
                    appendLog("正在从钥匙串读取已保存的密码…（若弹出系统授权框，请输入 Mac 登录密码并选择“始终允许”）")
                    secret = storedPassword(for: valid.id)
                } else {
                    secret = password
                }
                let configuration = SSHConfiguration(profile: valid, password: secret)
                try await remoteService.test(configuration, log: makeLogSink())
                activeConfiguration = configuration
                remotePath = valid.initialRemotePath.isEmpty ? "." : valid.initialRemotePath
                try await refreshRemoteThrowing()
                connectionState = .connected(valid.host)
                connectedSessionID = valid.id
                selectedSessionID = valid.id
                if !password.isEmpty { passwordCache[valid.id] = password }
                if valid.saveSession {
                    if let index = sessions.firstIndex(where: { $0.id == valid.id }) {
                        sessions[index] = valid
                    } else {
                        sessions.append(valid)
                    }
                    do {
                        try sessionStore.save(sessions)
                    } catch {
                        appendLog("会话保存失败：\(error.localizedDescription)", level: .warning)
                    }
                    if savePassword, !password.isEmpty {
                        do {
                            try credentialStore.save(password: password, for: valid.id)
                            passwordCache[valid.id] = password
                            knownPasswordPresence[valid.id] = true
                        } catch {
                            appendLog("密码保存到钥匙串失败：\(error.localizedDescription)", level: .warning)
                        }
                    }
                }
                appendLog("连接成功：\(valid.host)")
                pendingConnection = nil
                isQuickConnectVisible = false
            } catch {
                if connectionAttemptID != attemptID { return }
                if Task.isCancelled {
                    activeConfiguration = nil
                    remoteService.cancelAll()
                    pendingConnection = nil
                    remoteItems = []
                    remoteListingCache.removeAll()
                    isLoadingRemote = false
                    connectedSessionID = nil
                    connectionState = .disconnected
                    return
                }
                activeConfiguration = nil
                connectedSessionID = nil
                connectionState = .failed(error.localizedDescription)
                if let conflict = error as? HostKeyConflict {
                    remoteService.cancelAll()
                    hostKeyConflict = conflict
                    appendLog(conflict.localizedDescription, level: .warning)
                } else {
                    remoteService.cancelAll()
                    pendingConnection = nil
                    present(error)
                }
            }
        }
    }

    /// 只有双方都是密码认证（未配置私钥）时才复用会话，避免覆盖私钥会话。
    private func reusableSession(for profile: SessionProfile) -> SessionProfile? {
        guard profile.privateKeyPath.isEmpty, profile.authentication != .publicKey else { return nil }
        // 已经存在的会话（例如从会话列表连接）保持自己的 id，避免误用同名重复会话的密码。
        if sessions.contains(where: { $0.id == profile.id }) { return nil }
        return sessions.first {
            $0.privateKeyPath.isEmpty
                && $0.authentication != .publicKey
                && $0.host.caseInsensitiveCompare(profile.host) == .orderedSame
                && $0.port == profile.port
                && $0.username == profile.username
                && $0.protocolKind == profile.protocolKind
        }
    }

    func connectSaved(_ session: SessionProfile) {
        guard passwordPromptSession?.id != session.id else { return }
        if session.authentication == .publicKey || !session.privateKeyPath.isEmpty {
            do {
                if try PrivateKeyInspector.requiresPassphrase(atPath: session.privateKeyPath) {
                    appendLog("私钥已加密，正在查找已保存的私钥口令…")
                    if let passphrase = storedPassword(for: session.id), !passphrase.isEmpty {
                        connect(profile: session, password: passphrase, savePassword: false)
                    } else {
                        appendLog("会话“\(session.name)”需要私钥口令，等待输入。", level: .warning)
                        passwordPromptSession = session
                    }
                } else {
                    // 未加密私钥无需读取钥匙串，避免不必要的系统授权弹窗。
                    connect(profile: session, password: "", savePassword: false)
                }
            } catch {
                present(error)
            }
            return
        }

        appendLog("正在从钥匙串读取已保存的密码…（若弹出系统授权框，请输入 Mac 登录密码并选择“始终允许”）")
        if let saved = storedPassword(for: session.id), !saved.isEmpty {
            connect(profile: session, password: saved, savePassword: false)
            return
        }

        // 钥匙串里没有可用密码，不要直接报错，弹出输入窗口让用户补密码。
        appendLog("会话“\(session.name)”没有可用的钥匙串密码，等待输入。", level: .warning)
        passwordPromptSession = session
    }

    func trustChangedHostKey() {
        guard let conflict = hostKeyConflict, let pendingConnection else { return }
        do {
            try remoteService.trustReplacement(conflict)
            hostKeyConflict = nil
            appendLog("已由用户确认并更新 \(conflict.endpoint) 的主机指纹。", level: .warning)
            connect(profile: pendingConnection.profile, password: pendingConnection.password, savePassword: pendingConnection.savePassword)
        } catch { present(error) }
    }

    func rejectChangedHostKey() {
        remoteService.cancelAll()
        hostKeyConflict = nil
        pendingConnection = nil
        connectionState = .disconnected
    }

    func resetHostKeyStore() {
        disconnect()
        do {
            let backup = try remoteService.resetHostKeyStore()
            if let backup {
                appendLog("主机指纹库已重置，原文件已备份到：\(backup.path)", level: .warning)
            } else {
                appendLog("主机指纹库已初始化为空库。", level: .warning)
            }
        } catch {
            present(error)
        }
    }

    func deleteSession(_ session: SessionProfile) {
        if connectedSessionID == session.id { disconnect() }
        if editingSession?.id == session.id { editingSession = nil }
        let previousSessions = sessions
        sessions.removeAll { $0.id == session.id }
        do {
            try sessionStore.save(sessions)
        } catch {
            sessions = previousSessions
            present(AppFailure.commandFailed("无法保存会话列表：\(error.localizedDescription)"))
            return
        }
        credentialStore.delete(for: session.id)
        passwordCache.removeValue(forKey: session.id)
        knownPasswordPresence.removeValue(forKey: session.id)
        if selectedSessionID == session.id { selectedSessionID = nil }
        appendLog("已删除会话：\(session.name)")
    }

    /// 保存属性窗口改动的连接配置；密码留空时保留钥匙串中的原密码。
    func updateSession(
        _ session: SessionProfile, newPassword: String, savePassword: Bool, hadStoredPassword: Bool
    ) throws {
        let previousSessions = sessions
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        do {
            try sessionStore.save(sessions)
        } catch {
            sessions = previousSessions
            throw error
        }

        if !newPassword.isEmpty {
            if savePassword {
                try credentialStore.save(password: newPassword, for: session.id)
                passwordCache[session.id] = newPassword
                knownPasswordPresence[session.id] = true
            } else if hadStoredPassword {
                credentialStore.delete(for: session.id)
                passwordCache.removeValue(forKey: session.id)
                knownPasswordPresence[session.id] = false
            }
        } else if !savePassword && hadStoredPassword {
            credentialStore.delete(for: session.id)
            passwordCache.removeValue(forKey: session.id)
            knownPasswordPresence[session.id] = false
        }

        if editingSession?.id == session.id { editingSession = nil }
        appendLog("已更新会话属性：\(session.name)（\(session.protocolKind.rawValue) · \(session.destination):\(session.port)）")
        if connectedSessionID == session.id {
            appendLog("当前连接继续使用原有配置，断开并重新连接后生效。", level: .warning)
        }
    }

    func disconnect() {
        connectionTask?.cancel()
        connectionTask = nil
        connectionAttemptID = nil
        pendingConnection = nil
        cancelTransfers()
        remoteService.cancelAll()
        activeConfiguration = nil
        remoteRequestSerial &+= 1
        remoteListingCache.removeAll()
        remoteItems = []
        isLoadingRemote = false
        connectedSessionID = nil
        connectionState = .disconnected
        appendLog("连接已断开。")
    }

    func refreshRemote() {
        Task { do { try await refreshRemoteThrowing() } catch { present(error) } }
    }

    private func refreshRemoteThrowing() async throws {
        guard let configuration = activeConfiguration else { throw AppFailure.validation("请先连接远程主机。") }
        remoteRequestSerial &+= 1
        let serial = remoteRequestSerial
        let path = remotePath
        isLoadingRemote = true
        defer { if serial == remoteRequestSerial { isLoadingRemote = false } }
        do {
            let items = try await remoteService.list(path, config: configuration, log: makeLogSink())
            // 快速连击多个目录时，丢弃过期请求，避免旧目录结果覆盖新目录。
            guard serial == remoteRequestSerial, path == remotePath else { return }
            remoteItems = items
            remoteListingCache[path] = items
            remoteSelection.removeAll()
        } catch {
            if serial == remoteRequestSerial { isLoadingRemote = false }
            throw error
        }
    }

    func openRemote(_ item: RemoteItem) {
        guard item.isDirectory else { return }
        navigateRemote(to: item.path)
    }

    func goRemoteParent() {
        navigateRemote(to: RemoteListingParser.parent(of: remotePath))
    }

    func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            localPath = url
            refreshLocal()
        }
    }

    func createLocalFolder() {
        let url = localPath.appendingPathComponent(uniqueLocalName(base: "新建文件夹"))
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            refreshLocal()
        } catch { present(error) }
    }

    func createLocalFile() {
        let url = localPath.appendingPathComponent(uniqueLocalName(base: "新建文件"))
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        if FileManager.default.createFile(atPath: url.path, contents: nil) {
            refreshLocal()
        } else {
            present(AppFailure.commandFailed("无法在 \(localPath.path) 创建文件，请检查目录权限。"))
        }
    }

    /// 本地删除统一走废纸篓，可从废纸篓恢复。
    func deleteLocalItems(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        var failures: [String] = []
        for item in items {
            do { try LocalFileService().moveToTrash(item.url) } catch {
                failures.append("\(item.name)：\(error.localizedDescription)")
            }
        }
        localSelection.removeAll()
        refreshLocal()
        if !failures.isEmpty {
            present(AppFailure.commandFailed("以下项目无法移到废纸篓：\n" + failures.joined(separator: "\n")))
        }
    }

    private func uniqueLocalName(base: String) -> String {
        let existing = Set(localItems.map(\.name))
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    func createRemoteFolder() {
        guard let configuration = activeConfiguration else {
            present(AppFailure.validation("请先连接远程主机。"))
            return
        }
        let path = RemoteListingParser.join(remotePath, uniqueRemoteName(base: "新建文件夹"))
        Task {
            do {
                try await remoteService.createDirectory(path, config: configuration, log: makeLogSink())
                try await refreshRemoteThrowing()
            } catch { present(error) }
        }
    }

    func createRemoteFile() {
        guard let configuration = activeConfiguration else {
            present(AppFailure.validation("请先连接远程主机。"))
            return
        }
        let path = RemoteListingParser.join(remotePath, uniqueRemoteName(base: "新建文件"))
        Task {
            do {
                try await remoteService.createFile(path, config: configuration, log: makeLogSink())
                try await refreshRemoteThrowing()
            } catch { present(error) }
        }
    }

    func requestRemoteRename(_ item: RemoteItem) {
        remoteRenameRequest = RemoteRenameRequest(item: item)
    }

    func renameRemoteItem(_ item: RemoteItem, to newName: String) {
        guard let configuration = activeConfiguration else {
            present(AppFailure.validation("请先连接远程主机。"))
            return
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remoteItems.contains(where: { $0.path != item.path && $0.name == trimmed }) else {
            present(AppFailure.validation("当前目录已经存在同名项目。"))
            return
        }
        remoteRenameRequest = nil
        Task {
            do {
                _ = try await remoteService.rename(item, to: trimmed, config: configuration, log: makeLogSink())
                try await refreshRemoteThrowing()
            } catch { present(error) }
        }
    }

    func requestRemotePermissions(_ item: RemoteItem) {
        remotePermissionsRequest = RemotePermissionsRequest(item: item)
    }

    func changeRemotePermissions(_ item: RemoteItem, mode: String) {
        guard let configuration = activeConfiguration else {
            present(AppFailure.validation("请先连接远程主机。"))
            return
        }
        remotePermissionsRequest = nil
        Task {
            do {
                try await remoteService.changePermissions(item, modeText: mode, config: configuration, log: makeLogSink())
                try await refreshRemoteThrowing()
            } catch { present(error) }
        }
    }

    func openRemoteTextEditor(_ item: RemoteItem) {
        guard let configuration = activeConfiguration else {
            present(AppFailure.validation("请先连接远程主机。"))
            return
        }
        guard loadingEditorPath == nil else { return }
        loadingEditorPath = item.path
        Task {
            defer { loadingEditorPath = nil }
            do {
                let text = try await remoteService.readTextFile(item, config: configuration)
                remoteTextDocument = RemoteTextDocument(path: item.path, name: item.name, text: text, permissions: item.permissions)
            } catch { present(error) }
        }
    }

    func saveRemoteText(_ document: RemoteTextDocument, text: String) async -> Bool {
        guard let configuration = activeConfiguration else {
            present(AppFailure.validation("请先连接远程主机。"))
            return false
        }
        do {
            try await remoteService.writeTextFile(
                path: document.path, text: text, permissions: document.permissions, config: configuration, log: makeLogSink())
            do {
                try await refreshRemoteThrowing()
            } catch {
                appendLog("文本已保存，但刷新目录失败：\(error.localizedDescription)", level: .warning)
            }
            remoteTextDocument = nil
            return true
        } catch {
            present(error)
            return false
        }
    }

    func deleteRemoteItems(_ items: [RemoteItem]) {
        guard let configuration = activeConfiguration else {
            present(AppFailure.validation("请先连接远程主机。"))
            return
        }
        guard !items.isEmpty else { return }
        Task {
            do {
                for item in items {
                    try await remoteService.remove(item, config: configuration, log: makeLogSink())
                }
                try await refreshRemoteThrowing()
            } catch { present(error) }
        }
    }

    /// 生成不与当前目录现有项目重名的名称：新建文件夹、新建文件夹 2、新建文件夹 3…
    private func uniqueRemoteName(base: String) -> String {
        let existing = Set(remoteItems.map(\.name))
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    func uploadSelection() {
        let selected = localItems.filter { localSelection.contains($0.id) }
        guard !selected.isEmpty else {
            present(AppFailure.validation("请先选择要上传的文件或文件夹。"))
            return
        }
        uploadLocalURLs(selected.map(\.url))
    }

    /// 拖拽或按钮触发的上传入口。
    func uploadLocalURLs(_ urls: [URL]) {
        guard let configuration = activeConfiguration else {
            present(AppFailure.validation("请先连接远程主机。"))
            return
        }
        guard !urls.isEmpty else { return }
        for url in urls {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            } catch {
                appendLog("无法读取本地项目：\(url.lastPathComponent) — \(error.localizedDescription)", level: .error)
                continue
            }
            guard values.isSymbolicLink != true else {
                appendLog("已跳过本地符号链接：\(url.lastPathComponent)", level: .warning)
                alertMessage = "为避免循环目录或意外上传链接目标，不支持直接上传本地符号链接：\(url.lastPathComponent)"
                continue
            }
            let isDirectory = values.isDirectory == true
            let size = Int64(values.fileSize ?? 0)
            let destination = RemoteListingParser.join(remotePath, url.lastPathComponent)
            jobs.append(
                TransferJob(
                    id: UUID(), direction: .upload, source: url.path, destination: destination, displayName: url.lastPathComponent,
                    isDirectory: isDirectory, totalBytes: size))
        }
        startQueueIfNeeded(configuration: configuration)
    }

    func downloadSelection() {
        let selected = remoteItems.filter { remoteSelection.contains($0.id) }
        guard !selected.isEmpty else {
            present(AppFailure.validation("请先选择要下载的文件或文件夹。"))
            return
        }
        downloadRemoteItems(selected)
    }

    /// 拖拽或按钮触发的下载入口。
    func downloadRemoteItems(_ items: [RemoteItem]) {
        guard let configuration = activeConfiguration else {
            present(AppFailure.validation("请先连接远程主机。"))
            return
        }
        guard !items.isEmpty else { return }
        for item in items {
            let destination = localPath.appendingPathComponent(item.name).path
            jobs.append(
                TransferJob(
                    id: UUID(), direction: .download, source: item.path, destination: destination, displayName: item.name,
                    isDirectory: item.isDirectory, totalBytes: item.size))
        }
        startQueueIfNeeded(configuration: configuration)
    }

    /// 拖拽载体（RemoteDragItem）触发的下载入口。
    func downloadRemoteDragItems(_ items: [RemoteDragItem]) {
        guard let configuration = activeConfiguration else {
            present(AppFailure.validation("请先连接远程主机。"))
            return
        }
        guard !items.isEmpty else { return }
        for item in items {
            let destination = localPath.appendingPathComponent(item.name).path
            jobs.append(
                TransferJob(
                    id: UUID(), direction: .download, source: item.path, destination: destination, displayName: item.name,
                    isDirectory: item.isDirectory, totalBytes: item.size))
        }
        startQueueIfNeeded(configuration: configuration)
    }

    private func startQueueIfNeeded(configuration: SSHConfiguration) {
        guard queueTask == nil else { return }
        queueTask = Task { [weak self] in
            guard let self else { return }
            while let index = self.jobs.firstIndex(where: { $0.status == .queued }) {
                if Task.isCancelled { break }
                self.jobs[index].status = .running
                self.jobs[index].startedAt = Date()
                self.jobs[index].progress = 0
                let job = self.jobs[index]
                do {
                    let local = job.direction == .upload ? job.source : job.destination
                    let remote = job.direction == .upload ? job.destination : job.source
                    try await self.remoteService.transfer(
                        direction: job.direction, localPath: local, remotePath: remote, isDirectory: job.isDirectory, config: configuration,
                        expectedBytes: job.totalBytes, log: self.makeLogSink()
                    ) { [weak self] update in
                        Task { @MainActor [weak self] in
                            guard let self, let current = self.jobs.firstIndex(where: { $0.id == job.id }) else { return }
                            self.jobs[current].transferredBytes = update.transferredBytes
                            self.jobs[current].totalBytes = update.totalBytes
                            self.jobs[current].resumedBytes = update.resumedBytes
                            if update.totalBytes > 0 {
                                self.jobs[current].progress = min(1, Double(update.transferredBytes) / Double(update.totalBytes))
                            }
                            let elapsed = max(0.001, Date().timeIntervalSince(self.jobs[current].startedAt ?? Date()))
                            let networkBytes = max(0, update.transferredBytes - update.resumedBytes)
                            self.jobs[current].bytesPerSecond = Double(networkBytes) / elapsed
                        }
                    }
                    if let current = self.jobs.firstIndex(where: { $0.id == job.id }) {
                        self.jobs[current].status = .completed
                        self.jobs[current].progress = 1
                        if self.jobs[current].totalBytes == 0 {
                            self.jobs[current].totalBytes = self.jobs[current].transferredBytes
                        }
                        self.jobs[current].finishedAt = Date()
                    }
                } catch {
                    if let current = self.jobs.firstIndex(where: { $0.id == job.id }) {
                        self.jobs[current].status = (Task.isCancelled || error is CancellationError) ? .cancelled : .failed
                        self.jobs[current].errorMessage = error.localizedDescription
                        self.jobs[current].finishedAt = Date()
                    }
                    self.appendLog("传输失败：\(job.displayName) — \(error.localizedDescription)", level: .error)
                }
                self.refreshLocal()
                if self.isConnected { self.refreshRemote() }
            }
            self.queueTask = nil
        }
    }

    func cancelTransfers() {
        let hadActiveTransfers = jobs.contains { $0.status == .queued || $0.status == .running }
        queueTask?.cancel()
        queueTask = nil
        if hadActiveTransfers {
            // Citadel file streams share the SSH transport. Closing it is the only reliable way to
            // interrupt a blocked network write, so reflect that state instead of showing a stale connection.
            remoteService.cancelAll()
            activeConfiguration = nil
            remoteRequestSerial &+= 1
            remoteItems = []
            remoteListingCache.removeAll()
            connectedSessionID = nil
            isLoadingRemote = false
            connectionState = .disconnected
        }
        for index in jobs.indices where jobs[index].status == .queued || jobs[index].status == .running {
            jobs[index].status = .cancelled
            jobs[index].finishedAt = Date()
        }
        if hadActiveTransfers { appendLog("传输队列已取消。", level: .warning) }
    }

    func clearFinishedJobs() {
        jobs.removeAll { [.completed, .failed, .cancelled].contains($0.status) }
    }

    func appendLog(_ message: String, level: LogEntry.Level = .info) {
        for line in message.split(whereSeparator: \.isNewline) where !line.isEmpty {
            logs.append(LogEntry(level: level, message: String(line)))
        }
        if logs.count > 2_000 { logs.removeFirst(logs.count - 2_000) }
    }

    nonisolated private func makeLogSink() -> @Sendable (String) -> Void {
        { [weak self] text in
            Task { @MainActor [weak self] in self?.appendLog(text) }
        }
    }

    private func present(_ error: Error) {
        let message = error.localizedDescription
        alertMessage = message
        appendLog(message, level: .error)
    }
}
