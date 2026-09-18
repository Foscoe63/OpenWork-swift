import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkEngine

/// A run with no window has nobody to approve a sensitive tool call. Awaiting one would hang until
/// the caller gave up, leaving a half-finished turn and no explanation; auto-approving would hand
/// out more power exactly where there is least oversight. So it is refused and recorded.
@MainActor
final class UnattendedApprovalTests: XCTestCase {

    override func setUp() async throws {
        // The manager is a singleton, so leave it as we found it for the rest of the suite.
        while ToolApprovalManager.shared.isUnattended {
            ToolApprovalManager.shared.endUnattended()
        }
        ToolApprovalManager.shared.rejectAllPending()
    }

    override func tearDown() async throws {
        while ToolApprovalManager.shared.isUnattended {
            ToolApprovalManager.shared.endUnattended()
        }
        ToolApprovalManager.shared.rejectAllPending()
    }

    func testAttendedRequestWaitsForAPerson() async {
        let manager = ToolApprovalManager.shared
        let pending = Task { @MainActor in
            await manager.requestApproval(
                callId: "c1", toolName: "file_delete", argumentsJson: "{}", reason: "deletes a file"
            )
        }
        // Give the request a chance to enqueue before answering it.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(manager.pendingApprovals.count, 1)
        manager.resolve(callId: "c1", approved: true)
        let outcome = await pending.value
        XCTAssertEqual(outcome, .approved)
    }

    func testUnattendedRequestIsRefusedImmediately() async {
        let manager = ToolApprovalManager.shared
        manager.beginUnattended()
        defer { manager.endUnattended() }

        let outcome = await manager.requestApproval(
            callId: "c2", toolName: "file_delete", argumentsJson: "{}", reason: "deletes a file"
        )
        XCTAssertEqual(outcome, .refusedUnattended)
        XCTAssertNotEqual(outcome, .rejected, "nobody rejected it; nobody was asked")
    }

    /// A queued prompt nothing can resolve would surface as a live approval the next time the user
    /// opened the app, for a call that already finished.
    func testUnattendedRequestIsNotQueued() async {
        let manager = ToolApprovalManager.shared
        manager.beginUnattended()
        defer { manager.endUnattended() }

        _ = await manager.requestApproval(
            callId: "c3", toolName: "terminal_command", argumentsJson: "{}", reason: "runs a shell command"
        )
        XCTAssertTrue(manager.pendingApprovals.isEmpty)
    }

    func testRefusalsAreRecordedSoTheCallerCanSayWhatWasSkipped() async {
        let manager = ToolApprovalManager.shared
        manager.beginUnattended()
        _ = await manager.requestApproval(
            callId: "c4", toolName: "file_delete", argumentsJson: "{}", reason: "deletes a file"
        )
        manager.endUnattended()

        XCTAssertEqual(manager.refusedWhileUnattended.map(\.toolName), ["file_delete"])
    }

    func testANewScopeStartsWithAnEmptyRecord() async {
        let manager = ToolApprovalManager.shared
        manager.beginUnattended()
        _ = await manager.requestApproval(
            callId: "c5", toolName: "file_delete", argumentsJson: "{}", reason: "deletes a file"
        )
        manager.endUnattended()
        XCTAssertFalse(manager.refusedWhileUnattended.isEmpty)

        manager.beginUnattended()
        XCTAssertTrue(manager.refusedWhileUnattended.isEmpty, "a later run must not report an earlier run's skips")
        manager.endUnattended()
    }

    /// Depth, not a flag: an inner scope finishing must not re-arm approval prompts for the outer
    /// run that is still headless.
    func testNestedScopesDoNotEndEachOther() {
        let manager = ToolApprovalManager.shared
        manager.beginUnattended()
        manager.beginUnattended()
        manager.endUnattended()
        XCTAssertTrue(manager.isUnattended)
        manager.endUnattended()
        XCTAssertFalse(manager.isUnattended)
    }

    func testEndingMoreThanBegunDoesNotGoNegative() {
        let manager = ToolApprovalManager.shared
        manager.endUnattended()
        manager.endUnattended()
        manager.beginUnattended()
        XCTAssertTrue(manager.isUnattended, "a stray end must not leave the next scope attended")
        manager.endUnattended()
        XCTAssertFalse(manager.isUnattended)
    }

    // MARK: - What the caller says

    func testSpokenResultStatesWhatWasSkipped() {
        let result = HeadlessAgentTurn.Result(
            reply: "I updated the changelog.",
            skipped: ["file_delete — deletes a file"],
            sessionId: "s"
        )
        XCTAssertTrue(result.spoken.contains("I updated the changelog."))
        XCTAssertTrue(result.spoken.contains("file_delete"))
        XCTAssertTrue(result.spoken.lowercased().contains("approval"))
    }

    func testSpokenResultIsJustTheReplyWhenNothingWasSkipped() {
        let result = HeadlessAgentTurn.Result(reply: "Done.", skipped: [], sessionId: "s")
        XCTAssertEqual(result.spoken, "Done.")
    }

    /// Silence plus a skip list would sound like the job was mostly done.
    func testSpokenResultSaysSoWhenThereIsNoReplyAtAll() {
        let result = HeadlessAgentTurn.Result(
            reply: "   ",
            skipped: ["terminal_command — runs a shell command"],
            sessionId: "s"
        )
        XCTAssertTrue(result.spoken.contains("stopped before it produced an answer"))
    }
}
