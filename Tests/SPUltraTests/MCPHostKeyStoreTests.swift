import Foundation
import XCTest

@testable import SPUltraMCP

final class MCPHostKeyStoreTests: XCTestCase {
    func testResetRequiresOptInToRecoverCorruptStore() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("mcp_host_keys.json")
        try Data("not-json".utf8).write(to: file)
        let store = MCPHostKeyStore(fileURL: file)

        XCTAssertThrowsError(try store.reset(endpoint: "phone:22", recoverCorruptStore: false))
        let result = try store.reset(endpoint: "phone:22", recoverCorruptStore: true)
        XCTAssertTrue(result.removed)
        XCTAssertNotNil(result.backup)
        try store.validate(endpoint: "phone:22", key: "ssh-ed25519 NEW")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.uint16Value, 0o600)
    }
}
