import AppKit
import CryptoKit
import Foundation

/// What went wrong, in words for the slip.
enum UpdateError: Error, Equatable, Sendable {
    enum Location: Equatable, Sendable {
        /// Run straight from the Downloads folder or a disk image: macOS runs it from a
        /// read-only copy, so there is nothing to replace.
        case translocated
        case notWritable
        case notAnApp
    }

    case offline
    case network(String)
    case feed
    case noArchive
    case tooLarge
    case checksumMismatch
    case unpack(String)
    case wrongBundle
    case signature(String)
    case unsigned
    case location(Location)
    case install(String)

    var message: String {
        switch self {
        case .offline: "这台 Mac 现在没有网络。"
        case .network(let why): "连不上发布页：\(why)"
        case .feed: "发布页的回应看不懂。"
        case .noArchive: "这个版本没有可以自动安装的压缩包，请到发布页下载。"
        case .tooLarge: "新版本的压缩包大得不正常，没有下载。"
        case .checksumMismatch: "下载的文件和发布页记下的校验值对不上，已经丢掉了。"
        case .unpack(let why): "解压新版本失败：\(why)"
        case .wrongBundle: "压缩包里不是这个版本的 Notchfax。"
        case .signature(let why): "新版本的签名验证没有通过（\(why)），没有安装。"
        case .unsigned: "这个 Notchfax 没有开发者签名，没法确认更新的真假，不能自动更新。"
        case .location(.translocated): "Notchfax 是从「下载」或磁盘映像里直接打开的。先把它拖进「应用程序」文件夹，以后就能自动更新。"
        case .location(.notWritable): "Notchfax 所在的文件夹没有写入权限，换不了新版本。"
        case .location(.notAnApp): "找不到 Notchfax 自己的位置。"
        case .install(let why): "换上新版本时出错：\(why)"
        }
    }

    static func from(_ error: any Error) -> UpdateError {
        if let error = error as? UpdateError { return error }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return .offline
            case .timedOut: return .network("等了太久没有回应")
            case .cannotFindHost, .dnsLookupFailed: return .network("找不到 GitHub")
            default: return .network(error.localizedDescription)
            }
        }
        return .network(error.localizedDescription)
    }
}

/// Fetches the latest release, and downloads, checks and stages its app.
struct UpdateDownloader: Sendable {
    var session: URLSession
    var userAgent: String

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 15 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    func check(feed: URL, current: AppVersion) async throws(UpdateError) -> ReleaseFeed.Outcome {
        var request = URLRequest(url: feed)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        do {
            let (body, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError.network(http.statusCode == 403 || http.statusCode == 429 ? "GitHub 暂时限制了查询，过一会儿再试" : "发布页回应了 \(http.statusCode)")
            }
            data = body
        } catch {
            throw UpdateError.from(error)
        }
        guard let release = try? ReleaseFeed.decode(data), let outcome = ReleaseFeed.outcome(of: release, current: current) else {
            throw .feed
        }
        return outcome
    }

