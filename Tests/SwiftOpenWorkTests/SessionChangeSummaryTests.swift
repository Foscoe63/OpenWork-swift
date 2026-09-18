import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore

/// Per-turn review reads the checkpoint store, which holds real contents but only for this turn.
/// A session-wide view has to come from the transcript, and can therefore only say what was touched
/// and when — never restore it. These tests pin the weaker claim being made accurately.
final class SessionChangeSummaryTests: XCTestCase {

    private func message(
        _ calls: [(String, String, ToolCallStatus)],
        at seconds: TimeInterval = 0
    ) -> ChatMessage {
        var m = ChatMessage(sessionId: "s", role: .assistant, content: "")
        m.timestamp = Date(timeIntervalSince1970: seconds)
        m.toolCalls = calls.map { name, path, status in
            ToolCallInfo(
                id: UUID().uuidString,
                toolName: name,
                argumentsJson: "{\"path\":\"\(path)\"}",
                status: status
            )
        }
        return m
    }

    func testCollectsWritesEditsAndDeletes() {
        let files = SessionChangeSummary.changedFiles(in: [
            message([("file_write", "/repo/A.swift", .success)], at: 1),
            message([("edit_file", "/repo/B.swift", .success)], at: 2),
            message([("file_delete", "/repo/C.swift", .success)], at: 3)
        ], workspaceRoot: "/repo")

        XCTAssertEqual(files.map(\.path), ["C.swift", "B.swift", "A.swift"], "most recent first")
        XCTAssertTrue(files.first { $0.path == "A.swift" }?.wrote == true)
        XCTAssertTrue(files.first { $0.path == "B.swift" }?.edited == true)
        XCTAssertTrue(files.first { $0.path == "C.swift" }?.deleted == true)
    }

    func testMultiEditCountsAsAnEdit() {
        let files = SessionChangeSummary.changedFiles(in: [
            message([("multi_edit", "/repo/A.swift", .success)], at: 1)
        ], workspaceRoot: "/repo")
        XCTAssertEqual(files.first?.edited, true)
    }

    func testRepeatedTouchesCollapseIntoOneRowWithACount() {
        let files = SessionChangeSummary.changedFiles(in: [
            message([("edit_file", "/repo/A.swift", .success)], at: 1),
            message([("edit_file", "/repo/A.swift", .success)], at: 5)
        ], workspaceRoot: "/repo")

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.touches, 2)
        XCTAssertEqual(files.first?.lastTouchedAt, Date(timeIntervalSince1970: 5))
        XCTAssertTrue(files.first?.summary.contains("2 times") == true)
    }

    /// A failed write changed nothing; listing it sends a reviewer hunting a diff that is not there.
    func testFailedCallsAreNotListed() {
        let files = SessionChangeSummary.changedFiles(in: [
            message([("file_write", "/repo/A.swift", .error)], at: 1),
            message([("edit_file", "/repo/B.swift", .failed)], at: 2)
        ], workspaceRoot: "/repo")
        XCTAssertTrue(files.isEmpty)
    }

    func testReadsAndCommandsAreNotChanges() {
        let files = SessionChangeSummary.changedFiles(in: [
            message([("read_file", "/repo/A.swift", .success)], at: 1),
            message([("grep", "/repo", .success)], at: 2)
        ], workspaceRoot: "/repo")
        XCTAssertTrue(files.isEmpty)
    }

    func testPathsOutsideTheWorkspaceStayAbsolute() {
        let files = SessionChangeSummary.changedFiles(in: [
            message([("file_write", "/elsewhere/X.swift", .success)], at: 1)
        ], workspaceRoot: "/repo")
        XCTAssertEqual(files.map(\.path), ["/elsewhere/X.swift"])
    }

    func testSummaryDescribesASingleTouchWithoutACount() {
        let files = SessionChangeSummary.changedFiles(in: [
            message([("file_write", "/repo/A.swift", .success)], at: 1)
        ], workspaceRoot: "/repo")
        XCTAssertEqual(files.first?.summary, "written — once")
    }
}
