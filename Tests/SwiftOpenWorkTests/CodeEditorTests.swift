import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine

/// The lexer's job is to be right about strings and comments. Wrong colours mislead.
final class SyntaxHighlighterTests: XCTestCase {

    private func kinds(_ code: String, _ language: SyntaxLanguage) -> [(String, SyntaxTokenKind)] {
        let ns = code as NSString
        return SyntaxHighlighter.tokens(in: code, language: language).map { (ns.substring(with: $0.range), $0.kind) }
    }

    private func kind(of text: String, in code: String, _ language: SyntaxLanguage) -> SyntaxTokenKind? {
        kinds(code, language).first { $0.0 == text }?.1
    }

    func testSwiftBasics() {
        let code = """
        import SwiftUI
        // a comment with func inside
        @MainActor struct Box { let value = 42; func run() { print("let x // not a comment") } }
        """
        XCTAssertEqual(kind(of: "import", in: code, .swift), .keyword)
        XCTAssertEqual(kind(of: "SwiftUI", in: code, .swift), .type)
        XCTAssertEqual(kind(of: "// a comment with func inside", in: code, .swift), .comment)
        XCTAssertEqual(kind(of: "@MainActor", in: code, .swift), .attribute)
        XCTAssertEqual(kind(of: "42", in: code, .swift), .number)
        XCTAssertEqual(kind(of: "run", in: code, .swift), .function)
        XCTAssertEqual(kind(of: "\"let x // not a comment\"", in: code, .swift), .string)
        // Nothing inside the string or the comment is coloured as code.
        XCTAssertFalse(kinds(code, .swift).contains { $0.0 == "func" && $0.1 == .keyword && code.components(separatedBy: "func").count > 3 })
        XCTAssertEqual(kinds(code, .swift).filter { $0.0 == "let" }.count, 1, "only the real `let` is a keyword")
    }

    func testSwiftNestedBlockCommentsAndMultilineStrings() {
        let code = "/* outer /* inner */ still comment */ let s = \"\"\"\nline \"quoted\"\n\"\"\"\nvar"
        let tokens = kinds(code, .swift)
        XCTAssertEqual(tokens.first?.1, .comment)
        XCTAssertEqual(tokens.first?.0, "/* outer /* inner */ still comment */")
        XCTAssertTrue(tokens.contains { $0.1 == .string && $0.0.hasPrefix("\"\"\"") && $0.0.hasSuffix("\"\"\"") })
        XCTAssertEqual(tokens.last?.0, "var")
        XCTAssertEqual(tokens.last?.1, .keyword)
    }

    func testMemberAccessIsNotAKeyword() {
        XCTAssertNil(kind(of: "default", in: "x = .default", .swift))
    }

    func testRangesAreNotSwallowedByNumbers() {
        let tokens = kinds("for i in 0..<10 {}", .swift)
        XCTAssertTrue(tokens.contains { $0.0 == "0" && $0.1 == .number })
        XCTAssertTrue(tokens.contains { $0.0 == "10" && $0.1 == .number })
    }

    func testJavaScriptTemplatesAndComments() {
        let code = "const a = `multi\nline ${x}`; // done\nfunction go() { return null }"
        XCTAssertEqual(kind(of: "const", in: code, .javascript), .keyword)
        XCTAssertTrue(kinds(code, .javascript).contains { $0.1 == .string && $0.0.contains("\n") })
        XCTAssertEqual(kind(of: "// done", in: code, .javascript), .comment)
        XCTAssertEqual(kind(of: "go", in: code, .javascript), .function)
        XCTAssertEqual(kind(of: "null", in: code, .javascript), .keyword)
    }

    func testTypeScriptAddsItsKeywords() {
        XCTAssertEqual(kind(of: "interface", in: "interface A {}", .typescript), .keyword)
        XCTAssertNil(kind(of: "interface", in: "interface A {}", .javascript))
    }

    func testPythonDocstringsAndDecorators() {
        let code = "@dataclass\ndef f():\n    \"\"\"Doc # not comment\"\"\"\n    return None  # real"
        XCTAssertEqual(kind(of: "@dataclass", in: code, .python), .attribute)
        XCTAssertEqual(kind(of: "\"\"\"Doc # not comment\"\"\"", in: code, .python), .string)
        XCTAssertEqual(kind(of: "# real", in: code, .python), .comment)
        XCTAssertEqual(kind(of: "None", in: code, .python), .keyword)
    }

