import XCTest

@testable import SPUltra

private final class FakeCredentialStore: CredentialStoring {
    var storage: [UUID: String] = [:]

    func save(password: String, for id: UUID) throws { storage[id] = password }
    func password(for id: UUID) -> String? { storage[id] }
    func hasPassword(for id: UUID) -> Bool { storage[id] != nil }
    func delete(for id: UUID) { storage.removeValue(forKey: id) }
}

@MainActor
final class AppModelTests: XCTestCase {
    private func makeModel() throws -> (AppModel, SessionStore, FakeCredentialStore) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SPUltraAppModel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let store = SessionStore(fileURL: folder.appendingPathComponent("sessions.json"))
        let credentials = FakeCredentialStore()
        let model = AppModel(sessionStore: store, credentialStore: credentials, localPath: folder)
        return (model, store, credentials)
    }

    func testUpdateSessionPersistsEditsAndCredentialChanges() throws {
        let (model, store, credentials) = try makeModel()
        let session = SessionProfile(name: "Original", host: "example.com", port: 22, username: "root", protocolKind: .scp)
        credentials.storage[session.id] = "old-secret"

        try model.updateSession(session, newPassword: "", savePassword: true, hadStoredPassword: true)
        XCTAssertEqual(store.load(), [session])
        XCTAssertEqual(credentials.password(for: session.id), "old-secret")

        var edited = session
        edited.name = "Edited"
        edited.port = 2222
        edited.initialRemotePath = "/var/mobile"
        try model.updateSession(edited, newPassword: "new-secret", savePassword: true, hadStoredPassword: true)
        XCTAssertEqual(store.load(), [edited])
        XCTAssertEqual(credentials.password(for: session.id), "new-secret")

        var cleared = edited
        cleared.name = "Cleared"
        try model.updateSession(cleared, newPassword: "", savePassword: false, hadStoredPassword: true)
        XCTAssertEqual(store.load(), [cleared])
        XCTAssertNil(credentials.password(for: session.id))
    }

    func testConnectSavedWithoutKeychainPasswordShowsPrompt() throws {
        let (model, _, _) = try makeModel()
        let session = SessionProfile(name: "Phone", host: "127.0.0.1", port: 22, username: "root", protocolKind: .scp)
        model.connectSaved(session)

        XCTAssertEqual(model.passwordPromptSession?.id, session.id)
        XCTAssertEqual(model.connectionState, .disconnected)
        XCTAssertEqual(model.passwordPresence(for: session), false)
    }

    func testRepeatedConnectSavedDoesNotReplacePasswordPrompt() throws {
        let (model, _, _) = try makeModel()
        let session = SessionProfile(name: "Phone", host: "127.0.0.1", port: 22, username: "root", protocolKind: .scp)
        model.connectSaved(session)
        let firstPrompt = try XCTUnwrap(model.passwordPromptSession)

        model.connectSaved(session)

        XCTAssertEqual(model.passwordPromptSession, firstPrompt)
    }

    func testDeleteSessionRemovesCredentialAndSessionFile() throws {
        let (model, store, credentials) = try makeModel()
        let session = SessionProfile(name: "Doomed", host: "example.com", port: 22, username: "root")
        try model.updateSession(session, newPassword: "secret", savePassword: true, hadStoredPassword: false)
        XCTAssertEqual(credentials.password(for: session.id), "secret")

        model.deleteSession(session)
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertNil(credentials.password(for: session.id))
    }

    func testUpdateSessionRollsBackWhenPersistenceFails() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SPUltraAppModel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        // 让 SessionStore 的父目录变成一个普通文件，save 必然失败。
        let blocker = folder.appendingPathComponent("blocked")
        try Data("not-a-directory".utf8).write(to: blocker)
        let store = SessionStore(fileURL: blocker.appendingPathComponent("sessions.json"))
        let credentials = FakeCredentialStore()
        let model = AppModel(sessionStore: store, credentialStore: credentials, localPath: folder)

        let session = SessionProfile(name: "New", host: "example.com", port: 22, username: "root")
        XCTAssertThrowsError(try model.updateSession(session, newPassword: "secret", savePassword: true, hadStoredPassword: false))
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertNil(credentials.password(for: session.id))
    }
}
