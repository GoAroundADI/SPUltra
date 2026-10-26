import XCTest

@testable import SPUltra

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [TransferProgressUpdate] = []

    func record(_ update: TransferProgressUpdate) {
        lock.withLock { updates.append(update) }
    }

    var latest: TransferProgressUpdate? { lock.withLock { updates.last } }
}

private final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func append(_ message: String) { lock.withLock { messages.append(message) } }
    var text: String { lock.withLock { messages.joined() } }
}

final class NativeSSHIntegrationTests: XCTestCase {
    /// 集成测试使用的远程临时目录；不同服务器可设置 SPULTRA_TEST_REMOTE_DIR 覆盖。
    private var remoteDirectory: String {
        var value = ProcessInfo.processInfo.environment["SPULTRA_TEST_REMOTE_DIR"] ?? "/tmp"
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value.isEmpty ? "/tmp" : value
    }

    func testNativeSCPRoundTripWhenEnvironmentIsConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["SPULTRA_TEST_HOST"],
            let username = environment["SPULTRA_TEST_USER"],
            let password = environment["SPULTRA_TEST_PASSWORD"]
        else {
            throw XCTSkip("Set SPULTRA_TEST_HOST, SPULTRA_TEST_USER and SPULTRA_TEST_PASSWORD for the opt-in integration test.")
        }
        let port = Int(environment["SPULTRA_TEST_PORT"] ?? "22") ?? 22
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SPUltraIntegration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let hostKeys = HostKeyStore(fileURL: scratch.appendingPathComponent("host_keys.json"))
        let service = RemoteFileService(hostKeyStore: hostKeys)
        var profile = SessionProfile(name: "Integration", host: host, port: port, username: username, protocolKind: .scp)
        profile.authentication = .password
        profile.initialRemotePath = remoteDirectory
        let configuration = SSHConfiguration(profile: profile, password: password, connectTimeout: 10)
        try await service.test(configuration, log: { _ in })

