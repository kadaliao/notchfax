import Foundation

/// Puts the `notchfax` command on the PATH: a link in /usr/local/bin to the running app's
/// executable, the way editors install their shell commands.
public enum CommandLineInstaller {
    public static let linkPath = "/usr/local/bin/\(CommandLineTool.commandName)"

    public struct Failure: Error {
        public let message: String
    }

    private static var executablePath: String? {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path
    }

    /// The link exists and leads to this copy of the app.
    public static var isInstalled: Bool {
        guard let executablePath,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)) != nil else { return false }
        return URL(fileURLWithPath: linkPath).resolvingSymlinksInPath().path == executablePath
    }

    /// Creates or repoints the link. /usr/local/bin usually belongs to root, so this asks for an
    /// administrator password; it blocks until the person answers, so call it off the main actor.
    /// Returns false if they cancelled.
    public static func install() throws(Failure) -> Bool {
        guard let executablePath else { throw Failure(message: "找不到 Notchfax 的可执行文件。") }
        let manager = FileManager.default
        let folder = (linkPath as NSString).deletingLastPathComponent
        // Without a password when the folder is ours (Homebrew on Intel Macs makes it so).
        if manager.isWritableFile(atPath: folder) {
            do {
                if (try? manager.destinationOfSymbolicLink(atPath: linkPath)) != nil || manager.fileExists(atPath: linkPath) {
                    try manager.removeItem(atPath: linkPath)
                }
                try manager.createSymbolicLink(atPath: linkPath, withDestinationPath: executablePath)
                return true
            } catch {
                throw Failure(message: error.localizedDescription)
            }
        }

        let command = "mkdir -p \(shellQuoted(folder)) && ln -sfn \(shellQuoted(executablePath)) \(shellQuoted(linkPath))"
        let script = "do shell script \"\(appleScriptEscaped(command))\" with administrator privileges"
        let osascript = Process()
        osascript.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osascript.arguments = ["-e", script]
        let errors = Pipe()
        osascript.standardError = errors
        do {
            try osascript.run()
            osascript.waitUntilExit()
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        if osascript.terminationStatus == 0 { return true }
        let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // -128: the person pressed Cancel.
        if output.contains("-128") { return false }
        throw Failure(message: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptEscaped(_ string: String) -> String {
        string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
