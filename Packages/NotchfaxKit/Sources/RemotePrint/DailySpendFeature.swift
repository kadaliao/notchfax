import AppKit
import os
import PrintKit

/// 今日 AI 花费: once a day, at a time the person picks, a receipt of what this Mac spent on
/// AI models since midnight, by model and by agent. Off until turned on in the menu, and only
/// offered on a Mac that keeps a usage history (`UsageHistory`).
///
/// Launch argument, for development: `--daily-spend-demo` prints today's receipt at launch.
@MainActor
public final class DailySpendFeature: FeatureModule {
    /// Times offered in the menu; any other can be typed in.
    static let presetTimes: [(hour: Int, minute: Int)] = [
        (17, 0), (17, 30), (18, 0), (18, 30), (19, 0), (20, 0), (21, 0), (22, 0),
    ]
    /// A history that cannot be read is tried this many times on a day, ten minutes apart.
    static let attemptsPerDay = 3

    /// False for scripted runs, which should print nothing by themselves.
    public var allowsAutomaticPrints = true

    private let printer: Printer
    private let settings = DailySpendSettings()
    private let calendar = Calendar.autoupdatingCurrent
    private let log = Logger(subsystem: "com.kadaliao.notchfax", category: "daily-spend")
    private var checkTask: Task<Void, Never>?
    private var clockWatcher: ClockWatcher?
    private var isLoading = false
    private var failures: (day: String, count: Int) = ("", 0)
    private var mac: ThisMac?

    public init(printer: Printer) {
        self.printer = printer
        printer.menu.addSection(id: "daily-spend", order: 40) { [weak self] in self?.menuEntries() ?? [] }
    }

