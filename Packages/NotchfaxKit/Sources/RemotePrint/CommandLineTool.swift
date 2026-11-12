import AppKit
import Foundation
import ImageIO

/// The `notchfax` command. It is the app's own executable: run as `notchfax` (a link to
/// `Notchfax.app/Contents/MacOS/Notchfax`) or with a command as its first argument, it
/// talks to the running app and exits without ever starting the app itself.
public enum CommandLineTool {
    public static let commandName = "notchfax"
    static let bundleIdentifier = "com.kadaliao.notchfax"
    private static let commands: Set<String> = ["print", "help", "-h", "--help", "version", "--version"]

    /// Whether this process should act as the command line rather than the app.
    public static func handles(_ arguments: [String]) -> Bool {
        if let invokedAs = arguments.first, URL(fileURLWithPath: invokedAs).lastPathComponent == commandName {
            return true
        }
        return arguments.count > 1 && commands.contains(arguments[1])
    }

    public enum ExitCode {
        public static let success: Int32 = 0
        /// The app received the request and turned it down.
        public static let rejected: Int32 = 1
        /// Bad arguments or unreadable input.
        public static let usage: Int32 = 2
        /// The app could not be reached.
        public static let unavailable: Int32 = 3
    }

    public static func run(_ arguments: [String]) -> Int32 {
        let rest = Array(arguments.dropFirst())
        switch rest.first {
        case nil, "help", "-h", "--help":
            print(usage)
            return ExitCode.success
        case "version", "--version":
            print(version ?? "未知版本")
            return ExitCode.success
        case "print":
            return printCommand(Array(rest.dropFirst()))
        case let other?:
            fail("不认识的命令：\(other)\n\n\(usage)")
            return ExitCode.usage
        }
    }

    // MARK: print

    struct PrintOptions: Equatable {
        var words: [String] = []
        var imagePath: String?
        var photo = false
        var plain = false
        var keep = false
        var launch = true
        var quiet = false
        var name: String?
        var help = false
    }

