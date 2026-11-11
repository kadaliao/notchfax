import Foundation

/// Calendar arithmetic for "this day in earlier years".
public struct MemoryCalendar: Sendable {
    public var calendar: Calendar
    /// How far back to look.
    public var maxYearsBack: Int

    public init(calendar: Calendar = .current, maxYearsBack: Int = 30) {
        self.calendar = calendar
        self.maxYearsBack = maxYearsBack
    }

    /// The whole-day intervals, in earlier years, that share today's month and day.
    ///
    /// On 28 February of a common year, 29 February of earlier leap years is included
    /// too, so leap-day photos still come round. On 29 February only leap years match.
    public func windows(for today: Date) -> [DateInterval] {
        let parts = calendar.dateComponents([.year, .month, .day], from: today)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return [] }
        let includesLeapDay = month == 2 && day == 28 && !isLeapYear(year)
        var result: [DateInterval] = []
        for back in 1...max(1, maxYearsBack) {
            let target = year - back
            if let interval = dayInterval(year: target, month: month, day: day) {
                result.append(interval)
            }
            if includesLeapDay, isLeapYear(target), let leap = dayInterval(year: target, month: 2, day: 29) {
                result.append(leap)
            }
        }
        return result
    }

    /// Whole years between the photo and today ("3 年前").
    public func yearsAgo(_ date: Date, from today: Date) -> Int {
        let then = calendar.component(.year, from: date)
        let now = calendar.component(.year, from: today)
        return max(1, now - then)
    }

    /// The understated line printed with a memory.
    public func caption(for date: Date, today: Date) -> String {
        let years = yearsAgo(date, from: today)
        return years == 1 ? "去年的今天" : "\(years) 年前的今天"
    }

    /// A stable key for a calendar day, e.g. `2026-11-11`.
    public func dayKey(for date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func dayInterval(year: Int, month: Int, day: Int) -> DateInterval? {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        // Reject days that do not exist (29 February in a common year) instead of
        // letting the calendar roll them over into March.
        guard c.isValidDate(in: calendar), let start = calendar.date(from: c) else { return nil }
        return calendar.dateInterval(of: .day, for: start)
    }

    private func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }
}
