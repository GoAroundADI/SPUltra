import Citadel
import Foundation
import NIOCore
import NIOSSH

final class MCPHostKeyStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base =
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.fileURL = base.appendingPathComponent("SP Ultra", isDirectory: true).appendingPathComponent("mcp_host_keys.json")
        }
    }

    func validate(endpoint: String, key: String) throws {
        try lock.withLock {
            var keys = try loadUnlocked()
            if let existing = keys[endpoint], existing != key {
                throw MCPError("主机 \(endpoint) 的密钥与 MCP 记录不一致。确认设备或 SSH 服务确实更换过后，调用 reset_host_key(host, port) 清除旧记录再重新连接。")
            }
            if keys[endpoint] == nil {
                keys[endpoint] = key
                try saveUnlocked(keys)
            }
        }
    }

    /// 清除某个 endpoint 的 TOFU 记录，供确认主机确实更换后重新记录。
    func reset(endpoint: String, recoverCorruptStore: Bool) throws -> (removed: Bool, backup: URL?) {
        try lock.withLock {
            let keys: [String: String]
            do {
                keys = try loadUnlocked()
            } catch {
                guard recoverCorruptStore else { throw error }
                let backup = try backupCorruptStoreUnlocked()
                try saveUnlocked([:])
                return (true, backup)
            }
            var updated = keys
            guard updated.removeValue(forKey: endpoint) != nil else { return (false, nil) }
            try saveUnlocked(updated)
            return (true, nil)
        }
    }

    private func backupCorruptStoreUnlocked() throws -> URL? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
        try FileManager.default.moveItem(at: fileURL, to: backup)
        return backup
    }

    private func loadUnlocked() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw MCPError(
                "MCP 主机指纹数据库损坏或无法读取：\(fileURL.path)。为保护连接安全，不会自动忽略已有信任记录；请先备份并修复或移走该文件。")
        }
    }

    private func saveUnlocked(_ keys: [String: String]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(keys).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

private final class MCPHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let endpoint: String
    let store: MCPHostKeyStore
    init(endpoint: String, store: MCPHostKeyStore) {
        self.endpoint = endpoint
        self.store = store
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        do {
            try store.validate(endpoint: endpoint, key: String(openSSHPublicKey: hostKey))
            validationCompletePromise.succeed(())
        } catch { validationCompletePromise.fail(error) }
    }
}

private struct MCPError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private actor SSHSession {
    private let hostKeys = MCPHostKeyStore()
    private var client: SSHClient?
    private var sftp: SFTPClient?
    private var endpoint: String?
    private var protocolName = "SFTP"

    func connect(arguments: [String: Any]) async throws -> String {
        await disconnect()
        let host = try string("host", in: arguments)
        let username = try string("username", in: arguments)
        let password = try string("password", in: arguments)
        let port = arguments["port"] as? Int ?? 22
        guard (1...65_535).contains(port) else { throw MCPError("port 必须在 1–65535 之间。") }
        protocolName = (arguments["protocol"] as? String ?? "SFTP").uppercased()
        guard protocolName == "SFTP" || protocolName == "SCP" else { throw MCPError("protocol 只能是 SFTP 或 SCP。") }

        let validator = MCPHostKeyValidator(endpoint: "\(host):\(port)", store: hostKeys)
        var settings = SSHClientSettings(
            host: host,
            port: port,
            authenticationMethod: { .passwordBased(username: username, password: password) },
            hostKeyValidator: .custom(validator)
        )
        settings.connectTimeout = .seconds(15)
        if protocolName == "SCP" { settings.algorithms = SSHAlgorithms.all }
        let connection: SSHClient
        do {
            connection = try await SSHClient.connect(to: settings)
        } catch let error as NIOSSHError {
            throw MCPError(Self.describeHandshakeError(error))
        } catch SSHClientError.allAuthenticationOptionsFailed {
            throw MCPError("SSH 认证失败：请检查用户名和密码。")
        } catch CitadelError.unauthorized {
            throw MCPError("SSH 认证被拒绝：请检查用户名、密码或主机访问限制。")
        }
        do {
            if protocolName == "SFTP" {
                let subsystem = try await connection.openSFTP()
                _ = try await subsystem.getRealPath(atPath: ".")
                sftp = subsystem
            } else {
                var output = try await connection.executeCommand("pwd", maxResponseSize: 65_536)
                _ = output.readString(length: output.readableBytes)
            }
            client = connection
            endpoint = "\(username)@\(host):\(port)"
            return "已通过应用内 SwiftNIO SSH 连接 \(endpoint!)（\(protocolName)）。"
        } catch {
            try? await connection.close()
            throw error
        }
    }

