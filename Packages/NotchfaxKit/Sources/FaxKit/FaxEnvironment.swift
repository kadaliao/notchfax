import Foundation

/// Command-line switches the fax feature understands. The app shell ignores them, so
/// they can be passed straight to the executable:
///
/// - `--fax-profile <name>`: a separate identity and local store, so two instances can
///   talk to each other on one Mac. Named profiles keep their key in a file, not the keychain.
/// - `--fax-server <url>`: overrides the server for this run.
/// - `--fax-debug-…`: scripted actions for unattended end-to-end runs; see `FaxDebugScript`.
struct FaxLaunchOptions: Sendable, Equatable {
    var profile: String?
    var server: URL?
    var script = FaxDebugScript()
    var renderSamplesDirectory: String?
    /// Debug: open the server panel at launch.
    var showsServerSettings = false

    init(arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        func seconds(_ value: String?) -> TimeInterval? { value.flatMap(TimeInterval.init) }
        while let argument = iterator.next() {
            switch argument {
            case "--fax-profile":
                profile = iterator.next().flatMap(Self.validProfile)
            case "--fax-server":
                server = iterator.next().flatMap(Self.validServer)
            case "--fax-debug-send": script.sendText = iterator.next()
            case "--fax-debug-auto-reply": script.autoReplyText = iterator.next()
            case "--fax-debug-reply-delay": script.autoReplyDelay = seconds(iterator.next()) ?? script.autoReplyDelay
            case "--fax-debug-early-image": script.earlyImageDelay = seconds(iterator.next())
            case "--fax-debug-image-on-connect": script.imageOnConnectDelay = seconds(iterator.next())
            case "--fax-debug-image": script.imagePath = iterator.next()
            case "--fax-debug-image-caption": script.imageCaption = iterator.next()
            case "--fax-debug-tear-after-image": script.tearAfterImageDelay = seconds(iterator.next())
            case "--fax-debug-show-menu": script.showMenuAfter = seconds(iterator.next())
            case "--fax-debug-confirm-report": script.confirmReportAfter = seconds(iterator.next())
            case "--fax-debug-hands-off": script.handsOff = true
            case "--fax-debug-log": script.logPath = iterator.next()
            case "--fax-render-samples": renderSamplesDirectory = iterator.next()
            case "--fax-debug-server-settings": showsServerSettings = true
            default: break
            }
        }
    }

    static func validProfile(_ name: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard (1...32).contains(name.count), name.unicodeScalars.allSatisfy(allowed.contains), name != "default" else { return nil }
        return name
    }

    static func validServer(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }
}

/// Where this profile's identity and data live, and which server it talks to.
struct FaxEnvironment: Sendable {
    /// `nil` for the default profile.
    var profile: String?
    var server: URL?
    var directory: URL
    var keyStore: any IdentityKeyStore

    static let serverDefaultsKey = "fax.serverURL"

    static func make(launch: FaxLaunchOptions, defaults: UserDefaults = .standard) -> FaxEnvironment {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let fax = base.appendingPathComponent("Notchfax", isDirectory: true).appendingPathComponent("Fax", isDirectory: true)
        let directory: URL
        let keyStore: any IdentityKeyStore
        if let profile = launch.profile {
            directory = fax.appendingPathComponent("profiles", isDirectory: true).appendingPathComponent(profile, isDirectory: true)
            keyStore = FileKeyStore(url: directory.appendingPathComponent("identity.key"))
        } else {
            directory = fax.appendingPathComponent("default", isDirectory: true)
            keyStore = defaultKeyStore(directory: directory)
        }
        return FaxEnvironment(
            profile: launch.profile,
            server: resolveServer(launch: launch.server, defaults: defaults),
            directory: directory,
            keyStore: keyStore
        )
    }

    /// Release builds keep the default identity in the login keychain. Debug builds are
    /// ad-hoc signed with a new code identity on every build, so a keychain item's access
    /// list would stop matching and macOS would ask for the password on each launch; they
    /// use an owner-only file instead and never touch the keychain, not even to migrate.
    static func defaultKeyStore(directory: URL) -> any IdentityKeyStore {
        #if DEBUG
        return FileKeyStore(url: directory.appendingPathComponent("identity.key"))
        #else
        return KeychainKeyStore(account: "default")
        #endif
    }

    /// The launch argument, then the user default, then the local dev server in Debug builds or the public relay in Release builds.
    static func resolveServer(launch: URL?, defaults: UserDefaults) -> URL? {
        if let launch { return launch }
        if let string = defaults.string(forKey: serverDefaultsKey), let url = FaxLaunchOptions.validServer(string) {
            return url
        }
        #if DEBUG
        return URL(string: "http://127.0.0.1:8787")
        #else
        return URL(string: publicServer)
        #endif
    }

    /// The public relay that Release builds talk to unless another address is set.
    static let publicServer = "https://notchfax.liaoxingyi.com"
}
