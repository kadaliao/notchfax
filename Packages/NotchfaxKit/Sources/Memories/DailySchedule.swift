import Foundation

/// When the automatic daily print is due.
///
/// The print happens the first time the app is running at or after `hour` on a given
/// day, and never twice on the same day. The rule is evaluated whenever anything
/// could have changed the answer (launch, a timer, wake from sleep, the clock or the
/// time zone changing), so it does not depend on a timer surviving sleep.
public struct DailySchedule: Sendable, Equatable {
    /// Hour of the day (0–23) from which the print is due.
    public var hour: Int
    public var minute: Int

    public init(hour: Int = 9, minute: Int = 0) {
        self.hour = min(23, max(0, hour))
        self.minute = min(59, max(0, minute))
    }

    /// The moment on `date`'s day from which the print is due.
    public func dueTime(on date: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)
            ?? calendar.startOfDay(for: date)
    }

    /// True if the print should happen now: past the hour today and not done today.
    public func isDue(now: Date, lastPrintedDay: String?, calendar: MemoryCalendar) -> Bool {
        guard lastPrintedDay != calendar.dayKey(for: now) else { return false }
        return now >= dueTime(on: now, calendar: calendar.calendar)
    }

    /// When to look again. Already done today, or past the hour: tomorrow's due time.
    /// Before the hour: today's.
    public func nextCheck(after now: Date, lastPrintedDay: String?, calendar: MemoryCalendar) -> Date {
        let cal = calendar.calendar
        let today = dueTime(on: now, calendar: cal)
        if now < today { return today }
        if lastPrintedDay != calendar.dayKey(for: now) { return now }
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        return dueTime(on: tomorrow, calendar: cal)
    }
}