    func list(path: String) async throws -> String {
        guard client != nil else { throw MCPError("尚未连接；请先调用 connect。") }
        if protocolName == "SFTP" {
            guard let sftp else { throw MCPError("SFTP 子系统未建立。") }
            let responses = try await sftp.listDirectory(atPath: path)
            let rows = responses.flatMap(\.components).filter { $0.filename != "." && $0.filename != ".." }.map { component in
                let permissions = component.attributes.permissions ?? 0
                let kind = permissions & 0o170000 == 0o040000 ? "directory" : "file"
                return ["name": component.filename, "type": kind, "size": component.attributes.size ?? 0] as [String: Any]
            }
            return try jsonText(rows)
        }
        let output = try await execute("LC_ALL=C ls -lan \(shellQuote(path))/. ")
        return output
    }

    func resetHostKey(arguments: [String: Any]) throws -> String {
        let host = try string("host", in: arguments)
        let port = arguments["port"] as? Int ?? 22
        guard (1...65_535).contains(port) else { throw MCPError("port 必须在 1–65535 之间。") }
        let endpoint = "\(host):\(port)"
        let confirm = arguments["confirm"] as? Bool == true
        guard confirm else { throw MCPError("这是安全敏感操作；确认主机确实已更换后，请传入 confirm: true。") }
        let result = try hostKeys.reset(endpoint: endpoint, recoverCorruptStore: true)
        if let backup = result.backup {
            return "指纹库损坏，已备份到 \(backup.path) 并重建为空库；下次 connect 会重新记录主机密钥。"
        }
        return result.removed
            ? "已清除 \(endpoint) 的 MCP 主机密钥记录；下次 connect 会重新记录。"
            : "没有找到 \(endpoint) 的 MCP 主机密钥记录。"
    }

    func status() -> String {
        endpoint.map { "connected: \($0) (\(protocolName))" } ?? "disconnected"
    }

    func disconnect() async {
        let oldSFTP = sftp
        let oldClient = client
        sftp = nil
        client = nil
        endpoint = nil
        try? await oldSFTP?.close()
        try? await oldClient?.close()
    }

    private func execute(_ command: String) async throws -> String {
        guard let client else { throw MCPError("尚未连接。") }
        do {
            var output = try await client.executeCommand(command, maxResponseSize: 8 * 1024 * 1024)
            return output.readString(length: output.readableBytes) ?? ""
        } catch let error as TTYSTDError {
            var buffer = error.message
            let text =
                buffer.readString(length: buffer.readableBytes)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw MCPError(text.isEmpty ? "远程命令执行失败。" : "远程命令返回错误：\(text)")
        } catch let error as SSHClient.CommandFailed {
            throw MCPError("远程命令执行失败（退出码 \(error.exitCode)）。")
        }
    }

    private static func describeHandshakeError(_ error: NIOSSHError) -> String {
        switch error.type {
        case .keyExchangeNegotiationFailure:
            return "SSH 算法协商失败；旧设备或越狱 iOS 请使用 SCP 模式，应用会自动启用兼容算法。"
        case .invalidHostKeyForKeyExchange:
            return "主机密钥与协商结果不一致，请稍后重试。"
        case .tcpShutdown:
            return "SSH 在握手阶段被远端关闭，请稍后重试。"
        case .unsupportedVersion:
            return "远端 SSH 版本过旧；请使用 SCP 模式自动启用兼容算法。"
        default:
            return "SSH 握手失败：\(error.type)。"
        }
    }

