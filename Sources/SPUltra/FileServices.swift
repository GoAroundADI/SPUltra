import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH

struct LocalFileService {
    func contents(of directory: URL, showHidden: Bool) throws -> [FileItem] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys),
            options: showHidden ? [] : [.skipsHiddenFiles]
        )
        return try urls.map { url in
            let values = try url.resourceValues(forKeys: keys)
            return FileItem(
                url: url, name: url.lastPathComponent, isDirectory: values.isDirectory == true,
                isSymbolicLink: values.isSymbolicLink == true,
                size: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate, permissions: nil)
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 与 Finder 一致地移入废纸篓而不是永久删除，并返回实际废纸篓路径供测试与诊断使用。
    @discardableResult
    func moveToTrash(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }
}

final class TransferProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let discoversTotal: Bool
    private let callback: @Sendable (TransferProgressUpdate) -> Void
    private var transferredBytes: Int64 = 0
    private var totalBytes: Int64
    private var resumedBytes: Int64 = 0

    init(expectedBytes: Int64, callback: @escaping @Sendable (TransferProgressUpdate) -> Void) {
        discoversTotal = expectedBytes <= 0
        totalBytes = max(0, expectedBytes)
        self.callback = callback
        callback(TransferProgressUpdate(transferredBytes: 0, totalBytes: totalBytes, resumedBytes: 0))
    }

    func beginFile(size: Int64, resumedAt offset: Int64) {
        emit {
            if discoversTotal { totalBytes += max(0, size) }
            let safeOffset = min(max(0, offset), max(0, size))
            transferredBytes += safeOffset
            resumedBytes += safeOffset
        }
    }

    func advance(by byteCount: Int) {
        guard byteCount > 0 else { return }
        emit { transferredBytes += Int64(byteCount) }
    }

    private func emit(_ mutation: () -> Void) {
        let update = lock.withLock { () -> TransferProgressUpdate in
            mutation()
            return TransferProgressUpdate(
                transferredBytes: transferredBytes,
                totalBytes: totalBytes,
                resumedBytes: resumedBytes)
        }
        callback(update)
    }
}

