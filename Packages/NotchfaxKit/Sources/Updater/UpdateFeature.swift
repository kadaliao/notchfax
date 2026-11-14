import AppKit
import os
import PrintKit
import SwiftUI

/// Switches for trying updates out without publishing a release:
///
/// - `--update-feed <url>`: read the latest release from here instead of GitHub. A
///   `file://` URL to a saved `releases/latest` response works, and so do `file://`
///   download links inside it.
/// - `--update-check`: check once right after launch, as 检查更新… does.
/// - `--update-current <version>`: behave as if this version were running.
/// - `--update-install-when-ready`: restart into the update as soon as it is downloaded,
///   for unattended runs (the same as pressing 现在重启 on the slip).
struct UpdateLaunchOptions: Equatable {
    var feed: URL?
    var checksAtLaunch = false
    var current: AppVersion?
    var installsWhenReady = false

    init(arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--update-feed": feed = iterator.next().flatMap(URL.init(string:))
            case "--update-check": checksAtLaunch = true
            case "--update-current": current = iterator.next().flatMap(AppVersion.init)
            case "--update-install-when-ready": installsWhenReady = true
            default: break
            }
        }
    }
}

/// Keeps Notchfax up to date from its GitHub releases.
///
/// Every six hours (and when asked) it reads the latest release. A newer one is
/// downloaded in the background, checked against its checksum and, above all, its code
/// signature, which must be a Developer ID signature from the same team as the running
/// app, and kept in Caches. Then a slip comes out of the slot saying so, with a button to
/// restart into it; otherwise it goes in when Notchfax next quits.
@MainActor
public final class UpdateFeature: FeatureModule {
    enum Phase: Equatable {
        case idle
        case checking(manual: Bool)
        case downloading(AppVersion)
        case ready
        case installing
    }

    struct Staged: Sendable {
        var update: AvailableUpdate
        var app: URL
    }

    static let defaultFeed = URL(string: "https://api.github.com/repos/kadaliao/notchfax/releases/latest")!
    static let checkInterval: TimeInterval = 6 * 3600

    /// Debug builds run from a build folder and should stay what was just built.
    #if DEBUG
    static let automaticByDefault = false
    #else
    static let automaticByDefault = true
    #endif

    private enum Key {
        static let automatic = "update.automatic"
        static let lastCheck = "update.lastCheck"
        /// The newest version a slip has already been printed about.
        static let announced = "update.announced"
        /// `<from>><to>`, written just before an update goes in, read on the next launch.
        static let installed = "update.installed"
        static let feed = "update.feedURL"
    }

    /// Set by the app shell before `start()`: scripted runs never check by themselves.
    public var allowsAutomaticChecks = true

