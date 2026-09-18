import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine

final class WorkspaceFileScannerTests: XCTestCase {

    private var root: String = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "scanner-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func write(_ relative: String, _ contents: String) throws {
        let full = (root as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try contents.write(toFile: full, atomically: true, encoding: .utf8)
    }

    // MARK: - Listing

    func testListingDescendsIntoSubdirectories() throws {
        try write("top.md", "hi")
        try write("Sources/UI/Deep.swift", "struct A {}")

        let files = WorkspaceFileScanner.listFiles(at: root)

        XCTAssertTrue(files.contains("top.md"))
        XCTAssertTrue(files.contains("Sources/UI/Deep.swift"),
                      "The listing was flat before; nested source files never appeared.")
    }

    func testListingSkipsDotfilesAndHeavyDirectories() throws {
        try write(".secret", "nope")
        try write(".git/config", "nope")
        try write("node_modules/pkg/index.js", "nope")
        try write(".build/debug/thing.o", "nope")
        try write("keep.txt", "yes")

        let files = WorkspaceFileScanner.listFiles(at: root)

        XCTAssertEqual(files, ["keep.txt"])
    }

    func testListingHonoursDepthAndEntryLimits() throws {
        try write("a/b/c/d/e/TooDeep.swift", "x")
        XCTAssertFalse(WorkspaceFileScanner.listFiles(at: root).contains("a/b/c/d/e/TooDeep.swift"))

        for i in 0..<20 { try write("bulk/file\(i).txt", "x") }
        XCTAssertEqual(WorkspaceFileScanner.listFiles(at: root, maxEntries: 5).count, 5)
    }

    func testListingExcludesDirectoriesThemselves() throws {
        try write("Sources/File.swift", "x")
        let files = WorkspaceFileScanner.listFiles(at: root)
        XCTAssertFalse(files.contains("Sources"))
    }

    func testMissingRootYieldsEmptyListRatherThanThrowing() {
        XCTAssertEqual(WorkspaceFileScanner.listFiles(at: root + "/does-not-exist"), [])
    }

    // MARK: - Classification
    //
    // The editor used to set its text to "Binary or unreadable file format." and Save Changes
    // wrote that string straight back, so saving a PNG destroyed it. These cover the guard.

    func testUTF8FileReadsAsEditableText() throws {
        try write("notes.md", "# Title\n")
        let full = (root as NSString).appendingPathComponent("notes.md")

        let content = WorkspaceFileScanner.read(path: full)

        XCTAssertEqual(content, .text("# Title\n"))
        XCTAssertTrue(content.isEditable)
    }

    func testNonUTF8FileIsBinaryAndNotEditable() throws {
        let full = (root as NSString).appendingPathComponent("image.png")
        // A real PNG signature, which is not valid UTF-8.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0xFE, 0xC0])
        try png.write(to: URL(fileURLWithPath: full))

        let content = WorkspaceFileScanner.read(path: full)

        XCTAssertEqual(content, .binary(byteCount: png.count))
        XCTAssertFalse(content.isEditable,
                       "A binary marked editable is the data-loss path: Save would overwrite it.")
    }

    func testOversizedFileIsRefusedEvenWhenItIsValidText() throws {
        try write("huge.txt", String(repeating: "a", count: 4096))
        let full = (root as NSString).appendingPathComponent("huge.txt")

        let content = WorkspaceFileScanner.read(path: full, maxBytes: 1024)

        XCTAssertEqual(content, .tooLarge(byteCount: 4096))
        XCTAssertFalse(content.isEditable)
    }

    func testMissingFileIsUnreadableAndNotEditable() {
        let content = WorkspaceFileScanner.read(
            path: (root as NSString).appendingPathComponent("gone.txt"))

        guard case .unreadable = content else {
            return XCTFail("Expected .unreadable, got \(content)")
        }
        XCTAssertFalse(content.isEditable)
    }

    func testEmptyFileIsEditableText() throws {
        try write("empty.txt", "")
        let full = (root as NSString).appendingPathComponent("empty.txt")

        XCTAssertEqual(WorkspaceFileScanner.read(path: full), .text(""))
    }
}
