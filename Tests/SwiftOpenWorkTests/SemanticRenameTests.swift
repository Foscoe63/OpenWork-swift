import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkEngine

/// Compiler-backed rename. The pure half pins the edit arithmetic; the integration test runs the
/// real `sourcekit-lsp` against a two-type package, because the property that matters — renaming
/// `Alpha.value` leaves `Beta.value` alone — only exists when the index does.
final class SemanticRenameTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ow-sk-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await LanguageServerPool.shared.shutdown(under: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, _ text: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - Pure

    func testEditsApplyLastToFirstSoOffsetsDoNotShift() {
        let text = "let a = value + value\nvalue()\n"
        let edits = [
            SemanticRename.TextEdit(startLine: 0, startCharacter: 8, endLine: 0, endCharacter: 13, newText: "count"),
            SemanticRename.TextEdit(startLine: 0, startCharacter: 16, endLine: 0, endCharacter: 21, newText: "count"),
            SemanticRename.TextEdit(startLine: 1, startCharacter: 0, endLine: 1, endCharacter: 5, newText: "total"),
        ]
        XCTAssertEqual(SemanticRename.apply(edits, to: text), "let a = count + count\ntotal()\n")
    }

    /// LSP columns are UTF-16 offsets. An emoji before the name is two units, not one character.
    func testColumnsAreUTF16Offsets() {
        let text = "let 👋 = 1; let value = 2"
        let position = try? SymbolPosition.resolve(in: text, line: 1, symbol: "value", column: nil)
        XCTAssertEqual(position?.character, 16)
        let edit = SemanticRename.TextEdit(startLine: 0, startCharacter: 16, endLine: 0, endCharacter: 21, newText: "count")
        XCTAssertEqual(SemanticRename.apply([edit], to: text), "let 👋 = 1; let count = 2")
    }

    /// A position past the end of a line means the index is stale. Writing it would corrupt the file.
    func testAnEditOutsideTheTextIsRefused() {
        let edit = SemanticRename.TextEdit(startLine: 0, startCharacter: 40, endLine: 0, endCharacter: 45, newText: "x")
        XCTAssertNil(SemanticRename.apply([edit], to: "short\n"))
        let missingLine = SemanticRename.TextEdit(startLine: 9, startCharacter: 0, endLine: 9, endCharacter: 1, newText: "x")
        XCTAssertNil(SemanticRename.apply([missingLine], to: "short\n"))
    }

    /// An edit whose range no longer holds the old name was computed against other text. Applying
    /// it would overwrite whatever is there now.
    func testAnEditThatDoesNotLandOnTheOldNameIsRefused() {
        let text = "let total = 1\n"
        let stale = SemanticRename.TextEdit(startLine: 0, startCharacter: 4, endLine: 0, endCharacter: 9, newText: "count")
        XCTAssertNil(SemanticRename.apply([stale], to: text, expected: "value"))
        XCTAssertEqual(SemanticRename.apply([stale], to: text), "let count = 1\n", "without `expected` the arithmetic alone is checked")
    }

    /// Servers restate unchanged text (argument labels) as edits to itself; those are not stale.
    func testEditsThatChangeNothingAreSkippedRatherThanChecked() {
        let text = "func value(label: Int)\n"
        let edits = [
            SemanticRename.TextEdit(startLine: 0, startCharacter: 5, endLine: 0, endCharacter: 10, newText: "count"),
            SemanticRename.TextEdit(startLine: 0, startCharacter: 11, endLine: 0, endCharacter: 16, newText: "label"),
        ]
        XCTAssertEqual(SemanticRename.apply(edits, to: text, expected: "value"), "func count(label: Int)\n")
    }

    func testOneFileNamedByTwoPathsIsMergedIntoOne() throws {
        try write("A.swift", "let value = 1\n")
        // Foundation's symlink resolution spells temporary files /var/…; the index may say /private/var/….
        let real = LanguageServerCatalog.standardized(root.appendingPathComponent("A.swift").path)
        guard real.hasPrefix("/var/") || real.hasPrefix("/tmp/") else {
            throw XCTSkip("the temporary directory has no /private alias here: \(real)")
        }
        let alias = "/private" + real
        let edit = SemanticRename.TextEdit(startLine: 0, startCharacter: 4, endLine: 0, endCharacter: 9, newText: "count")
        let merged = SemanticRename.mergeByResolvedPath([real: [edit], alias: [edit]])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[real], [edit])
    }

    func testBothWorkspaceEditShapesAreRead() {
        let range: [String: Any] = ["start": ["line": 1, "character": 2], "end": ["line": 1, "character": 7]]
        let changes: [String: Any] = ["changes": ["file:///tmp/A.swift": [["range": range, "newText": "n"]]]]
        let documentChanges: [String: Any] = ["documentChanges": [["textDocument": ["uri": "file:///tmp/B.swift", "version": 1], "edits": [["range": range, "newText": "n"]]]]]
        XCTAssertEqual(SemanticRename.parseWorkspaceEdit(changes)["/tmp/A.swift"]?.first?.startCharacter, 2)
        XCTAssertEqual(SemanticRename.parseWorkspaceEdit(documentChanges)["/tmp/B.swift"]?.first?.endCharacter, 7)
    }

    // MARK: - Mode selection

    /// Outside a Swift package, `auto` falls back — and says it did, and says the method.
    func testAutoFallsBackToTextOutsideAPackageAndSaysSo() async throws {
        try write("Widget.swift", "struct Widget {}\nlet w = Widget()\n")
        let outcome = try await SymbolRename.rename(oldName: "Widget", newName: "Gadget", root: root.path, mode: .auto)
        XCTAssertEqual(outcome.method, "text")
        XCTAssertTrue(outcome.summary.contains("whole-word text replacement"))
        XCTAssertTrue(outcome.notes.contains { $0.contains("Compiler rename not used") })
        XCTAssertEqual(try read("Widget.swift"), "struct Gadget {}\nlet w = Gadget()\n")
    }

    /// `semantic` is a promise about which occurrences change, so it must not quietly become text.
    func testSemanticModeRefusesRatherThanFallingBack() async throws {
        try write("Widget.swift", "struct Widget {}\n")
        do {
            _ = try await SymbolRename.rename(oldName: "Widget", newName: "Gadget", root: root.path, mode: .semantic)
            XCTFail("semantic mode outside a package must fail")
        } catch SymbolRename.Failure.compilerRenameUnavailable {
            XCTAssertEqual(try read("Widget.swift"), "struct Widget {}\n", "nothing may be written")
        }
    }

    // MARK: - The real server

    func testCompilerRenameLeavesASameNamedMethodOnAnotherTypeAlone() async throws {
        guard ExecutableLocator().locate(LanguageServerCatalog.sourceKit) != nil else {
            throw XCTSkip("sourcekit-lsp is not installed")
        }
        try write("Package.swift", """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Toy", targets: [.target(name: "Toy")])
        """)
        try write("Sources/Toy/Types.swift", """
        public struct Alpha {
            public init() {}
            public func value() -> Int { 1 }
        }
        public struct Beta {
            public init() {}
            public func value() -> Int { 2 }
        }
        """)
        try write("Sources/Toy/Use.swift", """
        let x = Alpha().value()
        let y = Beta().value()
        // value is mentioned in a comment
        """)

        // Two declarations of `value` in one file: the line says which.
        let outcome = try await SymbolRename.rename(
            oldName: "value", newName: "count", root: root.path,
            pathHint: "Sources/Toy/Types.swift", mode: .semantic, declarationLine: 3
        )
        XCTAssertEqual(outcome.method, "compiler")
        XCTAssertEqual(outcome.server, "sourcekit-lsp")
        XCTAssertTrue(outcome.summary.contains("sourcekit-lsp"), "the summary names the server")
        XCTAssertEqual(outcome.filesChanged.sorted(), ["Sources/Toy/Types.swift", "Sources/Toy/Use.swift"],
                       "each file once, however many paths the server used for it")
        XCTAssertTrue(try read("Sources/Toy/Types.swift").contains("public func count() -> Int { 1 }"))
        XCTAssertTrue(try read("Sources/Toy/Types.swift").contains("public func value() -> Int { 2 }"), "Beta.value must not change")
        XCTAssertEqual(try read("Sources/Toy/Use.swift"), """
        let x = Alpha().count()
        let y = Beta().value()
        // value is mentioned in a comment
        """)
        XCTAssertEqual(outcome.diffs.count, 2)
    }
}
