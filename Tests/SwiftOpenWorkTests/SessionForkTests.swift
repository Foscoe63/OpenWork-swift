import XCTest
@testable import SwiftOpenWork

/// A long session that went 80% right and then took one bad turn has, today, only two bad
/// recoveries: argue inside the same transcript (leaving the bad turn in context, steering
/// everything after it) or start over. Forking is the third. What it must never do is *imply* it
/// restored files it cannot restore.
final class SessionForkTests: XCTestCase {

    private func session(messageCount: Int, title: String = "Fix the parser") -> Session {
        var s = Session(title: title)
        for i in 0..<messageCount {
            s.messages.append(ChatMessage(
                sessionId: s.id,
                role: i % 2 == 0 ? .user : .assistant,
                content: "m\(i)"
            ))
        }
        return s
    }

    func testForkKeepsEverythingUpToAndIncludingTheChosenMessage() throws {
        let original = session(messageCount: 6)
        let outcome = try XCTUnwrap(SessionFork.fork(original, at: original.messages[2].id))
        XCTAssertEqual(outcome.session.messages.map(\.content), ["m0", "m1", "m2"])
    }

    func testForkAtTheLastMessageIsRefused() {
        let original = session(messageCount: 4)
        XCTAssertNil(SessionFork.fork(original, at: original.messages[3].id),
                     "that would be a copy, not a branch")
    }

    func testForkOfAnUnknownMessageIsRefused() {
        XCTAssertNil(SessionFork.fork(session(messageCount: 4), at: "not-a-message"))
    }

    func testForkGetsItsOwnIdentityAndRecordsItsParent() throws {
        let original = session(messageCount: 6)
        let cutId = original.messages[2].id
        let outcome = try XCTUnwrap(SessionFork.fork(original, at: cutId))

        XCTAssertNotEqual(outcome.session.id, original.id)
        XCTAssertEqual(outcome.session.forkedFromSessionId, original.id)
        XCTAssertEqual(outcome.session.forkedAtMessageId, cutId)
    }

    /// Two transcripts sharing message session ids would write into each other.
    func testForkedMessagesAreReboundToTheNewSession() throws {
        let original = session(messageCount: 6)
        let outcome = try XCTUnwrap(SessionFork.fork(original, at: original.messages[2].id))
        XCTAssertTrue(outcome.session.messages.allSatisfy { $0.sessionId == outcome.session.id })
    }

    func testTokenTotalsDoNotCarryForward() throws {
        var original = session(messageCount: 6)
        original.totalPromptTokens = 5000
        original.totalCompletionTokens = 900
        original.estimatedCost = 1.25

        let outcome = try XCTUnwrap(SessionFork.fork(original, at: original.messages[2].id))
        XCTAssertEqual(outcome.session.totalPromptTokens, 0)
        XCTAssertEqual(outcome.session.totalCompletionTokens, 0)
        XCTAssertEqual(outcome.session.estimatedCost, 0)
    }

    // MARK: - The part that must not lie

    private func sessionWithFileChangesAfterCut() -> (Session, String) {
        var s = session(messageCount: 3)
        let cutId = s.messages[1].id
        var assistant = ChatMessage(sessionId: s.id, role: .assistant, content: "editing")
        assistant.toolCalls = [
            ToolCallInfo(
                id: "t1",
                toolName: "edit_file",
                argumentsJson: "{\"path\":\"/repo/Parser.swift\"}",
                status: .success
            ),
            ToolCallInfo(
                id: "t2",
                toolName: "file_write",
                argumentsJson: "{\"path\":\"/repo/Lexer.swift\"}",
                status: .success
            )
        ]
        s.messages.insert(assistant, at: 2)
        return (s, cutId)
    }

    func testDiscardedFileChangesAreReportedBecauseTheyAreStillOnDisk() throws {
        let (original, cutId) = sessionWithFileChangesAfterCut()
        let outcome = try XCTUnwrap(SessionFork.fork(original, at: cutId))

        XCTAssertEqual(Set(outcome.divergedFiles), ["Parser.swift", "Lexer.swift"])

        let note = try XCTUnwrap(outcome.session.messages.last)
        XCTAssertTrue(note.content.contains("still on disk"),
                      "a fork that silently dropped the turns would leave the transcript claiming a file state that is not true")
        XCTAssertTrue(note.content.contains("Parser.swift"))
        XCTAssertTrue(note.content.contains("Lexer.swift"))
    }

    /// No file changes means no divergence, so the note would be noise.
    func testNoNoteWhenTheDiscardedTurnsTouchedNoFiles() throws {
        let original = session(messageCount: 6)
        let outcome = try XCTUnwrap(SessionFork.fork(original, at: original.messages[2].id))
        XCTAssertTrue(outcome.divergedFiles.isEmpty)
        XCTAssertEqual(outcome.session.messages.count, 3, "no note should have been appended")
    }

    // MARK: - Titles

    func testFirstForkIsLabelled() throws {
        let original = session(messageCount: 6, title: "Fix the parser")
        let outcome = try XCTUnwrap(SessionFork.fork(original, at: original.messages[2].id))
        XCTAssertEqual(outcome.session.title, "Fix the parser (fork)")
    }

    func testForkingAForkCountsRatherThanNesting() throws {
        let first = session(messageCount: 6, title: "Fix the parser (fork)")
        let second = try XCTUnwrap(SessionFork.fork(first, at: first.messages[2].id))
        XCTAssertEqual(second.session.title, "Fix the parser (fork 2)")

        var third = session(messageCount: 6, title: second.session.title)
        third.title = second.session.title
        let fourth = try XCTUnwrap(SessionFork.fork(third, at: third.messages[2].id))
        XCTAssertEqual(fourth.session.title, "Fix the parser (fork 3)")
    }

    // MARK: - Persistence

    /// Sessions saved before forking existed have neither field; they must still decode.
    func testOlderSessionsWithoutForkFieldsStillDecode() throws {
        let json = """
        {"id":"s1","workspaceId":"w","title":"Old","agentId":"a","providerId":"p","modelId":"m",
         "isArchived":false,"isPinned":false,"createdAt":0,"updatedAt":0,"messages":[],
         "activeSubAgentTasks":[],"interAgentMessages":[],
         "totalPromptTokens":0,"totalCompletionTokens":0,"estimatedCost":0}
        """
        let decoded = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        XCTAssertNil(decoded.forkedFromSessionId)
        XCTAssertNil(decoded.forkedAtMessageId)
    }
}
