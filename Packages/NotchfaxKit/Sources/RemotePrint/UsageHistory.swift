import AppKit
import SystemConfiguration

/// Where a day's AI spending comes from: magpie's usage history, when magpie is installed.
/// It holds every call its gateway served, and the calls agents made on their own, read from
/// their session files, so it covers the whole Mac rather than one agent.
///
/// None of this is printed: the receipt names the computer, never where the numbers came from.
enum UsageHistory {
    struct Failure: Error {
        let message: String
    }

    static let bundleIdentifier = "com.yetone.magpie"
    /// Long enough for a busy day's history to be read; a stuck command must not hold up the next print.
    static let timeout: Duration = .seconds(30)

    /// The command, or `nil` if it is not on this Mac. Apps opened from Finder get a bare
    /// PATH, so it is looked for where it gets installed rather than on the PATH.
    @MainActor
    static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [URL] = []
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            candidates.append(app.appending(path: "Contents/MacOS/magpie"))
        }
        candidates += [
            URL(filePath: "/Applications/magpie.app/Contents/MacOS/magpie"),
            home.appending(path: "Applications/magpie.app/Contents/MacOS/magpie"),
            URL(filePath: "/opt/homebrew/bin/magpie"),
            URL(filePath: "/usr/local/bin/magpie"),
            home.appending(path: ".local/bin/magpie"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Every call made since midnight, local time.
    static func today(using executable: URL) async throws(Failure) -> [UsageRecord] {
        let output = try await run(executable, ["usage", "--csv", "today"])
        do {
            return try UsageCSV.records(from: String(decoding: output, as: UTF8.self))
        } catch {
            throw Failure(message: error.message)
        }
    }

    /// Runs a command to the end and returns what it wrote, or fails with what it said.
    static func run(_ executable: URL, _ arguments: [String]) async throws(Failure) -> Data {
        // The waiting blocks a thread, so it happens on one of GCD's rather than the shared pool.
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(executable, arguments))
            }
        }
        return try result.get()
    }

    private static func runBlocking(_ executable: URL, _ arguments: [String]) -> Result<Data, Failure> {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return .failure(Failure(message: "could not start \(executable.path): \(error.localizedDescription)"))
        }

        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(Int(timeout.components.seconds)), execute: watchdog)
        // Both pipes are drained at once: a command that fills one while we wait on the other would never finish.
        let errors = Drained()
        let drained = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: drained) {
            errors.data = stderr.fileHandleForReading.readDataToEndOfFile()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let said = String(decoding: errors.data.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let how = process.terminationReason == .uncaughtSignal ? "was stopped after \(timeout)" : "exited \(process.terminationStatus)"
            return .failure(Failure(message: "\(executable.lastPathComponent) \(arguments.joined(separator: " ")) \(how): \(said)"))
        }
        return .success(output)
    }

    /// Filled on one queue and read on another once the group says it is done.
    private final class Drained: @unchecked Sendable {
        var data = Data()
    }
}

extension ThisMac {
    /// This Mac's name, model and chip. The model comes from System Information, which takes
    /// a moment, so it is asked for once and kept.
    static func current() async -> ThisMac {
        let name = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? Host.current().localizedName ?? "这台 Mac"
        var hardware: [String: Any] = [:]
        if let data = try? await UsageHistory.run(URL(filePath: "/usr/sbin/system_profiler"), ["SPHardwareDataType", "-json"]),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let first = (json["SPHardwareDataType"] as? [[String: Any]])?.first {
            hardware = first
        }
        return ThisMac(
            name: name,
            model: nonEmpty(hardware["machine_name"]) ?? hardwareModel(),
            // Intel Macs name a processor instead of a chip.
            chip: chipName(nonEmpty(hardware["chip_type"]) ?? nonEmpty(hardware["cpu_type"]))
        )
    }

    /// `Apple M1 Max` → `M1 Max`.
    static func chipName(_ chip: String?) -> String? {
        chip.map { $0.hasPrefix("Apple ") ? String($0.dropFirst(6)) : $0 }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The model identifier (`MacBookPro18,2`), when System Information has nothing to say.
    private static func hardwareModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}
