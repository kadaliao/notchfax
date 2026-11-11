import AppKit
import os
import PrintKit

/// 那年今日: prints a photo taken on this day in an earlier year.
///
/// Launch arguments, for development:
/// - `--memories-sample`: use procedural sample pictures instead of the Photos library.
/// - `--memories-demo`: implies `--memories-sample`, and prints today's memories at launch.
@MainActor
public final class MemoriesFeature: FeatureModule {
    /// How many memories the daily print shows at most, one after another.
    static let dailyLimit = 3
    /// Long side of the picture loaded for a print and its export.
    static let exportPixels = 2048
    /// How long to wait for an original that has to come down from iCloud.
    static let downloadTimeout: Duration = .seconds(25)

    private let printer: Printer
    private let library: any MemoryLibrary
    private let settings: MemoriesSettings
    private let calendar = MemoryCalendar()
    private let selector: MemorySelector
    private let options: LaunchOptions
    private let log = Logger(subsystem: "com.kadaliao.notchfax", category: "memories")

    private var checkTask: Task<Void, Never>?
    private var dailyRun: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// A request is fetching or downloading.
    private var isLoading = false
    private var sampleCursor = 0
    /// Candidates of the last fetch, for "is there another one?" questions.
    private var lastFetch: (day: String, candidates: [MemoryCandidate])?

    struct LaunchOptions {
        var useSamples = false
        var demo = false

        init(arguments: [String] = ProcessInfo.processInfo.arguments) {
            demo = arguments.contains("--memories-demo")
            useSamples = demo || arguments.contains("--memories-sample")
        }
    }

    public init(printer: Printer) {
        self.printer = printer
        options = LaunchOptions()
        library = options.useSamples ? SampleMemoryLibrary() : PhotoKitLibrary()
        settings = MemoriesSettings(prefix: options.useSamples ? "memories.sample." : "memories.")
        selector = MemorySelector(calendar: calendar)
        printer.menu.addSection(id: "memories", order: 10) { [weak self] in self?.menuEntries() ?? [] }
    }

