import Foundation
import XCTest

@testable import SPUltra

final class LocalFileServiceTests: XCTestCase {
    func testListingPreservesSymbolicLinkIdentity() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SPUltraLocalFiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let target = folder.appendingPathComponent("target", isDirectory: true)
        let link = folder.appendingPathComponent("link", isDirectory: false)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let item = try XCTUnwrap(LocalFileService().contents(of: folder, showHidden: true).first { $0.name == "link" })
        XCTAssertTrue(item.isSymbolicLink)
    }

    func testMovesFileAndNonEmptyDirectoryToTrash() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SPUltraTrash-\(UUID().uuidString)", isDirectory: true)
        let file = folder.appendingPathComponent("file.txt")
        let nested = folder.appendingPathComponent("directory", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("file".utf8).write(to: file)
        try Data("nested".utf8).write(to: nested.appendingPathComponent("child.txt"))

        var trashed: [URL] = []
        defer {
            for item in trashed { try? FileManager.default.removeItem(at: item) }
        }
        let service = LocalFileService()
        if let result = try service.moveToTrash(file) { trashed.append(result) }
        if let result = try service.moveToTrash(nested) { trashed.append(result) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path))
        XCTAssertEqual(trashed.count, 2)
        XCTAssertTrue(trashed.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        try? FileManager.default.removeItem(at: folder)
    }
}