    /// Downloads the update into `directory/<version>/`, checks it, and returns the app
    /// inside, ready to be put in place. Nothing is left behind when a step fails.
    func stage(_ update: AvailableUpdate, in directory: URL, bundleIdentifier: String, signer: CodeSignature.Signer) async throws(UpdateError) -> URL {
        guard let archive = update.archive else { throw .noArchive }
        guard archive.size <= ReleaseFeed.largestArchive else { throw .tooLarge }
        let manager = FileManager.default
        let folder = directory.appendingPathComponent(update.version.description, isDirectory: true)
        try? manager.removeItem(at: directory)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw .install(error.localizedDescription)
        }
        do throws(UpdateError) {
            let app = try await downloadAndCheck(update, archive: archive, into: folder, bundleIdentifier: bundleIdentifier, signer: signer)
            // The notes travel with the staged copy, for the slip after a relaunch.
            if let data = try? JSONEncoder().encode(update) {
                try? data.write(to: folder.appendingPathComponent(UpdateInstaller.manifestName), options: .atomic)
            }
            return app
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    private func downloadAndCheck(
        _ update: AvailableUpdate, archive: AvailableUpdate.Archive, into folder: URL,
        bundleIdentifier: String, signer: CodeSignature.Signer
    ) async throws(UpdateError) -> URL {
        let manager = FileManager.default
        let zip = folder.appendingPathComponent("download.zip")
        do {
            var request = URLRequest(url: archive.url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (temporary, response) = try await session.download(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError.network("下载时对方回应了 \(http.statusCode)")
            }
            try manager.moveItem(at: temporary, to: zip)
        } catch {
            throw UpdateError.from(error)
        }

        let expected: String?
        if let sha256 = archive.sha256 {
            expected = sha256
        } else if let sums = archive.checksums {
            expected = await checksum(named: archive.name, at: sums)
        } else {
            expected = nil
        }
        guard let data = try? Data(contentsOf: zip, options: .mappedIfSafe) else { throw .unpack("读不出下载的文件") }
        guard data.count <= ReleaseFeed.largestArchive else { throw .tooLarge }
        if let expected {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw .checksumMismatch }
        }

        let unpacked = folder.appendingPathComponent("unpacked", isDirectory: true)
        try await UpdateInstaller.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        try? manager.removeItem(at: zip)
        let contents = (try? manager.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)) ?? []
        guard let found = contents.first(where: { $0.pathExtension == "app" }) else { throw .unpack("压缩包里没有 App") }
        guard UpdateInstaller.bundleIdentifier(of: found) == bundleIdentifier,
              UpdateInstaller.version(of: found) == update.version
        else { throw .wrongBundle }
        try CodeSignature.verify(bundle: found, signedLike: signer)

        let app = folder.appendingPathComponent(found.lastPathComponent, isDirectory: true)
        do {
            try manager.moveItem(at: found, to: app)
            try? manager.removeItem(at: unpacked)
        } catch {
            throw .install(error.localizedDescription)
        }
        return app
    }

    private func checksum(named name: String, at url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: request) else { return nil }
        return ReleaseFeed.checksum(for: name, in: String(decoding: data, as: UTF8.self))
    }
}

/// Puts a staged app in place of the running one, and starts it again.
enum UpdateInstaller {
    static let manifestName = "update.json"

    /// Why the app at `url` cannot be replaced, if it cannot.
    static func problem(replacing url: URL) -> UpdateError.Location? {
        guard url.pathExtension == "app" else { return .notAnApp }
        if url.path.contains("/AppTranslocation/") { return .translocated }
        let manager = FileManager.default
        guard manager.isWritableFile(atPath: url.deletingLastPathComponent().path), manager.isWritableFile(atPath: url.path) else {
            return .notWritable
        }
        return nil
    }

    /// Replaces `app` with `staged` in one step, so a failure leaves the old app as it was.
    /// Checks the staged copy's signature once more first: it has been sitting in Caches.
    static func install(_ staged: URL, over app: URL, signer: CodeSignature.Signer) throws(UpdateError) {
        if let problem = problem(replacing: app) { throw .location(problem) }
        try CodeSignature.verify(bundle: staged, signedLike: signer)
        let manager = FileManager.default
        do {
            // A copy next to the app, on the same volume, so the swap is a rename.
            let scratch = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
            defer { try? manager.removeItem(at: scratch) }
            let incoming = scratch.appendingPathComponent(app.lastPathComponent, isDirectory: true)
            try manager.copyItem(at: staged, to: incoming)
            _ = try manager.replaceItemAt(app, withItemAt: incoming)
        } catch {
            throw .install(error.localizedDescription)
        }
        LSRegisterURL(app as CFURL, true)
    }

    /// Opens the app again once this process has gone.
    static func relaunch(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            #"while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open "$2""#,
            "notchfax-relaunch",
            String(ProcessInfo.processInfo.processIdentifier),
            app.path,
        ]
        try? process.run()
    }

    static func bundleIdentifier(of app: URL) -> String? {
        Bundle(url: app)?.bundleIdentifier ?? infoValue("CFBundleIdentifier", of: app)
    }

    static func version(of app: URL) -> AppVersion? {
        infoValue("CFBundleShortVersionString", of: app).flatMap(AppVersion.init)
    }

    /// Read from the file, not through `Bundle`, which caches what it read first.
    private static func infoValue(_ key: String, of app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info[key] as? String
    }

    static func run(_ tool: String, _ arguments: [String]) async throws(UpdateError) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        let status: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: -1)
            }
        }
        guard status == 0 else {
            let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw .unpack(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(tool) 退出码 \(status)" : output)
        }
    }
}
