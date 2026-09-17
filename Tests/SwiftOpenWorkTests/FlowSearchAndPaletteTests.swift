import XCTest
@testable import SwiftOpenWork

final class ProjectSearchTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try "let total = 1\nfunc totalSpent() {}\n    let subtotal = total + 2\n".write(to: root.appendingPathComponent("Sources/App.swift"), atomically: true, encoding: .utf8)
        try "Total spent: $total\n".write(to: root.appendingPathComponent("docs/readme.md"), atomically: true, encoding: .utf8)
        try Data([0x00, 0x01, 0x74, 0x6f, 0x74, 0x61, 0x6c]).write(to: root.appendingPathComponent("blob.bin"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testMatchesCarryLineAndColumn() throws {
        let result = try ProjectSearch.search(.init(query: "total", caseSensitive: true), root: root.path)
        let app = try XCTUnwrap(result.files.first { $0.path == "Sources/App.swift" })
        XCTAssertEqual(app.matches.map(\.line), [1, 2, 3, 3])
        XCTAssertEqual(app.matches[0].column, 4)
        XCTAssertEqual(app.matches[2].column, 11, "`subtotal` contains the query")
        let preview = app.matches[3].preview as NSString
        XCTAssertEqual(preview.substring(with: app.matches[3].previewRange), "total")
        XCTAssertFalse(result.files.contains { $0.path == "blob.bin" }, "binary files are skipped")
        let readme = try XCTUnwrap(result.files.first { $0.path == "docs/readme.md" })
        XCTAssertEqual(readme.matches.count, 1, "case-sensitive: `Total` does not match, `$total` does")
    }

    func testWholeWordCaseAndRegex() throws {
        let whole = try ProjectSearch.search(.init(query: "total", wholeWord: true), root: root.path)
        XCTAssertEqual(whole.totalMatches, 4, "total ×2 in App.swift, Total and total in readme; subtotal/totalSpent excluded")
        let regex = try ProjectSearch.search(.init(query: #"func \w+\("#, isRegex: true), root: root.path)
        XCTAssertEqual(regex.totalMatches, 1)
        XCTAssertThrowsError(try ProjectSearch.search(.init(query: "(", isRegex: true), root: root.path))
    }

    func testIncludeAndExcludeFilters() throws {
        let onlySwift = try ProjectSearch.search(.init(query: "total", include: "*.swift"), root: root.path)
        XCTAssertEqual(onlySwift.files.map(\.path), ["Sources/App.swift"])
        let onlyDocs = try ProjectSearch.search(.init(query: "total", include: "docs/"), root: root.path)
        XCTAssertEqual(onlyDocs.files.map(\.path), ["docs/readme.md"])
        let excluded = try ProjectSearch.search(.init(query: "total", exclude: "*.md"), root: root.path)
        XCTAssertEqual(excluded.files.map(\.path), ["Sources/App.swift"])
        XCTAssertTrue(ProjectSearch.accepts(path: "Sources/Deep/A.swift", include: "Sources/**", exclude: ""))
        XCTAssertFalse(ProjectSearch.accepts(path: "SourcesExtra/A.swift", include: "Sources/", exclude: ""))
    }

    /// Open files are searched as the person sees them, unsaved edits included.
    func testUnsavedEditorTextIsWhatGetsSearched() throws {
        let full = URL(fileURLWithPath: root.path).resolvingSymlinksInPath().path + "/Sources/App.swift"
        let result = try ProjectSearch.search(.init(query: "brandNewName"), root: root.path, openDocuments: [full: "let brandNewName = 1\n"])
        XCTAssertEqual(result.totalMatches, 1)
        XCTAssertTrue(result.files.first?.fromOpenEditor == true)
    }

    func testReplacementIsLiteralUnlessRegex() throws {
        let literal = try ProjectSearch.replacing(in: "price total", options: .init(query: "total"), with: "$1 cost")
        XCTAssertEqual(literal.text, "price $1 cost", "a $ typed in literal mode stays a $")
        let regex = try ProjectSearch.replacing(in: "add(a, b)", options: .init(query: #"add\((\w), (\w)\)"#, isRegex: true), with: "add($2, $1)")
        XCTAssertEqual(regex.text, "add(b, a)")
        XCTAssertEqual(regex.count, 1)
    }
}

/// Replace All must never write to disk behind the person's back.
@MainActor
final class ReplaceAllTests: XCTestCase {

    func testReplaceAllEditsOpenTabsUnsavedAndUndoably() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("replace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "let oldName = 1\nprint(oldName)\n".write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try "oldName()\n".write(to: root.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)

        let editors = EditorWorkspace.shared
        for document in editors.documents { editors.close(document.id) }
        let model = ProjectSearchModel()
        model.options = .init(query: "oldName", wholeWord: true)
        model.replacement = "newName"
        // Search synchronously, as the panel's debounce would.
        let found = try ProjectSearch.search(model.options, root: root.path)
        XCTAssertEqual(found.totalMatches, 3)
        model.setResultForTesting(found)

        guard case .replaced(let matches, let files, let skipped) = model.replaceAll(workspaceRoot: root.path) else {
            return XCTFail("expected a replacement")
        }
        XCTAssertEqual(matches, 3)
        XCTAssertEqual(files, 2)
        XCTAssertTrue(skipped.isEmpty)

        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.swift"), encoding: .utf8), "let oldName = 1\nprint(oldName)\n",
                       "disk is untouched until the person saves")
        let a = try XCTUnwrap(editors.documents.first { $0.fileName == "a.swift" })
        XCTAssertEqual(a.text, "let newName = 1\nprint(newName)\n")
        XCTAssertTrue(a.isDirty)
        a.undoManager.undo()
        XCTAssertEqual(a.text, "let oldName = 1\nprint(oldName)\n", "one undo reverts the file's replacement")
        for document in editors.documents { editors.close(document.id) }
    }

    func testTooManyFilesIsRefused() {
        let model = ProjectSearchModel()
        let files = (0...ProjectSearchModel.replaceFileLimit).map {
            ProjectSearch.FileResult(path: "f\($0).swift", matches: [], fromOpenEditor: false)
        }
        model.setResultForTesting(ProjectSearch.Result(files: files, totalMatches: files.count, filesSearched: files.count, truncated: false))
        XCTAssertEqual(model.replaceAll(workspaceRoot: "/tmp"), .tooManyFiles(files.count))
    }
}

final class CommandPaletteRankingTests: XCTestCase {

    private func item(_ title: String, kind: PaletteItem.Kind = .command, keywords: [String] = []) -> PaletteItem {
        PaletteItem(id: title, title: title, kind: kind, keywords: keywords) {}
    }

    func testBetterMatchesComeFirst() {
        let items = [item("New Preview Tab"), item("New Chat"), item("Find in Project"), item("Show Editor")]
        XCTAssertEqual(PaletteRanker.rank(items, query: "new").first?.title, "New Chat", "shorter prefix match first")
        XCTAssertEqual(PaletteRanker.rank(items, query: "fip").first?.title, "Find in Project", "initials")
        XCTAssertEqual(PaletteRanker.rank(items, query: "edit").first?.title, "Show Editor", "start of a word")
        XCTAssertEqual(PaletteRanker.rank(items, query: "nwpt").first?.title, "New Preview Tab", "letters in order")
        XCTAssertTrue(PaletteRanker.rank(items, query: "zzz").isEmpty)
    }

    func testKeywordsAndRecentsCount() {
        let items = [item("Find in Project", keywords: ["grep"]), item("Show Editor")]
        XCTAssertEqual(PaletteRanker.rank(items, query: "grep").first?.title, "Find in Project")
        let recentFirst = PaletteRanker.rank(items, query: "", recent: ["Show Editor"])
        XCTAssertEqual(recentFirst.first?.title, "Show Editor", "recently run commands lead an empty palette")
    }

    func testCommandsBeatFilesAtEqualQuality() {
        let items = [item("Search.swift", kind: .file), item("Search", kind: .command)]
        XCTAssertEqual(PaletteRanker.rank(items, query: "search").first?.kind, .command)
    }

    func testPrefixModes() {
        XCTAssertEqual(PaletteRanker.mode(for: "> save"), .commands("save"))
        XCTAssertEqual(PaletteRanker.mode(for: "@render"), .symbols("render"))
        XCTAssertEqual(PaletteRanker.mode(for: ":42"), .line(42))
        XCTAssertEqual(PaletteRanker.mode(for: ":"), .line(nil))
        XCTAssertEqual(PaletteRanker.mode(for: "app.js"), .everything("app.js"))
    }
}
