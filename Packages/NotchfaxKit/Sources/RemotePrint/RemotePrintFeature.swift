import AppKit
import FaxKit
import PrintKit
import SwiftUI

/// Prints what the `notchfax` command sends: receipts (text, a picture, or both) on
/// thermal paper, or a picture on photo paper. Requests arrive over a local message port
/// (`Wire.portName`) and are answered as soon as the job is queued.
@MainActor
public final class RemotePrintFeature: FeatureModule {
    private let printer: Printer
    private var server: PrintPortServer?

    public init(printer: Printer) {
        self.printer = printer
    }

    public func start() {
        let server = PrintPortServer { [weak self] data in
            let reply = self?.handle(data) ?? .rejected("Notchfax 正在退出。")
            return (try? Wire.encode(reply)) ?? Data()
        }
        if server.start() {
            self.server = server
        } else {
            NSLog("Notchfax: command-line printing is unavailable, port %@ is taken (another copy running?)", Wire.portName)
        }
    }

    func handle(_ data: Data) -> PrintReply {
        guard let request = try? Wire.decode(PrintRequest.self, from: data) else {
            return .rejected("看不懂这份打印请求，命令行和 Notchfax 的版本可能对不上。")
        }
        guard request.version <= PrintRequest.currentVersion else {
            return .rejected("这份打印请求来自更新的版本，请先更新 Notchfax。")
        }
        let job: PrintJob
        do {
            job = try RemoteJobs.job(for: request)
        } catch {
            return .rejected(error.message)
        }
        let ahead = printer.pendingCount + (printer.activity.sheet == .none ? 0 : 1)
        printer.enqueue(job)
        return PrintReply(accepted: true, message: ahead == 0 ? "开始打印。" : "已排队，前面还有 \(ahead) 张。", ahead: ahead)
    }
}

/// Turns requests into print jobs.
@MainActor
enum RemoteJobs {
    struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// `PaperSheet.resolvedSize()` stops thermal paper at this height; anything taller would be cut off.
    static let maxSheetHeight: CGFloat = 1400

    static func job(for request: PrintRequest) throws(Failure) -> PrintJob {
        switch request.stock {
        case .photo: try photoJob(request)
        case .receipt: try receiptJob(request)
        }
    }

    private static func photoJob(_ request: PrintRequest) throws(Failure) -> PrintJob {
        guard request.text?.isEmpty ?? true else { throw Failure("相纸上只能印图片，不能印文字。") }
        guard let data = request.image else { throw Failure("相纸要配一张图片。") }
        guard let image = ThermalPicture.image(from: data) else { throw Failure("读不出这张图片。") }
        return PrintJob(
            PaperSheet(.glossyPhoto, image: image),
            autoRetract: request.keep ? .never : .after(16),
            export: PNGExport(filename: request.name ?? defaultName("照片")),
            readingTime: 6
        )
    }

    private static func receiptJob(_ request: PrintRequest) throws(Failure) -> PrintJob {
        let text = request.text.map(trimmed).flatMap { $0.isEmpty ? nil : $0 }
        guard text != nil || request.image != nil else { throw Failure("没有要打印的内容。") }
        if let text, text.count > Wire.maxTextCharacters {
            throw Failure("文字太长了（\(text.count) 个字），一次最多 \(Wire.maxTextCharacters) 个。")
        }

        let width = Paper.thermal.contentRect(in: Paper.thermal.defaultSize).width
        let insets = Paper.thermal.contentInsets
        let available = maxSheetHeight - insets.top - insets.bottom
        let body: ReceiptContent.Body? = text.map { request.markup ? .lines(ReceiptMarkup.parse($0)) : .plain($0) }
        var content = ReceiptContent(picture: nil, body: body)
        let textHeight = body == nil ? 0 : fittedHeight(content, width: width)

        if let data = request.image {
            guard let image = ThermalPicture.image(from: data) else { throw Failure("读不出这张图片。") }
            // The picture takes whatever room the text leaves.
            let room = available - (body == nil ? 0 : textHeight + 6)
            guard room >= 40, let dots = ThermalPicture.dithered(image, maxHeight: Int(room * Paper.thermalDotsPerPoint)) else {
                throw Failure("文字太长，放不下图片了。")
            }
            content.picture = dots
        }

        let height = fittedHeight(content, width: width)
        if height > available {
            throw Failure("太长了，一张纸印不下（大约需要 \(Int(height)) 点高，最多 \(Int(available)) 点）。")
        }

        let readingTime = readingTime(for: text, hasPicture: content.picture != nil)
        return PrintJob(
            PaperSheet(.thermal) { ReceiptView(content: content) },
            reveal: .progressive(lineHeight: ReceiptType.feedLine),
            autoRetract: request.keep ? .never : .after(max(20, readingTime + 10)),
            export: PNGExport(filename: request.name ?? defaultName("小票")),
            readingTime: readingTime
        )
    }

    /// Roughly how long a person needs to read it, give or take.
    static func readingTime(for text: String?, hasPicture: Bool) -> TimeInterval {
        let reading = Double(text?.count ?? 0) / 15
        return min(40, max(6, reading + (hasPicture ? 3 : 0)))
    }

    static func fittedHeight(_ content: ReceiptContent, width: CGFloat) -> CGFloat {
        let host = NSHostingController(rootView: ReceiptView(content: content).frame(width: width))
        return host.sizeThatFits(in: CGSize(width: width, height: 100_000)).height.rounded(.up)
    }

    /// Drops the trailing newline a shell `echo` adds, and any blank lines around the text.
    static func trimmed(_ text: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }

    private static func defaultName(_ kind: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Notchfax \(kind) \(formatter.string(from: Date()))"
    }
}
