import Foundation
import Testing

@testable import RemotePrint

@Suite struct ReceiptMarkupTests {
    @Test func stylesAndColumns() {
        let lines = ReceiptMarkup.parse("""
        # CLAUDE CODE
        ## Opus 5.5\t$3.21
        > 输入 1.2万\t$0.05
        ^ > 谢谢惠顾
        普通一行
        """)
        #expect(lines == [
            ReceiptLine(.text(left: "CLAUDE CODE", right: nil), style: .title, centered: true),
            ReceiptLine(.text(left: "Opus 5.5", right: "$3.21"), style: .bold),
            ReceiptLine(.text(left: "输入 1.2万", right: "$0.05"), style: .small),
            ReceiptLine(.text(left: "谢谢惠顾", right: nil), style: .small, centered: true),
            ReceiptLine(.text(left: "普通一行", right: nil)),
        ])
    }

    @Test func titleWithColumnIsNotCentred() {
        #expect(ReceiptMarkup.parseLine("# 合计\t$3.23") == ReceiptLine(.text(left: "合计", right: "$3.23"), style: .title))
    }

    @Test func rulesAndGaps() {
        let lines = ReceiptMarkup.parse("\n\na\n---\n\n\n\n===\n----------\nb\n\n")
        #expect(lines.map(\.kind) == [
            .text(left: "a", right: nil),
            .rule(dashed: true),
            .gap,
            .rule(dashed: false),
            .rule(dashed: true),
            .text(left: "b", right: nil),
        ])
    }

    @Test func thingsThatAreNotMarkup() {
        #expect(ReceiptMarkup.parseLine("#hashtag").style == .body)
        #expect(ReceiptMarkup.parseLine("-- 署名").kind == .text(left: "-- 署名", right: nil))
        #expect(ReceiptMarkup.parseLine("a\t").kind == .text(left: "a", right: nil))
        #expect(ReceiptMarkup.parseLine("a\tb\tc").kind == .text(left: "a", right: "b c"))
        #expect(ReceiptMarkup.parseLine("  缩进\t1").kind == .text(left: "  缩进", right: "1"))
    }
}

@Suite struct CommandLineTests {
    @Test func invocation() {
        #expect(CommandLineTool.handles(["/usr/local/bin/notchfax"]))
        #expect(CommandLineTool.handles(["notchfax", "print", "hi"]))
        #expect(CommandLineTool.handles(["/Applications/Notchfax.app/Contents/MacOS/Notchfax", "print"]))
        #expect(!CommandLineTool.handles(["/Applications/Notchfax.app/Contents/MacOS/Notchfax"]))
        #expect(!CommandLineTool.handles(["/Applications/Notchfax.app/Contents/MacOS/Notchfax", "--demo", "fax"]))
    }

    @Test func printOptions() throws {
        let options = try CommandLineTool.parsePrintOptions(["你好", "-i", "a.png", "--keep", "--no-launch", "世界", "--", "--plain"])
        #expect(options.words == ["你好", "世界", "--plain"])
        #expect(options.imagePath == "a.png")
        #expect(options.keep && !options.launch && !options.plain)
    }

    @Test func printOptionErrors() {
        #expect(throws: CommandLineTool.UsageError.self) { try CommandLineTool.parsePrintOptions(["--bogus"]) }
        #expect(throws: CommandLineTool.UsageError.self) { try CommandLineTool.parsePrintOptions(["-i"]) }
        #expect(throws: CommandLineTool.UsageError.self) { try CommandLineTool.parsePrintOptions(["--photo"]) }
        #expect(throws: CommandLineTool.UsageError.self) { try CommandLineTool.parsePrintOptions(["--photo", "-i", "a.png", "字"]) }
        #expect(throws: CommandLineTool.UsageError.self) { try CommandLineTool.parsePrintOptions(["-i", "-", "-"]) }
    }

    @Test func requestRoundTrip() throws {
        let request = PrintRequest(text: "# 你好", image: Data([1, 2, 3]), keep: true, name: "x")
        #expect(try Wire.decode(PrintRequest.self, from: Wire.encode(request)) == request)
    }

    @Test func installerQuoting() {
        #expect(CommandLineInstaller.shellQuoted("/a b/it's") == "'/a b/it'\\''s'")
        #expect(CommandLineInstaller.appleScriptEscaped("say \"hi\" \\") == "say \\\"hi\\\" \\\\")
    }
}

@Suite @MainActor struct RemoteJobTests {
    @Test func trimsShellNewlines() {
        #expect(RemoteJobs.trimmed("\n\n你好\n\n世界\n\n") == "你好\n\n世界")
    }

    @Test func rejectsEmptyAndOverlong() {
        #expect(throws: RemoteJobs.Failure.self) { try RemoteJobs.job(for: PrintRequest(text: "  \n ")) }
        let long = Array(repeating: "一行", count: 400).joined(separator: "\n")
        #expect(throws: RemoteJobs.Failure.self) { try RemoteJobs.job(for: PrintRequest(text: long)) }
        #expect(throws: RemoteJobs.Failure.self) { try RemoteJobs.job(for: PrintRequest(stock: .photo, text: "字")) }
        #expect(throws: RemoteJobs.Failure.self) { try RemoteJobs.job(for: PrintRequest(image: Data([0, 1, 2]))) }
    }

    @Test func acceptsReceipt() throws {
        let job = try RemoteJobs.job(for: PrintRequest(text: "# 小票\n---\n咖啡\t$4.00"))
        #expect(job.sheet.paper == .thermal)
        #expect(job.sheet.resolvedSize().height < 200)
    }

    @Test func messagePortRoundTrip() throws {
        let name = "com.kadaliao.notchfax.print.test.\(UUID().uuidString)"
        let server = PrintPortServer(name: name) { data in Data(data.reversed()) }
        #expect(server.start())
        defer { server.stop() }
        // A second server cannot take the same name.
        #expect(!PrintPortServer(name: name) { $0 }.start())
        #expect(PrintPortClient.isListening(name: name))
        // The reply is produced on the main run loop, so send from another thread and spin this one.
        let reply = LockedBox<Data?>(nil)
        Thread.detachNewThread {
            reply.set(try? PrintPortClient.send(Data([1, 2, 3]), name: name, timeout: 5))
        }
        let deadline = Date().addingTimeInterval(5)
        while reply.get() == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        #expect(reply.get() == Data([3, 2, 1]))
    }
}

final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
}