    struct UsageError: Error, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
    }

    static func parsePrintOptions(_ arguments: [String]) throws(UsageError) -> PrintOptions {
        var options = PrintOptions()
        var iterator = arguments.makeIterator()
        var onlyWords = false
        func value(for flag: String) throws(UsageError) -> String {
            guard let value = iterator.next() else { throw UsageError("\(flag) 后面要跟一个值。") }
            return value
        }
        while let argument = iterator.next() {
            if onlyWords || argument == "-" || !argument.hasPrefix("-") {
                options.words.append(argument)
                continue
            }
            switch argument {
            case "--": onlyWords = true
            case "-i", "--image": options.imagePath = try value(for: argument)
            case "--photo": options.photo = true
            case "--plain": options.plain = true
            case "--keep": options.keep = true
            case "--no-launch": options.launch = false
            case "-q", "--quiet": options.quiet = true
            case "--name": options.name = try value(for: argument)
            case "-h", "--help": options.help = true
            default: throw UsageError("不认识的选项：\(argument)")
            }
        }
        if options.photo {
            guard options.imagePath != nil else { throw UsageError("--photo 要配一张图片（-i <文件>）。") }
            guard options.words.isEmpty else { throw UsageError("相纸上只能印图片，不能印文字。") }
        }
        if options.imagePath == "-", options.words == ["-"] {
            throw UsageError("图片和文字不能都从标准输入读。")
        }
        return options
    }

    private static func printCommand(_ arguments: [String]) -> Int32 {
        let options: PrintOptions
        do {
            options = try parsePrintOptions(arguments)
        } catch {
            fail("\(error.message)\n用 notchfax help 查看用法。")
            return ExitCode.usage
        }
        if options.help {
            print(usage)
            return ExitCode.success
        }

        let request: PrintRequest
        do {
            request = try makeRequest(options)
        } catch {
            fail(error.message)
            return ExitCode.usage
        }
        return deliver(request, launch: options.launch, quiet: options.quiet)
    }

    private static func makeRequest(_ options: PrintOptions) throws(UsageError) -> PrintRequest {
        var image: Data?
        if let path = options.imagePath {
            image = try readImage(path)
        }

        var text: String?
        if options.words.isEmpty || options.words == ["-"] {
            // Read the text from a pipe, unless the pipe carries the picture or nothing was piped.
            if options.imagePath != "-", options.words == ["-"] || (image == nil && isatty(STDIN_FILENO) == 0) {
                text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            }
        } else {
            text = options.words.joined(separator: " ")
        }
        if let current = text, current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = nil }
        guard text != nil || image != nil else {
            throw UsageError("没有要打印的内容。把文字写在后面，或者从管道传进来：echo 你好 | notchfax print")
        }
        if let text, text.count > Wire.maxTextCharacters {
            throw UsageError("文字太长了（\(text.count) 个字），一次最多 \(Wire.maxTextCharacters) 个。")
        }
        return PrintRequest(
            stock: options.photo ? .photo : .receipt,
            text: text,
            image: image,
            markup: !options.plain,
            keep: options.keep,
            name: options.name
        )
    }

    private static func readImage(_ path: String) throws(UsageError) -> Data {
        let data: Data
        if path == "-" {
            data = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard let contents = try? Data(contentsOf: url) else { throw UsageError("打不开图片：\(path)") }
            data = contents
        }
        guard !data.isEmpty else { throw UsageError("图片是空的：\(path)") }
        guard data.count <= Wire.maxImageBytes else {
            throw UsageError("图片太大了（\(data.count / 1_048_576) MB），最多 \(Wire.maxImageBytes / 1_048_576) MB。")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw UsageError("读不出这张图片：\(path)")
        }
        return data
    }

    // MARK: Talking to the app

    private static func deliver(_ request: PrintRequest, launch: Bool, quiet: Bool) -> Int32 {
        guard let payload = try? Wire.encode(request) else {
            fail("打包打印请求失败。")
            return ExitCode.usage
        }
        if !PrintPortClient.isListening() {
            if let problem = reachApp(launch: launch) {
                fail(problem)
                return ExitCode.unavailable
            }
        }

        let replyData: Data
        do {
            replyData = try PrintPortClient.send(payload)
        } catch {
            switch error {
            case .notListening: fail("Notchfax 没在运行。")
            case .timedOut: fail("Notchfax 没有回应（等了 15 秒）。")
            case .transport(let status): fail("和 Notchfax 通信失败（\(status)）。")
            }
            return ExitCode.unavailable
        }
        guard let reply = try? Wire.decode(PrintReply.self, from: replyData) else {
            fail("看不懂 Notchfax 的回复，命令行和 App 的版本可能对不上。")
            return ExitCode.unavailable
        }
        guard reply.accepted else {
            fail("Notchfax：\(reply.message)")
            return ExitCode.rejected
        }
        if !quiet { print(reply.message) }
        return ExitCode.success
    }

    /// Opens the app in the background and waits until it listens. Returns what went wrong, if anything.
    private static func reachApp(launch: Bool) -> String? {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != getpid() }
        if !others.isEmpty {
            return "Notchfax 正在运行，但它的版本还不支持命令行打印。退出它，再打开新版本。"
        }
        guard launch else { return "Notchfax 没在运行。" }
        guard let app = appURL else { return "Notchfax 没在运行，也找不到 Notchfax.app。" }

        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", app.path]
        do {
            try open.run()
            open.waitUntilExit()
        } catch {
            return "打不开 Notchfax：\(error.localizedDescription)"
        }
        guard open.terminationStatus == 0 else { return "打不开 Notchfax（\(app.path)）。" }

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if PrintPortClient.isListening() { return nil }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return "Notchfax 打开了，但 20 秒内没有准备好。"
    }

    /// The app this executable belongs to, following the `notchfax` link; otherwise wherever
    /// Launch Services knows it to be.
    static var appURL: URL? {
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            if bundle.pathExtension == "app" { return bundle }
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    static var version: String? {
        guard let app = appURL, let info = Bundle(url: app)?.infoDictionary else { return nil }
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Notchfax \(short) (\(build))"
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static let usage = """
    用法：
      notchfax print [文字…] [选项]    从刘海里打印一张纸

    文字写在后面，或者从管道传进来：echo 你好 | notchfax print

    选项：
      -i, --image <文件>   印一张图片（- 表示从标准输入读）。可以和文字一起印，图在上、字在下
          --photo          印在光面相纸上（只能印图片）
          --plain          原样打印，不解析排版标记
          --keep           不自动收回，一直挂着等人来取
          --name <名字>    拖出去存成图片时用的文件名
          --no-launch      Notchfax 没在运行时直接失败，不去打开它
      -q, --quiet          成功时不输出

    排版标记（写在行首）：
      # 标题        大号粗体，居中
      ## 文字       粗体
      > 文字        小字
      ^ 文字        居中，可以叠在别的标记前面：^ > 谢谢惠顾
      ---  ===      虚线 / 实线
      左<Tab>右     两栏，右栏靠右，适合写价格

    退出码：0 成功；1 Notchfax 拒绝打印；2 用法或输入有误；3 连不上 Notchfax

    其他：
      notchfax help       显示这段说明
      notchfax version    显示版本
    """
}
