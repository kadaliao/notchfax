import Foundation
import Testing

@testable import Updater

private func version(_ string: String) -> AppVersion {
    guard let version = AppVersion(string) else { fatalError("not a version: \(string)") }
    return version
}

@Suite struct VersionTests {
    @Test func `numbers compare as numbers, not text`() {
        #expect(version("0.2.10") > version("0.2.9"))
        #expect(version("1.0") > version("0.99.99"))
        #expect(version("v0.3.0") == version("0.3"))
        #expect(version("0.3.0").hashValue == version("0.3").hashValue)
        #expect(!(version("0.2.2") < version("0.2.2")))
    }

    @Test func `a pre-release comes before its release`() {
        #expect(version("1.0.0-beta.2") < version("1.0.0"))
        #expect(version("1.0.0-beta.2") < version("1.0.0-beta.10"))
        #expect(version("1.0.0-beta.2") > version("0.9.9"))
        #expect(version("1.0.0+build.7") == version("1.0.0"))
    }

    @Test func `anything that is not a version is refused`() {
        for text in ["", "v", "latest", "1..2", "1.2.x", "1.2.3.4.5", "1.0-", "-1.0", "１.０"] {
            #expect(AppVersion(text) == nil, "\(text)")
        }
        #expect(version(" v0.2.2 \n").description == "0.2.2")
    }
}

/// The shape of GitHub's `releases/latest`, trimmed to what matters, as 0.2.2 shipped.
private func releaseJSON(tag: String = "v0.3.0", draft: Bool = false, prerelease: Bool = false, assets: String? = nil, body: String = "- **聊天记录**：每条线路都能翻看\\n- 自动更新") -> Data {
    let defaultAssets = """
    [
      {"name": "Notchfax-0.3.0.dmg", "size": 3240942, "digest": "sha256:\(String(repeating: "a", count: 64))",
       "browser_download_url": "https://github.com/kadaliao/notchfax/releases/download/v0.3.0/Notchfax-0.3.0.dmg"},
      {"name": "Notchfax-0.3.0.zip", "size": 3108152, "digest": "sha256:\(String(repeating: "B", count: 64))",
       "browser_download_url": "https://github.com/kadaliao/notchfax/releases/download/v0.3.0/Notchfax-0.3.0.zip"},
      {"name": "SHA256SUMS", "size": 170, "digest": null,
       "browser_download_url": "https://github.com/kadaliao/notchfax/releases/download/v0.3.0/SHA256SUMS"}
    ]
    """
    return Data("""
    {"tag_name": "\(tag)", "name": "Notchfax \(tag)", "draft": \(draft), "prerelease": \(prerelease),
     "html_url": "https://github.com/kadaliao/notchfax/releases/tag/\(tag)",
     "body": "\(body)", "assets": \(assets ?? defaultAssets)}
    """.utf8)
}

@Suite struct ReleaseFeedTests {
    @Test func `a newer release offers its zip and GitHub's digest`() throws {
        let release = try ReleaseFeed.decode(releaseJSON())
        guard case .available(let update) = ReleaseFeed.outcome(of: release, current: version("0.2.2")) else {
            Issue.record("expected an update")
            return
        }
        #expect(update.version == version("0.3.0"))
        #expect(update.archive?.name == "Notchfax-0.3.0.zip")
        #expect(update.archive?.sha256 == String(repeating: "b", count: 64), "lowercased")
        #expect(update.archive?.checksums?.lastPathComponent == "SHA256SUMS")
        #expect(update.releasePage.absoluteString.hasSuffix("/tag/v0.3.0"))
        #expect(update.notes == ["聊天记录", "自动更新"])
    }

    @Test func `the same or an older release is up to date`() throws {
        let release = try ReleaseFeed.decode(releaseJSON(tag: "v0.3.0"))
        #expect(ReleaseFeed.outcome(of: release, current: version("0.3.0")) == .upToDate(latest: version("0.3.0")))
        #expect(ReleaseFeed.outcome(of: release, current: version("0.4.0")) == .upToDate(latest: version("0.3.0")))
    }

    @Test func `drafts, pre-releases and odd tags are not offered`() throws {
        #expect(ReleaseFeed.outcome(of: try ReleaseFeed.decode(releaseJSON(draft: true)), current: version("0.1")) == nil)
        #expect(ReleaseFeed.outcome(of: try ReleaseFeed.decode(releaseJSON(prerelease: true)), current: version("0.1")) == nil)
        #expect(ReleaseFeed.outcome(of: try ReleaseFeed.decode(releaseJSON(tag: "nightly")), current: version("0.1")) == nil)
    }

    @Test func `a release without a zip can only be downloaded by hand`() throws {
        let assets = """
        [{"name": "Notchfax-0.3.0.dmg", "size": 10, "browser_download_url": "https://example.com/a.dmg"}]
        """
        guard case .available(let update) = ReleaseFeed.outcome(of: try ReleaseFeed.decode(releaseJSON(assets: assets)), current: version("0.2.2")) else {
            Issue.record("expected an update")
            return
        }
        #expect(update.archive == nil)
    }

    @Test func `an unreasonably large archive is not offered`() throws {
        let assets = """
        [{"name": "Notchfax-0.3.0.zip", "size": \(ReleaseFeed.largestArchive + 1), "browser_download_url": "https://example.com/a.zip"}]
        """
        guard case .available(let update) = ReleaseFeed.outcome(of: try ReleaseFeed.decode(releaseJSON(assets: assets)), current: version("0.2.2")) else {
            Issue.record("expected an update")
            return
        }
        #expect(update.archive == nil)
    }

