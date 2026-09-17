import XCTest
@testable import SwiftOpenWork

/// The parser behind every next-run time the Automations screen shows, and behind every automation
/// that fires. One function for both, so the screen cannot promise a run the app will not make.
final class AutomationScheduleTests: XCTestCase {

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

    private func string(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    // MARK: - The strings the app actually ships

    /// Both seeded automations. If these do not parse, the app ships schedules that never fire.
    func testTheSeededSchedulesParse() {
        XCTAssertEqual(AutomationSchedule.parse("Daily at 9:00 AM"), .dailyAt(hour: 9, minute: 0))
        XCTAssertEqual(AutomationSchedule.parse("Hourly"), .everyHours(1))
    }

    func testTheEditorPlaceholdersParse() {
        XCTAssertEqual(AutomationSchedule.parse("Daily at 6:00 AM"), .dailyAt(hour: 6, minute: 0))
        XCTAssertEqual(AutomationSchedule.parse("Every 2 hours"), .everyHours(2))
        XCTAssertEqual(AutomationSchedule.parse("Weekly on Monday"), .weeklyAt(weekday: 2, hour: 9, minute: 0))
    }

    func testIntervalFormsBeatClockForms() {
        // "Every 30 mins" contains a number that a clock-time reader would take as 30 o'clock, or
        // worse, as 30 minutes past an unstated hour. Intervals are tried first for that reason.
        XCTAssertEqual(AutomationSchedule.parse("Every 30 mins"), .everyMinutes(30))
        XCTAssertEqual(AutomationSchedule.parse("every 15 minutes"), .everyMinutes(15))
        XCTAssertEqual(AutomationSchedule.parse("Every 6h"), .everyHours(6))
    }

    func testMeridiemIsApplied() {
        XCTAssertEqual(AutomationSchedule.parse("Daily at 6:30 PM"), .dailyAt(hour: 18, minute: 30))
        XCTAssertEqual(AutomationSchedule.parse("Daily at 12:00 AM"), .dailyAt(hour: 0, minute: 0))
        XCTAssertEqual(AutomationSchedule.parse("Daily at 18:45"), .dailyAt(hour: 18, minute: 45))
    }

    // MARK: - Refusing to guess

    /// The old display heuristic ended in `return schedule`, so an unparseable string was echoed
    /// back into the UI as if it were a time. Nil is the whole point.
    func testUnrecognisedSchedulesReturnNilRatherThanAGuess() {
        XCTAssertNil(AutomationSchedule.parse("whenever I feel like it"))
        XCTAssertNil(AutomationSchedule.parse(""))
        XCTAssertNil(AutomationSchedule.parse("   "))
    }

    /// Periods that are almost expressible are the dangerous ones: each of these contains
    /// something a looser reader recognises, and each would fire at the wrong rate rather than
    /// not at all. "Every other Tuesday" read as weekly runs twice as often as asked.
    func testNearMissPeriodsAreRefusedRatherThanRoundedToSomethingSimilar() {
        XCTAssertNil(AutomationSchedule.parse("Every other Tuesday"), "fortnightly is not weekly")
        XCTAssertNil(AutomationSchedule.parse("Biweekly on Monday"))
        XCTAssertNil(AutomationSchedule.parse("First Monday of the month"))
        XCTAssertNil(AutomationSchedule.parse("Every 30 seconds"), "not 30 minutes")
        XCTAssertNil(AutomationSchedule.parse("Quarterly"))
    }

    /// A bare number is a count, not a clock reading. Without this, "every 2 weeks" — which the
    /// parser cannot honour — came back as "daily at 2am".
    func testABareNumberIsNotReadAsATime() {
        XCTAssertNil(AutomationSchedule.parse("every 2 weeks"))
        XCTAssertNil(AutomationSchedule.parse("9"))
        XCTAssertEqual(AutomationSchedule.parse("09:00"), .dailyAt(hour: 9, minute: 0))
        XCTAssertEqual(AutomationSchedule.parse("6pm"), .dailyAt(hour: 18, minute: 0))
    }

    func testAnUnrecognisedScheduleSaysItWillNotRun() {
        let description = AutomationSchedule.describeNextRun(
            schedule: "sometime soon",
            after: date("2026-09-15 08:00"),
            now: date("2026-09-15 08:00"),
            calendar: calendar
        )
        XCTAssertFalse(description.willRun)
        XCTAssertTrue(description.text.lowercased().contains("will not run"))
    }

    // MARK: - Next fire

    func testDailyRollsToTomorrowOnceTodayIsPast() {
        let next = AutomationSchedule.nextFireDate(
            after: date("2026-09-15 10:00"),
            cadence: .dailyAt(hour: 9, minute: 0),
            calendar: calendar
        )
        XCTAssertEqual(string(XCTUnwrap2(next)), "2026-09-16 09:00")
    }

    func testDailyStaysTodayWhenTheTimeIsStillAhead() {
        let next = AutomationSchedule.nextFireDate(
            after: date("2026-09-15 07:00"),
            cadence: .dailyAt(hour: 9, minute: 0),
            calendar: calendar
        )
        XCTAssertEqual(string(XCTUnwrap2(next)), "2026-09-15 09:00")
    }

    func testWeeklyFindsTheNamedDay() {
        // 2026-09-15 is a Tuesday; the next Monday is the 21st.
        let next = AutomationSchedule.nextFireDate(
            after: date("2026-09-15 07:00"),
            cadence: .weeklyAt(weekday: 2, hour: 8, minute: 30),
            calendar: calendar
        )
        XCTAssertEqual(string(XCTUnwrap2(next)), "2026-09-21 08:30")
    }

    func testMonthlyFindsTheNamedDayNextMonth() {
        let next = AutomationSchedule.nextFireDate(
            after: date("2026-09-15 07:00"),
            cadence: .monthlyAt(day: 1, hour: 9, minute: 0),
            calendar: calendar
        )
        XCTAssertEqual(string(XCTUnwrap2(next)), "2026-10-01 09:00")
    }

    /// The property the scheduler depends on for rule 1: next fire is computed from the last run,
    /// so an app closed for a week owes one run, not a week of them.
    func testABacklogCollapsesToASingleDueRun() {
        let lastRun = date("2026-09-08 09:00")
        let now = date("2026-09-15 10:00")
        var fires = 0
        var cursor = lastRun
        while let next = AutomationSchedule.nextFireDate(
            after: cursor, cadence: .dailyAt(hour: 9, minute: 0), calendar: calendar
        ), next <= now {
            fires += 1
            // What the scheduler does after firing: stamp `lastRunAt` with *now*, not with the
            // missed slot. One tick, one run.
            cursor = now
        }
        XCTAssertEqual(fires, 1, "a week of missed daily runs must not queue up seven turns")
    }

    private func XCTUnwrap2(_ date: Date?) -> Date {
        guard let date else {
            XCTFail("expected a next fire date")
            return Date()
        }
        return date
    }
}
