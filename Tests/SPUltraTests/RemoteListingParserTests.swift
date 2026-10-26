import XCTest

@testable import SPUltra

private final class ProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TransferProgressUpdate] = []

    func append(_ update: TransferProgressUpdate) { lock.withLock { values.append(update) } }
    var latest: TransferProgressUpdate? { lock.withLock { values.last } }
}

final class RemoteListingParserTests: XCTestCase {
    func testPathHelpers() {
        XCTAssertEqual(RemoteListingParser.join("/", "tmp"), "/tmp")
        XCTAssertEqual(RemoteListingParser.join("/srv", "data"), "/srv/data")
        XCTAssertEqual(RemoteListingParser.parent(of: "/srv/data"), "/srv")
        XCTAssertEqual(RemoteListingParser.parent(of: "/"), "/")
        XCTAssertEqual(RemoteListingParser.parent(of: "/srv"), "/")
        XCTAssertEqual(RemoteListingParser.parent(of: "/srv/"), "/")
        XCTAssertEqual(RemoteListingParser.parent(of: "//srv/data//"), "/srv")
        XCTAssertEqual(RemoteListingParser.parent(of: "data"), ".")
        XCTAssertEqual(RemoteListingParser.parent(of: ""), ".")
        XCTAssertEqual(RemoteListingParser.join("/srv/", "data with spaces"), "/srv/data with spaces")
    }

    func testRelativeLoginDirectoryHelpers() {
        XCTAssertEqual(RemoteListingParser.join(".", "file"), "file")
        XCTAssertEqual(RemoteListingParser.parent(of: "."), ".")
        XCTAssertEqual(RemoteListingParser.parent(of: "file"), ".")
        XCTAssertEqual(RemoteListingParser.join("/", "新建文件"), "/新建文件")
    }

    func testRemovalCommandsIncludeLegacyFallbackAndProtectOptionLikeNames() {
        XCTAssertEqual(
            RemoteFileService.removalCommands(path: "/tmp/folder", isDirectory: true),
            ["rm -rf -- '/tmp/folder'", "rm -rf '/tmp/folder'"])
        XCTAssertEqual(
            RemoteFileService.removalCommands(path: "-unsafe", isDirectory: false),
            ["rm -f -- '-unsafe'", "rm -f './-unsafe'"])
        XCTAssertEqual(
            RemoteFileService.removalCommands(path: "/tmp/it's here", isDirectory: true),
            ["rm -rf -- '/tmp/it'\\''s here'", "rm -rf '/tmp/it'\\''s here'"])
    }

    func testRemoteOperationValidationAndCompatibilityCommands() throws {
        XCTAssertEqual(try RemoteFileService.validatedRemoteName("  renamed.txt  "), "renamed.txt")
        for invalid in ["", ".", "..", "folder/name", "\0", "line\nfeed", "carriage\rreturn"] {
            XCTAssertThrowsError(try RemoteFileService.validatedRemoteName(invalid))
        }
        XCTAssertEqual(try RemoteFileService.validatedPermissionMode("755"), 0o755)
        XCTAssertEqual(try RemoteFileService.validatedPermissionMode("0644"), 0o644)
        for invalid in ["", "88", "999", "12345", "u+r"] {
            XCTAssertThrowsError(try RemoteFileService.validatedPermissionMode(invalid))
        }
        XCTAssertEqual(
            RemoteFileService.renameCommands(source: "/tmp/old name", destination: "/tmp/new name"),
            [
                "if [ -e '/tmp/new name' ] || [ -L '/tmp/new name' ]; then echo '目标已存在' >&2; exit 1; fi; mv -- '/tmp/old name' '/tmp/new name'",
                "if [ -e '/tmp/new name' ] || [ -L '/tmp/new name' ]; then echo '目标已存在' >&2; exit 1; fi; mv '/tmp/old name' '/tmp/new name'",
            ])
        XCTAssertEqual(
            RemoteFileService.chmodCommands(path: "-unsafe", mode: 0o755),
            ["chmod 0755 -- '-unsafe'", "chmod 0755 './-unsafe'"])
        XCTAssertEqual(RemoteFileService.permissionMode(from: "-rw-r-----"), 0o640)
        XCTAssertEqual(RemoteFileService.permissionMode(from: "drwxr-xr-x"), 0o755)
        XCTAssertNil(RemoteFileService.permissionMode(from: "unknown"))
    }

    func testStablePartialTransferPaths() {
        XCTAssertEqual(RemoteFileService.partialRemotePath(for: "/tmp/archive.zip"), "/tmp/.archive.zip.spultra-part")
        XCTAssertEqual(
            RemoteFileService.partialLocalURL(for: URL(fileURLWithPath: "/tmp/archive.zip")).path,
            "/tmp/.archive.zip.spultra-part")
    }

    func testTransferProgressTracksResumeAndDiscoveredTotals() {
        let knownProbe = ProgressProbe()
        let known = TransferProgressTracker(expectedBytes: 100) { update in knownProbe.append(update) }
        known.beginFile(size: 100, resumedAt: 20)
        known.advance(by: 30)
        XCTAssertEqual(
            knownProbe.latest,
            TransferProgressUpdate(transferredBytes: 50, totalBytes: 100, resumedBytes: 20))

        let discoveredProbe = ProgressProbe()
        let discovered = TransferProgressTracker(expectedBytes: 0) { update in discoveredProbe.append(update) }
        discovered.beginFile(size: 40, resumedAt: 0)
        discovered.advance(by: 40)
        discovered.beginFile(size: 60, resumedAt: 10)
        XCTAssertEqual(
            discoveredProbe.latest,
            TransferProgressUpdate(transferredBytes: 50, totalBytes: 100, resumedBytes: 10))
    }

    func testParsesNativeShellListingWithSpacesAndLinks() {
        let listing = """
            total 8
            drwxr-xr-x  2 0 0  64 Oct 25 16:00 Folder One
            -rw-r--r--  1 0 0 123 Oct 25 16:01 report final.txt
            lrwxr-xr-x  1 0 0  16 Oct 25 16:02 latest -> report final.txt
            """
        let items = RemoteListingParser.parsePOSIXListing(listing, directory: "/tmp")
        XCTAssertEqual(items.map(\.name), ["Folder One", "latest", "report final.txt"])
        XCTAssertTrue(items[0].isDirectory)
        XCTAssertTrue(items[1].isSymbolicLink)
        XCTAssertEqual(items[2].size, 123)
    }
}