    @Test func `checksums are read from a shasum listing`() {
        let a = String(repeating: "0f", count: 32)
        let b = String(repeating: "AC", count: 32)
        let listing = "\(a)  Notchfax-0.2.2.dmg\n\(b) *Notchfax-0.2.2.zip\nnot a line\n"
        #expect(ReleaseFeed.checksum(for: "Notchfax-0.2.2.dmg", in: listing) == a)
        #expect(ReleaseFeed.checksum(for: "Notchfax-0.2.2.zip", in: listing) == b.lowercased())
        #expect(ReleaseFeed.checksum(for: "Notchfax-0.2.1.zip", in: listing) == nil)
        #expect(ReleaseFeed.checksum(for: "x", in: "1234  x") == nil, "too short to be SHA-256")
        #expect(ReleaseFeed.sha256(fromDigest: "md5:abc") == nil)
    }

    @Test func `release notes become a few plain lines`() {
        let body = """
        ## 新功能

        - **更多编程助手的会话小票**：除了 Claude Code，仓库的 [`integrations/`](https://github.com/x) 里新增了 Pi。
          - 一条缩进的细节
        - 菜单「AI 会话小票…」里的提示词会先让你的 AI 参考这些现成实现：是这几家就直接装，别家照着最像的那个改。

        ```sh
        - not a bullet
        ```

        ## 其他

        - README 重写，加了演示动画和[英文版](https://github.com/x)

        ## 安装与升级

        - brew upgrade --cask notchfax
        """
        let notes = ReleaseFeed.notes(fromMarkdown: body, limit: 4)
        #expect(notes == [
            "更多编程助手的会话小票",
            "菜单「AI 会话小票…」里的提示词会先让你的 AI 参考这些现成实现",
            "README 重写，加了演示动画和英文版",
        ])
        #expect(ReleaseFeed.notes(fromMarkdown: body, width: 20)[1] == "菜单「AI 会话小票…」里的提示词会先…", "long lines are cut")
        #expect(ReleaseFeed.notes(fromMarkdown: body, limit: 1).count == 1)
        #expect(ReleaseFeed.plain("[`a`](b) **c** `d`") == "a c d")
    }
}

@Suite struct SignatureTests {
    @Test func `the requirement pins the team, the identifier and Developer ID`() {
        let requirement = CodeSignature.requirement(for: .init(identifier: "com.kadaliao.notchfax", team: "HMDAVG9B8J"))
        #expect(requirement.contains(#"identifier "com.kadaliao.notchfax""#))
        #expect(requirement.contains(#"certificate leaf[subject.OU] = "HMDAVG9B8J""#))
        #expect(requirement.contains("1.2.840.113635.100.6.1.13"), "Developer ID Application")
        #expect(requirement.contains("anchor apple generic"))
    }

    @Test func `a bundle that is not signed by the team is refused`() throws {
        // Finder is signed by Apple itself, not by a Developer ID team.
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        #expect(throws: UpdateError.self) {
            try CodeSignature.verify(bundle: finder, signedLike: .init(identifier: "com.apple.finder", team: "HMDAVG9B8J"))
        }
        #expect(throws: UpdateError.self) {
            try CodeSignature.verify(bundle: finder, signedLike: .init(identifier: "x\" or anchor apple", team: "T"))
        }
    }
}

@Suite struct InstallerTests {
    @Test func `only an app in a folder it can write to can be replaced`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("updater-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent("Notchfax.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        #expect(UpdateInstaller.problem(replacing: app) == nil)
        #expect(UpdateInstaller.problem(replacing: folder) == .notAnApp)
        #expect(UpdateInstaller.problem(replacing: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Notchfax.app")) == .translocated)
        #expect(UpdateInstaller.problem(replacing: URL(fileURLWithPath: "/System/Applications/Notchfax.app")) == .notWritable)
    }

    @Test func `the version is read from the bundle's own Info.plist`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("updater-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent("Notchfax.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.kadaliao.notchfax", "CFBundleShortVersionString": "0.3.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        #expect(UpdateInstaller.version(of: app) == version("0.3.0"))
        #expect(UpdateInstaller.bundleIdentifier(of: app) == "com.kadaliao.notchfax")
    }

    @Test func `launch switches point at a test feed`() {
        let options = UpdateLaunchOptions(arguments: ["Notchfax", "--update-feed", "file:///tmp/latest.json", "--update-check", "--update-current", "0.2.1"])
        #expect(options.feed?.isFileURL == true)
        #expect(options.checksAtLaunch)
        #expect(options.current == version("0.2.1"))
        #expect(UpdateLaunchOptions(arguments: ["Notchfax"]) == UpdateLaunchOptions(arguments: []))
    }

    @Test func `slips read in a few seconds and say which version`() {
        let ready = UpdateSlip.ready(version("0.3.0"), current: version("0.2.2"), notes: ["聊天记录"])
        #expect(ready.title == "0.3.0 已经下好了")
        #expect(ready.readingTime >= 5 && ready.readingTime <= 24)
        #expect(UpdateSlip.installed(version("0.3.0"), from: version("0.2.2")).lines == ["从 0.2.2 换过来了。"])
        #expect(UpdateSlip.failed(.offline).title == "没能检查更新")
        #expect(UpdateSlip.failed(.checksumMismatch, version: version("0.3.0")).title == "没能更新到 0.3.0")
    }
}
