import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// 应用内部拖拽远程文件时使用的自定义类型标识。
    static let spUltraRemoteItem = UTType(exportedAs: "com.spultra.remoteitem")
}

/// 拖拽远程文件/文件夹时随拖拽携带的轻量描述（仅应用内使用）。
struct RemoteDragItem: Codable, Transferable, Sendable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64

    init(item: RemoteItem) {
        path = item.path
        name = item.name
        isDirectory = item.isDirectory
        size = item.size
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .spUltraRemoteItem)
    }
}

enum TransferProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case sftp = "SFTP"
    case scp = "SCP"
    var id: String { rawValue }
}

enum AuthenticationMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic = "自动（密钥/密码）"
    case password = "密码"
    case publicKey = "私钥"
    var id: String { rawValue }
}

enum RemotePathFavorites {
    static let defaultsKey = "SPUltra.favoriteRemotePaths"

    static func load(defaults: UserDefaults = .standard) -> [String] {
        normalized(defaults.stringArray(forKey: defaultsKey) ?? ["/"])
    }

    static func save(_ paths: [String], defaults: UserDefaults = .standard) {
        defaults.set(normalized(paths), forKey: defaultsKey)
    }

    static func validated(_ value: String) throws -> String {
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path == "." || path.hasPrefix("/"), !path.contains("\n"), !path.contains("\r"), !path.contains("\0") else {
            throw AppFailure.validation("远程路径必须是 / 开头的绝对路径，或使用 . 表示登录目录。")
        }
        return path
    }

    private static func normalized(_ paths: [String]) -> [String] {
        var seen: Set<String> = ["/"]
        var result = ["/"]
        for raw in paths {
            guard let path = try? validated(raw), !seen.contains(path) else { continue }
            seen.insert(path)
            result.append(path)
        }
        return result
    }
}

struct SessionProfile: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name = "新建会话"
    var host = ""
    var port = 22
    var username = ""
    var protocolKind: TransferProtocol = .sftp
    var authentication: AuthenticationMethod = .automatic
    var privateKeyPath = ""
    var initialRemotePath = "/"
    var saveSession = true

    var destination: String { "\(username)@\(host)" }

    func validated() throws -> SessionProfile {
        var copy = self
        copy.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.initialRemotePath = initialRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.initialRemotePath.isEmpty { copy.initialRemotePath = "/" }
        guard !copy.host.isEmpty else { throw AppFailure.validation("请输入主机名或 IP 地址。") }
        guard !copy.username.isEmpty else { throw AppFailure.validation("请输入用户名。") }
        guard (1...65535).contains(copy.port) else { throw AppFailure.validation("端口必须在 1–65535 之间。") }
        if copy.authentication == .publicKey {
            guard !copy.privateKeyPath.isEmpty else { throw AppFailure.validation("请选择私钥文件。") }
            guard FileManager.default.fileExists(atPath: copy.privateKeyPath) else {
                throw AppFailure.validation("私钥文件不存在。")
            }
        }
        if copy.name.isEmpty { copy.name = copy.host }
        return copy
    }
}

struct FileItem: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let size: Int64
    let modifiedAt: Date?
    let permissions: String?

    static func parent(of url: URL) -> FileItem {
        FileItem(
            url: url.deletingLastPathComponent(), name: "..", isDirectory: true,
            isSymbolicLink: false, size: 0, modifiedAt: nil, permissions: nil)
    }
}

struct RemoteItem: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let size: Int64
    let modifiedText: String
    let permissions: String
}

struct RemoteRenameRequest: Identifiable, Sendable {
    let id = UUID()
    let item: RemoteItem
}

struct RemotePermissionsRequest: Identifiable, Sendable {
    let id = UUID()
    let item: RemoteItem
}

struct RemoteTextDocument: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let text: String
    let permissions: String
}

enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(String)
    case failed(String)

    var label: String {
        switch self {
        case .disconnected: return "未连接"
        case .connecting: return "正在连接…"
        case .connected(let host): return "已连接 · \(host)"
        case .failed: return "连接失败"
        }
    }
}

enum TransferDirection: String, Codable, Sendable {
    case upload = "上传"
    case download = "下载"
}

enum TransferStatus: String, Codable, Sendable {
    case queued = "等待"
    case running = "传输中"
    case completed = "完成"
    case failed = "失败"
    case cancelled = "已取消"
}

struct TransferJob: Identifiable, Sendable {
    let id: UUID
    let direction: TransferDirection
    let source: String
    let destination: String
    let displayName: String
    let isDirectory: Bool
    var totalBytes: Int64
    var transferredBytes: Int64 = 0
    var resumedBytes: Int64 = 0
    var bytesPerSecond: Double = 0
    var progress: Double = 0
    var status: TransferStatus = .queued
    var createdAt = Date()
    var startedAt: Date?
    var finishedAt: Date?
    var errorMessage: String?
}

struct TransferProgressUpdate: Sendable, Equatable {
    let transferredBytes: Int64
    let totalBytes: Int64
    let resumedBytes: Int64
}

enum AppFailure: LocalizedError, Equatable {
    case validation(String)
    case authentication(String)
    case commandFailed(String)
    case timedOut
    case cancelled
    case parsing(String)

    var errorDescription: String? {
        switch self {
        case .validation(let message), .authentication(let message), .commandFailed(let message), .parsing(let message): return message
        case .timedOut: return "操作超时。请检查网络、端口和防火墙。"
        case .cancelled: return "操作已取消。"
        }
    }
}

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let time = Date()
    let level: Level
    let message: String

    enum Level: String, Sendable {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }
}
