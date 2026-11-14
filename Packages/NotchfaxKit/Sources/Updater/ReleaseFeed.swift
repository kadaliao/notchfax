import Foundation

/// GitHub's description of a release (`GET /repos/{owner}/{repo}/releases/latest`), the
/// few fields an update needs.
struct GitHubRelease: Decodable, Sendable, Equatable {
    struct Asset: Decodable, Sendable, Equatable {
        var name: String
        var browserDownloadURL: URL
        var size: Int
        /// `sha256:<hex>`, computed by GitHub when the file was uploaded.
        var digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }
    }

    var tagName: String
    var name: String?
    var body: String?
    var draft: Bool
    var prerelease: Bool
    var htmlURL: URL
    var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case name, body, draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

/// A newer release than the one running.
public struct AvailableUpdate: Codable, Sendable, Equatable {
    /// The zip of the app that `scripts/release.sh` uploads with every release.
    public struct Archive: Codable, Sendable, Equatable {
        public var url: URL
        public var name: String
        public var size: Int
        /// Lowercase hex, from GitHub's own digest of the upload.
        public var sha256: String?
        /// The release's `SHA256SUMS`, used when GitHub gives no digest.
        public var checksums: URL?
    }

    public var version: AppVersion
    /// `nil` when the release has no zip to install from; it can only be downloaded by hand.
    public var archive: Archive?
    public var releasePage: URL
    /// A few short lines from the release notes, for the slip.
    public var notes: [String]
}

enum ReleaseFeed {
    enum Outcome: Equatable {
        case upToDate(latest: AppVersion)
        case available(AvailableUpdate)
    }

    /// Releases are uploaded as `Notchfax-<version>.zip`, next to the dmg and `SHA256SUMS`.
    static func archiveName(for version: AppVersion) -> String { "Notchfax-\(version).zip" }

    static let largestArchive = 200 * 1024 * 1024

    static func decode(_ data: Data) throws -> GitHubRelease {
        try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    /// What the latest release means for the version that is running. `nil` when the
    /// release cannot be read as one (a draft, a pre-release, or a tag that is not a version).
    static func outcome(of release: GitHubRelease, current: AppVersion) -> Outcome? {
        guard !release.draft, !release.prerelease, let version = AppVersion(release.tagName) else { return nil }
        guard version > current else { return .upToDate(latest: version) }
        let expected = archiveName(for: version)
        let zip = release.assets.first { $0.name == expected }
            ?? release.assets.first { $0.name.hasPrefix("Notchfax") && $0.name.hasSuffix(".zip") }
        let sums = release.assets.first { $0.name == "SHA256SUMS" }
        let archive = zip.flatMap { asset -> AvailableUpdate.Archive? in
            guard asset.size > 0, asset.size <= largestArchive else { return nil }
            return AvailableUpdate.Archive(
                url: asset.browserDownloadURL,
                name: asset.name,
                size: asset.size,
                sha256: asset.digest.flatMap(sha256(fromDigest:)),
                checksums: sums?.browserDownloadURL
            )
        }
        return .available(AvailableUpdate(
            version: version,
            archive: archive,
            releasePage: release.htmlURL,
            notes: notes(fromMarkdown: release.body ?? "")
        ))
    }

    static func sha256(fromDigest digest: String) -> String? {
        let parts = digest.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "sha256" else { return nil }
        return validHex(String(parts[1]))
    }

    /// The hash of `name` in a `shasum -a 256` listing.
    static func checksum(for name: String, in listing: String) -> String? {
        for line in listing.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 2 else { continue }
            var file = fields[1].trimmingCharacters(in: .whitespaces)
            // `shasum -b` marks binary mode with a star; `./` comes from a glob.
            if file.hasPrefix("*") { file.removeFirst() }
            if file.hasPrefix("./") { file.removeFirst(2) }
            if file == name, let hex = validHex(String(fields[0])) { return hex }
        }
        return nil
    }

    private static func validHex(_ string: String) -> String? {
        let hex = string.lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }

    // MARK: Release notes

    /// The first few bullet points of the release notes, flattened to plain text and kept to
    /// a line or two of the slip. A bullet that opens with a bold phrase (`**传真记录**：……`)
    /// is shortened to that phrase, any other to its first clause. The install instructions
    /// are skipped: updating is what is happening.
    static func notes(fromMarkdown markdown: String, limit: Int = 3, width: Int = 34) -> [String] {
        var notes: [String] = []
        var inCode = false
        var skipping = false
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inCode.toggle()
                continue
            }
            if inCode { continue }
            if line.hasPrefix("#") {
                skipping = line.contains("安装") || line.lowercased().contains("install")
                continue
            }
            // Top-level bullets only: nested ones are detail.
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
            guard !skipping, indent < 2, line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
            var item = String(line.dropFirst(2))
            if item.hasPrefix("**"), let close = item.range(of: "**", range: item.index(item.startIndex, offsetBy: 2)..<item.endIndex) {
                let rest = item[close.upperBound...].trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("：") || rest.hasPrefix(":") {
                    item = String(item[item.index(item.startIndex, offsetBy: 2)..<close.lowerBound])
                }
            }
            var text = plain(item)
            if let stop = text.firstIndex(where: { "：；。:;".contains($0) }), text.distance(from: text.startIndex, to: stop) >= 6 {
                text = String(text[..<stop])
            }
            guard !text.isEmpty else { continue }
            notes.append(text.count > width ? String(text.prefix(width - 1)) + "…" : text)
            if notes.count == limit { break }
        }
        return notes
    }

    /// Markdown inline syntax removed: links keep their text, emphasis and code marks go.
    static func plain(_ markdown: String) -> String {
        var text = markdown
        // [text](url) → text
        while let open = text.range(of: "["),
              let middle = text.range(of: "](", range: open.upperBound..<text.endIndex),
              let close = text.range(of: ")", range: middle.upperBound..<text.endIndex) {
            let label = text[open.upperBound..<middle.lowerBound]
            text.replaceSubrange(open.lowerBound..<close.upperBound, with: label)
        }
        for mark in ["**", "__", "`"] {
            text = text.replacingOccurrences(of: mark, with: "")
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