    func testJSONKeysAreDistinctFromValues() {
        let code = #"{"name": "value", "n": 3, "ok": true}"#
        XCTAssertEqual(kind(of: #""name""#, in: code, .json), .property)
        XCTAssertEqual(kind(of: #""value""#, in: code, .json), .string)
        XCTAssertEqual(kind(of: "3", in: code, .json), .number)
        XCTAssertEqual(kind(of: "true", in: code, .json), .keyword)
    }

    func testShellHashNeedsABoundary() {
        let code = "echo ${#arr[@]} $HOME # comment"
        XCTAssertEqual(kind(of: "# comment", in: code, .shell), .comment)
        XCTAssertEqual(kind(of: "$HOME", in: code, .shell), .property)
        XCTAssertFalse(kinds(code, .shell).contains { $0.1 == .comment && $0.0.hasPrefix("#arr") })
    }

    func testYAMLKeys() {
        let code = "name: CI\non:\n  push: # trigger\n    branches: [main]"
        XCTAssertEqual(kind(of: "name", in: code, .yaml), .property)
        XCTAssertEqual(kind(of: "branches", in: code, .yaml), .property)
        XCTAssertEqual(kind(of: "# trigger", in: code, .yaml), .comment)
    }

    func testHTMLTagsAttributesAndComments() {
        let code = #"<!-- note --><div class="a">x &amp; y</div>"#
        let tokens = kinds(code, .html)
        XCTAssertEqual(tokens.first?.1, .comment)
        XCTAssertTrue(tokens.contains { $0.0 == "<div" && $0.1 == .tag })
        XCTAssertTrue(tokens.contains { $0.0 == "class" && $0.1 == .attributeName })
        XCTAssertTrue(tokens.contains { $0.0 == #""a""# && $0.1 == .string })
        XCTAssertTrue(tokens.contains { $0.0 == "&amp;" && $0.1 == .keyword })
    }

    func testMarkdownFencesHideTheirContents() {
        let code = "# Title\n```swift\nlet x = 1\n```\nSee [docs](https://x) and `code`."
        let tokens = kinds(code, .markdown)
        XCTAssertEqual(tokens.first?.1, .heading)
        XCTAssertTrue(tokens.contains { $0.1 == .string && $0.0.contains("let x = 1") })
        XCTAssertTrue(tokens.contains { $0.0 == "[docs](https://x)" && $0.1 == .link })
        XCTAssertTrue(tokens.contains { $0.0 == "`code`" && $0.1 == .string })
    }

    func testUnterminatedConstructsDoNotCrashOrLeak() {
        for language in SyntaxLanguage.allCases {
            for code in ["\"open", "/* open", "<div class=\"", "```\nopen", "'", "#", "@", "$", "${", "0x"] {
                let tokens = SyntaxHighlighter.tokens(in: code, language: language)
                for token in tokens {
                    XCTAssertLessThanOrEqual(NSMaxRange(token.range), (code as NSString).length, "\(language) \(code)")
                    XCTAssertGreaterThan(token.range.length, 0, "\(language) \(code)")
                }
            }
        }
    }

    /// UTF-16 ranges must line up with NSString even around emoji.
    func testRangesAreUTF16() {
        let code = "let 🎉 = \"🎉\" // 🎉"
        let ns = code as NSString
        let comment = SyntaxHighlighter.tokens(in: code, language: .swift).first { $0.kind == .comment }
        XCTAssertEqual(comment.map { ns.substring(with: $0.range) }, "// 🎉")
    }

    func testLanguageDetection() {
        XCTAssertEqual(SyntaxLanguage.detect(path: "/a/b/App.swift"), .swift)
        XCTAssertEqual(SyntaxLanguage.detect(path: "Dockerfile"), .dockerfile)
        XCTAssertEqual(SyntaxLanguage.detect(path: "x/Makefile"), .makefile)
        XCTAssertEqual(SyntaxLanguage.detect(path: "page.tsx"), .typescript)
        XCTAssertEqual(SyntaxLanguage.detect(path: "notes.txt"), .plain)
    }

    func testALargeFileHighlightsQuickly() {
        let line = "    let value = compute(\"string // x\", 42) // trailing comment\n"
        let code = String(repeating: line, count: 12_000)
        measureMetrics([.wallClockTime], automaticallyStartMeasuring: true) {
            _ = SyntaxHighlighter.tokens(in: code, language: .swift)
        }
    }
}

final class EditorTextTests: XCTestCase {

    func testLineEndingsRoundTrip() {
        let crlf = "a\r\nb\r\nc"
        XCTAssertEqual(EditorText.detectLineEnding(crlf), .crlf)
        let normalized = EditorText.normalizeNewlines(crlf)
        XCTAssertEqual(normalized, "a\nb\nc")
        XCTAssertEqual(EditorText.restoreLineEndings(normalized, to: .crlf), crlf)
        XCTAssertEqual(EditorText.detectLineEnding("a\nb"), .lf)
    }

    func testIndentationDetection() {
        XCTAssertEqual(EditorText.detectIndentation("func a() {\n  let x = 1\n  if x {\n    y()\n  }\n}"), .spaces(2))
        XCTAssertEqual(EditorText.detectIndentation("a:\n    b\n    c:\n        d"), .spaces(4))
        XCTAssertEqual(EditorText.detectIndentation("func a() {\n\tlet x\n\tlet y\n}"), .tabs)
        XCTAssertEqual(EditorText.detectIndentation("no indentation", fallback: .spaces(3)), .spaces(3))
    }

    func testNewlineKeepsIndentation() {
        let text = "    let x = 1" as NSString
        let result = EditorText.newlineInsertion(at: text.length, in: text, indentation: .spaces(4), language: .swift)
        XCTAssertEqual(result.text, "\n    ")
    }

    func testNewlineAfterOpeningBraceIndents() {
        let text = "if ok {" as NSString
        let result = EditorText.newlineInsertion(at: text.length, in: text, indentation: .spaces(4), language: .swift)
        XCTAssertEqual(result.text, "\n    ")
    }

    func testNewlineBetweenBracesOpensThePair() {
        let text = "  f() {}" as NSString
        let result = EditorText.newlineInsertion(at: 7, in: text, indentation: .spaces(2), language: .swift)
        XCTAssertEqual(result.text, "\n    \n  ")
        XCTAssertEqual(result.cursorOffset, 5, "cursor sits on the indented middle line")
    }

    func testPythonColonIndents() {
        let text = "def f():" as NSString
        XCTAssertEqual(EditorText.newlineInsertion(at: text.length, in: text, indentation: .spaces(4), language: .python).text, "\n    ")
        XCTAssertEqual(EditorText.newlineInsertion(at: text.length, in: text, indentation: .spaces(4), language: .swift).text, "\n")
    }

    func testShiftLines() {
        XCTAssertEqual(EditorText.shiftLines("a\n\nb\n", by: .spaces(2), outdent: false), "  a\n\n  b\n")
        XCTAssertEqual(EditorText.shiftLines("    a\n  b", by: .spaces(4), outdent: true), "a\nb")
        XCTAssertEqual(EditorText.shiftLines("\ta", by: .tabs, outdent: true), "a")
    }

    func testToggleCommentsRoundTrip() {
        let block = "    let a = 1\n\n        let b = 2\n"
        let commented = EditorText.toggleLineComments(block, prefix: "//")
        XCTAssertEqual(commented, "    // let a = 1\n\n    //     let b = 2\n")
        XCTAssertEqual(EditorText.toggleLineComments(commented, prefix: "//"), block)
    }

    func testWholeLinesExcludesALineTheSelectionOnlyTouchesTheStartOf() {
        let text = "one\ntwo\nthree\n" as NSString
        // Selecting "one\n" exactly must not also take "two".
        XCTAssertEqual(EditorText.wholeLines(for: NSRange(location: 0, length: 4), in: text), NSRange(location: 0, length: 4))
        XCTAssertEqual(EditorText.wholeLines(for: NSRange(location: 5, length: 0), in: text), NSRange(location: 4, length: 4))
    }

    func testLineAndColumnRoundTrip() {
        let text = "ab\ncde\n\nf" as NSString
        XCTAssertEqual(EditorText.lineAndColumn(of: 4, in: text).line, 2)
        XCTAssertEqual(EditorText.lineAndColumn(of: 4, in: text).column, 2)
        XCTAssertEqual(EditorText.location(ofLine: 3, in: text), 7)
        XCTAssertEqual(EditorText.location(ofLine: 99, in: text), text.length)
    }

    func testCompletionOrderingAndFiltering() {
        let result = EditorText.completions(
            prefix: "val",
            documentWords: ["value", "validate", "val"],
            workspaceSymbols: ["ValueStore", "value"],
            keywords: ["var"]
        )
        XCTAssertEqual(result, ["value", "validate", "ValueStore"],
                       "document words first, exact case before case-insensitive, no duplicates, never the prefix itself")
        XCTAssertTrue(EditorText.completions(prefix: "", documentWords: ["a"], workspaceSymbols: [], keywords: []).isEmpty)
    }

    func testWordsAreRankedByUse() {
        let words = EditorText.words(in: "alpha beta alpha 123abc gamma alpha beta x")
        XCTAssertEqual(Array(words.prefix(2)), ["alpha", "beta"])
        XCTAssertFalse(words.contains("x"), "too short to be worth offering")
        XCTAssertFalse(words.contains("123abc"), "not an identifier")
    }

    func testQuickOpenPrefersFileNameMatches() {
        let files = ["Sources/Engine/Tools/ToolExecutionEngine.swift", "Sources/UI/Views/Chat/ToolCallCardView.swift", "README.md"]
        XCTAssertEqual(QuickOpenMatcher.rank(files: files, query: "toolcall").first, "Sources/UI/Views/Chat/ToolCallCardView.swift")
        XCTAssertEqual(QuickOpenMatcher.rank(files: files, query: "tee").first, "Sources/Engine/Tools/ToolExecutionEngine.swift")
        XCTAssertTrue(QuickOpenMatcher.rank(files: files, query: "zzz").isEmpty)
    }

    func testFirstChangedLineOfADiff() throws {
        let diff = try XCTUnwrap(InlineFileDiff.between(before: "a\nb\nc\nd\n", after: "a\nb\nX\nd\n", path: "/f"))
        XCTAssertEqual(diff.firstChangedLine, 3)
        let removal = try XCTUnwrap(InlineFileDiff.between(before: "a\nb\nc\n", after: "a\nc\n", path: "/f"))
        XCTAssertEqual(removal.firstChangedLine, 2, "a pure removal points at the line now in its place")
    }

    func testUnsavedBannerWording() {
        XCTAssertTrue(UnsavedEditorFilesBanner.message(for: ["A.swift"]).contains("A.swift has unsaved edits"))
        XCTAssertTrue(UnsavedEditorFilesBanner.message(for: ["A", "B", "C"]).hasPrefix("3 files"))
    }
}

/// The agent edits files you have open. None of that may lose anyone's work.
@MainActor
final class EditorDocumentDiskSyncTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String, to name: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        // Modification dates have one-second resolution on some volumes; make every write visible.
        let bump = Date().addingTimeInterval(Double.random(in: 2...1_000))
        try FileManager.default.setAttributes([.modificationDate: bump], ofItemAtPath: url.path)
        return url.path
    }

    private func edit(_ document: EditorDocument, append text: String) {
        document.storage.append(NSAttributedString(string: text))
        document.textDidChange()
    }

    func testDecisionTable() {
        XCTAssertEqual(EditorDiskSync.decide(exists: false, diskTextMatchesLastSeen: false, hasUnsavedEdits: true), .deleted)
        XCTAssertEqual(EditorDiskSync.decide(exists: true, diskTextMatchesLastSeen: true, hasUnsavedEdits: true), .none)
        XCTAssertEqual(EditorDiskSync.decide(exists: true, diskTextMatchesLastSeen: false, hasUnsavedEdits: false), .reload)
        XCTAssertEqual(EditorDiskSync.decide(exists: true, diskTextMatchesLastSeen: false, hasUnsavedEdits: true), .conflict)
    }

    func testACleanDocumentFollowsTheAgent() throws {
        let path = try write("one\n", to: "a.swift")
        let editors = EditorWorkspace()
        let document = try editors.open(path: path)
        _ = try write("one\ntwo\n", to: "a.swift")
        document.checkDisk()
        XCTAssertEqual(document.text, "one\ntwo\n")
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(document.diskState, .inSync)
        XCTAssertNotNil(document.lastExternalReload)
    }

    func testUnsavedEditsAreNeverOverwrittenByDisk() throws {
        let path = try write("one\n", to: "b.swift")
        let document = try EditorWorkspace().open(path: path)
        edit(document, append: "mine\n")
        XCTAssertTrue(document.isDirty)

        _ = try write("agent\n", to: "b.swift")
        document.checkDisk()
        XCTAssertEqual(document.diskState, .conflict)
        XCTAssertEqual(document.text, "one\nmine\n", "the user's edit survives")
        XCTAssertEqual(document.conflictingDiskText, "agent\n")

        // Saving while unresolved must not silently overwrite the agent's write.
        XCTAssertThrowsError(try document.save())
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "agent\n")
    }

    func testKeepMineThenSaveOverwrites() throws {
        let path = try write("one\n", to: "c.swift")
        let document = try EditorWorkspace().open(path: path)
        edit(document, append: "mine\n")
        _ = try write("agent\n", to: "c.swift")
        document.checkDisk()
        document.resolveByKeepingMine()
        XCTAssertEqual(document.diskState, .inSync)
        XCTAssertTrue(document.isDirty)
        try document.save()
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "one\nmine\n")
        XCTAssertFalse(document.isDirty)
    }

    func testTakeDiskDiscardsEditsAndUndo() throws {
        let path = try write("one\n", to: "d.swift")
        let document = try EditorWorkspace().open(path: path)
        edit(document, append: "mine\n")
        _ = try write("agent\n", to: "d.swift")
        document.checkDisk()
        document.resolveByReloading()
        XCTAssertEqual(document.text, "agent\n")
        XCTAssertFalse(document.isDirty)
        XCTAssertFalse(document.undoManager.canUndo, "undo must not resurrect text that described the old file")
    }

    func testCRLFFilesKeepTheirEndings() throws {
        let path = try write("a\r\nb\r\n", to: "e.txt")
        let document = try EditorWorkspace().open(path: path)
        XCTAssertEqual(document.text, "a\nb\n", "edited as LF")
        edit(document, append: "c\n")
        try document.save()
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "a\r\nb\r\nc\r\n")
    }

    func testDeletionIsFlaggedAndSaveWritesItBack() throws {
        let path = try write("keep\n", to: "f.swift")
        let document = try EditorWorkspace().open(path: path)
        try FileManager.default.removeItem(atPath: path)
        document.checkDisk()
        XCTAssertEqual(document.diskState, .deleted)
        XCTAssertEqual(document.text, "keep\n")
        try document.save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(document.diskState, .inSync)
    }

    func testOpeningTwiceReusesTheTabAndRevealsTheLine() throws {
        let path = try write("1\n2\n3\n", to: "g.swift")
        let editors = EditorWorkspace()
        let first = try editors.open(path: path)
        let second = try editors.open(path: directory.appendingPathComponent("./g.swift").path, line: 3)
        XCTAssertTrue(first === second)
        XCTAssertEqual(editors.documents.count, 1)
        XCTAssertEqual(second.pendingReveal, 3)
    }

    func testRelativePathsResolveAgainstTheWorkspace() throws {
        _ = try write("x", to: "h.swift")
        let editors = EditorWorkspace()
        let document = try editors.open(path: "h.swift", workspaceRoot: directory.path)
        XCTAssertEqual(EditorWorkspace.relativePath(document.path, root: directory.path), "h.swift")
    }

    func testBinaryFilesAreRefused() throws {
        let url = directory.appendingPathComponent("image.bin")
        try Data([0xFF, 0xD8, 0xFF, 0x00, 0xC3, 0x28]).write(to: url)
        XCTAssertThrowsError(try EditorWorkspace().open(path: url.path))
    }

    func testClosingTheActiveTabActivatesANeighbour() throws {
        let editors = EditorWorkspace()
        let a = try editors.open(path: try write("a", to: "a1.swift"))
        let b = try editors.open(path: try write("b", to: "b1.swift"))
        XCTAssertEqual(editors.activeDocumentId, b.id)
        editors.close(b.id)
        XCTAssertEqual(editors.activeDocumentId, a.id)
        editors.close(a.id)
        XCTAssertNil(editors.activeDocumentId)
    }

    func testSaveAllReportsFailuresAndSavesTheRest() throws {
        let editors = EditorWorkspace()
        let good = try editors.open(path: try write("a", to: "ok.swift"))
        let bad = try editors.open(path: try write("b", to: "conflicted.swift"))
        edit(good, append: "!")
        edit(bad, append: "!")
        _ = try write("agent", to: "conflicted.swift")
        bad.checkDisk()
        let failures = editors.saveAll()
        XCTAssertEqual(failures.map(\.fileName), ["conflicted.swift"])
        XCTAssertFalse(good.isDirty)
    }
}