    private func string(_ name: String, in arguments: [String: Any]) throws -> String {
        guard let value = arguments[name] as? String, !value.isEmpty else { throw MCPError("缺少参数：\(name)") }
        return value
    }

    private func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func jsonText(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

private actor MCPServer {
    let session = SSHSession()

    func handle(_ request: [String: Any]) async -> [String: Any]? {
        guard let method = request["method"] as? String else { return error(id: request["id"], code: -32600, message: "Invalid Request") }
        guard let id = request["id"] else { return nil }
        do {
            switch method {
            case "initialize":
                return success(
                    id: id,
                    result: [
                        "protocolVersion": "2024-11-05",
                        "capabilities": ["tools": ["listChanged": false]],
                        "serverInfo": ["name": "SP Ultra", "version": "1.0.0"],
                    ])
            case "ping": return success(id: id, result: [:])
            case "tools/list": return success(id: id, result: ["tools": toolDefinitions])
            case "tools/call":
                let params = request["params"] as? [String: Any] ?? [:]
                let name = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                let text: String
                switch name {
                case "connect": text = try await session.connect(arguments: arguments)
                case "list_directory": text = try await session.list(path: arguments["path"] as? String ?? ".")
                case "connection_status": text = await session.status()
                case "disconnect":
                    await session.disconnect()
                    text = "已断开连接。"
                case "reset_host_key": text = try await session.resetHostKey(arguments: arguments)
                default: throw MCPError("未知工具：\(name)")
                }
                return success(id: id, result: ["content": [["type": "text", "text": text]], "isError": false])
            default: return error(id: id, code: -32601, message: "Method not found")
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            if method == "tools/call" {
                return success(id: id, result: ["content": [["type": "text", "text": message]], "isError": true])
            }
            return self.error(id: id, code: -32603, message: message)
        }
    }

    private var toolDefinitions: [[String: Any]] {
        [
            [
                "name": "connect", "description": "使用 SP Ultra 内嵌 SSH 协议栈连接 SFTP 或 SCP 主机。密码只在本次 MCP 进程内存中使用。",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "host": ["type": "string"], "port": ["type": "integer", "default": 22],
                        "username": ["type": "string"], "password": ["type": "string"],
                        "protocol": ["type": "string", "enum": ["SFTP", "SCP"], "default": "SFTP"],
                    ], "required": ["host", "username", "password"],
                ],
            ],
            [
                "name": "list_directory", "description": "列出当前已连接主机的远程目录。",
                "inputSchema": [
                    "type": "object", "properties": ["path": ["type": "string", "default": "."]],
                ],
            ],
            ["name": "connection_status", "description": "读取 MCP SSH 会话状态。", "inputSchema": ["type": "object", "properties": [:]]],
            ["name": "disconnect", "description": "断开 MCP SSH 会话。", "inputSchema": ["type": "object", "properties": [:]]],
            [
                "name": "reset_host_key", "description": "清除某个主机的 MCP TOFU 主机密钥记录。仅在确认设备或 SSH 服务确实更换后使用；下次 connect 会重新记录。",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "host": ["type": "string"], "port": ["type": "integer", "default": 22],
                        "confirm": ["type": "boolean", "description": "确认已核实主机变更或需要恢复损坏的指纹库。"],
                    ], "required": ["host", "confirm"],
                ],
            ],
        ]
    }

    private func success(id: Any, result: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
    private func error(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }
}

@main
private enum SPUltraMCPMain {
    static func main() async {
        let server = MCPServer()
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                let data = line.data(using: .utf8),
                let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let response = await server.handle(request),
                let output = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
            {
                FileHandle.standardOutput.write(output)
                FileHandle.standardOutput.write(Data([0x0A]))
            }
        }
        await server.session.disconnect()
    }
}
