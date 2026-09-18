import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine

/// From a real session: a 46GB checkpoint loaded in ~220s and answered, then the next turn gave up
/// on the same load at the flat 180s budget and reported the model unavailable — abandoning work it
/// had already proved it could finish. A download fares worse: it cannot finish inside any fixed
/// budget, so the turn always failed while the download was working. Time the silence instead.
final class LoadWatchdogTests: XCTestCase {

    func testWorkThatKeepsReportingProgressIsNeverAbandoned() async throws {
        let clock = AsyncDeadline.ProgressClock()
        let done = AsyncDeadline.ProgressClock()  // reused as a simple "finished" marker

        let work = Task<String, Error> {
            // Runs well past the stall window, but reports progress throughout.
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                clock.tick()
            }
            done.tick()
            return "finished"
        }

        let result = try await AsyncDeadline.wait(
            for: work,
            stalledAfter: 0.3,
            clock: clock,
            pollInterval: 0.05
        )
        XCTAssertEqual(result, "finished", "progress was continuous, so it must not have timed out")
    }

    func testSilentWorkIsGivenUpOn() async {
        let clock = AsyncDeadline.ProgressClock()
        let work = Task<String, Error> {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return "too late"
        }

        do {
            _ = try await AsyncDeadline.wait(
                for: work,
                stalledAfter: 0.3,
                clock: clock,
                pollInterval: 0.05
            )
            XCTFail("a wedged load must still fail the turn rather than hang it")
        } catch is AsyncDeadline.TimedOut {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        work.cancel()
    }

    /// Progress that stops partway must still time out — otherwise a load that dies mid-way hangs
    /// the turn forever.
    func testProgressThatStopsStillTimesOut() async {
        let clock = AsyncDeadline.ProgressClock()
        let work = Task<String, Error> {
            clock.tick()
            try? await Task.sleep(nanoseconds: 50_000_000)
            clock.tick()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return "too late"
        }

        do {
            _ = try await AsyncDeadline.wait(for: work, stalledAfter: 0.3, clock: clock, pollInterval: 0.05)
            XCTFail("expected a timeout once progress stopped")
        } catch is AsyncDeadline.TimedOut {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        work.cancel()
    }

    func testAFailingLoadReportsItsOwnErrorNotATimeout() async {
        struct Boom: Error {}
        let clock = AsyncDeadline.ProgressClock()
        let work = Task<String, Error> { throw Boom() }

        do {
            _ = try await AsyncDeadline.wait(for: work, stalledAfter: 5, clock: clock, pollInterval: 0.05)
            XCTFail("expected the task's own error")
        } catch is Boom {
            // Expected: a real failure must not be dressed up as a timeout.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testClockStartsTickingImmediately() {
        let clock = AsyncDeadline.ProgressClock()
        XCTAssertLessThan(clock.secondsSinceLastTick, 1)
    }
}

/// Progress chips accumulated one per percent. A real screenshot showed six stacked rows for a
/// download that had reached 4%, and an export carried sixteen for a load at 36%.
@MainActor
final class ProgressNoticeCollapseTests: XCTestCase {

    private func accumulator(_ onUpdate: @escaping (ChatMessage) -> Void) -> AgentStreamAccumulator {
        AgentStreamAccumulator(
            initialMessage: ChatMessage(sessionId: "s", role: .assistant, content: ""),
            onUpdate: onUpdate
        )
    }

    func testPercentageProgressReplacesRatherThanStacks() {
        var final: ChatMessage?
        let acc = accumulator { final = $0 }
        for pct in 0...4 {
            acc.appendNotice("Loading MLX weights: \(pct)%")
        }
        XCTAssertEqual(final?.notices, ["Loading MLX weights: 4%"])
    }

    func testDistinctProgressRunsKeepTheirOwnChip() {
        var final: ChatMessage?
        let acc = accumulator { final = $0 }
        acc.appendNotice("Downloading MLX weights: 90%")
        acc.appendNotice("Loading MLX weights: 1%")
        acc.appendNotice("Loading MLX weights: 2%")
        XCTAssertEqual(final?.notices, ["Downloading MLX weights: 90%", "Loading MLX weights: 2%"])
    }

    /// Only progress collapses. Ordinary notices are distinct events and must all survive.
    func testNonProgressNoticesAreNotCollapsed() {
        var final: ChatMessage?
        let acc = accumulator { final = $0 }
        acc.appendNotice("Plan mode exited.")
        acc.appendNotice("Context compacted to free tokens.")
        acc.appendNotice("Stopped: the model was repeating itself.")
        XCTAssertEqual(final?.notices.count, 3)
    }

    func testProgressFamilyIgnoresAnythingWithoutAPercentage() {
        XCTAssertNil(AgentStreamAccumulator.progressFamily("Plan mode exited."))
        XCTAssertNil(AgentStreamAccumulator.progressFamily("Downloading MLX weights for foo/bar…"))
        XCTAssertEqual(AgentStreamAccumulator.progressFamily("Loading MLX weights: 7%"), "Loading MLX weights: ")
    }
}

/// A message saved mid-stream keeps `isStreaming` true on disk and comes back as a bubble that
/// spins forever with no generation behind it. A real exported session contained one, empty.
final class InterruptedMessageRecoveryTests: XCTestCase {

    private func roundTrip(_ session: Session) throws -> Session {
        // Exercised through the same Codable path the store uses.
        let data = try JSONEncoder().encode([session])
        let decoded = try JSONDecoder().decode([Session].self, from: data)
        return decoded[0]
    }

    func testAStreamingFlagSurvivesEncodingSoTheFixIsNeeded() throws {
        var session = Session(title: "t")
        var message = ChatMessage(sessionId: session.id, role: .assistant, content: "")
        message.isStreaming = true
        session.messages = [message]

        XCTAssertTrue(try roundTrip(session).messages[0].isStreaming,
                      "if this ever stops persisting, the load-time reset can go")
    }
}
