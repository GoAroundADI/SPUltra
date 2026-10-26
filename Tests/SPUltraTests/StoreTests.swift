import XCTest

@testable import SPUltra

final class StoreTests: XCTestCase {
    func testSessionStoreRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("sessions.json")
        let store = SessionStore(fileURL: file)
        let profile = SessionProfile(name: "Server", host: "host", port: 2222, username: "user")
        try store.save([profile])
        XCTAssertEqual(store.load(), [profile])
    }

    func testSessionStorePreservesRemotePathPresets() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("sessions.json")
        let store = SessionStore(fileURL: file)
        var rootProfile = SessionProfile(name: "Root", host: "host", port: 22, username: "root", protocolKind: .scp)
        rootProfile.initialRemotePath = "/"
        var loginProfile = SessionProfile(name: "Login", host: "host", port: 22, username: "root")
        loginProfile.initialRemotePath = "."
        try store.save([rootProfile, loginProfile])
        let loaded = store.load()
        XCTAssertEqual(loaded.map(\.initialRemotePath), ["/", "."])
        XCTAssertEqual(loaded.map(\.protocolKind), [.scp, .sftp])
    }

    func testCorruptSessionFileFailsClosed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("sessions.json")
        try Data("not-json".utf8).write(to: file)
        XCTAssertEqual(SessionStore(fileURL: file).load(), [])
    }
}
