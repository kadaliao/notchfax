import AppKit
import PrintKit
import SwiftUI

/// Offscreen renders of fax pages and dithered pictures, for checking the look without a
/// server (`--fax-render-samples <dir>`).
@MainActor
enum FaxSamples {
    static func render(to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        func save(_ data: Data?, _ name: String) throws {
            guard let data else { return }
            let url = directory.appendingPathComponent(name).appendingPathExtension("png")
            try data.write(to: url)
            written.append(url)
        }

        let now = Date()
        let first = FaxPageModel(
            time: now, alias: "A3F2", page: 1,
            body: .text("你好，陌生人。\n今晚的月亮很圆，我这边刚下过雨，路面像一张刚洗出来的照片。\n\n如果你也还没睡，回我一句吧。"),
            footer: "一位陌生人发来的 · 回复后线路接通，就能互发图片"
        )
        try save(first.sheet().pngData(scale: 2), "fax-first")

        let reply = FaxPageModel(
            time: now, alias: "9C01", page: 2,
            body: .text("收到啦！这边是凌晨两点，窗外在下雪。Hello from the other side :)"),
            footer: "对方回复了，线路已接通 · 现在可以互发图片"
        )
        try save(reply.sheet().pngData(scale: 2), "fax-reply")

        let picture = try FaxDither.make(from: PrintSamples.landscape(width: 960, height: 720, variant: 2))
        try save(picture.png, "dither-landscape")
        let portrait = try FaxDither.make(from: PrintSamples.portrait(width: 600, height: 800, variant: 1))
        try save(portrait.png, "dither-portrait")
        if let image = picture.bits.cgImage() {
            let page = FaxPageModel(time: now, alias: "A3F2", page: 3, body: .image(image), footer: "线路已接通")
            try save(page.sheet().pngData(scale: 2), "fax-image")
        }
        if let image = portrait.bits.cgImage() {
            let page = FaxPageModel(time: now, alias: "A3F2", page: 4, body: .image(image), footer: nil)
            try save(page.sheet().pngData(scale: 2), "fax-image-portrait")
        }
        // The compose sheet as it is fed into the slot: the picture must stay crisp dots.
        let header = ComposeHeader(left: "回复 线路 #9C01", right: FaxFormat.headerTime(now))
        let size = CGSize(width: FaxType.paperWidth, height: 300)
        let sent = PaperSheet(.thermal, size: size) {
            ComposeSheetLayout(header: header, excerpt: "对方：收到啦！这边是凌晨，窗外在下雪。", textHeight: FaxType.lineHeight * 2, image: picture, footer: Text(" ").font(FaxType.footer())) {
                Text("给你看看我这边的晚霞。").font(FaxType.body()).lineSpacing(FaxType.bodySpacing).foregroundStyle(.black)
            }
        }
        try save(sent.pngData(scale: 2), "compose-sent-image")
        return written
    }
}
