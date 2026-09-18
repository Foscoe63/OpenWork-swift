import Foundation

/// A five-field cron expression: `minute hour day-of-month month day-of-week`.
///
/// The Automations screen offers "Scheduled (Interval / Cron)" as a trigger type, so cron has to
/// mean cron. Supported per field: `*`, a number, a `a-b` range, a `*/n` or `a-b/n` step, and
/// comma-separated lists of any of those. Day-of-week accepts 0 or 7 for Sunday.
///
/// Day-of-month and day-of-week follow the traditional cron rule that surprises everyone once:
/// when **both** are restricted the expression fires when **either** matches, not both. `0 0 1 * 1`
/// is "the 1st, and every Monday", not "Mondays that fall on the 1st". Implemented deliberately
/// rather than accidentally, because the other reading silently drops runs.
public struct CronExpression: Equatable, Sendable {

    private let minutes: Set<Int>
    private let hours: Set<Int>
    private let daysOfMonth: Set<Int>
    private let months: Set<Int>
    private let weekdays: Set<Int>      // 0 = Sunday, matching cron
    private let dayOfMonthRestricted: Bool
    private let weekdayRestricted: Bool

    public init?(_ raw: String) {
        let fields = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count == 5 else { return nil }

        guard let minutes = Self.parseField(fields[0], range: 0...59),
              let hours = Self.parseField(fields[1], range: 0...23),
              let daysOfMonth = Self.parseField(fields[2], range: 1...31),
              let months = Self.parseField(fields[3], range: 1...12),
              let rawWeekdays = Self.parseField(fields[4], range: 0...7) else { return nil }

        self.minutes = minutes
        self.hours = hours
        self.daysOfMonth = daysOfMonth
        self.months = months
        // 7 and 0 are both Sunday.
        self.weekdays = Set(rawWeekdays.map { $0 == 7 ? 0 : $0 })
        self.dayOfMonthRestricted = fields[2] != "*"
        self.weekdayRestricted = fields[4] != "*"
    }

    /// The first minute strictly after `date` that this expression matches, or nil if it matches
    /// no date in the next four years (`0 0 30 2 *` — February 30th).
    ///
    /// Four years rather than one so that February 29th resolves rather than reading as never.
    public func nextFireDate(after date: Date, calendar: Calendar = .current) -> Date? {
        // Start at the top of the minute after `date`: cron has minute resolution, and starting
        // inside the current minute would re-fire a schedule that just ran.
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        components.second = 0
        guard let flooredNow = calendar.date(from: components),
              var cursor = calendar.date(byAdding: .minute, value: 1, to: flooredNow) else { return nil }

        let limit = calendar.date(byAdding: .year, value: 4, to: date) ?? date
        while cursor <= limit {
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: cursor)
            guard let month = parts.month, let day = parts.day,
                  let hour = parts.hour, let minute = parts.minute,
                  let weekday = parts.weekday else { return nil }

            guard months.contains(month) else {
                cursor = Self.startOfNextMonth(after: cursor, calendar: calendar) ?? limit.addingTimeInterval(1)
                continue
            }
            guard matchesDay(dayOfMonth: day, calendarWeekday: weekday) else {
                cursor = Self.startOfNextDay(after: cursor, calendar: calendar) ?? limit.addingTimeInterval(1)
                continue
            }
            guard hours.contains(hour) else {
                cursor = Self.startOfNextHour(after: cursor, calendar: calendar) ?? limit.addingTimeInterval(1)
                continue
            }
            if minutes.contains(minute) { return cursor }
            guard let next = calendar.date(byAdding: .minute, value: 1, to: cursor) else { return nil }
            cursor = next
        }
        return nil
    }

    /// The traditional either/or rule when both day fields are restricted.
    private func matchesDay(dayOfMonth: Int, calendarWeekday: Int) -> Bool {
        let cronWeekday = calendarWeekday - 1      // Calendar: 1 = Sunday. Cron: 0 = Sunday.
        let dayMatches = daysOfMonth.contains(dayOfMonth)
        let weekdayMatches = weekdays.contains(cronWeekday)
        if dayOfMonthRestricted && weekdayRestricted { return dayMatches || weekdayMatches }
        if dayOfMonthRestricted { return dayMatches }
        if weekdayRestricted { return weekdayMatches }
        return true
    }

    // MARK: - Field parsing

    public static func parseField(_ field: String, range: ClosedRange<Int>) -> Set<Int>? {
        var values: Set<Int> = []
        for part in field.split(separator: ",") {
            guard let parsed = parsePart(String(part), range: range) else { return nil }
            values.formUnion(parsed)
        }
        return values.isEmpty ? nil : values
    }

    private static func parsePart(_ part: String, range: ClosedRange<Int>) -> Set<Int>? {
        var body = part
        var step = 1
        if let slash = part.firstIndex(of: "/") {
            body = String(part[part.startIndex..<slash])
            guard let parsedStep = Int(part[part.index(after: slash)...]), parsedStep > 0 else { return nil }
            step = parsedStep
        }

        let bounds: ClosedRange<Int>
        if body == "*" {
            bounds = range
        } else if let dash = body.firstIndex(of: "-") {
            guard let low = Int(body[body.startIndex..<dash]),
                  let high = Int(body[body.index(after: dash)...]),
                  low <= high, range.contains(low), range.contains(high) else { return nil }
            bounds = low...high
        } else {
            guard let value = Int(body), range.contains(value) else { return nil }
            bounds = value...value
        }

        return Set(stride(from: bounds.lowerBound, through: bounds.upperBound, by: step))
    }

    // MARK: - Cursor jumps

    private static func startOfNextDay(after date: Date, calendar: Calendar) -> Date? {
        guard let midnight = calendar.date(from: calendar.dateComponents([.year, .month, .day], from: date)) else { return nil }
        return calendar.date(byAdding: .day, value: 1, to: midnight)
    }

    private static func startOfNextHour(after date: Date, calendar: Calendar) -> Date? {
        guard let topOfHour = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: date)) else { return nil }
        return calendar.date(byAdding: .hour, value: 1, to: topOfHour)
    }

    private static func startOfNextMonth(after date: Date, calendar: Calendar) -> Date? {
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) else { return nil }
        return calendar.date(byAdding: .month, value: 1, to: first)
    }
}
