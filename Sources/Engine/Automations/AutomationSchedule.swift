import Foundation

/// When an automation actually fires.
///
/// `Automation.cronSchedule` is a free-text string — "Daily at 9:00 AM", "Every 30 mins", and the
/// seeded automations ship with exactly those. Until now nothing parsed it. The Automations
/// screen ran it through a display heuristic that rendered "Tomorrow at 9:00 AM" beside a clock
/// icon, and no code anywhere fired the automation: `AutomationTriggerType` has five cases and
/// only `.manual` was ever read, and that only to decide whether to *draw* the next-run line.
///
/// A next-run time the app will not honour is worse than no schedule UI at all, so the parser and
/// the scheduler read the same function. Two rules follow from that:
///
/// 1. **`parse` returns nil rather than guessing.** An unrecognised string produces
///    `Cadence?  == nil`, the UI says the schedule will not run, and the scheduler skips it. The
///    display heuristic used to fall through to `return schedule` — echoing "Every other Tuesday"
///    back as if it were a time.
/// 2. **Next fire is computed from the last run, not from now.** An app closed for a week comes
///    back to one overdue run, not a week of them: firing sets `lastRunAt`, so the backlog
///    collapses on the first tick. See `AutomationScheduler`.
public enum AutomationSchedule {

    /// A schedule the app knows how to honour.
    public enum Cadence: Equatable, Sendable {
        case everyMinutes(Int)
        case everyHours(Int)
        /// 24-hour clock.
        case dailyAt(hour: Int, minute: Int)
        /// `weekday` follows `Calendar`: 1 = Sunday … 7 = Saturday.
        case weeklyAt(weekday: Int, hour: Int, minute: Int)
        case monthlyAt(day: Int, hour: Int, minute: Int)
        /// Five-field cron: minute, hour, day-of-month, month, day-of-week.
        case cron(CronExpression)
    }

    // MARK: - Parsing

    /// Read a schedule string, or return nil if it is not one this app can honour.
    public static func parse(_ raw: String) -> Cadence? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // A real cron expression wins over the English forms: "0 9 * * *" contains no words to
        // misread, and anything with five whitespace-separated fields is unambiguous.
        if let cron = CronExpression(text) { return .cron(cron) }

        let lower = text.lowercased()

        // "Every 30 minutes" / "every 30 mins" / "every 5m"
        if let n = firstInteger(in: lower, matching: #"every\s+(\d+)\s*(?:minutes?|mins?|m)\b"#) {
            return n > 0 ? .everyMinutes(n) : nil
        }
        // "Every 2 hours" / "every 6h"
        if let n = firstInteger(in: lower, matching: #"every\s+(\d+)\s*(?:hours?|hrs?|h)\b"#) {
            return n > 0 ? .everyHours(n) : nil
        }
        if lower.contains("hourly") || lower.contains("every hour") {
            return .everyHours(1)
        }
        if lower.contains("every minute") {
            return .everyMinutes(1)
        }

        // Periods this parser cannot honour, refused before the weekday and clock-time readers get
        // a chance to find something familiar inside them.
        //
        // "Every other Tuesday" contains "tue", and a weekday reader alone turns it into a weekly
        // schedule that fires twice as often as asked. Half the fortnightly runs would be wrong
        // and nothing would ever say so. Same for "biweekly", "the first Monday of the month", and
        // "every 30 seconds" — all of them read as something this app can almost do.
        for qualifier in unsupportedQualifiers where lower.contains(qualifier) {
            return nil
        }

        let time = clockTime(in: text)

