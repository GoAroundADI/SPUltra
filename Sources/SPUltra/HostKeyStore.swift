import CryptoKit
import Foundation
import NIOCore
import NIOSSH

struct HostKeyConflict: LocalizedError, Identifiable, Sendable {
    let id = UUID()
    let endpoint: String
    let previousKey: String
    let presentedKey: String

    var previousFingerprint: String { Self.fingerprint(previousKey) }
    var presentedFingerprint: String { Self.fingerprint(presentedKey) }
    var errorDescription: String? {
        "主机 \(endpoint) 的身份指纹发生变化。旧指纹：\(previousFingerprint)，新指纹：\(presentedFingerprint)。如果设备刚重装或 SSH 服务刚更换，可核对后信任新指纹。"
    }

    static func fingerprint(_ openSSHKey: String) -> String {
        let parts = openSSHKey.split(separator: " ")
        let bytes = parts.count > 1 ? Data(base64Encoded: String(parts[1])) ?? Data(openSSHKey.utf8) : Data(openSSHKey.utf8)
        return "SHA256:" + Data(SHA256.hash(data: bytes)).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

final class HostKeyStore: @unchecked Sendable {
    enum Decision: Equatable {
        case trusted, firstUse
        case changed(previous: String)
    }
    private let lock = NSLock()
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base =
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.fileURL = base.appendingPathComponent("SP Ultra", isDirectory: true).appendingPathComponent("host_keys.json")
        }
    }

    func evaluate(endpoint: String, key: String) throws -> Decision {
        lock.lock()
        defer { lock.unlock() }
        var keys = try loadUnlocked()
        if let previous = keys[endpoint] { return previous == key ? .trusted : .changed(previous: previous) }
        keys[endpoint] = key
        try saveUnlocked(keys)
        return .firstUse
    }

    func replace(endpoint: String, with key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var keys = try loadUnlocked()
        keys[endpoint] = key
        try saveUnlocked(keys)
    }

    /// 用户明确确认后重置整个 TOFU 数据库。原文件总是先改名备份，因此即使 JSON
    /// 已损坏也能恢复连接，同时仍保留取证与手工恢复所需的原始内容。
    @discardableResult
    func resetAllWithBackup() throws -> URL? {
        try lock.withLock {
            var backupURL: URL?
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let formatter = ISO8601DateFormatter()
                let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let candidate = fileURL.deletingPathExtension().appendingPathExtension("backup-\(stamp).json")
                try FileManager.default.moveItem(at: fileURL, to: candidate)
                backupURL = candidate
            }
            try saveUnlocked([:])
            return backupURL
        }
    }

    private func loadUnlocked() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw AppFailure.commandFailed(
                "主机指纹数据库损坏或无法读取：\(fileURL.path)。为保护连接安全，SP Ultra 不会自动忽略已有信任记录。请从“连接”菜单执行受控重置。")
        }
    }

    private func saveUnlocked(_ keys: [String: String]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(keys).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

final class ApplicationHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let endpoint: String
    private let store: HostKeyStore
    private let onFirstUse: @Sendable (String) -> Void

    init(endpoint: String, store: HostKeyStore, onFirstUse: @escaping @Sendable (String) -> Void) {
        self.endpoint = endpoint
        self.store = store
        self.onFirstUse = onFirstUse
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let encoded = String(openSSHPublicKey: hostKey)
        do {
            switch try store.evaluate(endpoint: endpoint, key: encoded) {
            case .trusted: validationCompletePromise.succeed(())
            case .firstUse:
                onFirstUse(HostKeyConflict.fingerprint(encoded))
                validationCompletePromise.succeed(())
            case .changed(let previous):
                validationCompletePromise.fail(HostKeyConflict(endpoint: endpoint, previousKey: previous, presentedKey: encoded))
            }
        } catch { validationCompletePromise.fail(error) }
    }
}
