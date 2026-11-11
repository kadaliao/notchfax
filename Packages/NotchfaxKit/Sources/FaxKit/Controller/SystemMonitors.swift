import AppKit
import Foundation
import Network
import os

/// Tells the connection when the Mac sleeps, wakes, or loses and regains the network.
@MainActor
final class SystemMonitors {
    private var observers: [any NSObjectProtocol] = []
    private let path = NWPathMonitor()
    private var lastSatisfied: Bool?
    private var lastInterfaces: [String] = []

    init(
        onSleep: @escaping @MainActor () -> Void,
        onWake: @escaping @MainActor () -> Void,
        onNetwork: @escaping @MainActor (_ available: Bool, _ interfaceChanged: Bool) -> Void
    ) {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { onSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { onWake() }
        })
        path.pathUpdateHandler = { [weak self] update in
            let satisfied = update.status == .satisfied
            let interfaces = update.availableInterfaces.map(\.name)
            Task { @MainActor in
                guard let self else { return }
                let changed = self.lastInterfaces != interfaces
                defer {
                    self.lastSatisfied = satisfied
                    self.lastInterfaces = interfaces
                }
                // The first report only describes the starting point.
                guard let previous = self.lastSatisfied else { return }
                if previous != satisfied || (satisfied && changed) {
                    onNetwork(satisfied, changed)
                }
            }
        }
        path.start(queue: DispatchQueue(label: "com.kadaliao.notchfax.fax.path"))
    }

    func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        path.cancel()
    }
}

/// Logging for the fax feature, plus an optional plain-text trail for scripted runs
/// (`--fax-debug-log <file>`). Never writes message text or tokens.
@MainActor
final class FaxLog {
    private let logger = Logger(subsystem: "com.kadaliao.notchfax", category: "fax")
    private let handle: FileHandle?
    private let profile: String

    init(path: String?, profile: String?) {
        self.profile = profile ?? "default"
        if let path {
            FileManager.default.createFile(atPath: path, contents: nil)
            handle = FileHandle(forWritingAtPath: path)
        } else {
            handle = nil
        }
    }

    func callAsFunction(_ message: String) {
        logger.info("\(message, privacy: .public)")
        guard let handle else { return }
        let stamp = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
        handle.write(Data("\(stamp) [\(profile)] \(message)\n".utf8))
    }
}
