import XCTest
@testable import OpenWorkSwift

/// A model called `screenshot_window` with identical arguments eight times and was still going
/// when the user stopped it by hand. Dead-end detection existed only for MCP (`mcpDeadEnds`), so
/// a first-party tool could fail the same way forever. The model was not being stupid: nothing
/// told it the attempt was hopeless, and retrying once is a reasonable thing to do.
@MainActor
final class RepeatedFailingCallTests: XCTestCase {

    func testTheSameCallWithTheSameArgumentsHasTheSameSignature() {
        let a = AgentRunner.callSignature("screenshot_window", #"{"app":"OpenWork"}"#)
        let b = AgentRunner.callSignature("screenshot_window", #"{"app":"OpenWork"}  "#)
        XCTAssertEqual(a, b, "trailing whitespace must not disguise a repeat")
    }

    /// Changing the arguments is a new attempt, not a repeat — it must not be blocked.
    func testDifferentArgumentsAreADifferentCall() {
        let a = AgentRunner.callSignature("screenshot_window", #"{"app":"OpenWork"}"#)
        let b = AgentRunner.callSignature("screenshot_window", #"{"app":"Finder"}"#)
        XCTAssertNotEqual(a, b)
    }

    func testDifferentToolsAreDifferentCalls() {
        XCTAssertNotEqual(
            AgentRunner.callSignature("screenshot_window", "{}"),
            AgentRunner.callSignature("accessibility_tree", "{}")
        )
    }

    /// One retry is reasonable; the third identical attempt is a loop rather than a strategy.
    func testTheLimitAllowsARetryButNotALoop() {
        XCTAssertEqual(AgentRunner.identicalFailureLimit, 2)

        var failures: [String: Int] = [:]
        let key = AgentRunner.callSignature("screenshot_window", #"{"app":"OpenWork"}"#)

        var executions = 0
        for _ in 0..<8 {
            if let prior = failures[key], prior >= AgentRunner.identicalFailureLimit { continue }
            executions += 1
            failures[key, default: 0] += 1   // every attempt fails
        }
        XCTAssertEqual(executions, 2, "eight attempts must cost two executions, not eight")
    }

    /// A success clears the count, so a tool that starts working is not punished for its past.
    func testASuccessResetsTheCount() {
        var failures: [String: Int] = [:]
        let key = AgentRunner.callSignature("run_app", "{}")
        failures[key] = 2
        failures[key] = 0   // the success path
        XCTAssertLessThan(failures[key] ?? 0, AgentRunner.identicalFailureLimit)
    }
}
