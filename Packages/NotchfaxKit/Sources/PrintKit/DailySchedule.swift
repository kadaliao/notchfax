import AppKit

/// When an automatic daily print is due.
///
/// The print happens the first time the app is running at or after `hour:minute` on a
/// given day, and never twice on the same day. The rule is evaluated whenever anything
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

    /// A stable key for a calendar day, e.g. `2026-11-11`.
    public static func dayKey(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The moment on `date`'s day from which the print is due.
    public func dueTime(on date: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)
            ?? calendar.startOfDay(for: date)
    }

    /// True if the print should happen now: past the time today and not done today.
    public func isDue(now: Date, lastPrintedDay: String?, calendar: Calendar) -> Bool {
        guard lastPrintedDay != Self.dayKey(for: now, calendar: calendar) else { return false }
        return now >= dueTime(on: now, calendar: calendar)
    }

    /// When to look again. Already done today, or past the time: tomorrow's due time.
    /// Before the time: today's.
    public func nextCheck(after now: Date, lastPrintedDay: String?, calendar: Calendar) -> Date {
        let today = dueTime(on: now, calendar: calendar)
        if now < today { return today }
        if lastPrintedDay != Self.dayKey(for: now, calendar: calendar) { return now }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        return dueTime(on: tomorrow, calendar: calendar)
    }
}

/// Whether someone is likely to see a print right now.
public enum Presence {
    /// Why not, or `nil` if the coast is clear.
    @MainActor
    public static func notReady(slot: SlotActivity) -> String? {
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return "display asleep" }
        // The booth, or a fax being written: a daily print can wait until it is put away.
        if slot.isPresenting { return "something is open under the slot" }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           session["CGSSessionScreenIsLocked"] as? Bool == true {
            return "screen locked"
        }
        let idle = min(
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        )
        if idle > 120 { return "idle for \(Int(idle)) s" }
        return nil
    }
}

/// Calls back whenever the answer to "is a daily print due?" could have changed without a
/// timer firing: the Mac or its screens waking, the session coming back, the screen being
/// unlocked, the day rolling over, the clock or the time zone changing.
@MainActor
public final class ClockWatcher {
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    public init(_ handler: @escaping @MainActor () -> Void) {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let events: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.didWakeNotification),
            (workspace, NSWorkspace.screensDidWakeNotification),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification),
            (NotificationCenter.default, .NSCalendarDayChanged),
            (NotificationCenter.default, .NSSystemClockDidChange),
            (NotificationCenter.default, .NSSystemTimeZoneDidChange),
            (distributed, Notification.Name("com.apple.screenIsUnlocked")),
        ]
        for (center, name) in events {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            }
            observers.append((center, token))
        }
    }
}