        let marker = UUID().uuidString
        var payload = Data(marker.utf8)
        payload.append(Data(repeating: 0xA5, count: 1_200_123))
        let localSource = scratch.appendingPathComponent("source.txt")
        let localDestination = scratch.appendingPathComponent("download.txt")
        let remotePath = "\(remoteDirectory)/spultra-\(UUID().uuidString).txt"
        let localFolder = scratch.appendingPathComponent("symlink-folder", isDirectory: true)
        let localRealFile = localFolder.appendingPathComponent("real.txt")
        let localLink = localFolder.appendingPathComponent("link.txt")
        let remoteFolderPath = "\(remoteDirectory)/spultra-links-\(UUID().uuidString)"
        try payload.write(to: localSource)
        try FileManager.default.createDirectory(at: localFolder, withIntermediateDirectories: true)
        try Data("real".utf8).write(to: localRealFile)
        try FileManager.default.createSymbolicLink(at: localLink, withDestinationURL: localRealFile)
        let remote = RemoteItem(
            path: remotePath, name: URL(fileURLWithPath: remotePath).lastPathComponent,
            isDirectory: false, isSymbolicLink: false, size: 0,
            modifiedText: "", permissions: "")
        let remoteFolder = RemoteItem(
            path: remoteFolderPath, name: URL(fileURLWithPath: remoteFolderPath).lastPathComponent,
            isDirectory: true, isSymbolicLink: false, size: 0,
            modifiedText: "", permissions: "")
        do {
            // Clear files left by interrupted earlier test runs, then verify a full upload/download/cleanup cycle.
            for stale in try await service.list(remoteDirectory, config: configuration, log: { _ in })
            where stale.name.hasPrefix("spultra-") && stale.name.hasSuffix(".txt") {
                try? await service.remove(stale, config: configuration, log: { _ in })
            }
            try await service.transfer(
                direction: .upload, localPath: localSource.path, remotePath: remotePath,
                isDirectory: false, config: configuration, log: { _ in })
            let remoteItems = try await service.list(remoteDirectory, config: configuration, log: { _ in })
            XCTAssertTrue(remoteItems.contains { $0.path == remotePath })
            try await service.transfer(
                direction: .download, localPath: localDestination.path, remotePath: remotePath,
                isDirectory: false, config: configuration, log: { _ in })
            XCTAssertEqual(try Data(contentsOf: localDestination), payload)
            let log = LogRecorder()
            try await service.transfer(
                direction: .upload, localPath: localFolder.path, remotePath: remoteFolderPath,
                isDirectory: true, config: configuration, log: { log.append($0) })
            let uploadedChildren = try await service.list(remoteFolderPath, config: configuration, log: { _ in })
            XCTAssertTrue(uploadedChildren.contains { $0.name == "real.txt" })
            XCTAssertFalse(uploadedChildren.contains { $0.name == "link.txt" })
            XCTAssertTrue(log.text.contains("已跳过本地符号链接"))
            try await service.remove(remote, config: configuration, log: { _ in })
            try await service.remove(remoteFolder, config: configuration, log: { _ in })
            let afterCleanup = try await service.list(remoteDirectory, config: configuration, log: { _ in })
            XCTAssertFalse(afterCleanup.contains { $0.path == remotePath })
            XCTAssertFalse(afterCleanup.contains { $0.name.hasPrefix("spultra-") && $0.name.hasSuffix(".txt") })
            await service.disconnect()
        } catch {
            try? await service.remove(remote, config: configuration, log: { _ in })
            try? await service.remove(remoteFolder, config: configuration, log: { _ in })
            await service.disconnect()
            throw error
        }
    }

    func testNativeSCPCreateFileAndFolderWhenEnvironmentIsConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["SPULTRA_TEST_HOST"],
            let username = environment["SPULTRA_TEST_USER"],
            let password = environment["SPULTRA_TEST_PASSWORD"]
        else {
            throw XCTSkip("Set SPULTRA_TEST_HOST, SPULTRA_TEST_USER and SPULTRA_TEST_PASSWORD for the opt-in integration test.")
        }
        let port = Int(environment["SPULTRA_TEST_PORT"] ?? "22") ?? 22
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SPUltraCreate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let service = RemoteFileService(hostKeyStore: HostKeyStore(fileURL: scratch.appendingPathComponent("host_keys.json")))
        var profile = SessionProfile(name: "Integration", host: host, port: port, username: username, protocolKind: .scp)
        profile.authentication = .password
        profile.initialRemotePath = remoteDirectory
        let configuration = SSHConfiguration(profile: profile, password: password, connectTimeout: 10)
        try await service.test(configuration, log: { _ in })

        let token = String(UUID().uuidString.prefix(8))
        let folder = "\(remoteDirectory)/spultra-新建文件夹-\(token)"
        let nestedFolder = "\(folder)/嵌套目录"
        let nestedFile = "\(nestedFolder)/内容.txt"
        let file = "\(remoteDirectory)/spultra-新建文件-\(token).txt"
        let folderItem = RemoteItem(
            path: folder, name: URL(fileURLWithPath: folder).lastPathComponent,
            isDirectory: true, isSymbolicLink: false, size: 0, modifiedText: "", permissions: "")
        let fileItem = RemoteItem(
            path: file, name: URL(fileURLWithPath: file).lastPathComponent,
            isDirectory: false, isSymbolicLink: false, size: 0, modifiedText: "", permissions: "")
        do {
            try await service.createDirectory(folder, config: configuration, log: { _ in })
            try await service.createDirectory(nestedFolder, config: configuration, log: { _ in })
            try await service.createFile(nestedFile, config: configuration, log: { _ in })
            try await service.createFile(file, config: configuration, log: { _ in })
            let items = try await service.list(remoteDirectory, config: configuration, log: { _ in })
            XCTAssertTrue(items.contains { $0.path == folder && $0.isDirectory })
            XCTAssertTrue(items.contains { $0.path == file && !$0.isDirectory })
            XCTAssertEqual(items.first { $0.path == file }?.size, 0)
            try await service.remove(folderItem, config: configuration, log: { _ in })
            try await service.remove(fileItem, config: configuration, log: { _ in })
            let after = try await service.list(remoteDirectory, config: configuration, log: { _ in })
            XCTAssertFalse(after.contains { $0.path == folder || $0.path == file })
            await service.disconnect()
        } catch {
            try? await service.remove(folderItem, config: configuration, log: { _ in })
            try? await service.remove(fileItem, config: configuration, log: { _ in })
            await service.disconnect()
            throw error
        }
    }

    func testNativeSFTPCreateAndRoundTripWhenEnvironmentIsConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SPULTRA_TEST_SFTP"] == "1" else {
            throw XCTSkip("Set SPULTRA_TEST_SFTP=1 only when the target exposes an SFTP subsystem.")
        }
        guard let host = environment["SPULTRA_TEST_HOST"],
            let username = environment["SPULTRA_TEST_USER"],
            let password = environment["SPULTRA_TEST_PASSWORD"]
        else {
            throw XCTSkip("Set SPULTRA_TEST_HOST, SPULTRA_TEST_USER and SPULTRA_TEST_PASSWORD for the opt-in integration test.")
        }
        let port = Int(environment["SPULTRA_TEST_PORT"] ?? "22") ?? 22
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("SPUltraSFTP-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let service = RemoteFileService(hostKeyStore: HostKeyStore(fileURL: scratch.appendingPathComponent("host_keys.json")))
        var profile = SessionProfile(name: "Integration-SFTP", host: host, port: port, username: username, protocolKind: .sftp)
        profile.authentication = .password
        profile.initialRemotePath = remoteDirectory
        let configuration = SSHConfiguration(profile: profile, password: password, connectTimeout: 10)
        try await service.test(configuration, log: { _ in })

        let token = String(UUID().uuidString.prefix(8))
        let folder = "\(remoteDirectory)/spultra-sftp-文件夹-\(token)"
        let nestedFolder = "\(folder)/嵌套目录"
        let nestedFile = "\(nestedFolder)/内容.txt"
        let emptyFile = "\(remoteDirectory)/spultra-sftp-空文件-\(token).txt"
        let uploadFile = "\(remoteDirectory)/spultra-sftp-上传-\(token).txt"
        let renamedFile = "\(remoteDirectory)/spultra-sftp-已重命名-\(token).txt"
        let localSource = scratch.appendingPathComponent("sftp-source.txt")
        let localDownload = scratch.appendingPathComponent("sftp-download.txt")
        let payload = Data("SP Ultra SFTP \(token)".utf8)
        try payload.write(to: localSource)

        let folderItem = RemoteItem(
            path: folder, name: URL(fileURLWithPath: folder).lastPathComponent,
            isDirectory: true, isSymbolicLink: false, size: 0, modifiedText: "", permissions: "")
        let emptyItem = RemoteItem(
            path: emptyFile, name: URL(fileURLWithPath: emptyFile).lastPathComponent,
            isDirectory: false, isSymbolicLink: false, size: 0, modifiedText: "", permissions: "")
        let uploadItem = RemoteItem(
            path: uploadFile, name: URL(fileURLWithPath: uploadFile).lastPathComponent,
            isDirectory: false, isSymbolicLink: false, size: 0, modifiedText: "", permissions: "")
        let renamedItem = RemoteItem(
            path: renamedFile, name: URL(fileURLWithPath: renamedFile).lastPathComponent,
            isDirectory: false, isSymbolicLink: false, size: 0, modifiedText: "", permissions: "")
        do {
            try await service.createDirectory(folder, config: configuration, log: { _ in })
            try await service.createDirectory(nestedFolder, config: configuration, log: { _ in })
            try await service.createFile(nestedFile, config: configuration, log: { _ in })
            try await service.createFile(emptyFile, config: configuration, log: { _ in })
            let resumePrefix = String(decoding: payload.prefix(5), as: UTF8.self)
            try await service.writeTextFile(
                path: RemoteFileService.partialRemotePath(for: uploadFile), text: resumePrefix,
                config: configuration, log: { _ in })
            let uploadProgress = ProgressRecorder()
            try await service.transfer(
                direction: .upload, localPath: localSource.path, remotePath: uploadFile,
                isDirectory: false, config: configuration, expectedBytes: Int64(payload.count), log: { _ in },
                progress: { update in uploadProgress.record(update) })
            XCTAssertEqual(uploadProgress.latest?.transferredBytes, Int64(payload.count))
            XCTAssertEqual(uploadProgress.latest?.totalBytes, Int64(payload.count))
            XCTAssertEqual(uploadProgress.latest?.resumedBytes, 5)
            try Data(payload.prefix(7)).write(to: RemoteFileService.partialLocalURL(for: localDownload))
            let downloadProgress = ProgressRecorder()
            try await service.transfer(
                direction: .download, localPath: localDownload.path, remotePath: uploadFile,
                isDirectory: false, config: configuration, expectedBytes: Int64(payload.count), log: { _ in },
                progress: { update in downloadProgress.record(update) })
            XCTAssertEqual(downloadProgress.latest?.resumedBytes, 7)
            XCTAssertEqual(try Data(contentsOf: localDownload), payload)

            let items = try await service.list(remoteDirectory, config: configuration, log: { _ in })
            XCTAssertTrue(items.contains { $0.path == folder && $0.isDirectory })
            XCTAssertTrue(items.contains { $0.path == emptyFile && !$0.isDirectory && $0.size == 0 })
            XCTAssertTrue(items.contains { $0.path == uploadFile && $0.size == Int64(payload.count) })

            try await service.changePermissions(uploadItem, modeText: "0600", config: configuration, log: { _ in })
            let originalText = try await service.readTextFile(uploadItem, config: configuration)
            XCTAssertEqual(originalText, String(data: payload, encoding: .utf8))
            let editedText = "SP Ultra online edit \(token)\n"
            try await service.writeTextFile(path: uploadFile, text: editedText, config: configuration, log: { _ in })
            let savedText = try await service.readTextFile(uploadItem, config: configuration)
            XCTAssertEqual(savedText, editedText)
            _ = try await service.rename(uploadItem, to: renamedItem.name, config: configuration, log: { _ in })
            let renamedItems = try await service.list(remoteDirectory, config: configuration, log: { _ in })
            XCTAssertTrue(renamedItems.contains { $0.path == renamedFile && $0.permissions.hasSuffix("rw-------") })
            XCTAssertFalse(renamedItems.contains { $0.path == uploadFile })

            try await service.remove(folderItem, config: configuration, log: { _ in })
            try await service.remove(emptyItem, config: configuration, log: { _ in })
            try await service.remove(renamedItem, config: configuration, log: { _ in })
            let after = try await service.list(remoteDirectory, config: configuration, log: { _ in })
            XCTAssertFalse(after.contains { $0.path == folder || $0.path == emptyFile || $0.path == uploadFile || $0.path == renamedFile })
            await service.disconnect()
        } catch {
            try? await service.remove(folderItem, config: configuration, log: { _ in })
            try? await service.remove(emptyItem, config: configuration, log: { _ in })
            try? await service.remove(uploadItem, config: configuration, log: { _ in })
            try? await service.remove(renamedItem, config: configuration, log: { _ in })
            await service.disconnect()
            throw error
        }
    }

    func testNativeSCPRapidReconnectWhenEnvironmentIsConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["SPULTRA_TEST_HOST"],
            let username = environment["SPULTRA_TEST_USER"],
            let password = environment["SPULTRA_TEST_PASSWORD"]
        else {
            throw XCTSkip("Set SPULTRA_TEST_HOST, SPULTRA_TEST_USER and SPULTRA_TEST_PASSWORD for the opt-in integration test.")
        }
        let port = Int(environment["SPULTRA_TEST_PORT"] ?? "22") ?? 22
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SPUltraReconnect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let service = RemoteFileService(hostKeyStore: HostKeyStore(fileURL: scratch.appendingPathComponent("host_keys.json")))
        var profile = SessionProfile(name: "Reconnect", host: host, port: port, username: username, protocolKind: .scp)
        profile.authentication = .password
        profile.initialRemotePath = remoteDirectory
        let configuration = SSHConfiguration(profile: profile, password: password, connectTimeout: 10)
        do {
            for attempt in 1...5 {
                try await service.test(configuration, log: { _ in })
                let items = try await service.list(remoteDirectory, config: configuration, log: { _ in })
                XCTAssertFalse(items.isEmpty, "attempt \(attempt) listing failed")
                await service.disconnect()
            }
        } catch {
            await service.disconnect()
            throw error
        }
    }
}
