import XCTest
@testable import SwiftOpenWork

/// The Automations trigger picker says "Scheduled (Interval / Cron)", so cron has to mean cron.
final class CronExpressionTests: XCTestCase {

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

    private func next(_ expression: String, after: String) -> String? {
        guard let cron = CronExpression(expression),
              let fire = cron.nextFireDate(after: date(after), calendar: calendar) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: fire)
    }

    func testRejectsAnythingThatIsNotFiveFields() {
        XCTAssertNil(CronExpression("0 9 * *"))
        XCTAssertNil(CronExpression("0 9 * * * *"))
        XCTAssertNil(CronExpression("Daily at 9am"))
        XCTAssertNil(CronExpression("60 9 * * *"), "minute 60 does not exist")
        XCTAssertNil(CronExpression("0 24 * * *"), "hour 24 does not exist")
    }

    func testEveryDayAtNine() {
        XCTAssertEqual(next("0 9 * * *", after: "2026-09-15 10:00"), "2026-09-16 09:00")
        XCTAssertEqual(next("0 9 * * *", after: "2026-09-15 08:00"), "2026-09-15 09:00")
    }

    func testStepsAndLists() {
        XCTAssertEqual(next("*/15 * * * *", after: "2026-09-15 08:04"), "2026-09-15 08:15")
        XCTAssertEqual(next("0 8,20 * * *", after: "2026-09-15 09:00"), "2026-09-15 20:00")
        XCTAssertEqual(next("0 9 * * 1-5", after: "2026-09-19 10:00"), "2026-09-21 09:00",
                       "Saturday the 19th rolls to Monday the 21st")
    }

    /// The traditional rule everyone meets once: when both day fields are restricted, cron fires
    /// when *either* matches. The other reading silently drops runs.
    func testRestrictedDayFieldsAreOrNotAnd() {
        // 2026-09-15 is a Tuesday. "1st of the month, and every Monday."
        XCTAssertEqual(next("0 0 1 * 1", after: "2026-09-15 12:00"), "2026-09-21 00:00",
                       "the next Monday comes before the 1st of October")
        XCTAssertEqual(next("0 0 1 * 1", after: "2026-09-28 12:00"), "2026-10-01 00:00",
                       "and the 1st comes before the Monday after it")
    }

    func testSundayIsBothZeroAndSeven() {
        XCTAssertEqual(next("0 0 * * 0", after: "2026-09-15 12:00"), next("0 0 * * 7", after: "2026-09-15 12:00"))
    }

    /// A date that never arrives must read as never, not as a hang or a wrong answer.
    func testAnImpossibleDateReturnsNil() {
        guard let cron = CronExpression("0 0 30 2 *") else { return XCTFail("should parse") }
        XCTAssertNil(cron.nextFireDate(after: date("2026-09-15 12:00"), calendar: calendar))
    }

    func testTheParserPrefersCronOverTheEnglishForms() {
        XCTAssertEqual(AutomationSchedule.parse("0 9 * * 1-5"), .cron(CronExpression("0 9 * * 1-5")!))
    }
}
