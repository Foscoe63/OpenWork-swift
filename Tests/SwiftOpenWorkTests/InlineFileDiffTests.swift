import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine

/// A diff shown in a card is read instead of the file, so being wrong here is worse than showing
/// nothing: it invites someone to approve a change they did not actually see.
final class InlineFileDiffTests: XCTestCase {

    private var root: String!
    private var workspace: Workspace!
    private var agent: Agent!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "ow-diff-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        workspace = Workspace(name: "Diff", folderPath: root)
        agent = Agent(name: "Runner", role: "executor")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func path(_ name: String) -> String { root + "/" + name }

    private func run(_ tool: String, _ args: [String: Any]) async -> ToolExecutionResult {
        let json = String(data: try! JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        return await ToolExecutionEngine.shared.execute(
            toolName: tool, argumentsJson: json, workspace: workspace, currentAgent: agent
        )
    }

    // MARK: - The diff itself

    func testAnUnchangedFileProducesNoDiff() {
        XCTAssertNil(InlineFileDiff.between(before: "same", after: "same", path: "/a"))
    }

    func testCountsMatchTheLinesActuallyChanged() throws {
        let diff = try XCTUnwrap(InlineFileDiff.between(
            before: "a\nb\nc\n",
            after: "a\nB\nc\nd\n",
            path: "/a"
        ))
        XCTAssertEqual(diff.kind, .modified)
        XCTAssertEqual(diff.added, 2, "the replacement line and the appended one")
        XCTAssertEqual(diff.removed, 1)
    }

    func testANewFileIsReportedAsCreatedWithEveryLineAdded() throws {
        let diff = try XCTUnwrap(InlineFileDiff.between(before: nil, after: "one\ntwo\n", path: "/a"))
        XCTAssertEqual(diff.kind, .created)
        XCTAssertEqual(diff.added, 2)
        XCTAssertEqual(diff.removed, 0)
    }

    func testADeletedFileIsReportedAsDeleted() throws {
        let diff = try XCTUnwrap(InlineFileDiff.between(before: "one\ntwo\n", after: nil, path: "/a"))
        XCTAssertEqual(diff.kind, .deleted)
        XCTAssertEqual(diff.removed, 2)
        XCTAssertEqual(diff.added, 0)
    }

    /// A trailing newline terminates the last line; counting it as an extra empty one would report
    /// a phantom added line on almost every edit.
    func testATrailingNewlineIsNotAnExtraLine() throws {
        let diff = try XCTUnwrap(InlineFileDiff.between(before: "a\n", after: "a\nb\n", path: "/a"))
        XCTAssertEqual(diff.added, 1)
        XCTAssertEqual(diff.removed, 0)
    }

    /// The reason for doing a real LCS rather than walking both sides greedily: inserting a line
    /// must not read as "rewrote everything below it".
    func testInsertingALineDoesNotRewriteTheRestOfTheFile() throws {
        let before = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let after = before.replacingOccurrences(of: "line 10", with: "line 10\ninserted")
        let diff = try XCTUnwrap(InlineFileDiff.between(before: before, after: after, path: "/a"))
        XCTAssertEqual(diff.added, 1)
        XCTAssertEqual(diff.removed, 0)
    }

    func testOnlyChangedLinesAndTheirContextAreKept() throws {
        let before = (1...60).map { "line \($0)" }.joined(separator: "\n")
        let after = before.replacingOccurrences(of: "line 30", with: "changed")
        let diff = try XCTUnwrap(InlineFileDiff.between(before: before, after: after, path: "/a"))

        XCTAssertLessThan(diff.lines.count, 12, "fifty-odd untouched lines should not be in the card")
        let texts = diff.lines.map(\.text)
        XCTAssertTrue(texts.contains("changed"))
        XCTAssertTrue(texts.contains("line 29"), "a little context on each side is the point")
        XCTAssertFalse(texts.contains("line 5"))
    }

    func testAVeryLargeChangeIsCountedButNotRendered() throws {
        let huge = (1...(InlineFileDiff.maxComparableLines + 10)).map(String.init).joined(separator: "\n")
        let diff = try XCTUnwrap(InlineFileDiff.between(before: nil, after: huge, path: "/a"))
        XCTAssertTrue(diff.truncated)
        XCTAssertTrue(diff.lines.isEmpty, "a card is not the place to render a 4000-line file")
        XCTAssertGreaterThan(diff.added, InlineFileDiff.maxComparableLines)
    }

    func testTheRenderedBodyIsBounded() throws {
        let before = (1...300).map { "line \($0)" }.joined(separator: "\n")
        let after = (1...300).map { "changed \($0)" }.joined(separator: "\n")
        let diff = try XCTUnwrap(InlineFileDiff.between(before: before, after: after, path: "/a"))
        XCTAssertLessThanOrEqual(diff.lines.count, InlineFileDiff.maxRenderedLines)
        XCTAssertTrue(diff.truncated)
    }

    func testLineNumbersPointAtTheRightSides() throws {
        let diff = try XCTUnwrap(InlineFileDiff.between(before: "a\nb\nc", after: "a\nB\nc", path: "/a"))
        let removed = try XCTUnwrap(diff.lines.first { $0.kind == .removed })
        let added = try XCTUnwrap(diff.lines.first { $0.kind == .added })
        XCTAssertEqual(removed.oldNumber, 2)
        XCTAssertNil(removed.newNumber)
        XCTAssertEqual(added.newNumber, 2)
        XCTAssertNil(added.oldNumber)
    }

    // MARK: - Which tools get one

    func testEditToolsGetADiffTarget() {
        for tool in ["file_write", "edit_file", "multi_edit", "file_delete"] {
            XCTAssertNotNil(
                ToolExecutionEngine.diffTarget(
                    toolName: tool, argumentsJson: #"{"path":"a.swift"}"#, workspace: workspace
                ),
                "\(tool) edits one named file"
            )
        }
    }

    /// Showing one of the eleven files `rename_symbol` touched would be worse than showing none.
    func testToolsThatTouchManyFilesGetNoInlineDiff() {
        for tool in ["rename_symbol", "terminal_command", "revert_changes", "file_read"] {
            XCTAssertNil(
                ToolExecutionEngine.diffTarget(
                    toolName: tool, argumentsJson: #"{"path":"a.swift"}"#, workspace: workspace
                ),
                "\(tool) should not claim a single-file diff"
            )
        }
    }

    func testRelativePathsAreResolvedAgainstTheWorkspace() {
        let target = ToolExecutionEngine.diffTarget(
            toolName: "file_write", argumentsJson: #"{"path":"src/a.swift"}"#, workspace: workspace
        )
        XCTAssertEqual(target, root + "/src/a.swift")
    }

    // MARK: - End to end through the engine

    func testWritingAFileAttachesADiffToTheResult() async throws {
        try "one\ntwo\n".write(toFile: path("a.txt"), atomically: true, encoding: .utf8)
        let result = await run("file_write", ["path": path("a.txt"), "content": "one\nTWO\n"])
        XCTAssertTrue(result.success, result.error ?? "")
        let diff = try XCTUnwrap(result.fileDiff, "an edit should carry what it changed")
        XCTAssertEqual(diff.added, 1)
        XCTAssertEqual(diff.removed, 1)
        XCTAssertEqual(diff.path, path("a.txt"))
    }

    func testEditFileAttachesADiff() async throws {
        try "let a = 1\nlet b = 2\n".write(toFile: path("b.swift"), atomically: true, encoding: .utf8)
        let result = await run("edit_file", [
            "path": path("b.swift"), "old_string": "let a = 1", "new_string": "let a = 99",
        ])
        XCTAssertTrue(result.success, result.error ?? "")
        let diff = try XCTUnwrap(result.fileDiff)
        XCTAssertTrue(diff.lines.contains { $0.kind == .added && $0.text.contains("99") })
    }

    /// Writing the same bytes back succeeds; a card claiming a change would be a lie.
    func testARewriteWithIdenticalContentCarriesNoDiff() async throws {
        try "unchanged\n".write(toFile: path("c.txt"), atomically: true, encoding: .utf8)
        let result = await run("file_write", ["path": path("c.txt"), "content": "unchanged\n"])
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertNil(result.fileDiff)
    }

    func testAFailedEditCarriesNoDiff() async throws {
        try "hello\n".write(toFile: path("d.txt"), atomically: true, encoding: .utf8)
        let result = await run("edit_file", [
            "path": path("d.txt"), "old_string": "not present", "new_string": "x",
        ])
        XCTAssertFalse(result.success)
        XCTAssertNil(result.fileDiff)
    }

    func testDeletingAFileCarriesADeletionDiff() async throws {
        try "gone\nsoon\n".write(toFile: path("e.txt"), atomically: true, encoding: .utf8)
        let result = await run("file_delete", ["path": path("e.txt")])
        XCTAssertTrue(result.success, result.error ?? "")
        let diff = try XCTUnwrap(result.fileDiff)
        XCTAssertEqual(diff.kind, .deleted)
        XCTAssertEqual(diff.removed, 2)
    }

    func testARunCommandCarriesNoDiff() async throws {
        let result = await run("terminal_command", ["command": "echo hi", "cwd": root!])
        XCTAssertNil(result.fileDiff)
    }

    /// The diff rides along in the transcript, so it has to survive being written and read back.
    func testADiffRoundTripsThroughTheTranscriptEncoding() throws {
        let diff = try XCTUnwrap(InlineFileDiff.between(before: "a\nb", after: "a\nc", path: "/x"))
        let call = ToolCallInfo(toolName: "edit_file", fileDiff: diff)
        let data = try JSONEncoder().encode(call)
        let decoded = try JSONDecoder().decode(ToolCallInfo.self, from: data)
        XCTAssertEqual(decoded.fileDiff, diff)
    }

    /// Old sessions were written before the field existed and must still open.
    func testATranscriptWithoutADiffStillDecodes() throws {
        let json = #"{"id":"1","toolName":"edit_file","argumentsJson":"{}","status":"success","durationMs":0,"timestamp":0}"#
        let decoded = try JSONDecoder().decode(ToolCallInfo.self, from: Data(json.utf8))
        XCTAssertNil(decoded.fileDiff)
    }

    // MARK: - Multi-file

    /// A rename card has to list every file it reached, not one of them.
    func testARenameCarriesADiffForEveryFileItWrote() async throws {
        try "struct Widget {}\n".write(toFile: path("Widget.swift"), atomically: true, encoding: .utf8)
        try "let a = Widget()\n".write(toFile: path("A.swift"), atomically: true, encoding: .utf8)
        try "let b = Widget()\nlet c = 1\n".write(toFile: path("B.swift"), atomically: true, encoding: .utf8)

        let result = await run("rename_symbol", ["old_name": "Widget", "new_name": "Gadget"])
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertNil(result.fileDiff, "a multi-file call must not pick one file to show")
        let diffs = try XCTUnwrap(result.fileDiffs)
        XCTAssertEqual(Set(diffs.map { ($0.path as NSString).lastPathComponent }), ["Widget.swift", "A.swift", "B.swift"])
        XCTAssertTrue(diffs.allSatisfy { $0.added == 1 && $0.removed == 1 })
    }

    func testADryRunRenameCarriesNoDiffs() async throws {
        try "struct Widget {}\n".write(toFile: path("Widget.swift"), atomically: true, encoding: .utf8)
        let result = await run("rename_symbol", ["old_name": "Widget", "new_name": "Gadget", "dry_run": true])
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertNil(result.fileDiffs, "nothing was written, so there is nothing to show as changed")
    }

    /// Past the budget, files keep their counts and lose their bodies — never dropped from the list.
    func testTheBoundedSetKeepsEveryFileButCapsTheBodies() throws {
        let many = (0..<20).compactMap { i in
            InlineFileDiff.between(before: "a\nb\nc", after: "a\nX\nc", path: "/f\(i)")
        }
        let bounded = InlineFileDiff.boundedSet(many, maxFilesWithBodies: 5, maxTotalLines: 1_000)
        XCTAssertEqual(bounded.count, 20)
        XCTAssertEqual(bounded.filter { !$0.lines.isEmpty }.count, 5)
        XCTAssertTrue(bounded.dropFirst(5).allSatisfy { $0.truncated && $0.added == 1 })
    }
}