    public func start() {
        observeSystemEvents()
        if options.demo {
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                settings.resetPrinted(on: calendar.dayKey(for: Date()), keeping: nil)
                await run(.daily)
            }
        }
        scheduleCheck(after: options.demo ? 5 : 2)
    }

    // MARK: Menu

    private func menuEntries() -> [MenuEntry] {
        let access = library.access()
        let today = calendar.dayKey(for: Date())
        var entries: [MenuEntry] = [
            .action("打印那年今日", systemImage: "photo.on.rectangle.angled", isEnabled: !isLoading) { [weak self] in
                self?.request(.today)
            },
        ]
        if !settings.printed(on: today).isEmpty, access.canRead {
            entries.append(.action("再来一张", systemImage: "photo.stack", isEnabled: !isLoading) { [weak self] in
                self?.request(.another)
            })
        }
        if isLoading {
            entries.append(.label("正在取出照片…"))
        }
        entries.append(.action("每天自动打印", isOn: settings.autoPrint) { [weak self] in self?.toggleAutoPrint() })
        if settings.autoPrint {
            let hours = [7, 8, 9, 10, 12, 18, 21]
            entries.append(.submenu(title: "打印时间：\(settings.hour):00 以后", items: hours.map { hour in
                .action(String(format: "%d:00 以后", hour), isOn: settings.hour == hour) { [weak self] in self?.setHour(hour) }
            }))
        }
        if options.useSamples {
            entries.append(.label("正在使用样张图库"))
        }
        #if DEBUG
        entries.append(.action("打印样张（那年今日）", systemImage: "hammer") { [weak self] in self?.printSample() })
        #endif
        if access == .denied, let url = MemorySlip.privacySettings {
            entries.append(.action("允许访问照片…", systemImage: "lock") { NSWorkspace.shared.open(url) })
        }
        return entries
    }

    private func toggleAutoPrint() {
        settings.autoPrint.toggle()
        // Turning it on is the moment the person asks for it: the right time to ask for access.
        if settings.autoPrint, library.access() == .notDetermined {
            Task { _ = await library.requestAccess() }
        }
        scheduleCheck(after: 1)
    }

    private func setHour(_ hour: Int) {
        settings.hour = hour
        scheduleCheck(after: 1)
    }

    // MARK: Requests

    enum Request: Equatable {
        /// The automatic print: up to `dailyLimit` years, one after another.
        case daily
        /// Today's best memory, again if it was printed already.
        case today
        /// The next memory not printed yet today.
        case another
    }

    private func request(_ request: Request) {
        Task { await run(request) }
    }

    func run(_ request: Request) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let now = Date()
        let day = calendar.dayKey(for: now)
        let isAutomatic = request == .daily
        if !isAutomatic {
            // Asked for by hand: that takes over from the rest of today's automatic prints.
            dailyRun?.cancel()
            dailyRun = nil
        }
        var access = library.access()
        if access == .notDetermined {
            // The daily print never interrupts with a permission prompt.
            guard !isAutomatic else { return }
            access = await library.requestAccess()
        }
        guard access.canRead else {
            if isAutomatic {
                settings.lastPrintedDay = day
            } else {
                printer.enqueue(MemorySlip.job(.noAccess, today: now))
            }
            return
        }

        let candidates: [MemoryCandidate]
        do {
            candidates = try await library.candidates(in: calendar.windows(for: now))
        } catch {
            log.error("Fetching memories failed: \(error.localizedDescription, privacy: .public)")
            if !isAutomatic { printer.enqueue(MemorySlip.job(.noAccess, today: now)) }
            return
        }
        lastFetch = (day, candidates)
        let seed = Self.seed(for: day)
        let printed = Set(settings.printed(on: day))

        // Best first; later entries are fallbacks if a picture cannot be loaded.
        let queue: [MemoryCandidate]
        switch request {
        case .daily:
            queue = selector.dailyPicks(from: candidates, limit: Self.dailyLimit, excluding: printed, seed: seed)
        case .today:
            queue = selector.ranking(candidates, seed: seed)
        case .another:
            let ranking = selector.ranking(candidates, seed: seed)
            var fresh = ranking.filter { !printed.contains($0.id) }
            if fresh.isEmpty, ranking.count > 1 {
                // Every one has been shown: start over, but not with the one just printed.
                let last = settings.printed(on: day).last
                settings.resetPrinted(on: day, keeping: last)
                fresh = ranking.filter { $0.id != last }
            }
            queue = fresh.isEmpty ? ranking : fresh
        }

        settings.lastPrintedDay = day
        if queue.isEmpty {
            if !isAutomatic { printer.enqueue(MemorySlip.job(.nothingToday(limited: access == .limited), today: now)) }
            return
        }
        if isAutomatic {
            dailyRun?.cancel()
            dailyRun = Task { [weak self] in await self?.printOneAfterAnother(queue, today: now) }
            return
        }

        for candidate in queue.prefix(4) {
            do {
                printMemory(try await prepare(candidate), today: now)
                return
            } catch {
                log.notice("Skipping a memory that could not be loaded: \(String(describing: error), privacy: .public)")
            }
        }
        printer.enqueue(MemorySlip.job(.unavailable, today: now))
    }

    /// The daily prints, one after another. They are ambient jobs: the printer holds
    /// them back while the booth or a fax being written hangs from the slot, lets
    /// anything the person asked for go first, and never hurries a sheet for them.
    /// The next picture loads while the current one hangs.
    private func printOneAfterAnother(_ picks: [MemoryCandidate], today: Date) async {
        var pending = picks[...]
        var loading = pending.popFirst().map(load)
        var printedAny = false
        while let current = loading {
            loading = pending.popFirst().map(load)
            guard let item = await current.value else { continue }
            guard !Task.isCancelled else { return }
            if printedAny { try? await Task.sleep(for: .milliseconds(700)) }
            printedAny = true
            let outcome = await printMemory(item, today: today, priority: .ambient).outcome()
            if outcome == .cancelled { return }
        }
    }

    private func load(_ candidate: MemoryCandidate) -> Task<MemoryPrint.Prepared?, Never> {
        Task { [weak self] in
            do {
                return try await self?.prepare(candidate)
            } catch {
                self?.log.notice("Skipping a memory that could not be loaded: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
    }

    /// Debug: prints the next sample picture, whatever library is in use, without
    /// touching the real library's record of what was printed.
    private func printSample() {
        let sample = SampleMemoryLibrary()
        let now = Date()
        Task { [weak self] in
            guard let self else { return }
            let candidates = (try? await sample.candidates(in: self.calendar.windows(for: now))) ?? []
            let ranking = self.selector.ranking(candidates)
            guard !ranking.isEmpty else { return }
            let pick = ranking[self.sampleCursor % ranking.count]
            self.sampleCursor += 1
            guard let image = try? await sample.image(for: pick, maxPixel: Self.exportPixels, timeout: .seconds(5)) else { return }
            let printImage = await Self.downscale(image, to: MemoryPrint.printPixels)
            let item = MemoryPrint.Prepared(candidate: pick, printImage: printImage, exportImage: image)
            self.printer.enqueue(MemoryPrint.job(item, today: now, calendar: self.calendar, actions: []))
        }
    }

    @discardableResult
    private func printMemory(_ item: MemoryPrint.Prepared, today: Date, priority: PrintJob.Priority = .normal) -> PrintHandle {
        let day = calendar.dayKey(for: today)
        settings.recordPrinted(item.candidate.id, on: day)
        var actions: [PaperAction] = []
        if hasAnother(than: item.candidate, day: day) {
            actions.append(PaperAction(id: "another", title: "再来一张", systemImage: "photo.stack") { [weak self] handle in
                handle.retract()
                self?.request(.another)
            })
        }
        return printer.enqueue(MemoryPrint.job(item, today: today, calendar: calendar, actions: actions, priority: priority))
    }

    private func hasAnother(than candidate: MemoryCandidate, day: String) -> Bool {
        guard let lastFetch, lastFetch.day == day else { return false }
        return selector.ranking(lastFetch.candidates).contains { $0.id != candidate.id }
    }

    private func prepare(_ candidate: MemoryCandidate) async throws -> MemoryPrint.Prepared {
        let image = try await library.image(for: candidate, maxPixel: Self.exportPixels, timeout: Self.downloadTimeout)
        let printImage = await Self.downscale(image, to: MemoryPrint.printPixels)
        return MemoryPrint.Prepared(candidate: candidate, printImage: printImage, exportImage: image)
    }

    @concurrent
    private static func downscale(_ image: CGImage, to pixels: Int) async -> CGImage {
        ImageTools.downscaled(image, maxPixel: pixels)
    }

    private static func seed(for day: String) -> UInt64 {
        UInt64(truncatingIfNeeded: MemorySelector.jitter(day, seed: 0x5eed).bitPattern)
    }

    // MARK: Daily schedule

    private var schedule: DailySchedule { DailySchedule(hour: settings.hour) }

    /// Looks at the clock now (after a short grace period) and again whenever the answer
    /// could change. Re-checks at least every quarter hour so a missed wake-up or a
    /// clock change never leaves the timer stale.
    private func scheduleCheck(after delay: TimeInterval) {
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.check()
        }
    }

    private func check() {
        let now = Date()
        guard settings.autoPrint else { return }
        if schedule.isDue(now: now, lastPrintedDay: settings.lastPrintedDay, calendar: calendar) {
            if let reason = Presence.notReady(slot: printer.activity) {
                // Nobody to see it yet; look again shortly.
                log.debug("Daily memory postponed: \(reason, privacy: .public)")
                scheduleCheck(after: 30)
                return
            }
            request(.daily)
        }
        let next = schedule.nextCheck(after: now, lastPrintedDay: calendar.dayKey(for: now), calendar: calendar)
        scheduleCheck(after: min(15 * 60, max(5, next.timeIntervalSince(now) + 1)))
    }

    private func observeSystemEvents() {
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
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleCheck(after: 3) }
            }
            observers.append((center, token))
        }
    }
}

/// Whether someone is likely to see a print right now.
enum Presence {
    /// Why not, or `nil` if the coast is clear.
    @MainActor
    static func notReady(slot: SlotActivity) -> String? {
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return "display asleep" }
        // The booth, or a fax being written: the day's photos can wait until it is put away.
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
