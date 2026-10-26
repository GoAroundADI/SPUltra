import XCTest

@testable import SPUltra

final class HostKeyStoreTests: XCTestCase {
    func testTrustOnFirstUseThenTrusted() throws {
        let (store, folder) = makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(try store.evaluate(endpoint: "phone:22", key: "ssh-ed25519 AAAA"), .firstUse)
        XCTAssertEqual(try store.evaluate(endpoint: "phone:22", key: "ssh-ed25519 AAAA"), .trusted)
    }

    func testChangedHostKeyRequiresExplicitReplacement() throws {
        let (store, folder) = makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try store.evaluate(endpoint: "127.0.0.1:22", key: "ssh-rsa OLD")
        XCTAssertEqual(
            try store.evaluate(endpoint: "127.0.0.1:22", key: "ssh-ed25519 NEW"),
            .changed(previous: "ssh-rsa OLD")
        )
        try store.replace(endpoint: "127.0.0.1:22", with: "ssh-ed25519 NEW")
        XCTAssertEqual(try store.evaluate(endpoint: "127.0.0.1:22", key: "ssh-ed25519 NEW"), .trusted)
    }

    func testEndpointIncludesPort() throws {
        let (store, folder) = makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(try store.evaluate(endpoint: "host:22", key: "key-a"), .firstUse)
        XCTAssertEqual(try store.evaluate(endpoint: "host:2222", key: "key-b"), .firstUse)
    }

    func testFingerprintIsStableAndHasOpenSSHPrefix() {
        let value = HostKeyConflict.fingerprint("ssh-ed25519 QUJD")
        XCTAssertTrue(value.hasPrefix("SHA256:"))
        XCTAssertEqual(value, HostKeyConflict.fingerprint("ssh-ed25519 QUJD"))
    }

    func testCorruptDatabaseFailsClosedAndIsNotOverwritten() throws {
        let (store, folder) = makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("host_keys.json")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: file)

        XCTAssertThrowsError(try store.evaluate(endpoint: "phone:22", key: "ssh-ed25519 NEW")) { error in
            XCTAssertTrue(error.localizedDescription.contains("主机指纹数据库损坏"))
        }
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    func testExplicitResetBacksUpCorruptDatabaseAndRestoresUse() throws {
        let (store, folder) = makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("host_keys.json")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: file)

        let backup = try XCTUnwrap(store.resetAllWithBackup())
        XCTAssertEqual(try Data(contentsOf: backup), corrupt)
        XCTAssertEqual(try store.evaluate(endpoint: "phone:22", key: "ssh-ed25519 NEW"), .firstUse)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.uint16Value, 0o600)
    }

    private func makeStore() -> (HostKeyStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (HostKeyStore(fileURL: folder.appendingPathComponent("host_keys.json")), folder)
    }
}