        if lower.contains("weekly") || weekday(in: lower) != nil {
            // "Weekly on Monday at 9am". A weekly schedule with no named day is Monday, because a
            // user who wrote "Weekly" and nothing else wants a week's cadence, not a refusal.
            let day = weekday(in: lower) ?? 2
            let t = time ?? (hour: 9, minute: 0)
            return .weeklyAt(weekday: day, hour: t.hour, minute: t.minute)
        }
        if lower.contains("monthly") {
            let day = firstInteger(in: lower, matching: #"(?:on\s+the\s+)?(\d{1,2})(?:st|nd|rd|th)\b"#) ?? 1
            let t = time ?? (hour: 9, minute: 0)
            return .monthlyAt(day: min(max(day, 1), 28), hour: t.hour, minute: t.minute)
        }
        if lower.contains("daily") || lower.contains("every day") {
            let t = time ?? (hour: 9, minute: 0)
            return .dailyAt(hour: t.hour, minute: t.minute)
        }

        // A bare time reads as daily — but only written as a time. "09:00" and "6:30 PM" are
        // clock times; a lone "2" is a count, and "every 2 weeks" must not become "daily at 2am".
        let looksLikeAClock = text.contains(":")
            || lower.range(of: #"\d\s*(am|pm)\b"#, options: .regularExpression) != nil
        if looksLikeAClock, let t = time {
            return .dailyAt(hour: t.hour, minute: t.minute)
        }
        return nil
    }

    /// Words that change a period in a way this parser does not implement. Their presence is a
    /// refusal, not a hint — see `parse`.
    private static let unsupportedQualifiers = [
        "other", "alternate", "alternating", "biweekly", "bi-weekly", "bimonthly", "bi-monthly",
        "fortnight", "second", "seconds", "quarter", "yearly", "annually",
        "first ", "third", "fourth", "last "
    ]

    // MARK: - Next fire

    /// The first moment strictly after `date` at which `cadence` fires.
    ///
    /// Returns nil only for a cron expression that matches nothing in the next year (`0 0 30 2 *`
    /// — February 30th). A nil here means the same thing as a nil from `parse`: it will not run.
    public static func nextFireDate(
        after date: Date,
        cadence: Cadence,
        calendar: Calendar = .current
    ) -> Date? {
        switch cadence {
        case .everyMinutes(let n):
            return calendar.date(byAdding: .minute, value: max(1, n), to: date)
        case .everyHours(let n):
            return calendar.date(byAdding: .hour, value: max(1, n), to: date)

        case .dailyAt(let hour, let minute):
            return nextDay(after: date, calendar: calendar, hour: hour, minute: minute) { _ in true }

        case .weeklyAt(let weekday, let hour, let minute):
            return nextDay(after: date, calendar: calendar, hour: hour, minute: minute) { day in
                calendar.component(.weekday, from: day) == weekday
            }

        case .monthlyAt(let day, let hour, let minute):
            return nextDay(after: date, calendar: calendar, hour: hour, minute: minute) { candidate in
                calendar.component(.day, from: candidate) == day
            }

        case .cron(let expression):
            return expression.nextFireDate(after: date, calendar: calendar)
        }
    }

    /// Convenience: parse and compute in one step. Nil when the string is not a schedule.
    public static func nextFireDate(
        after date: Date,
        schedule: String,
        calendar: Calendar = .current
    ) -> Date? {
        guard let cadence = parse(schedule) else { return nil }
        return nextFireDate(after: date, cadence: cadence, calendar: calendar)
    }

    // MARK: - Description

    /// What the UI shows. Built from the same parse the scheduler uses, so the screen cannot
    /// promise a run that will not happen.
    public struct Description: Equatable, Sendable {
        public var text: String
        /// False when the schedule is not one the app can honour — the UI must say so plainly.
        public var willRun: Bool
    }

    public static func describeNextRun(
        schedule: String,
        after date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Description {
        guard let cadence = parse(schedule) else {
            return Description(text: "Unrecognised schedule — will not run", willRun: false)
        }
        guard let next = nextFireDate(after: date, cadence: cadence, calendar: calendar) else {
            return Description(text: "No matching date — will not run", willRun: false)
        }
        if next <= now {
            return Description(text: "Due now", willRun: true)
        }
        let formatter = DateFormatter()
        if calendar.isDateInToday(next) {
            formatter.dateFormat = "'Today at' h:mm a"
        } else if calendar.isDateInTomorrow(next) {
            formatter.dateFormat = "'Tomorrow at' h:mm a"
        } else if next.timeIntervalSince(now) < 7 * 24 * 3600 {
            formatter.dateFormat = "EEEE 'at' h:mm a"
        } else {
            formatter.dateFormat = "d MMM 'at' h:mm a"
        }
        return Description(text: formatter.string(from: next), willRun: true)
    }

    /// A short badge for the automation card. Unrecognised schedules say so here too.
    public static func shortFrequency(_ schedule: String) -> String {
        switch parse(schedule) {
        case .everyMinutes(let n): return n == 1 ? "Every min" : "Every \(n)m"
        case .everyHours(let n): return n == 1 ? "Hourly" : "Every \(n)h"
        case .dailyAt: return "Daily"
        case .weeklyAt: return "Weekly"
        case .monthlyAt: return "Monthly"
        case .cron: return "Cron"
        case nil: return "Unrecognised"
        }
    }

    // MARK: - Helpers

    /// Walk forward a day at a time to the next date satisfying `matches`, at `hour:minute`.
    ///
    /// Day-stepping rather than minute-stepping: a monthly schedule is at most 31 iterations and a
    /// yearly cron at most 366, where scanning minutes would be half a million `Calendar` calls.
    private static func nextDay(
        after date: Date,
        calendar: Calendar,
        hour: Int,
        minute: Int,
        limitDays: Int = 366,
        matches: (Date) -> Bool
    ) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard var candidate = calendar.date(from: components) else { return nil }

        var steps = 0
        while steps <= limitDays {
            if candidate > date && matches(candidate) { return candidate }
            guard let next = calendar.date(byAdding: .day, value: 1, to: candidate) else { return nil }
            candidate = next
            steps += 1
        }
        return nil
    }

    private static func firstInteger(in text: String, matching pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    /// "9am", "9:30 PM", "18:30" → 24-hour components.
    static func clockTime(in text: String) -> (hour: Int, minute: Int)? {
        let pattern = #"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let hourRange = Range(match.range(at: 1), in: text),
                  var hour = Int(text[hourRange]) else { continue }
            let minute = Range(match.range(at: 2), in: text).flatMap { Int(text[$0]) } ?? 0
            let meridiem = Range(match.range(at: 3), in: text).map { text[$0].lowercased() }

            if let meridiem {
                if meridiem == "pm" && hour < 12 { hour += 12 }
                if meridiem == "am" && hour == 12 { hour = 0 }
            } else if match.range(at: 2).location == NSNotFound {
                // A bare number with no colon and no am/pm is a count, not a clock time — the "30"
                // in "Every 30 minutes". Only accept it as an hour if it could not be anything
                // else, which it cannot once the interval forms have already been tried.
                guard hour <= 23 else { continue }
            }
            guard (0...23).contains(hour), (0...59).contains(minute) else { continue }
            return (hour, minute)
        }
        return nil
    }

    private static let weekdayNames: [(String, Int)] = [
        ("sunday", 1), ("sun", 1),
        ("monday", 2), ("mon", 2),
        ("tuesday", 3), ("tue", 3),
        ("wednesday", 4), ("wed", 4),
        ("thursday", 5), ("thu", 5),
        ("friday", 6), ("fri", 6),
        ("saturday", 7), ("sat", 7)
    ]

    private static func weekday(in lower: String) -> Int? {
        for (name, value) in weekdayNames where lower.contains(name) { return value }
        return nil
    }
}
