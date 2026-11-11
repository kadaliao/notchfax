import AppKit
import FaxKit
import Memories
import PhotoBooth
import PrintKit
import ServiceManagement

/// Command-line switches for development.
///
/// - `--demo fax,photo,strip,viewfinder,compose`: run these samples right after launch.
/// - `--simulate-notch`: draw a notch on a display without one.
/// - `--quit-after <seconds>`: quit on its own, for scripted runs.
struct LaunchOptions {
    var demos: [String] = []
    var simulatesNotch = false
    var quitAfter: TimeInterval?

    init(arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--demo": demos = (iterator.next() ?? "").split(separator: ",").map(String.init)
            case "--simulate-notch": simulatesNotch = true
            case "--quit-after": quitAfter = iterator.next().flatMap(TimeInterval.init)
            default: break
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let launch: LaunchOptions
    private let printer = Printer()
    private var features: [any FeatureModule] = []
    private var statusItem: NSStatusItem?
    private lazy var debug = DebugSamples(printer: printer)

    private enum Key {
        static let muted = "muted"
        static let simulatesNotch = "debug.simulatesNotch"
    }

    init(launch: LaunchOptions) {
        self.launch = launch
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        printer.isMuted = defaults.bool(forKey: Key.muted)
        printer.simulatesNotch = launch.simulatesNotch || defaults.bool(forKey: Key.simulatesNotch)

        // Each feature registers itself here; this list is the only wiring a module needs.
        features = [
            MemoriesFeature(printer: printer),
            PhotoBoothFeature(printer: printer),
            FaxFeature(printer: printer),
        ]

        installStatusItem()
        printer.start()
        features.forEach { $0.start() }
        runLaunchDemos()
    }

    func applicationWillTerminate(_ notification: Notification) {
        printer.stop()
    }

    // MARK: Menu

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "printer.fill", accessibilityDescription: "Notchfax")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        var entries = printer.menu.entries()
        if !entries.isEmpty { entries.append(.separator) }
        entries += [
            .submenu(title: "调试", systemImage: "hammer", items: debug.menuEntries + [
                .separator,
                .action("模拟刘海", isOn: printer.simulatesNotch) { [weak self] in self?.toggleSimulatedNotch() },
            ]),
            .separator,
            .action("静音", systemImage: "speaker.slash", isOn: printer.isMuted) { [weak self] in self?.toggleMute() },
            .action("登录时启动", isOn: SMAppService.mainApp.status == .enabled) { [weak self] in self?.toggleLaunchAtLogin() },
            .separator,
            .action("退出 Notchfax") { NSApp.terminate(nil) },
        ]
        MenuEntry.menuItems(for: entries).forEach(menu.addItem)
    }

    private func toggleMute() {
        printer.isMuted.toggle()
        UserDefaults.standard.set(printer.isMuted, forKey: Key.muted)
    }

    private func toggleSimulatedNotch() {
        printer.simulatesNotch.toggle()
        UserDefaults.standard.set(printer.simulatesNotch, forKey: Key.simulatesNotch)
    }

    private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法更改登录时启动"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: Scripted runs

    private func runLaunchDemos() {
        if !launch.demos.isEmpty {
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                for demo in launch.demos { debug.run(demo) }
            }
        }
        if let seconds = launch.quitAfter {
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                NSApp.terminate(nil)
            }
        }
    }
}
