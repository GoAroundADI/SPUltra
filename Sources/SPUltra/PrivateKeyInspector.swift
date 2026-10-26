import Foundation

enum PrivateKeyInspector {
    static func requiresPassphrase(atPath path: String) throws -> Bool {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        if text.contains("BEGIN ENCRYPTED PRIVATE KEY") || text.uppercased().contains("PROC-TYPE: 4,ENCRYPTED") {
            return true
        }
        guard text.contains("BEGIN OPENSSH PRIVATE KEY") else { return false }
        let payload =
            text.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let data = Data(base64Encoded: payload) else {
            throw AppFailure.validation("无法解析 OpenSSH 私钥格式。")
        }
        let magic = Data("openssh-key-v1\0".utf8)
        guard data.starts(with: magic) else { throw AppFailure.validation("无法识别 OpenSSH 私钥格式。") }
        var offset = magic.count
        let cipher = try readSSHString(from: data, offset: &offset)
        return String(decoding: cipher, as: UTF8.self) != "none"
    }

    private static func readSSHString(from data: Data, offset: inout Int) throws -> Data {
        guard offset + 4 <= data.count else { throw AppFailure.validation("OpenSSH 私钥内容不完整。") }
        let length = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += 4
        guard length <= Int.max, offset + Int(length) <= data.count else {
            throw AppFailure.validation("OpenSSH 私钥内容不完整。")
        }
        defer { offset += Int(length) }
        return data[offset..<(offset + Int(length))]
    }
}
