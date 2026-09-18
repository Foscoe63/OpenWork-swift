import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore

/// A long command that shows nothing until it exits is indistinguishable from a hung one, so these
/// cover the two halves of the fix: the tail reaching the running card, and the same bytes reaching
/// the terminal panel.
@MainActor
final class LiveToolOutputTests: XCTestCase {

    private var workspace: Workspace!
    private var agent: Agent!
    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "ow-live-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        workspace = Workspace(name: "Live", folderPath: root)
        agent = Agent(name: "Runner", role: "executor")
        WorkspaceTerminalSession.shared.clear()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    // MARK: - The tail itself

    func testTailAccumulatesChunksInOrder() {
        let store = LiveToolOutput.shared
        store.begin(callId: "c1")
        store.append(callId: "c1", chunk: "first\n")
        store.append(callId: "c1", chunk: "second\n")
        XCTAssertEqual(store.tail(for: "c1"), "first\nsecond\n")
        store.finish(callId: "c1")
    }

    /// This is a glance at progress, not a log — an unbounded tail would grow with the build.
    func testTailKeepsOnlyTheMostRecentLines() {
        let store = LiveToolOutput.shared
        store.begin(callId: "c2")
        for index in 1...(LiveToolOutput.maxTailLines + 20) {
            store.append(callId: "c2", chunk: "line \(index)\n")
        }
        let tail = try? XCTUnwrap(store.tail(for: "c2"))
        let lines = (tail ?? "").split(separator: "\n")
        XCTAssertLessThanOrEqual(lines.count, LiveToolOutput.maxTailLines)
        XCTAssertTrue((tail ?? "").contains("line \(LiveToolOutput.maxTailLines + 20)"), "newest line must survive")
        XCTAssertFalse((tail ?? "").contains("line 1\n"), "oldest lines should have been dropped")
        store.finish(callId: "c2")
    }

    /// The card shows the tail *or* the result, never both, so finishing has to clear it.
    func testFinishingClearsTheTailSoTheResultTakesOver() {
        let store = LiveToolOutput.shared
        store.begin(callId: "c3")
        store.append(callId: "c3", chunk: "working\n")
        XCTAssertNotNil(store.tail(for: "c3"))
        store.finish(callId: "c3")
        XCTAssertNil(store.tail(for: "c3"))
    }

    func testBlankOutputIsNotShownAsATail() {
        let store = LiveToolOutput.shared
        store.begin(callId: "c4")
        store.append(callId: "c4", chunk: "  \n \n")
        XCTAssertNil(store.tail(for: "c4"), "whitespace would render as an empty grey box")
        store.finish(callId: "c4")
    }

    func testCallsDoNotSeeEachOthersOutput() {
        let store = LiveToolOutput.shared
        store.begin(callId: "a")
        store.begin(callId: "b")
        store.append(callId: "a", chunk: "from a\n")
        XCTAssertEqual(store.tail(for: "a"), "from a\n")
        XCTAssertNil(store.tail(for: "b"))
        store.finish(callId: "a")
        store.finish(callId: "b")
    }

    // MARK: - Reaching the terminal panel

    private func waitForTerminal(
        containing needle: String,
        timeout: TimeInterval = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if WorkspaceTerminalSession.shared.lines.contains(where: { $0.text.contains(needle) }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    /// The panel already streamed commands the user typed. Agent commands went somewhere else
    /// entirely and showed nothing until they finished.
    func testAnAgentCommandIsMirroredIntoTheTerminalPanel() async throws {
        let marker = "hello-\(UUID().uuidString.prefix(6))"
        let json = #"{"command":"echo \#(marker)"}"#
        let result = await ToolExecutionEngine.shared.execute(
            toolName: "terminal_command",
            argumentsJson: json,
            workspace: workspace,
            currentAgent: agent,
            callId: "stream-1"
        )
        XCTAssertTrue(result.success, result.error ?? "")

        let sawCommand = await waitForTerminal(containing: "[agent] $ echo \(marker)")
        XCTAssertTrue(sawCommand, "the command itself should be announced in the panel")
        let sawOutput = await waitForTerminal(containing: marker)
        XCTAssertTrue(sawOutput, "its output should reach the panel too")
    }

    /// Mirroring must not make the panel think it owns the agent's process: Stop in the terminal
    /// means "stop the command I typed", and claiming otherwise would offer a button that lies.
    func testMirroringDoesNotMarkTheUserTerminalAsRunning() async throws {
        let json = #"{"command":"echo quiet"}"#
        _ = await ToolExecutionEngine.shared.execute(
            toolName: "terminal_command",
            argumentsJson: json,
            workspace: workspace,
            currentAgent: agent,
            callId: "stream-2"
        )
        _ = await waitForTerminal(containing: "quiet")
        XCTAssertFalse(WorkspaceTerminalSession.shared.isRunning)
    }

    /// A command read-only mode also allows, so the test covers the exit path rather than the gate.
    func testAFailingAgentCommandReportsItsExitCode() async throws {
        let missing = "/nope-\(UUID().uuidString)"
        let json = #"{"command":"ls \#(missing)"}"#
        _ = await ToolExecutionEngine.shared.execute(
            toolName: "terminal_command",
            argumentsJson: json,
            workspace: workspace,
            currentAgent: agent,
            callId: "stream-3"
        )
        let sawExit = await waitForTerminal(containing: "[agent] exited with code")
        XCTAssertTrue(sawExit, "a nonzero exit has to be visible, or a failed build looks like a quiet one")
    }

    /// Once the call is done the card shows the real result, so nothing may be left behind.
    func testTheTailIsClearedWhenTheCommandFinishes() async throws {
        let callId = "stream-4"
        let json = #"{"command":"echo done"}"#
        _ = await ToolExecutionEngine.shared.execute(
            toolName: "terminal_command",
            argumentsJson: json,
            workspace: workspace,
            currentAgent: agent,
            callId: callId
        )
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, LiveToolOutput.shared.tail(for: callId) != nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(LiveToolOutput.shared.tail(for: callId))
    }

    /// Tools called without a call id (tests, Shortcuts, the mock service) must still work.
    func testACommandWithoutACallIdStillRuns() async throws {
        let result = await ToolExecutionEngine.shared.execute(
            toolName: "terminal_command",
            argumentsJson: #"{"command":"echo anonymous"}"#,
            workspace: workspace,
            currentAgent: agent
        )
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertTrue(result.output.contains("anonymous"))
    }
}