    public func start() {
        clockWatcher = ClockWatcher { [weak self] in self?.scheduleCheck(after: 3) }
        if CommandLine.arguments.contains("--daily-spend-demo") {
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                await printToday(automatic: false)
            }
        }
        scheduleCheck(after: 4)
    }

    // MARK: Menu

    private func menuEntries() -> [MenuEntry] {
        let available = UsageHistory.executable() != nil
        // Nothing to offer on a Mac without a history, unless it was turned on before.
        guard available || settings.isOn else { return [] }
        var entries: [MenuEntry] = [
            .action("打印今日 AI 花费", systemImage: "chart.bar.doc.horizontal", isEnabled: available && !isLoading) { [weak self] in
                Task { await self?.printToday(automatic: false) }
            },
        ]
        if isLoading {
            entries.append(.label("正在汇总今天的用量…"))
        }
        entries.append(.action("每天打印 AI 花费", isOn: settings.isOn) { [weak self] in self?.toggle() })
        if settings.isOn {
            entries.append(.submenu(title: "打印时间：\(Self.clock(settings.hour, settings.minute))", items: timeEntries()))
            if !available {
                entries.append(.label("找不到这台 Mac 的用量记录"))
            }
        }
        return entries
    }

    private func timeEntries() -> [MenuEntry] {
        var times = Self.presetTimes
        if !times.contains(where: { $0 == (settings.hour, settings.minute) }) {
            times.append((settings.hour, settings.minute))
            times.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        }
        var entries: [MenuEntry] = times.map { time in
            .action(Self.clock(time.hour, time.minute), isOn: (time.hour, time.minute) == (settings.hour, settings.minute)) { [weak self] in
                self?.setTime(hour: time.hour, minute: time.minute)
            }
        }
        entries.append(.separator)
        entries.append(.action("其他时间…") { [weak self] in self?.chooseTime() })
        return entries
    }

    private func toggle() {
        settings.isOn.toggle()
        scheduleCheck(after: 1)
    }

    private func setTime(hour: Int, minute: Int) {
        settings.hour = hour
        settings.minute = minute
        scheduleCheck(after: 1)
    }

    private func chooseTime() {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        picker.dateValue = settings.schedule.dueTime(on: Date(), calendar: calendar)
        picker.sizeToFit()

        let alert = NSAlert()
        alert.messageText = "每天几点打印 AI 花费？"
        alert.informativeText = "到点时如果没人在电脑前，会等你回来再打。"
        alert.accessoryView = picker
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let time = calendar.dateComponents([.hour, .minute], from: picker.dateValue)
        setTime(hour: time.hour ?? settings.hour, minute: time.minute ?? settings.minute)
    }

    static func clock(_ hour: Int, _ minute: Int) -> String {
        String(format: "%d:%02d", hour, minute)
    }

    // MARK: Printing

    private func printToday(automatic: Bool) async {
        guard !isLoading else {
            // One asked for by hand got there first; the daily one is still owed.
            if automatic { scheduleCheck(after: 5) }
            return
        }
        isLoading = true
        defer { isLoading = false }

        let now = Date()
        let day = DailySchedule.dayKey(for: now, calendar: calendar)
        let mac = await thisMac()
        let text: String
        do throws(UsageHistory.Failure) {
            guard let executable = UsageHistory.executable() else {
                throw UsageHistory.Failure(message: "no usage history on this Mac")
            }
            let records = try await UsageHistory.today(using: executable)
            text = DailySpendReceipt.text(DaySpend(records, on: now, calendar: calendar), mac: mac, now: now, calendar: calendar)
        } catch {
            log.error("Reading today's usage failed: \(error.message, privacy: .public)")
            if automatic {
                failures = (day, failures.day == day ? failures.count + 1 : 1)
                if failures.count >= Self.attemptsPerDay {
                    // Not today, then; tomorrow it tries again.
                    settings.lastPrintedDay = day
                    scheduleCheck(after: 1)
                } else {
                    scheduleCheck(after: 10 * 60)
                }
            } else {
                enqueue(DailySpendReceipt.unavailable(mac: mac, now: now, calendar: calendar), day: day, priority: .normal)
            }
            return
        }
        if automatic {
            settings.lastPrintedDay = day
            scheduleCheck(after: 1)
        }
        enqueue(text, day: day, priority: automatic ? .ambient : .normal)
    }

    private func enqueue(_ text: String, day: String, priority: PrintJob.Priority) {
        do {
            var job = try RemoteJobs.job(for: PrintRequest(text: text, name: "AI 花费 \(day)"))
            job.priority = priority
            printer.enqueue(job)
        } catch {
            log.error("Today's spending does not fit on a sheet: \(error.message, privacy: .public)")
        }
    }

    private func thisMac() async -> ThisMac {
        if let mac { return mac }
        let current = await ThisMac.current()
        mac = current
        return current
    }

    // MARK: Daily schedule

    /// Looks at the clock after `delay`, and again whenever the answer could change (see
    /// `ClockWatcher`). Re-checks at least every quarter hour so a missed wake-up or a clock
    /// change never leaves the timer stale.
    private func scheduleCheck(after delay: TimeInterval) {
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.check()
        }
    }

    private func check() {
        guard settings.isOn, allowsAutomaticPrints else { return }
        let now = Date()
        let schedule = settings.schedule
        if schedule.isDue(now: now, lastPrintedDay: settings.lastPrintedDay, calendar: calendar), !isLoading {
            if let reason = Presence.notReady(slot: printer.activity) {
                // Nobody to see it yet; look again shortly.
                log.debug("Today's spending postponed: \(reason, privacy: .public)")
                scheduleCheck(after: 30)
                return
            }
            // It looks at the clock again once it is done.
            Task { await printToday(automatic: true) }
            return
        }
        let next = schedule.nextCheck(after: now, lastPrintedDay: settings.lastPrintedDay, calendar: calendar)
        scheduleCheck(after: min(15 * 60, max(5, next.timeIntervalSince(now) + 1)))
    }
}

/// What 今日 AI 花费 remembers between launches.
@MainActor
final class DailySpendSettings {
    private let defaults: UserDefaults
    private let prefix = "dailySpend."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Print by itself once a day. Off by default: it is an extra, not the point of the app.
    var isOn: Bool {
        get { defaults.bool(forKey: prefix + "autoPrint") }
        set { defaults.set(newValue, forKey: prefix + "autoPrint") }
    }

    var hour: Int {
        get { defaults.object(forKey: prefix + "hour") as? Int ?? 18 }
        set { defaults.set(min(23, max(0, newValue)), forKey: prefix + "hour") }
    }

    var minute: Int {
        get { defaults.object(forKey: prefix + "minute") as? Int ?? 30 }
        set { defaults.set(min(59, max(0, newValue)), forKey: prefix + "minute") }
    }

    var schedule: DailySchedule { DailySchedule(hour: hour, minute: minute) }

    /// The day (`yyyy-MM-dd`) the automatic print last went out, or was given up on.
    var lastPrintedDay: String? {
        get { defaults.string(forKey: prefix + "lastPrintedDay") }
        set { defaults.set(newValue, forKey: prefix + "lastPrintedDay") }
    }
}
