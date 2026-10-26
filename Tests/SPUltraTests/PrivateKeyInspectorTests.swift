import Foundation
import XCTest

@testable import SPUltra

final class PrivateKeyInspectorTests: XCTestCase {
    func testDetectsEncryptedAndUnencryptedOpenSSHKeys() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let plain = folder.appendingPathComponent("plain")
        let encrypted = folder.appendingPathComponent("encrypted")
        try openSSHStub(cipher: "none").write(to: plain, atomically: true, encoding: .utf8)
        try openSSHStub(cipher: "aes256-ctr").write(to: encrypted, atomically: true, encoding: .utf8)

        XCTAssertFalse(try PrivateKeyInspector.requiresPassphrase(atPath: plain.path))
        XCTAssertTrue(try PrivateKeyInspector.requiresPassphrase(atPath: encrypted.path))
    }

    func testDetectsEncryptedPEMKey() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try "-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----\n".write(
            to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(try PrivateKeyInspector.requiresPassphrase(atPath: file.path))
    }

    private func openSSHStub(cipher: String) -> String {
        var data = Data("openssh-key-v1\0".utf8)
        let length = UInt32(cipher.utf8.count)
        data.append(contentsOf: [
            UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff), UInt8(length & 0xff),
        ])
        data.append(Data(cipher.utf8))
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(data.base64EncodedString())\n-----END OPENSSH PRIVATE KEY-----\n"
    }
}