struct RemoteListingParser {
    static func join(_ directory: String, _ name: String) -> String {
        if directory == "/" { return "/" + name }
        if directory == "." { return name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    static func parent(of path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if path.hasPrefix("/") {
            guard components.count > 1 else { return "/" }
            return "/" + components.dropLast().joined(separator: "/")
        }
        return components.count <= 1 ? "." : components.dropLast().joined(separator: "/")
    }

    static func parsePOSIXListing(_ text: String, directory: String) -> [RemoteItem] {
        text.split(whereSeparator: \Character.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            guard !line.hasPrefix("total ") else { return nil }
            let fields = line.split(maxSplits: 8, omittingEmptySubsequences: true, whereSeparator: \Character.isWhitespace)
            guard fields.count == 9, fields[0].count >= 10, let size = Int64(fields[4]) else { return nil }
            let permissions = String(fields[0].prefix(10))
            let kind = permissions.first
            var name = String(fields[8])
            if kind == "l", let range = name.range(of: " -> ") { name = String(name[..<range.lowerBound]) }
            guard name != ".", name != ".." else { return nil }
            return RemoteItem(
                path: join(directory, name), name: name, isDirectory: kind == "d", isSymbolicLink: kind == "l",
                size: size, modifiedText: "\(fields[5]) \(fields[6]) \(fields[7])", permissions: permissions
            )
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

struct SSHConfiguration: Sendable {
    let profile: SessionProfile
    let password: String?
    var connectTimeout: Int = 15
}

final class RemoteFileService: @unchecked Sendable {
    private let lock = NSLock()
    private let hostKeyStore: HostKeyStore
    private var client: SSHClient?
    private var sftp: SFTPClient?
    private var pendingClosures: [Task<Void, Never>] = []
    private var connectionGeneration: UInt64 = 0

    init(hostKeyStore: HostKeyStore = HostKeyStore()) { self.hostKeyStore = hostKeyStore }

    func test(_ config: SSHConfiguration, log: @escaping @Sendable (String) -> Void) async throws {
        let (generation, previousSFTP, previousClient) = lock.withLock { () -> (UInt64, SFTPClient?, SSHClient?) in
            connectionGeneration &+= 1
            let values = (connectionGeneration, sftp, client)
            sftp = nil
            client = nil
            return values
        }
        try? await previousSFTP?.close()
        try? await previousClient?.close()
        do {
            try await establish(config, generation: generation, forceLegacyAlgorithms: false, log: log)
        } catch let failure as AppFailure {
            // 现代算法协商或刚断开的连接失败时，在同一个普通连接入口里用完整算法集重试。
            guard case .commandFailed = failure else { throw failure }
            guard isCurrentGeneration(generation) else { throw CancellationError() }
            log("首次握手失败，启用旧设备兼容算法后重试一次：\(failure.localizedDescription)\n")
            try await Task.sleep(for: .milliseconds(400))
            guard isCurrentGeneration(generation) else { throw CancellationError() }
            try await establish(config, generation: generation, forceLegacyAlgorithms: true, log: log)
        }
    }

    private func establish(
        _ config: SSHConfiguration, generation: UInt64, forceLegacyAlgorithms: Bool,
        log: @escaping @Sendable (String) -> Void
    ) async throws {
        let endpoint = "\(config.profile.host):\(config.profile.port)"
        log("使用应用内 SwiftNIO SSH 连接 \(endpoint)…\n")
        let validator = ApplicationHostKeyValidator(endpoint: endpoint, store: hostKeyStore) { fingerprint in
            log("首次连接，已记录主机指纹 \(fingerprint)\n")
        }
        let method = try authenticationMethod(config)
        var settings = SSHClientSettings(
            host: config.profile.host,
            port: config.profile.port,
            authenticationMethod: { method },
            hostKeyValidator: .custom(validator)
        )
        settings.connectTimeout = TimeAmount.seconds(Int64(config.connectTimeout))
        if forceLegacyAlgorithms { settings.algorithms = SSHAlgorithms.all }
        let newClient: SSHClient
        do {
            newClient = try await SSHClient.connect(to: settings)
        } catch let error as NIOSSHError {
            throw AppFailure.commandFailed(Self.describeHandshakeError(error))
        } catch SSHClientError.allAuthenticationOptionsFailed {
            throw AppFailure.authentication("SSH 认证失败：保存的密码或私钥可能已失效。请在会话属性中重新填写密码后重试。")
        } catch CitadelError.unauthorized {
            throw AppFailure.authentication("SSH 认证被拒绝：请检查用户名、密码或私钥。")
        }
        do {
            if config.profile.protocolKind == .sftp {
                let newSFTP = try await newClient.openSFTP()
                _ = try await newSFTP.getRealPath(atPath: ".")
                guard install(newClient, sftp: newSFTP, generation: generation) else {
                    try? await newSFTP.close()
                    try? await newClient.close()
                    throw CancellationError()
                }
                log("SSH 握手与 SFTP 子系统初始化成功。\n")
            } else {
                var output = try await newClient.executeCommand("pwd", maxResponseSize: 64 * 1024)
                _ = output.readString(length: output.readableBytes)
                guard install(newClient, sftp: nil, generation: generation) else {
                    try? await newClient.close()
                    throw CancellationError()
                }
                log("SSH 握手成功；SCP 模式将直接使用应用内协议通道。\n")
            }
        } catch let error as NIOSSHError {
            try? await newClient.close()
            throw AppFailure.commandFailed(Self.describeHandshakeError(error))
        } catch {
            try? await newClient.close()
            throw error
        }
    }

    /// 把 NIOSSH 的英文/泛化握手错误翻译成可操作的提示。
    private static func describeHandshakeError(_ error: NIOSSHError) -> String {
        switch error.type {
        case .keyExchangeNegotiationFailure:
            return "SSH 算法协商失败：请确认服务器 SSH 配置；SCP 模式已自动启用旧设备兼容算法。"
        case .invalidHostKeyForKeyExchange:
            return "主机密钥与协商结果不一致，连接可能被中断。请稍后重试。"
        case .tcpShutdown:
            return "SSH 在握手阶段被远端关闭。请稍后重试。"
        case .unsupportedVersion:
            return "远端 SSH 版本过旧，当前连接参数无法协商；可改用 SCP 模式自动启用旧设备兼容算法。"
        default:
            return "SSH 握手失败：\(error.type)。请稍后重试。"
        }
    }

    func trustReplacement(_ conflict: HostKeyConflict) throws {
        try hostKeyStore.replace(endpoint: conflict.endpoint, with: conflict.presentedKey)
    }

    func resetHostKeyStore() throws -> URL? {
        try hostKeyStore.resetAllWithBackup()
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        lock.withLock { connectionGeneration == generation }
    }

    private func install(_ newClient: SSHClient, sftp newSFTP: SFTPClient?, generation: UInt64) -> Bool {
        lock.withLock {
            guard connectionGeneration == generation else { return false }
            client = newClient
            sftp = newSFTP
            return true
        }
    }

    func list(_ path: String, config: SSHConfiguration, log: @escaping @Sendable (String) -> Void) async throws -> [RemoteItem] {
        if config.profile.protocolKind == .scp { return try await listViaShell(path) }
        let responses = try await activeSFTP().listDirectory(atPath: path)
        return responses.flatMap(\.components).compactMap { component in
            guard component.filename != ".", component.filename != ".." else { return nil }
            let mode = component.attributes.permissions ?? 0
            let type = mode & 0o170000
            let date = component.attributes.accessModificationTime?.modificationTime
            return RemoteItem(
                path: RemoteListingParser.join(path, component.filename), name: component.filename,
                isDirectory: type == 0o040000, isSymbolicLink: type == 0o120000,
                size: Int64(component.attributes.size ?? 0),
                modifiedText: date?.formatted(date: .numeric, time: .shortened) ?? "—",
                permissions: Self.permissionString(mode)
            )
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func createDirectory(_ path: String, config: SSHConfiguration, log: @escaping @Sendable (String) -> Void) async throws {
        if config.profile.protocolKind == .scp {
            _ = try await executeRemote("mkdir \(Self.shellQuote(path))")
        } else {
            try await activeSFTP().createDirectory(atPath: path)
        }
        log("已创建远程文件夹：\(path)\n")
    }

    func createFile(_ path: String, config: SSHConfiguration, log: @escaping @Sendable (String) -> Void) async throws {
        if config.profile.protocolKind == .scp {
            try await createFileOverShellOrSCP(path, log: log)
        } else {
            try await activeSFTP().withFile(filePath: path, flags: [.write, .create, .truncate]) { _ in }
        }
        log("已创建远程文件：\(path)\n")
    }

    func rename(
        _ item: RemoteItem, to newName: String, config: SSHConfiguration, log: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let name = try Self.validatedRemoteName(newName)
        let destination = RemoteListingParser.join(RemoteListingParser.parent(of: item.path), name)
        guard destination != item.path else { return destination }
        if config.profile.protocolKind == .scp {
            var failures: [String] = []
            for command in Self.renameCommands(source: item.path, destination: destination) {
                do {
                    _ = try await executeRemote(command)
                    guard await remotePathExists(destination) else {
                        throw AppFailure.commandFailed("重命名命令返回成功，但没有找到新路径。")
                    }
                    log("已重命名远程项目：\(item.path) → \(destination)\n")
                    return destination
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            throw AppFailure.commandFailed("无法重命名远程项目：\n" + failures.joined(separator: "\n"))
        }

        let session = try activeSFTP()
        try await session.rename(at: item.path, to: destination)
        let destinationExists = (try? await session.getAttributes(at: destination)) != nil
        let sourceStillExists = (try? await session.getAttributes(at: item.path)) != nil
        guard destinationExists, !sourceStillExists else {
            throw AppFailure.commandFailed("SFTP 服务器没有完成重命名，原项目仍位于旧路径。")
        }
        log("已重命名远程项目：\(item.path) → \(destination)\n")
        return destination
    }

    func changePermissions(
        _ item: RemoteItem, modeText: String, config: SSHConfiguration, log: @escaping @Sendable (String) -> Void
    ) async throws {
        let mode = try Self.validatedPermissionMode(modeText)
        if config.profile.protocolKind == .scp {
            var lastError: Error?
            for command in Self.chmodCommands(path: item.path, mode: mode) {
                do {
                    _ = try await executeRemote(command)
                    log("已修改远程权限：\(item.path) → \(String(mode, radix: 8))\n")
                    return
                } catch {
                    lastError = error
                }
            }
            throw lastError ?? AppFailure.commandFailed("无法修改远程权限。")
        }

        var attributes = SFTPFileAttributes()
        attributes.permissions = mode
        let session = try activeSFTP()
        try await session.setAttributes(at: item.path, to: attributes)
        let applied = try await session.getAttributes(at: item.path).permissions ?? 0
        guard applied & 0o7777 == mode else {
            throw AppFailure.commandFailed("SFTP 服务器没有应用请求的权限。")
        }
        log("已修改远程权限：\(item.path) → \(String(mode, radix: 8))\n")
    }

    func readTextFile(
        _ item: RemoteItem, config: SSHConfiguration, maximumBytes: Int = 4 * 1024 * 1024
    ) async throws -> String {
        guard !item.isDirectory else { throw AppFailure.validation("文件夹不能在线编辑。") }
        guard item.size <= Int64(maximumBytes) else {
            throw AppFailure.validation("在线编辑仅支持不超过 4 MB 的 UTF-8 文本文件。")
        }
        let data: Data
        if config.profile.protocolKind == .sftp {
            data = try await activeSFTP().withFile(filePath: item.path, flags: .read) { file in
                var result = Data()
                var offset: UInt64 = 0
                while true {
                    var buffer = try await file.read(from: offset, length: 256 * 1024)
                    guard buffer.readableBytes > 0 else { break }
                    guard result.count + buffer.readableBytes <= maximumBytes else {
                        throw AppFailure.validation("在线编辑仅支持不超过 4 MB 的 UTF-8 文本文件。")
                    }
                    let chunk = buffer.readData(length: buffer.readableBytes) ?? Data()
                    result.append(chunk)
                    offset += UInt64(chunk.count)
                }
                return result
            }
        } else {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SPUltra-Edit-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await downloadSCPFile(remotePath: item.path, localURL: temporary, tracker: nil)
            data = try Data(contentsOf: temporary, options: .mappedIfSafe)
            guard data.count <= maximumBytes else {
                throw AppFailure.validation("在线编辑仅支持不超过 4 MB 的 UTF-8 文本文件。")
            }
        }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw AppFailure.validation("该文件不是 UTF-8 文本，不能安全地在线编辑。")
        }
        return text
    }

    func writeTextFile(
        path: String, text: String, permissions: String? = nil, config: SSHConfiguration,
        log: @escaping @Sendable (String) -> Void
    ) async throws {
        guard let data = text.data(using: .utf8), data.count <= 4 * 1024 * 1024 else {
            throw AppFailure.validation("在线编辑仅支持不超过 4 MB 的 UTF-8 文本文件。")
        }
        if config.profile.protocolKind == .sftp {
            try await activeSFTP().withFile(filePath: path, flags: [.write, .create, .truncate]) { file in
                var offset: UInt64 = 0
                for start in stride(from: 0, to: data.count, by: 256 * 1024) {
                    let end = min(start + 256 * 1024, data.count)
                    try await file.write(ByteBuffer(bytes: data[start..<end]), at: offset)
                    offset += UInt64(end - start)
                }
            }
        } else {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SPUltra-Edit-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: .atomic)
            try await uploadSCPFile(
                localURL: temporary, remotePath: path,
                permissions: permissions.flatMap { Self.permissionMode(from: $0) }, tracker: nil)
        }
        log("已保存远程文本文件：\(path)\n")
    }

    static func validatedRemoteName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"), !name.contains("\n"),
            !name.contains("\r")
        else {
            throw AppFailure.validation("名称不能为空、不能是 . 或 ..，且不能包含 /、换行或回车。")
        }
        return name
    }

    static func validatedPermissionMode(_ value: String) throws -> UInt32 {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...4).contains(text.count), text.allSatisfy({ ("0"..."7").contains($0) }), let mode = UInt32(text, radix: 8),
            mode <= 0o7777
        else {
            throw AppFailure.validation("请输入 3 或 4 位八进制权限，例如 644、755 或 0755。")
        }
        return mode
    }

    static func renameCommands(source: String, destination: String) -> [String] {
        let destinationCheck =
            "if [ -e \(shellQuote(destination)) ] || [ -L \(shellQuote(destination)) ]; then echo '目标已存在' >&2; exit 1; fi;"
        let legacySource = source.hasPrefix("-") ? "./" + source : source
        let legacyDestination = destination.hasPrefix("-") ? "./" + destination : destination
        return [
            "\(destinationCheck) mv -- \(shellQuote(source)) \(shellQuote(destination))",
            "\(destinationCheck) mv \(shellQuote(legacySource)) \(shellQuote(legacyDestination))",
        ]
    }

    static func chmodCommands(path: String, mode: UInt32) -> [String] {
        let modeText = String(format: "%04o", mode)
        return [
            "chmod \(modeText) -- \(shellQuote(path))",
            "chmod \(modeText) \(shellQuote(path.hasPrefix("-") ? "./" + path : path))",
        ]
    }

    static func permissionMode(from symbolic: String) -> UInt32? {
        let characters = Array(symbolic.suffix(9))
        guard characters.count == 9 else { return nil }
        var mode: UInt32 = 0
        for (index, character) in characters.enumerated() where character != "-" {
            let bit = 8 - index
            mode |= 1 << bit
        }
        return mode
    }

    /// 越狱 iOS 的精简引导里通常没有 touch，优先用 POSIX shell 内建重定向；
    /// 若该主机的 shell 连内建命令都不支持，则退回与上传共用、已在设备上验证可用的 SCP 协议通道。
    private func createFileOverShellOrSCP(_ path: String, log: @escaping @Sendable (String) -> Void) async throws {
        var attempts: [String] = []
        do {
            _ = try await executeRemote(": > \(Self.shellQuote(path))")
            if await remotePathExists(path) { return }
            attempts.append("shell 重定向：命令返回成功，但没有找到目标文件")
            log("shell 重定向后未找到目标文件，改用 SCP 协议通道…\n")
        } catch {
            attempts.append("shell 重定向：\(error.localizedDescription)")
            log("shell 重定向创建文件失败，改用 SCP 协议通道…（\(error.localizedDescription)）\n")
        }
        if #available(macOS 15.0, *) {
            do {
                try await createEmptyFileViaSCP(remotePath: path)
                return
            } catch {
                attempts.append("SCP 协议：\(error.localizedDescription)")
            }
        }
        do {
            _ = try await executeRemote("touch \(Self.shellQuote(path))")
            if await remotePathExists(path) { return }
            attempts.append("touch：命令返回成功，但没有找到目标文件")
        } catch {
            attempts.append("touch：\(error.localizedDescription)")
        }
        throw AppFailure.commandFailed("无法在远程主机创建文件：\(path)\n" + attempts.joined(separator: "\n"))
    }

    /// 用 ls 确认路径真的存在，避免某些受限 shell 返回 0 却没有创建文件。
    private func remotePathExists(_ path: String) async -> Bool {
        guard let text = try? await executeRemote("LC_ALL=C ls -ldn \(Self.shellQuote(path))") else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 通过 SCP 协议上传一个 0 字节文件来创建空文件，不依赖远端 shell 的 : 或 touch。
    @available(macOS 15.0, *)
    private func createEmptyFileViaSCP(remotePath: String) async throws {
        let ssh = try activeSSHClient()
        let parent = RemoteListingParser.parent(of: remotePath)
        let name = try Self.validatedRemoteName(URL(fileURLWithPath: remotePath).lastPathComponent)
        try await ssh.withExec("scp -t -- \(Self.shellQuote(parent))") { inbound, outbound in
            var reader = SCPReplyReader(output: inbound)
            try await reader.expectOK()
            try await outbound.write(ByteBuffer(string: "C0644 0 \(name)\n"))
            try await reader.expectOK()
            try await outbound.write(ByteBuffer(bytes: [UInt8(0)]))
            try await reader.expectOK()
        }
    }

    func remove(_ item: RemoteItem, config: SSHConfiguration, log: @escaping @Sendable (String) -> Void) async throws {
        if config.profile.protocolKind == .scp {
            try await removeViaShell(item, log: log)
        } else if item.isDirectory {
            do {
                try await removeSFTPDirectory(item.path)
            } catch {
                // 某些 SFTP 服务不返回完整类型或实现不完整；普通 SSH shell 可用时再兜底一次。
                log("SFTP 递归删除文件夹失败，尝试 SSH shell 兼容模式…（\(error.localizedDescription)）\n")
                do {
                    try await removeViaShell(item, log: log)
                } catch let fallbackError {
                    throw AppFailure.commandFailed(
                        "无法删除远程文件夹：\(item.path)\nSFTP：\(error.localizedDescription)\nSSH shell：\(fallbackError.localizedDescription)")
                }
            }
        } else {
            do {
                try await activeSFTP().remove(at: item.path)
            } catch let fileError {
                // 少数 SFTP 服务的目录项不携带类型位：先按文件删除失败后，
                // 再按目录递归处理，最后才退回经过转义的 shell 删除。
                do {
                    try await removeSFTPDirectory(item.path)
                } catch let directoryError {
                    log("SFTP 无法判断项目类型，尝试 SSH shell 兼容删除…\n")
                    do {
                        try await removeViaShell(item, log: log)
                    } catch let shellError {
                        throw AppFailure.commandFailed(
                            "无法删除远程项目：\(item.path)\n文件删除：\(fileError.localizedDescription)\n目录删除：\(directoryError.localizedDescription)\nSSH shell：\(shellError.localizedDescription)"
                        )
                    }
                }
            }
        }
        log("已删除远程项目：\(item.path)\n")
    }

    /// 新版 rm 支持 `--` 防止路径被当作参数；旧 iOS / BusyBox 可能不支持，因此失败时使用安全路径重试。
    private func removeViaShell(_ item: RemoteItem, log: @escaping @Sendable (String) -> Void) async throws {
        let commands = Self.removalCommands(path: item.path, isDirectory: item.isDirectory)
        var failures: [String] = []
        for (index, command) in commands.enumerated() {
            do {
                _ = try await executeRemote(command)
                guard !(await remotePathExists(item.path)) else {
                    throw AppFailure.commandFailed("删除命令已返回成功，但远程路径仍然存在。")
                }
                return
            } catch {
                failures.append(error.localizedDescription)
                if index == 0 {
                    log("标准删除命令失败，尝试旧版 rm 兼容模式…（\(error.localizedDescription)）\n")
                }
            }
        }
        throw AppFailure.commandFailed("无法删除远程项目：\(item.path)\n" + failures.joined(separator: "\n"))
    }

    static func removalCommands(path: String, isDirectory: Bool) -> [String] {
        let flags = isDirectory ? "-rf" : "-f"
        let quoted = shellQuote(path)
        // 不支持 `--` 的 rm 仍需防止相对路径 `-name` 被解释为选项。
        let legacyPath = path.hasPrefix("-") ? "./" + path : path
        return ["rm \(flags) -- \(quoted)", "rm \(flags) \(shellQuote(legacyPath))"]
    }

    /// SFTP 的 rmdir 无法删除非空目录，这里递归清空后再删。
    private func removeSFTPDirectory(_ path: String) async throws {
        let session = try activeSFTP()
        let responses = try await session.listDirectory(atPath: path)
        for component in responses.flatMap(\.components) {
            try Task.checkCancellation()
            guard component.filename != ".", component.filename != ".." else { continue }
            let childPath = RemoteListingParser.join(path, component.filename)
            let type = (component.attributes.permissions ?? 0) & 0o170000
            if type == 0o040000 {
                try await removeSFTPDirectory(childPath)
            } else {
                do {
                    try await session.remove(at: childPath)
                } catch {
                    // permissions 缺失时无法从目录项判断类型；文件删除失败后按目录再试。
                    try await removeSFTPDirectory(childPath)
                }
            }
        }
        try await session.rmdir(at: path)
    }

    func transfer(
        direction: TransferDirection, localPath: String, remotePath: String, isDirectory: Bool,
        config: SSHConfiguration, expectedBytes: Int64 = 0, log: @escaping @Sendable (String) -> Void,
        progress: @escaping @Sendable (TransferProgressUpdate) -> Void = { _ in }
    ) async throws {
        let totalBytes: Int64
        if expectedBytes > 0 || !isDirectory {
            totalBytes = expectedBytes
        } else if direction == .upload {
            totalBytes = try Self.localTransferSize(at: URL(fileURLWithPath: localPath))
        } else {
            totalBytes = try await remoteTransferSize(at: remotePath, config: config, log: log)
        }
        let tracker = TransferProgressTracker(expectedBytes: totalBytes, callback: progress)
        if config.profile.protocolKind == .scp {
            try await transferSCP(
                direction: direction, localPath: localPath, remotePath: remotePath, isDirectory: isDirectory, log: log, tracker: tracker)
        } else if direction == .upload {
            try await uploadSFTP(localURL: URL(fileURLWithPath: localPath), remotePath: remotePath, log: log, tracker: tracker)
        } else {
            try await downloadSFTP(
                remotePath: remotePath, localURL: URL(fileURLWithPath: localPath), isDirectory: isDirectory, log: log, tracker: tracker)
        }
    }

    func cancelAll() {
        let activeClient = lock.withLock {
            connectionGeneration &+= 1
            let value = client
            client = nil
            sftp = nil
            return value
        }
        guard let activeClient else { return }
        let closure = Task {
            _ = try? await activeClient.close()
        }
        lock.withLock { pendingClosures.append(closure) }
    }

    func disconnect() async {
        let (activeSFTP, activeClient) = lock.withLock {
            connectionGeneration &+= 1
            let values = (sftp, client)
            sftp = nil
            client = nil
            return values
        }
        try? await activeSFTP?.close()
        try? await activeClient?.close()

        // 等待之前 cancelAll() 启动的关闭任务结束，避免旧 TCP 连接还在收尾时立刻建新连接。
        let closures = lock.withLock { () -> [Task<Void, Never>] in
            let tasks = pendingClosures
            pendingClosures.removeAll()
            return tasks
        }
        for closure in closures { await closure.value }
    }

    private func activeSFTP() throws -> SFTPClient {
        try lock.withLock {
            guard let sftp else { throw AppFailure.commandFailed("SFTP 会话尚未建立或已经断开。") }
            return sftp
        }
    }

    private func activeSSHClient() throws -> SSHClient {
        try lock.withLock {
            guard let client else { throw AppFailure.commandFailed("SSH 会话尚未建立或已经断开。") }
            return client
        }
    }

    private func authenticationMethod(_ config: SSHConfiguration) throws -> SSHAuthenticationMethod {
        let profile = config.profile
        if profile.authentication == .publicKey || !profile.privateKeyPath.isEmpty {
            let keyText = try String(contentsOfFile: profile.privateKeyPath, encoding: .utf8)
            let passphrase = config.password?.data(using: .utf8)
            switch try SSHKeyDetection.detectPrivateKeyType(from: keyText) {
            case .rsa:
                return .rsa(username: profile.username, privateKey: try Insecure.RSA.PrivateKey(sshRsa: keyText, decryptionKey: passphrase))
            case .ed25519:
                return .ed25519(
                    username: profile.username,
                    privateKey: try Curve25519.Signing.PrivateKey(sshEd25519: keyText, decryptionKey: passphrase))
            default:
                throw AppFailure.validation("当前版本支持 OpenSSH RSA 和 ED25519 私钥；此私钥类型暂不支持。")
            }
        }
        guard let password = config.password, !password.isEmpty else {
            throw AppFailure.validation("请输入密码，或选择 RSA/ED25519 私钥。也可以在会话右键菜单的“属性…”中保存密码。")
        }
        return .passwordBased(username: profile.username, password: password)
    }

    private func uploadSFTP(
        localURL: URL, remotePath: String, log: @escaping @Sendable (String) -> Void, tracker: TransferProgressTracker
    ) async throws {
        let values = try localURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        if values.isSymbolicLink == true {
            log("已跳过本地符号链接：\(localURL.path)\n")
            return
        }
        if values.isDirectory == true {
            try await ensureRemoteDirectory(remotePath)
            for child in try FileManager.default.contentsOfDirectory(
                at: localURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            {
                try Task.checkCancellation()
                try await uploadSFTP(
                    localURL: child, remotePath: RemoteListingParser.join(remotePath, child.lastPathComponent), log: log, tracker: tracker)
            }
            return
        }
        let session = try activeSFTP()
        let fileSize = Int64(values.fileSize ?? 0)
        let partialPath = Self.partialRemotePath(for: remotePath)
        var resumeOffset: Int64 = 0
        if let attributes = try? await session.getAttributes(at: partialPath) {
            resumeOffset = min(Int64(attributes.size ?? 0), fileSize)
            if Int64(attributes.size ?? 0) > fileSize {
                try? await session.remove(at: partialPath)
                resumeOffset = 0
            } else if resumeOffset > 0 {
                let matches = try await resumePrefixMatches(
                    localURL: localURL, remotePath: partialPath, byteCount: resumeOffset, session: session)
                if !matches {
                    try? await session.remove(at: partialPath)
                    log("SFTP 断点内容与本地文件不一致，已从头重新上传：\(localURL.lastPathComponent)\n")
                    resumeOffset = 0
                }
            }
        }
        tracker.beginFile(size: fileSize, resumedAt: resumeOffset)
        if resumeOffset > 0 { log("SFTP 从 \(resumeOffset) 字节处续传：\(localURL.lastPathComponent)\n") }
        let startingOffset = resumeOffset
        let source = try FileHandle(forReadingFrom: localURL)
        defer { try? source.close() }
        try source.seek(toOffset: UInt64(startingOffset))
        let flags: SFTPOpenFileFlags = startingOffset > 0 ? [.write, .create] : [.write, .create, .truncate]
        try await session.withFile(filePath: partialPath, flags: flags) { file in
            var offset = UInt64(startingOffset)
            while let data = try source.read(upToCount: 512 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                try await file.write(ByteBuffer(bytes: data), at: offset)
                offset += UInt64(data.count)
                tracker.advance(by: data.count)
            }
        }
        try await replaceRemoteFile(session: session, partialPath: partialPath, destination: remotePath)
        log("SFTP 上传完成：\(localURL.lastPathComponent)\n")
    }

    private func downloadSFTP(
        remotePath: String, localURL: URL, isDirectory: Bool, log: @escaping @Sendable (String) -> Void,
        tracker: TransferProgressTracker
    ) async throws {
        if isDirectory {
            try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
            for child in try await list(remotePath, config: SSHConfiguration(profile: SessionProfile(), password: nil), log: log) {
                try Task.checkCancellation()
                try await downloadSFTP(
                    remotePath: child.path, localURL: localURL.appendingPathComponent(child.name), isDirectory: child.isDirectory, log: log,
                    tracker: tracker)
            }
            return
        }
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = Self.partialLocalURL(for: localURL)
        let remoteSize = Int64(try await activeSFTP().getAttributes(at: remotePath).size ?? 0)
        var resumeOffset = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if resumeOffset > remoteSize {
            try? FileManager.default.removeItem(at: temporary)
            resumeOffset = 0
        } else if resumeOffset > 0 {
            let matches = try await resumePrefixMatches(
                localURL: temporary, remotePath: remotePath, byteCount: resumeOffset, session: activeSFTP())
            if !matches {
                try? FileManager.default.removeItem(at: temporary)
                log("SFTP 本地断点内容与远端文件不一致，已从头重新下载：\(localURL.lastPathComponent)\n")
                resumeOffset = 0
            }
        }
        if !FileManager.default.fileExists(atPath: temporary.path) {
            FileManager.default.createFile(atPath: temporary.path, contents: nil)
        }
        tracker.beginFile(size: remoteSize, resumedAt: resumeOffset)
        if resumeOffset > 0 { log("SFTP 从 \(resumeOffset) 字节处续传：\(localURL.lastPathComponent)\n") }
        let startingOffset = resumeOffset
        let destination = try FileHandle(forWritingTo: temporary)
        do {
            try destination.seek(toOffset: UInt64(startingOffset))
            try await activeSFTP().withFile(filePath: remotePath, flags: .read) { file in
                var offset = UInt64(startingOffset)
                while true {
                    try Task.checkCancellation()
                    var buffer = try await file.read(from: offset, length: 512 * 1024)
                    guard buffer.readableBytes > 0 else { break }
                    let data = buffer.readData(length: buffer.readableBytes) ?? Data()
                    try destination.write(contentsOf: data)
                    offset += UInt64(data.count)
                    tracker.advance(by: data.count)
                }
            }
            try destination.synchronize()
            try destination.close()
            if FileManager.default.fileExists(atPath: localURL.path) {
                _ = try FileManager.default.replaceItemAt(localURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: localURL)
            }
            log("SFTP 下载完成：\(localURL.lastPathComponent)\n")
        } catch {
            try? destination.close()
            throw error
        }
    }

    static func partialRemotePath(for path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return RemoteListingParser.join(RemoteListingParser.parent(of: path), ".\(name).spultra-part")
    }

    static func partialLocalURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).spultra-part")
    }

    private static func localTransferSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        if values.isSymbolicLink == true { return 0 }
        guard values.isDirectory == true else { return Int64(values.fileSize ?? 0) }
        return try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        ).reduce(Int64(0)) { total, child in
            try total + localTransferSize(at: child)
        }
    }

    private func remoteTransferSize(
        at path: String, config: SSHConfiguration, log: @escaping @Sendable (String) -> Void
    ) async throws -> Int64 {
        var total: Int64 = 0
        for item in try await list(path, config: config, log: log) {
            try Task.checkCancellation()
            if item.isDirectory {
                total += try await remoteTransferSize(at: item.path, config: config, log: log)
            } else {
                total += item.size
            }
        }
        return total
    }

    private func resumePrefixMatches(
        localURL: URL, remotePath: String, byteCount: Int64, session: SFTPClient
    ) async throws -> Bool {
        let sampleSize = min(byteCount, 64 * 1024)
        guard sampleSize > 0 else { return true }
        let offsets = byteCount > sampleSize ? [Int64(0), byteCount - sampleSize] : [Int64(0)]
        let local = try FileHandle(forReadingFrom: localURL)
        defer { try? local.close() }
        for offset in offsets {
            try local.seek(toOffset: UInt64(offset))
            let localData = try local.read(upToCount: Int(sampleSize)) ?? Data()
            let remoteData = try await session.withFile(filePath: remotePath, flags: .read) { file in
                var buffer = try await file.read(from: UInt64(offset), length: UInt32(sampleSize))
                return buffer.readData(length: buffer.readableBytes) ?? Data()
            }
            guard localData == remoteData else { return false }
        }
        return true
    }

    private func replaceRemoteFile(session: SFTPClient, partialPath: String, destination: String) async throws {
        let destinationExists = (try? await session.getAttributes(at: destination)) != nil
        let backupPath = Self.partialRemotePath(for: destination) + ".backup-\(UUID().uuidString)"
        if destinationExists {
            try await session.rename(at: destination, to: backupPath)
            let backupExists = (try? await session.getAttributes(at: backupPath)) != nil
            let originalStillExists = (try? await session.getAttributes(at: destination)) != nil
            guard backupExists, !originalStillExists else {
                throw AppFailure.commandFailed("SFTP 无法安全备份原目标文件；断点文件已保留。")
            }
        }

        try await session.rename(at: partialPath, to: destination)
        let replacementExists = (try? await session.getAttributes(at: destination)) != nil
        let partialStillExists = (try? await session.getAttributes(at: partialPath)) != nil
        guard replacementExists, !partialStillExists else {
            if destinationExists {
                try? await session.rename(at: backupPath, to: destination)
            }
            throw AppFailure.commandFailed("SFTP 数据已上传，但服务器无法安全替换目标文件；原文件或备份已保留。")
        }
        if destinationExists { try? await session.remove(at: backupPath) }
    }

    private func ensureRemoteDirectory(_ path: String) async throws {
        let session = try activeSFTP()
        do {
            let attributes = try await session.getAttributes(at: path)
            guard (attributes.permissions ?? 0) & 0o170000 == 0o040000 else {
                throw AppFailure.commandFailed("远程路径已存在但不是文件夹：\(path)")
            }
        } catch let error as AppFailure { throw error } catch { try await session.createDirectory(atPath: path) }
    }

    private func listViaShell(_ path: String) async throws -> [RemoteItem] {
        // Appending `/.` follows directory symlinks such as `/tmp` on iOS instead of listing the link itself.
        let text = try await executeRemote("LC_ALL=C ls -lan \(Self.shellQuote(path))/. ")
        return RemoteListingParser.parsePOSIXListing(text, directory: path)
    }

    private func executeRemote(_ command: String, maxResponseSize: Int = 8 * 1024 * 1024) async throws -> String {
        do {
            var output = try await activeSSHClient().executeCommand(command, maxResponseSize: maxResponseSize)
            return output.readString(length: output.readableBytes) ?? ""
        } catch let error as TTYSTDError {
            // Citadel 在 stderr 有内容时会抛 TTYSTDError；把远端真实报错带给界面，便于定位 iOS 精简环境的问题。
            var buffer = error.message
            let text =
                buffer.readString(length: buffer.readableBytes)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw AppFailure.commandFailed(text.isEmpty ? "远程命令执行失败：\(command)" : "远程命令返回错误：\(text)")
        } catch let error as SSHClient.CommandFailed {
            throw AppFailure.commandFailed("远程命令执行失败（退出码 \(error.exitCode)）：\(command)")
        }
    }

    private func transferSCP(
        direction: TransferDirection, localPath: String, remotePath: String, isDirectory: Bool,
        log: @escaping @Sendable (String) -> Void, tracker: TransferProgressTracker
    ) async throws {
        guard #available(macOS 15.0, *) else {
            throw AppFailure.commandFailed("应用内 SCP 需要 macOS 15 或更高版本；macOS 14 可使用 SFTP。")
        }
        if direction == .upload {
            let localURL = URL(fileURLWithPath: localPath)
            let values = try localURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                log("已跳过本地符号链接：\(localURL.path)\n")
                return
            }
        }
        if isDirectory {
            if direction == .upload {
                _ = try await executeRemote("mkdir -p \(Self.shellQuote(remotePath))")
                let localURL = URL(fileURLWithPath: localPath)
                for child in try FileManager.default.contentsOfDirectory(
                    at: localURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                {
                    let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values.isSymbolicLink == true {
                        log("已跳过本地符号链接：\(child.path)\n")
                        continue
                    }
                    let directory = values.isDirectory == true
                    try await transferSCP(
                        direction: .upload, localPath: child.path,
                        remotePath: RemoteListingParser.join(remotePath, child.lastPathComponent), isDirectory: directory, log: log,
                        tracker: tracker)
                }
            } else {
                let localURL = URL(fileURLWithPath: localPath)
                try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
                for child in try await listViaShell(remotePath) {
                    try await transferSCP(
                        direction: .download, localPath: localURL.appendingPathComponent(child.name).path, remotePath: child.path,
                        isDirectory: child.isDirectory, log: log, tracker: tracker)
                }
            }
            return
        }
        if direction == .upload {
            try await uploadSCPFile(localURL: URL(fileURLWithPath: localPath), remotePath: remotePath, tracker: tracker)
        } else if let link = try await resolveRemoteSymlink(remotePath) {
            // scp -f 无法直接读取符号链接（not a regular file），先解析真实目标再传
            log("已解析符号链接：\(remotePath) -> \(link.path)\n")
            try await transferSCP(
                direction: .download, localPath: localPath, remotePath: link.path, isDirectory: link.isDirectory, log: log,
                tracker: tracker)
            return
        } else {
            try await downloadSCPFile(remotePath: remotePath, localURL: URL(fileURLWithPath: localPath), tracker: tracker)
        }
        log("SCP \(direction.rawValue)完成：\(URL(fileURLWithPath: localPath).lastPathComponent)\n")
    }

    /// 用 ls -ldn 判断远程路径是否为符号链接；是则返回解析后的绝对路径及目标类型。
    /// 不依赖 readlink（越狱 iOS 的精简引导里通常没有）。
    private func resolveRemoteSymlink(_ path: String) async throws -> (path: String, isDirectory: Bool)? {
        let text = try await executeRemote("LC_ALL=C ls -ldn \(Self.shellQuote(path))")
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard line.hasPrefix("l"), let arrow = line.range(of: " -> ") else { return nil }
        let rawTarget = String(line[arrow.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTarget.isEmpty else { return nil }
        let resolved =
            rawTarget.hasPrefix("/")
            ? rawTarget
            : RemoteListingParser.join(RemoteListingParser.parent(of: path), rawTarget)
        let probe = try await executeRemote("if [ -d \(Self.shellQuote(resolved)) ]; then echo d; fi")
        return (resolved, probe.contains("d"))
    }

    @available(macOS 15.0, *)
    private func uploadSCPFile(
        localURL: URL, remotePath: String, permissions: UInt32? = nil, tracker: TransferProgressTracker?
    ) async throws {
        let ssh = try activeSSHClient()
        let fileSize = try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        tracker?.beginFile(size: Int64(fileSize), resumedAt: 0)
        let source = try FileHandle(forReadingFrom: localURL)
        defer { try? source.close() }
        let parent = RemoteListingParser.parent(of: remotePath)
        let name = try Self.validatedRemoteName(URL(fileURLWithPath: remotePath).lastPathComponent)
        try await ssh.withExec("scp -t -- \(Self.shellQuote(parent))") { inbound, outbound in
            var reader = SCPReplyReader(output: inbound)
            try await reader.expectOK()
            let mode = String(format: "%04o", permissions ?? 0o644)
            try await outbound.write(ByteBuffer(string: "C\(mode) \(fileSize) \(name)\n"))
            try await reader.expectOK()
            while let data = try source.read(upToCount: 512 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                try await outbound.write(ByteBuffer(bytes: data))
                tracker?.advance(by: data.count)
            }
            try await outbound.write(ByteBuffer(bytes: [UInt8(0)]))
            try await reader.expectOK()
        }
    }

    @available(macOS 15.0, *)
    private func downloadSCPFile(remotePath: String, localURL: URL, tracker: TransferProgressTracker?) async throws {
        let ssh = try activeSSHClient()
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = localURL.deletingLastPathComponent().appendingPathComponent(
            ".\(localURL.lastPathComponent).spultra-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let destination = try FileHandle(forWritingTo: temporary)
        do {
            try await ssh.withExec("scp -f -- \(Self.shellQuote(remotePath))") { inbound, outbound in
                var reader = SCPReplyReader(output: inbound)
                try await outbound.write(ByteBuffer(bytes: [UInt8(0)]))
                let header = try await reader.readLine()
                guard header.first == "C" else { throw AppFailure.commandFailed("SCP 返回了无效文件头：\(header)") }
                let pieces = header.dropFirst().split(separator: " ", maxSplits: 2)
                guard pieces.count == 3, let size = Int(pieces[1]), size >= 0 else {
                    throw AppFailure.commandFailed("SCP 文件头无法解析。")
                }
                tracker?.beginFile(size: Int64(size), resumedAt: 0)
                try await outbound.write(ByteBuffer(bytes: [UInt8(0)]))
                try await reader.copyExactly(size, to: destination) { count in tracker?.advance(by: count) }
                try await reader.expectOK()
                try await outbound.write(ByteBuffer(bytes: [UInt8(0)]))
            }
            try destination.synchronize()
            try destination.close()
            if FileManager.default.fileExists(atPath: localURL.path) {
                _ = try FileManager.default.replaceItemAt(localURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: localURL)
            }
        } catch {
            try? destination.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func permissionString(_ mode: UInt32) -> String {
        let type: Character = (mode & 0o170000) == 0o040000 ? "d" : ((mode & 0o170000) == 0o120000 ? "l" : "-")
        let masks: [(UInt32, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"), (0o040, "r"), (0o020, "w"), (0o010, "x"), (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ]
        return String(type) + masks.map { mode & $0.0 != 0 ? String($0.1) : "-" }.joined()
    }
}

@available(macOS 15.0, *)
private struct SCPReplyReader {
    private var iterator: TTYOutput.AsyncIterator
    private var pending = ByteBuffer()
    init(output: TTYOutput) { iterator = output.makeAsyncIterator() }

    mutating func expectOK() async throws {
        let code = try await readByte()
        guard code == 0 else { throw AppFailure.commandFailed("SCP 错误：\(try await readLine())") }
    }

    mutating func readLine() async throws -> String {
        var bytes: [UInt8] = []
        while true {
            let byte = try await readByte()
            if byte == 10 { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
    }

    mutating func copyExactly(_ count: Int, to destination: FileHandle, progress: (Int) -> Void = { _ in }) async throws {
        var remaining = count
        while remaining > 0 {
            try Task.checkCancellation()
            try await fillPendingIfNeeded()
            let length = min(remaining, pending.readableBytes, 512 * 1024)
            guard length > 0, let data = pending.readData(length: length) else {
                throw AppFailure.commandFailed("SCP 连接提前结束。")
            }
            try destination.write(contentsOf: data)
            remaining -= data.count
            progress(data.count)
        }
    }

    private mutating func readByte() async throws -> UInt8 {
        try await fillPendingIfNeeded()
        guard let byte: UInt8 = pending.readInteger() else { throw AppFailure.commandFailed("SCP 连接提前结束。") }
        return byte
    }

    private mutating func fillPendingIfNeeded() async throws {
        while pending.readableBytes == 0 {
            guard let output = try await iterator.next() else { throw AppFailure.commandFailed("SCP 连接提前结束。") }
            switch output {
            case .stdout(var buffer): pending.writeBuffer(&buffer)
            case .stderr(var buffer): throw AppFailure.commandFailed(buffer.readString(length: buffer.readableBytes) ?? "未知 SCP 错误")
            }
        }
    }
}