    private let printer: Printer
    private let launch: UpdateLaunchOptions
    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: "com.kadaliao.notchfax", category: "update")
    private let current: AppVersion?
    private let app = Bundle.main.bundleURL
    private let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.kadaliao.notchfax"
    private let signer = CodeSignature.runningApp()
    private let downloader: UpdateDownloader
    private(set) var phase: Phase = .idle
    private var staged: Staged?
    private var schedule: Task<Void, Never>?

    public init(printer: Printer) {
        self.printer = printer
        launch = UpdateLaunchOptions(arguments: CommandLine.arguments)
        current = launch.current
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
        downloader = UpdateDownloader(
            session: UpdateDownloader.makeSession(),
            userAgent: "Notchfax/\(current?.description ?? "0") (macOS)"
        )
    }

    public func start() {
        announceInstalled()
        restoreStaged()
        reschedule()
        if launch.checksAtLaunch {
            Task {
                try? await Task.sleep(for: .milliseconds(1500))
                await check(manual: true)
            }
        }
    }

    // MARK: Settings

    public var isAutomatic: Bool {
        get { defaults.object(forKey: Key.automatic) as? Bool ?? Self.automaticByDefault }
        set {
            defaults.set(newValue, forKey: Key.automatic)
            reschedule()
        }
    }

    private var feed: URL {
        launch.feed ?? defaults.string(forKey: Key.feed).flatMap(URL.init(string:)) ?? Self.defaultFeed
    }

    private var stagingDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent(bundleIdentifier, isDirectory: true).appendingPathComponent("Updates", isDirectory: true)
    }

    // MARK: Menu

    public func menuEntries() -> [MenuEntry] {
        var entries: [MenuEntry] = []
        switch phase {
        case .idle:
            entries.append(.action("检查更新…") { [weak self] in
                Task { await self?.check(manual: true) }
            })
        case .checking:
            entries.append(.label("正在检查更新…"))
        case .downloading(let version):
            entries.append(.label("正在下载 \(version)…"))
        case .ready:
            let version = staged?.update.version.description ?? ""
            entries.append(.action("重启以更新到 \(version)", systemImage: "arrow.down.circle") { [weak self] in
                self?.installNow()
            })
        case .installing:
            entries.append(.label("正在更新…"))
        }
        entries.append(.action("自动更新", isOn: isAutomatic, isEnabled: signer != nil) { [weak self] in
            self?.isAutomatic.toggle()
        })
        return entries
    }

    // MARK: Checking

    private func reschedule() {
        schedule?.cancel()
        schedule = nil
        guard isAutomatic, allowsAutomaticChecks, signer != nil, current != nil else { return }
        schedule = Task { [weak self] in
            // Not in the middle of launching: let the slot and the fax connection settle first.
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                guard let self else { return }
                if self.isDue { await self.check(manual: false) }
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
    }

    private var isDue: Bool {
        let last = defaults.double(forKey: Key.lastCheck)
        return Date().timeIntervalSince1970 - last >= Self.checkInterval
    }

    func check(manual: Bool) async {
        switch phase {
        case .idle:
            break
        case .ready:
            // Already downloaded: say so again.
            if manual, let staged, let current {
                printReady(staged.update, current: current, priority: .normal)
            }
            return
        case .checking, .downloading, .installing:
            return
        }
        guard let current else {
            if manual { printSlip(.failed(.feed), priority: .normal) }
            return
        }
        phase = .checking(manual: manual)
        logger.info("checking \(self.feed.absoluteString, privacy: .public) from \(current.description, privacy: .public)")
        do throws(UpdateError) {
            let outcome = try await downloader.check(feed: feed, current: current)
            defaults.set(Date().timeIntervalSince1970, forKey: Key.lastCheck)
            switch outcome {
            case .upToDate(let latest):
                phase = .idle
                logger.info("up to date (latest \(latest.description, privacy: .public))")
                if manual { printSlip(.upToDate(current), priority: .normal) }
            case .available(let update):
                logger.info("found \(update.version.description, privacy: .public)")
                if let reason = blocker(for: update) {
                    phase = .idle
                    if manual || !wasAnnounced(update.version) {
                        printManual(update, current: current, reason: reason, priority: manual ? .normal : .ambient)
                    }
                    return
                }
                guard let signer else { return }
                phase = .downloading(update.version)
                let staged: URL
                do throws(UpdateError) {
                    staged = try await downloader.stage(update, in: stagingDirectory, bundleIdentifier: bundleIdentifier, signer: signer)
                } catch {
                    phase = .idle
                    logger.error("download of \(update.version.description, privacy: .public) failed: \(error.message, privacy: .public)")
                    // Said once per version when nobody asked; the next check tries again quietly.
                    if manual || !wasAnnounced(update.version) {
                        defaults.set(update.version.description, forKey: Key.announced)
                        printSlip(.failed(error, version: update.version), priority: manual ? .normal : .ambient, actions: [downloadAction(update.releasePage)])
                    }
                    return
                }
                self.staged = Staged(update: update, app: staged)
                phase = .ready
                logger.info("staged \(update.version.description, privacy: .public) at \(staged.path, privacy: .public)")
                if manual || !wasAnnounced(update.version) {
                    printReady(update, current: current, priority: manual ? .normal : .ambient)
                }
                if launch.installsWhenReady { installNow() }
            }
        } catch {
            phase = .idle
            logger.error("update check failed: \(error.message, privacy: .public)")
            if manual { printSlip(.failed(error), priority: .normal) }
        }
    }

    /// Why this update cannot go in by itself, in a sentence for the slip.
    private func blocker(for update: AvailableUpdate) -> String? {
        if signer == nil { return UpdateError.unsigned.message }
        if update.archive == nil { return UpdateError.noArchive.message }
        if let problem = UpdateInstaller.problem(replacing: app) { return UpdateError.location(problem).message }
        return nil
    }

    /// A copy downloaded by an earlier run, if it is still newer and still intact.
    private func restoreStaged() {
        let directory = stagingDirectory
        guard let current, let signer else {
            try? FileManager.default.removeItem(at: directory)
            return
        }
        Task {
            let found = await Task.detached { Self.findStaged(in: directory, newerThan: current, signer: signer) }.value
            guard phase == .idle else { return }
            guard let found else {
                try? FileManager.default.removeItem(at: directory)
                return
            }
            staged = found
            phase = .ready
            logger.info("found staged \(found.update.version.description, privacy: .public)")
            if !wasAnnounced(found.update.version) {
                printReady(found.update, current: current, priority: .ambient)
            }
        }
    }

    nonisolated static func findStaged(in directory: URL, newerThan current: AppVersion, signer: CodeSignature.Signer) -> Staged? {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(UpdateInstaller.manifestName)),
                  let update = try? JSONDecoder().decode(AvailableUpdate.self, from: data),
                  update.version > current,
                  let contents = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil),
                  let app = contents.first(where: { $0.pathExtension == "app" }),
                  UpdateInstaller.version(of: app) == update.version,
                  (try? CodeSignature.verify(bundle: app, signedLike: signer)) != nil
            else { continue }
            return Staged(update: update, app: app)
        }
        return nil
    }

    // MARK: Installing

    /// Puts the new version in place and starts it.
    func installNow() {
        guard phase == .ready, let staged, let signer else { return }
        phase = .installing
        let app = self.app
        Task {
            let result = await Task.detached {
                Result { () throws(UpdateError) in try UpdateInstaller.install(staged.app, over: app, signer: signer) }
            }.value
            switch result {
            case .success:
                logger.info("installed \(staged.update.version.description, privacy: .public), relaunching")
                recordInstalled(staged.update.version)
                try? FileManager.default.removeItem(at: stagingDirectory)
                UpdateInstaller.relaunch(app)
                NSApp.terminate(nil)
            case .failure(let error):
                logger.error("install failed: \(error.message, privacy: .public)")
                self.staged = nil
                phase = .idle
                try? FileManager.default.removeItem(at: stagingDirectory)
                printSlip(.failed(error, version: staged.update.version), priority: .normal, actions: [downloadAction(staged.update.releasePage)])
            }
        }
    }

    /// Called as the app quits: a downloaded update goes in now, and is running next time.
    public func installOnQuit() {
        guard phase == .ready, let staged, let signer else { return }
        phase = .installing
        do throws(UpdateError) {
            try UpdateInstaller.install(staged.app, over: app, signer: signer)
            recordInstalled(staged.update.version)
            try? FileManager.default.removeItem(at: stagingDirectory)
            logger.info("installed \(staged.update.version.description, privacy: .public) on quit")
        } catch {
            logger.error("install on quit failed: \(error.message, privacy: .public)")
        }
    }

    private func recordInstalled(_ version: AppVersion) {
        defaults.set("\(current?.description ?? "")>\(version)", forKey: Key.installed)
    }

    /// The first launch of a new version says which one it is.
    private func announceInstalled() {
        guard let marker = defaults.string(forKey: Key.installed) else { return }
        defaults.removeObject(forKey: Key.installed)
        let parts = marker.split(separator: ">", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let version = AppVersion(parts[1]), version == current else { return }
        printSlip(.installed(version, from: AppVersion(parts[0])), priority: .ambient)
    }

    // MARK: Slips

    private func wasAnnounced(_ version: AppVersion) -> Bool {
        defaults.string(forKey: Key.announced).flatMap(AppVersion.init).map { $0 >= version } ?? false
    }

    private func printReady(_ update: AvailableUpdate, current: AppVersion, priority: PrintJob.Priority) {
        defaults.set(update.version.description, forKey: Key.announced)
        let restart = PaperAction(id: "restart", title: "现在重启", systemImage: "arrow.clockwise") { [weak self] handle in
            handle.retract()
            self?.installNow()
        }
        printSlip(.ready(update.version, current: current, notes: update.notes), priority: priority, actions: [restart])
    }

    private func printManual(_ update: AvailableUpdate, current: AppVersion, reason: String, priority: PrintJob.Priority) {
        defaults.set(update.version.description, forKey: Key.announced)
        printSlip(
            .manual(update.version, current: current, notes: update.notes, reason: reason),
            priority: priority,
            actions: [downloadAction(update.releasePage)]
        )
    }

    private func downloadAction(_ page: URL) -> PaperAction {
        PaperAction(id: "download", title: "去下载", systemImage: "safari") { handle in
            handle.retract()
            NSWorkspace.shared.open(page)
        }
    }

    private func printSlip(_ slip: UpdateSlip, priority: PrintJob.Priority, actions: [PaperAction] = []) {
        printer.enqueue(PrintJob(
            PaperSheet(.thermal) { UpdateSlipView(slip: slip) },
            reveal: .progressive(lineHeight: 14),
            autoRetract: .after(max(14, slip.readingTime + 12)),
            export: PNGExport(filename: "Notchfax \(slip.tag)"),
            actions: actions,
            priority: priority,
            readingTime: slip.readingTime
        ))
    }
}
