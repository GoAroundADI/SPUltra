import XCTest

@testable import SPUltra

final class ModelValidationTests: XCTestCase {
    func testProfileValidationRejectsInvalidValues() {
        XCTAssertThrowsError(try SessionProfile(host: "", port: 22, username: "u").validated())
        XCTAssertThrowsError(try SessionProfile(host: "host", port: 70_000, username: "u").validated())
        XCTAssertThrowsError(try SessionProfile(host: "host", port: 22, username: "").validated())
    }

    func testProfileValidationTrimsAndPreservesNativeSSHOptions() throws {
        let profile = SessionProfile(
            name: "  Phone  ", host: " 127.0.0.1 ", port: 2222, username: " root ",
            protocolKind: .scp
        )
        let validated = try profile.validated()
        XCTAssertEqual(validated.name, "Phone")
        XCTAssertEqual(validated.host, "127.0.0.1")
        XCTAssertEqual(validated.username, "root")
        XCTAssertEqual(validated.protocolKind, .scp)
    }

    func testNewProfileDefaultsToRootRemoteDirectory() throws {
        let profile = SessionProfile(host: "host", port: 22, username: "u")
        XCTAssertEqual(profile.initialRemotePath, "/")
        XCTAssertEqual(try profile.validated().initialRemotePath, "/")
    }

    func testInitialRemotePathTrimsAndFallsBackToRoot() throws {
        var profile = SessionProfile(host: "host", port: 22, username: "u")
        profile.initialRemotePath = "   "
        XCTAssertEqual(try profile.validated().initialRemotePath, "/")

        profile.initialRemotePath = "  /var/mobile  "
        XCTAssertEqual(try profile.validated().initialRemotePath, "/var/mobile")
    }

    func testLoginDirectoryPresetIsPreserved() throws {
        var profile = SessionProfile(host: "host", port: 22, username: "u")
        profile.initialRemotePath = "."
        XCTAssertEqual(try profile.validated().initialRemotePath, ".")
    }

    func testRemotePathFavoritesDefaultToRootOnly() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        XCTAssertEqual(RemotePathFavorites.load(defaults: defaults), ["/"])
    }

    func testRemotePathFavoritesPersistUserPathsAndKeepRootFirst() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        RemotePathFavorites.save(["/var/mobile", "/", "/tmp", "/var/mobile"], defaults: defaults)
        XCTAssertEqual(RemotePathFavorites.load(defaults: defaults), ["/", "/var/mobile", "/tmp"])
        XCTAssertThrowsError(try RemotePathFavorites.validated("relative/path"))
    }

    func testPublicKeyRequiresExistingFile() {
        var profile = SessionProfile(host: "host", port: 22, username: "user")
        profile.authentication = .publicKey
        profile.privateKeyPath = "/path/that/does/not/exist"
        XCTAssertThrowsError(try profile.validated())
    }
}
