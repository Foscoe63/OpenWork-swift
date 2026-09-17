import XCTest
@testable import SwiftOpenWork

/// The scheduler's one decision: is this automation due?
///
/// Tested directly rather than through `AppState`, because everything else in
/// `AutomationScheduler` is plumbing around this predicate — and because the failure this whole
/// file exists to prevent is the silent one: an automation that looks scheduled and never runs.
@MainActor
final class AutomationSchedulerTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: string)!
    }

    private func automation(
        schedule: String = "Daily at 9:00 AM",
        trigger: AutomationTriggerType = .scheduled,
        enabled: Bool = true,
        lastRun: String? = nil,
        created: String = "2026-09-01 00:00"
    ) -> Automation {
        Automation(
            name: "Test",
            triggerType: trigger,
            cronSchedule: schedule,
            targetAgentId: "lead-assistant",
            promptTemplate: "do the thing",
            isEnabled: enabled,
            lastRunAt: lastRun.map(date),
            createdAt: date(created)
        )
    }

    func testADailyAutomationIsDueOnceItsTimeHasPassed() {
        let auto = automation(lastRun: "2026-09-15 09:00")
        XCTAssertFalse(AutomationScheduler.isDue(auto, now: date("2026-09-15 23:00"), calendar: calendar))
        XCTAssertTrue(AutomationScheduler.isDue(auto, now: date("2026-09-16 09:00"), calendar: calendar))
    }

    /// The first run is measured from creation. Measuring from "now" on every tick would push the
    /// first run permanently one interval into the future — an automation that never fires once.
    func testAnAutomationThatHasNeverRunBecomesDueFromItsCreationDate() {
        let auto = automation(schedule: "Every 30 mins", created: "2026-09-15 08:00")
        XCTAssertFalse(AutomationScheduler.isDue(auto, now: date("2026-09-15 08:20"), calendar: calendar))
        XCTAssertTrue(AutomationScheduler.isDue(auto, now: date("2026-09-15 08:30"), calendar: calendar))
    }

    func testAPausedAutomationIsNeverDue() {
        let auto = automation(enabled: false, lastRun: "2026-09-01 09:00")
        XCTAssertFalse(AutomationScheduler.isDue(auto, now: date("2026-09-15 12:00"), calendar: calendar))
    }

    /// The other four triggers are not clock-driven; the tick must not fire them.
    func testOnlyScheduledTriggersAreClockDriven() {
        for trigger in AutomationTriggerType.allCases where trigger != .scheduled {
            let auto = automation(trigger: trigger, lastRun: "2026-09-01 09:00")
            XCTAssertFalse(
                AutomationScheduler.isDue(auto, now: date("2026-09-15 12:00"), calendar: calendar),
                "\(trigger.rawValue) must not be fired by the clock"
            )
        }
    }

    /// The whole reason the parser returns nil instead of guessing: a schedule the app cannot
    /// honour must not fire on some approximation of it.
    func testAnUnrecognisedScheduleIsNeverDue() {
        let auto = automation(schedule: "whenever", lastRun: "2026-09-01 09:00")
        XCTAssertFalse(AutomationScheduler.isDue(auto, now: date("2026-09-15 12:00"), calendar: calendar))
    }

    func testCronSchedulesAreDueLikeAnyOther() {
        // Weekdays at 09:00. 2026-09-19 is a Saturday, so nothing is due until Monday the 21st.
        let auto = automation(schedule: "0 9 * * 1-5", lastRun: "2026-09-18 09:00")
        XCTAssertFalse(AutomationScheduler.isDue(auto, now: date("2026-09-19 12:00"), calendar: calendar))
        XCTAssertTrue(AutomationScheduler.isDue(auto, now: date("2026-09-21 09:00"), calendar: calendar))
    }

    /// A tick has to be cheap enough to run every thirty seconds against a long list.
    func testTheDuenessCheckIsCheapEnoughToRunOnATimer() {
        let autos = (0..<500).map { _ in automation(lastRun: "2026-09-15 09:00") }
        let now = date("2026-09-16 10:00")
        let started = CFAbsoluteTimeGetCurrent()
        let due = autos.filter { AutomationScheduler.isDue($0, now: now, calendar: calendar) }
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        XCTAssertEqual(due.count, 500)
        XCTAssertLessThan(elapsed, 1.0, "500 automations took \(elapsed)s to check; a 30s tick cannot afford that")
    }

    /// The test host is the real app on the real data directory. A scheduler that started there
    /// ran the user's startup automations on every `xcodebuild test`.
    @MainActor
    func testTheSchedulerRefusesToStartInsideATestHost() {
        XCTAssertTrue(AutomationScheduler.isHostedByTests)
    }

    // MARK: - Interrupted runs

    /// A run the app quit during used to stay "success" with a prompt-only session. At launch
    /// nothing is running, so "running" can only mean interrupted.
    func testARunStillMarkedRunningAtLaunchIsReportedInterrupted() {
        let session = Session(workspaceId: "w", title: "MorningBrief")
        var running = Automation(name: "MorningBrief", lastStatus: "running")
        running.lastSessionId = session.id
        let finished = Automation(name: "Other", lastStatus: "success")

        let recovered = AppState.recoveringInterruptedRuns(automations: [running, finished], sessions: [session])

        XCTAssertEqual(recovered.automations[0].lastStatus, "interrupted")
        XCTAssertTrue(recovered.automations[0].lastResultSummary?.contains("Did not finish") ?? false)
        XCTAssertEqual(recovered.automations[1].lastStatus, "success", "a finished run is left alone")
        XCTAssertEqual(recovered.sessions[0].title, "MorningBrief (interrupted)")
    }

    func testRecoveryDoesNotLabelASessionTwice() {
        var session = Session(workspaceId: "w", title: "MorningBrief (interrupted)")
        session.title = "MorningBrief (interrupted)"
        var running = Automation(name: "MorningBrief", lastStatus: "running")
        running.lastSessionId = session.id
        let recovered = AppState.recoveringInterruptedRuns(automations: [running], sessions: [session])
        XCTAssertEqual(recovered.sessions[0].title, "MorningBrief (interrupted)")
    }

    /// Automations saved before `lastSessionId` existed must still load.
    func testAnAutomationWithoutASessionIdStillDecodes() throws {
        let json = #"{"id":"a","workspaceId":"w","name":"n","description":"","triggerType":"manual","cronSchedule":"Hourly","targetAgentId":"","promptTemplate":"","isEnabled":true,"createdAt":0,"updatedAt":0}"#
        let decoded = try JSONDecoder().decode(Automation.self, from: Data(json.utf8))
        XCTAssertNil(decoded.lastSessionId)
    }
}
