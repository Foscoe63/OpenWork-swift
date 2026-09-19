import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine

final class VibeCodingSurfaceTests: XCTestCase {

    func testSessionTodoParseMapsStatuses() {
        let items: [[String: Any]] = [
            ["content": "One", "status": "pending"],
            ["id": "a", "content": "Two", "status": "in_progress"],
            ["content": "Three", "status": "done"],
        ]
        let todos = SessionTodoItem.parse(from: items)
        XCTAssertEqual(todos.count, 3)
        XCTAssertEqual(todos[0].status, .pending)
        XCTAssertEqual(todos[1].id, "a")
        XCTAssertEqual(todos[1].status, .inProgress)
        XCTAssertEqual(todos[2].status, .done)
    }

    func testComposerMentionEnrichInjectsFileBlock() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ow-mention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("Hello.swift")
        try "struct Hello {}".write(to: file, atomically: true, encoding: .utf8)

        let enriched = ComposerContextMentions.enrich(
            text: "Explain @Hello.swift please",
            workspacePath: dir.path
        )
        XCTAssertTrue(enriched.modelText.contains("### Attached context"))
        XCTAssertTrue(enriched.modelText.contains("struct Hello"))
        XCTAssertEqual(enriched.userVisible, "Explain @Hello.swift please")
    }

    func testDiagnosticLinkParserFindsCompilerLines() {
        let output = """
        /tmp/App.swift:12:5: error: cannot find 'foo'
        note: ignore me
        /tmp/App.swift:12:5: error: cannot find 'foo'
        Sources/Main.swift:3: warning: unused
        """
        let links = DiagnosticLinkParser.links(in: output)
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].file, "/tmp/App.swift")
        XCTAssertEqual(links[0].line, 12)
        XCTAssertEqual(links[1].file, "Sources/Main.swift")
        XCTAssertEqual(links[1].line, 3)
    }

    func testSymbolRenameDryRunAndWrite() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ow-rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("Widget.swift")
        try """
        struct Widget {}
        let x = Widget()
        """.write(to: file, atomically: true, encoding: .utf8)

        let dry = try await SymbolRename.rename(
            oldName: "Widget",
            newName: "Gadget",
            root: dir.path,
            dryRun: true
        )
        XCTAssertTrue(dry.dryRun)
        XCTAssertGreaterThan(dry.occurrenceCount, 0)
        let before = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(before.contains("Widget"))

        let live = try await SymbolRename.rename(
            oldName: "Widget",
            newName: "Gadget",
            root: dir.path,
            dryRun: false
        )
        XCTAssertFalse(live.dryRun)
        let after = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(after.contains("Gadget"))
        XCTAssertFalse(after.contains("Widget"))
    }

    /// Grep's file list is capped. A rename that trusted a capped list would rename some files and
    /// report success, so a truncated search must reach the caller as truncated.
    func testGrepReportsTruncationWhenTheFileListItselfIsCapped() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ow-grepcap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<5_010 {
            try "nothing here\n".write(to: dir.appendingPathComponent("f\(i).txt"), atomically: false, encoding: .utf8)
        }
        let result = try CodeSearch.grep(pattern: "absent", root: dir.path, limit: 10)
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertTrue(result.truncated, "5,010 files with a 5,000-file listing is not a complete search")
    }

    func testMentionWithLineNumberYieldsFocusedExcerpt() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ow-focus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("Big.swift")
        let body = (1...200).map { "line \($0)" }.joined(separator: "\n")
        try body.write(to: file, atomically: true, encoding: .utf8)

        let enriched = ComposerContextMentions.enrich(
            text: "fix @Big.swift:120 please",
            workspacePath: dir.path
        )
        XCTAssertTrue(enriched.modelText.contains("focus line 120"))
        XCTAssertTrue(enriched.modelText.contains(">>> 120| line 120"))
        // A window, not the whole file.
        XCTAssertFalse(enriched.modelText.contains("line 1\n"))
        XCTAssertFalse(enriched.modelText.contains("| line 200"))
    }

    func testMentionWithLineRangeAttachesExactlyThoseLines() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ow-range-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("Big.swift")
        let body = (1...200).map { "line \($0)" }.joined(separator: "\n")
        try body.write(to: file, atomically: true, encoding: .utf8)

        let enriched = ComposerContextMentions.enrich(
            text: "tidy @Big.swift:120-140, thanks",
            workspacePath: dir.path
        )
        XCTAssertTrue(enriched.modelText.contains("selected lines 120–140 of 200"))
        XCTAssertTrue(enriched.modelText.contains(">>> 120| line 120"))
        XCTAssertTrue(enriched.modelText.contains(">>> 140| line 140"))
        XCTAssertFalse(enriched.modelText.contains("| line 119\n"))
        XCTAssertFalse(enriched.modelText.contains("| line 141\n"))
    }

    func testMentionTokenParsesLineRange() {
        let range = ComposerContextMentions.parseMentionToken("Sources/A.swift:12-40")
        XCTAssertEqual(range.pathToken, "Sources/A.swift")
        XCTAssertEqual(range.line, 12)
        XCTAssertEqual(range.endLine, 40)
        XCTAssertNil(ComposerContextMentions.parseMentionToken("Sources/A.swift:12-12").endLine)
        XCTAssertEqual(ComposerContextMentions.activeQuery(in: "see @Foo.swift:1-9"), "Foo.swift")
    }

    func testLineSpanIgnoresTrailingNewlineOfWholeLineSelection() {
        let text = "one\ntwo\nthree\n" as NSString
        // "two\n" selected: ends at the start of line 3, which is not part of the selection.
        XCTAssertTrue(EditorText.lineSpan(of: NSRange(location: 4, length: 4), in: text) == (2, 2))
        XCTAssertTrue(EditorText.lineSpan(of: NSRange(location: 0, length: 8), in: text) == (1, 2))
        XCTAssertTrue(EditorText.lineSpan(of: NSRange(location: 5, length: 0), in: text) == (2, 2))
        XCTAssertTrue(EditorText.lineSpan(of: NSRange(location: 2, length: 8), in: text) == (1, 3))
    }

    func testMentionTokenParsesTrailingLine() {
        XCTAssertEqual(ComposerContextMentions.parseMentionToken("Sources/A.swift:42").line, 42)
        XCTAssertEqual(ComposerContextMentions.parseMentionToken("Sources/A.swift:42").pathToken, "Sources/A.swift")
        XCTAssertNil(ComposerContextMentions.parseMentionToken("Sources/A.swift").line)
    }

    func testActiveQueryStripsTypedLineSuffix() {
        XCTAssertEqual(ComposerContextMentions.activeQuery(in: "see @Foo.swift:1"), "Foo.swift")
        XCTAssertEqual(ComposerContextMentions.activeQuery(in: "see @Foo"), "Foo")
        XCTAssertNil(ComposerContextMentions.activeQuery(in: "see @Foo.swift done"))
    }

    func testAttachmentIntakeClassifiesImagesAndText() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ow-intake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let text = dir.appendingPathComponent("Notes.md")
        try "# hello".write(to: text, atomically: true, encoding: .utf8)
        let textAttachment = try XCTUnwrap(ComposerAttachmentIntake.attachment(fromFileURL: text))
        XCTAssertEqual(textAttachment.mimeType, "text/plain")
        XCTAssertEqual(textAttachment.previewText, "# hello")
        XCTAssertFalse(ImageTransport.isImage(textAttachment))

        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let pasted = try XCTUnwrap(ComposerAttachmentIntake.attachment(fromPNGData: png, preferredName: "shot"))
        XCTAssertEqual(pasted.mimeType, "image/png")
        XCTAssertEqual(pasted.name, "shot.png")
        XCTAssertTrue(ImageTransport.isImage(pasted))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pasted.path))
        try? FileManager.default.removeItem(atPath: pasted.path)
    }

    func testSessionTodosSurviveCodableRoundTrip() throws {
        var session = Session(title: "t")
        session.todos = [
            SessionTodoItem(content: "Ship vibe UI", status: .inProgress),
            SessionTodoItem(content: "Done item", status: .done),
        ]
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(decoded.todos.count, 2)
        XCTAssertEqual(decoded.todos[0].status, .inProgress)
    }
}
