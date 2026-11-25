import Foundation
import Testing

@testable import PrintKit

@Suite struct DailyScheduleTests {
    private static let shanghai: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    let calendar = Self.shanghai
    let schedule = DailySchedule(hour: 9)

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func notDueBeforeTheHour() {
        #expect(!schedule.isDue(now: date(2026, 11, 11, 8, 59), lastPrintedDay: nil, calendar: calendar))
        #expect(schedule.nextCheck(after: date(2026, 11, 11, 8, 0), lastPrintedDay: nil, calendar: calendar) == date(2026, 11, 11, 9))
    }

    @Test func dueFromTheHourUntilMidnight() {
        #expect(schedule.isDue(now: date(2026, 11, 11, 9, 0), lastPrintedDay: "2026-11-10", calendar: calendar))
        // Mac woke up late in the evening: still today's print.
        #expect(schedule.isDue(now: date(2026, 11, 11, 23, 50), lastPrintedDay: "2026-11-10", calendar: calendar))
    }

    @Test func neverTwiceOnTheSameDay() {
        let now = date(2026, 11, 11, 14)
        #expect(!schedule.isDue(now: now, lastPrintedDay: "2026-11-11", calendar: calendar))
        #expect(schedule.nextCheck(after: now, lastPrintedDay: "2026-11-11", calendar: calendar) == date(2026, 11, 12, 9))
    }

    @Test func dayRolloverMakesItDueAgain() {
        // Printed late yesterday; the Mac slept through midnight and wakes at 10:00.
        #expect(schedule.isDue(now: date(2026, 11, 12, 10), lastPrintedDay: "2026-11-11", calendar: calendar))
        // Woken just after midnight: wait for the hour.
        #expect(!schedule.isDue(now: date(2026, 11, 12, 0, 5), lastPrintedDay: "2026-11-11", calendar: calendar))
    }

    @Test func minutesCount() {
        let evening = DailySchedule(hour: 18, minute: 30)
        #expect(!evening.isDue(now: date(2026, 11, 25, 18, 29), lastPrintedDay: nil, calendar: calendar))
        #expect(evening.isDue(now: date(2026, 11, 25, 18, 30), lastPrintedDay: nil, calendar: calendar))
        #expect(evening.nextCheck(after: date(2026, 11, 25, 12), lastPrintedDay: nil, calendar: calendar) == date(2026, 11, 25, 18, 30))
    }

    @Test func hoursAndMinutesAreClamped() {
        #expect(DailySchedule(hour: 30).hour == 23)
        #expect(DailySchedule(hour: -2).hour == 0)
        #expect(DailySchedule(hour: 9, minute: 75).minute == 59)
    }

    @Test func dayKeysAreLocal() {
        #expect(DailySchedule.dayKey(for: date(2026, 11, 25, 0, 30), calendar: calendar) == "2026-11-25")
    }
}
