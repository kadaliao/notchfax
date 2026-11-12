import AppKit
import SwiftUI

@testable import FaxKit
@testable import Memories
@testable import PhotoBooth
@testable import PrintKit
@testable import RemotePrint

// Notchfax 宣传片：画面全部来自 App 自己的走纸引擎（SheetController + SheetNode），
// 离屏逐帧渲染，所以纸的物理、撕纸、光泽都是真的。声音也取自引擎的合成器。
//
//   film                      渲染整片 → out/video.mp4 + out/sfx.wav
//   film --frame 12.5         只出一帧 → out/frame-12.50.png
//   film --range 40 58        只渲染一段（调试）

let outW = 1920, outH = 1080, fps = 60
let screenSize = CGSize(width: 900, height: 560)
let promoDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let outDir = promoDir.appendingPathComponent("out")
let filmLength = 69.5

// MARK: - Small helpers

func clamp(_ x: Double, _ a: Double = 0, _ b: Double = 1) -> Double { min(b, max(a, x)) }
func smooth(_ x: Double) -> Double { let u = clamp(x); return u * u * (3 - 2 * u) }
func easeOut(_ x: Double) -> Double { let u = 1 - clamp(x); return 1 - u * u * u }
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let orange = rgb(1.0, 0.62, 0.26)

func withGraphics(_ ctx: CGContext, _ body: () -> Void) {
    let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    body()
    NSGraphicsContext.restoreGraphicsState()
}

func blob(_ ctx: CGContext, at p: CGPoint, radius: CGFloat, color: (CGFloat, CGFloat, CGFloat), alpha: CGFloat) {
    let colours = [rgb(color.0, color.1, color.2, alpha), rgb(color.0, color.1, color.2, alpha * 0.45), rgb(color.0, color.1, color.2, 0)] as CFArray
    guard let gradient = CGGradient(colorsSpace: srgb, colors: colours, locations: [0, 0.45, 1]) else { return }
    ctx.drawRadialGradient(gradient, startCenter: p, startRadius: 0, endCenter: p, endRadius: radius, options: [])
}

// MARK: - Wallpaper

struct Palette {
    var base: (CGFloat, CGFloat, CGFloat)
    var blobs: [(x: CGFloat, y: CGFloat, r: CGFloat, c: (CGFloat, CGFloat, CGFloat), a: CGFloat)]
    var glow: (CGFloat, CGFloat, CGFloat)

    static let ink = Palette(
        base: (0.07, 0.08, 0.13),
        blobs: [(0.15, 0.2, 0.7, (0.20, 0.24, 0.46), 0.9), (0.9, 0.85, 0.7, (0.34, 0.20, 0.42), 0.8), (0.6, 0.1, 0.5, (0.10, 0.28, 0.40), 0.6)],
        glow: (0.25, 0.28, 0.55)
    )
    static let dusk = Palette(
        base: (0.16, 0.10, 0.20),
        blobs: [(0.1, 0.15, 0.75, (0.78, 0.36, 0.26), 0.85), (0.85, 0.8, 0.8, (0.30, 0.22, 0.55), 0.9), (0.55, 0.05, 0.5, (0.95, 0.62, 0.30), 0.5)],
        glow: (0.75, 0.38, 0.28)
    )
    static let candy = Palette(
        base: (0.10, 0.16, 0.24),
        blobs: [(0.12, 0.8, 0.7, (0.14, 0.52, 0.60), 0.9), (0.9, 0.2, 0.75, (0.78, 0.34, 0.52), 0.8), (0.5, 0.0, 0.5, (0.90, 0.70, 0.36), 0.4)],
        glow: (0.2, 0.55, 0.62)
    )
    static let night = Palette(
        base: (0.03, 0.05, 0.11),
        blobs: [(0.2, 0.85, 0.8, (0.08, 0.20, 0.44), 0.9), (0.85, 0.15, 0.7, (0.16, 0.14, 0.40), 0.9), (0.55, 0.5, 0.4, (0.10, 0.30, 0.50), 0.35)],
        glow: (0.12, 0.24, 0.55)
    )
    static let terminal = Palette(
        base: (0.05, 0.07, 0.07),
        blobs: [(0.15, 0.2, 0.7, (0.08, 0.30, 0.26), 0.9), (0.9, 0.9, 0.7, (0.16, 0.20, 0.30), 0.9), (0.6, 0.0, 0.4, (0.30, 0.42, 0.30), 0.35)],
        glow: (0.12, 0.40, 0.32)
    )
}

@MainActor
func wallpaper(_ palette: Palette, clock: String) -> CGImage {
    let scale: CGFloat = 3
    let size = screenSize
    let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    ctx.setFillColor(rgb(palette.base.0, palette.base.1, palette.base.2))
    ctx.fill(CGRect(origin: .zero, size: size))
    for b in palette.blobs {
        blob(ctx, at: CGPoint(x: b.x * size.width, y: (1 - b.y) * size.height), radius: b.r * size.width, color: b.c, alpha: b.a)
    }
    // 菜单栏
    let bar: CGFloat = 32
    ctx.setFillColor(CGColor(gray: 0, alpha: 0.28))
    ctx.fill(CGRect(x: 0, y: size.height - bar, width: size.width, height: bar))
    withGraphics(ctx) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.92)]
        var x: CGFloat = 20
        for (index, item) in ["", "Finder", "文件", "编辑", "显示", "前往", "窗口", "帮助"].enumerated() {
            var a = attrs
            if index == 0 { continue }
            if index == 1 { a[.font] = NSFont.systemFont(ofSize: 12.5, weight: .bold) }
            let s = NSAttributedString(string: item, attributes: a)
            s.draw(at: CGPoint(x: x, y: size.height - bar + (bar - s.size().height) / 2))
            x += s.size().width + 17
        }
        let right = NSAttributedString(string: clock, attributes: attrs)
        right.draw(at: CGPoint(x: size.width - 20 - right.size().width, y: size.height - bar + (bar - right.size().height) / 2))
    }
    return ctx.makeImage()!
}

// MARK: - Sound collection

final class SFXTrack {
    var samples: [Float]
    var now = 0.0
    var gain: Float = 1
    init(seconds: Double) { samples = [Float](repeating: 0, count: Int(seconds * SoundSynth.sampleRate)) }

    func add(_ s: [Float]) {
        let start = Int(now * SoundSynth.sampleRate)
        for (i, v) in s.enumerated() where start + i < samples.count { samples[start + i] += v * gain }
    }

    func write(to url: URL) throws {
        var data = Data()
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36 + bytes)); data.append(contentsOf: Array("WAVEfmt ".utf8))
        le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(44_100)); le(UInt32(88_200)); le(UInt16(2)); le(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); le(UInt32(bytes))
        for v in samples { le(Int16(max(-1, min(1, v)) * 32_000)) }
        try data.write(to: url)
    }
}

// MARK: - Host

@MainActor
final class FilmHost: SheetHost {
    let scene: PrintKit.Scene
    let reduceMotion = false
    let sound = SoundPlayer()
    var controllers: [SheetController] = []

    init(palette: Palette, clock: String) {
        scene = PrintKit.Scene(size: screenSize, dark: true, simulateNotch: true)
        scene.root.sublayers?.first?.contents = wallpaper(palette, clock: clock)
        sound.isMuted = true
    }

    var geometry: SlotGeometry { scene.geometry }

    func place(_ layer: CALayer, clipped: Bool, atBack: Bool) {
        let target = clipped ? scene.clip : scene.free
        guard layer.superlayer !== target else { return }
        if atBack { target.insertSublayer(layer, at: 0) } else { target.addSublayer(layer) }
    }

    func slotDidFree(_ controller: SheetController) {}
    func remove(_ controller: SheetController) { controllers.removeAll { $0 === controller } }
    func sheetStateDidChange() {}
    func requestFrames() {}
    func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {}
    func beginDragSession(for controller: SheetController) -> Bool { false }
    func saveToDesktop(_ file: URL) -> URL? { file }
}

// MARK: - Shots

struct CameraKey {
    var t: Double
    var x: CGFloat
    var y: CGFloat
    var zoom: CGFloat
}

@MainActor
protocol Shot: AnyObject {
    var start: Double { get }
    var end: Double { get }
    /// Advance the simulation to local time `t`, then draw.
    func draw(in ctx: CGContext, at t: Double)
}

/// 一个镜头：一块屏幕、一台出纸口、按时间表发生的事，和一台摄影机。
@MainActor
final class ScreenShot: Shot {
    let start: Double
    let end: Double
    let host: FilmHost
    let palette: Palette
    let sfx: SFXTrack
    var camera: [CameraKey] = [CameraKey(t: 0, x: 355, y: 150, zoom: 3.2)]
    var fadeIn = 0.5, fadeOut = 0.45
    private var actions: [(t: Double, run: () -> Void)] = []
    private var flashes: [Double] = []
    /// 大头贴取景框：出现、收起的时刻，倒数的三下。照 App 里的样子重画的简化版。
    var booth: (show: Double, hide: Double, counts: [Double])?
    private lazy var poses: [CGImage] = (0..<4).map { PrintSamples.portrait(width: 864, height: 648, variant: $0) }
    private var simTime = 0.0
    private var housekeeping = 0.0
    private var sheets: [SheetController] = []

    // 光标
    private var run: PointerScript.Run?
    private weak var runTarget: SheetController?
    private var approach: (from: CGPoint, to: CGPoint, t0: Double, t1: Double)?
    private var cursor: CGPoint?
    private var cursorDown = false
    private var cursorGoneAt: Double?
    private static let arrow = cursorImage(.arrow)
    private static let hand = cursorImage(.closedHand)
    private static let open = cursorImage(.openHand)

    init(start: Double, end: Double, palette: Palette, clock: String, sfx: SFXTrack) {
        self.start = start
        self.end = end
        self.palette = palette
        self.sfx = sfx
        host = FilmHost(palette: palette, clock: clock)
        host.sound.tap = { [weak self] samples in
            guard let self else { return }
            sfx.now = self.start + self.simTime
            sfx.add(samples)
        }
    }

    static func cursorImage(_ cursor: NSCursor) -> (image: CGImage, size: CGSize, hot: CGPoint)? {
        let image = cursor.image
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform(scale: 4)]) else { return nil }
        return (cg, image.size, cursor.hotSpot)
    }

    func at(_ t: Double, _ run: @escaping () -> Void) {
        actions.append((t, run))
        actions.sort { $0.t < $1.t }
    }

    /// Sends a job through the slot at `t`. The closure receives the sheet for later gestures.
    func print(at t: Double, seed: UInt64, _ job: @escaping () -> PrintJob) {
        at(t) { [self] in
            let job = job()
            let layout = job.sheet.resolvedSize()
            let rendered = PaperRenderer.render(job.sheet, size: layout, scale: job.sheet.paper == .thermal ? 2 : 5, seed: seed)
            let fit = host.geometry.fittingScale(forPaperWidth: layout.width)
            let controller = SheetController(job: job, handle: nil, rendered: rendered, fit: fit, host: host, seed: seed)
            host.controllers.append(controller)
            host.scene.nodes.append(controller.node)
            sheets.append(controller)
            controller.beginFeed()
        }
    }

    /// Plays one of the app's recorded pointer paths on the newest sheet, the cursor gliding in first.
    func gesture(at t: Double, _ name: String, from offset: CGPoint = CGPoint(x: 150, y: 110)) {
        at(t - 0.9) { [self] in
            guard let sheet = sheets.last, let make = PointerScript.library[name] else { return }
            let script = make(sheet.node.size.height)
            let anchor = host.geometry.anchor
            let first = script.point(at: 0)
            let to = CGPoint(x: anchor.x + first.x, y: anchor.y + first.y)
            let from = cursor ?? CGPoint(x: to.x + offset.x, y: to.y + offset.y)
            approach = (from, to, simTime, simTime + 0.9)
            cursorGoneAt = nil
            runTarget = sheet
        }
        at(t) { [self] in
            guard let sheet = runTarget, let make = PointerScript.library[name] else { return }
            approach = nil
            run = PointerScript.Run(script: make(sheet.node.size.height), anchor: host.geometry.anchor)
        }
    }

    func flash(at t: Double) {
        flashes.append(t)
        at(t) { [self] in host.sound.play(.shutter) }
    }

    func sound(at t: Double, _ effect: SoundEffect) { at(t) { [self] in host.sound.play(effect) } }
    func tearOff(at t: Double) { at(t) { [self] in sheets.last?.requestTearOff() } }
    func retract(at t: Double) { at(t) { [self] in sheets.last?.requestRetract() } }

    private func step(_ dt: Double) {
        while let next = actions.first, next.t <= simTime {
            actions.removeFirst()
            next.run()
        }
        if let a = approach {
            let u = CGFloat(smooth((simTime - a.t0) / (a.t1 - a.t0)))
            cursor = CGPoint(x: a.from.x + (a.to.x - a.from.x) * u, y: a.from.y + (a.to.y - a.from.y) * u)
            cursorDown = false
            runTarget?.pointerHover(at: cursor)
        }
        if var current = run, let target = runTarget {
            let finished = current.advance(dt, on: target)
            cursor = current.pointer
            cursorDown = current.isDown
            run = finished ? nil : current
            if finished {
                cursorDown = false
                cursorGoneAt = simTime + 0.5
                target.pointerHover(at: nil)
            }
        }
        for sheet in host.controllers where sheet.needsFrames { sheet.tick(dt) }
        housekeeping += dt
        if housekeeping >= 0.25 {
            housekeeping = 0
            host.controllers.forEach { $0.housekeeping(0.25) }
        }
        simTime += dt
    }

    private func cameraAt(_ t: Double) -> CameraKey {
        guard let first = camera.first, let last = camera.last else { return CameraKey(t: 0, x: 450, y: 280, zoom: 1.5) }
        if t <= first.t { return first }
        if t >= last.t { return last }
        for (a, b) in zip(camera, camera.dropFirst()) where t <= b.t {
            let u = CGFloat(smooth((t - a.t) / (b.t - a.t)))
            // 缩放按比例插值，推近才匀。
            let zoom = a.zoom * CGFloat(pow(Double(b.zoom / a.zoom), Double(u)))
            return CameraKey(t: t, x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u, zoom: zoom)
        }
        return last
    }

    func draw(in ctx: CGContext, at t: Double) {
        let dt = 1.0 / 240
        while simTime + dt <= t + 1e-9 { step(dt) }

        let cam = cameraAt(t)
        let size = screenSize
        // 舞台
        ctx.setFillColor(rgb(0.012, 0.012, 0.02))
        ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        ctx.scaleBy(x: cam.zoom, y: cam.zoom)
        ctx.translateBy(x: -cam.x, y: -(size.height - cam.y))
        blob(ctx, at: CGPoint(x: size.width / 2, y: size.height / 2), radius: size.width * 0.95, color: palette.glow, alpha: 0.30)

        let screen = CGRect(origin: .zero, size: size)
        ctx.addPath(CGPath(roundedRect: screen.insetBy(dx: -10, dy: -10), cornerWidth: 22, cornerHeight: 22, transform: nil))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: screen.insetBy(dx: -10.5, dy: -10.5), cornerWidth: 22.5, cornerHeight: 22.5, transform: nil))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
        ctx.setLineWidth(1)
        ctx.strokePath()

        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.clip()
        renderScene(ctx, zoom: cam.zoom)
        drawBooth(ctx, t)
        // 闪光灯
        for f in flashes where t >= f && t < f + 0.34 {
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.82 * (1 - easeOut((t - f) / 0.34))))
            ctx.fill(screen)
        }
        ctx.restoreGState()
        drawCursor(ctx, t)
        ctx.restoreGState()

        // 暗角
        let colours = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.38)] as CFArray
        if let vignette = CGGradient(colorsSpace: srgb, colors: colours, locations: [0.55, 1]) {
            let c = CGPoint(x: outW / 2, y: outH / 2)
            ctx.drawRadialGradient(vignette, startCenter: c, startRadius: 0, endCenter: c, endRadius: 1150, options: [.drawsAfterEndLocation])
        }
        let length = end - start
        let fade = 1 - min(smooth(t / fadeIn), smooth((length - t) / fadeOut))
        if fade > 0.001 {
            ctx.setFillColor(CGColor(gray: 0, alpha: fade))
            ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
        }
    }

    private func drawBooth(_ ctx: CGContext, _ t: Double) {
        guard let booth, t >= booth.show, t <= booth.hide + 0.5 else { return }
        let out = min(easeOut((t - booth.show) / 0.55), 1 - smooth((t - booth.hide) / 0.45))
        let width: CGFloat = 278, preview = CGSize(width: 252, height: 189)
        let height: CGFloat = 3 + preview.height + 12 + 34 + 13
        let slot = host.geometry.slotLineY, cx = host.geometry.centerX
        let top = screenSize.height - slot
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: screenSize.width, height: top))
        ctx.translateBy(x: 0, y: height * CGFloat(1 - out))
        let panel = CGRect(x: cx - width / 2, y: top - height, width: width, height: height + 20)
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * 3), blur: 60, color: CGColor(gray: 0, alpha: 0.5))
        ctx.addPath(CGPath(roundedRect: panel, cornerWidth: 20, cornerHeight: 20, transform: nil))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        let taken = flashes.filter { $0 <= t }.count
        let screen = CGRect(x: cx - preview.width / 2, y: top - 3 - preview.height, width: preview.width, height: preview.height)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 13, cornerHeight: 13, transform: nil))
        ctx.clip()
        ctx.draw(poses[min(3, taken)], in: screen)
        ctx.restoreGState()
        withGraphics(ctx) {
            // 倒数
            for (index, at) in booth.counts.enumerated() where t >= at && t < at + 0.4 {
                let u = (t - at) / 0.4
                let digit = NSAttributedString(string: "\(3 - index)", attributes: [
                    .font: NSFont.systemFont(ofSize: 76 + 10 * u, weight: .bold), .foregroundColor: NSColor(white: 1, alpha: 0.95 * (1 - smooth((u - 0.5) / 0.5))),
                ])
                digit.draw(at: CGPoint(x: screen.midX - digit.size().width / 2, y: screen.midY - digit.size().height / 2))
            }
            if taken > 0 {
                let label = NSAttributedString(string: "\(min(4, taken)) / 4", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor(white: 1, alpha: 0.92)])
                let pill = CGRect(x: screen.maxX - 8 - label.size().width - 14, y: screen.maxY - 8 - 19, width: label.size().width + 14, height: 19)
                NSColor(white: 0, alpha: 0.35).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 9.5, yRadius: 9.5).fill()
                label.draw(at: CGPoint(x: pill.minX + 7, y: pill.minY + (19 - label.size().height) / 2))
            }
        }
        // 四格
        let cell = CGSize(width: 44, height: 33), gap: CGFloat = 8
        let rowWidth = cell.width * 4 + gap * 3
        for i in 0..<4 {
            let rect = CGRect(x: cx - rowWidth / 2 + CGFloat(i) * (cell.width + gap), y: screen.minY - 12 - cell.height, width: cell.width, height: cell.height)
            let shape = CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil)
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.clip()
            if i < taken { ctx.draw(poses[i], in: rect) } else { ctx.setFillColor(CGColor(gray: 1, alpha: 0.09)); ctx.fill(rect) }
            ctx.restoreGState()
            ctx.addPath(shape)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
            ctx.setLineWidth(0.5)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private func drawCursor(_ ctx: CGContext, _ t: Double) {
        guard let cursor else { return }
        var alpha = 1.0
        if let a = approach { alpha = smooth((t - a.t0) / 0.3) }
        if let gone = cursorGoneAt { alpha = 1 - smooth((t - gone) / 0.35) }
        guard alpha > 0.01, let picture = cursorDown ? Self.hand : (approach == nil && run != nil ? Self.open : Self.arrow) else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        let y = screenSize.height - cursor.y
        ctx.draw(picture.image, in: CGRect(x: cursor.x - picture.hot.x, y: y - (picture.size.height - picture.hot.y), width: picture.size.width, height: picture.size.height))
        ctx.restoreGState()
    }

    /// `Scene.render` 的翻版，画进已经架好摄影机的上下文里。
    private func renderScene(_ ctx: CGContext, zoom: CGFloat) {
        let scene = host.scene
        CATransaction.flush()
        ctx.interpolationQuality = .high
        scene.clip.isHidden = true
        scene.free.isHidden = true
        scene.root.render(in: ctx)
        scene.clip.isHidden = false
        scene.free.isHidden = false
        for node in scene.nodes where node.root.superlayer != nil {
            ctx.saveGState()
            if node.root.superlayer === scene.clip { ctx.clip(to: scene.clip.frame) }
            let transform = node.root.affineTransform()
            let away = (scene.size.width + scene.size.height) * 4
            for shadow in node.shadows {
                var shift = transform.concatenating(CGAffineTransform(translationX: away, y: 0))
                guard let path = shadow.path.copy(using: &shift) else { continue }
                let offset = CGSize(width: shadow.offset.width, height: shadow.offset.height).applying(
                    CGAffineTransform(a: transform.a, b: transform.b, c: transform.c, d: transform.d, tx: 0, ty: 0)
                )
                ctx.setShadow(
                    offset: CGSize(width: (offset.width - away) * zoom, height: offset.height * zoom),
                    blur: shadow.radius * 2 * zoom,
                    color: CGColor(gray: 0, alpha: min(1, shadow.opacity * 1.5))
                )
                ctx.addPath(path)
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fillPath()
            }
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.clip(to: scene.clip.frame)
        scene.clip.render(in: ctx)
        ctx.restoreGState()
        scene.free.render(in: ctx)
    }
}

/// 片尾：黑场上的一句话，然后是图标和名字。
@MainActor
final class EndShot: Shot {
    let start: Double
    let end: Double
    let icon: CGImage?
    let iconAt: Double

    init(start: Double, end: Double, iconAt: Double) {
        self.start = start
        self.end = end
        self.iconAt = iconAt
        let url = promoDir.deletingLastPathComponent().appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
        icon = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func draw(in ctx: CGContext, at t: Double) {
        ctx.setFillColor(rgb(0.012, 0.012, 0.02))
        ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
        let breathe = 0.5 + 0.5 * sin(t * 0.5)
        blob(ctx, at: CGPoint(x: 960, y: 620), radius: 900, color: (0.75, 0.40, 0.25), alpha: 0.10 + 0.03 * breathe)
        blob(ctx, at: CGPoint(x: 700, y: 300), radius: 800, color: (0.20, 0.24, 0.55), alpha: 0.12)
        if let icon, t >= iconAt {
            let u = easeOut((t - iconAt) / 1.1)
            let side = 230.0 * (0.92 + 0.08 * u)
            ctx.saveGState()
            ctx.setAlpha(u)
            ctx.draw(icon, in: CGRect(x: 960 - side / 2, y: 1080 - 290 - side / 2 - 18 * (1 - u), width: side, height: side))
            ctx.restoreGState()
        }
        let fade = smooth((t - (end - start - 1.3)) / 1.2)
        if fade > 0.001 {
            ctx.setFillColor(CGColor(gray: 0, alpha: fade))
            ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
        }
    }
}

// MARK: - Titles

struct Title {
    enum Align { case left, center }
    var text: String
    var size: CGFloat
    var weight: NSFont.Weight = .semibold
    /// 左对齐时是左边缘，居中时是中线；y 是文字块顶边，都按 1920×1080、原点在左上。
    var x: CGFloat
    var y: CGFloat
    var align: Align = .left
    var t0: Double
    var t1: Double
    var color: CGColor = CGColor(gray: 1, alpha: 1)
    var tracking: CGFloat = 0
    var mono = false
    var lineSpacing: CGFloat = 0
    /// 逐字敲出来，每秒多少个字符。
    var typed: Double?
    var pill = false
}

@MainActor
func draw(_ title: Title, in ctx: CGContext, at t: Double) {
    guard t >= title.t0, t <= title.t1 else { return }
    let enter = easeOut((t - title.t0) / 0.9)
    let leave = smooth((title.t1 - t) / 0.5)
    let alpha = min(smooth((t - title.t0) / 0.6), leave)
    var text = title.text
    var caret = false
    if let rate = title.typed {
        let count = Int((t - title.t0 - 0.3) * rate)
        text = String(text.prefix(max(0, count)))
        caret = count < title.text.count || Int(t * 2) % 2 == 0
    }
    let font = title.mono ? NSFont.monospacedSystemFont(ofSize: title.size, weight: title.weight) : NSFont.systemFont(ofSize: title.size, weight: title.weight)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = title.lineSpacing
    paragraph.alignment = title.align == .center ? .center : .left
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.45)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = CGSize(width: 0, height: -4)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor(cgColor: title.color) ?? .white, .kern: title.tracking, .paragraphStyle: paragraph, .shadow: shadow,
    ]
    let full = NSAttributedString(string: title.text, attributes: attrs)
    let shown = NSAttributedString(string: text + (caret && title.typed != nil ? "▍" : ""), attributes: attrs)
    let bounds = full.boundingRect(with: CGSize(width: 1700, height: 1000), options: [.usesLineFragmentOrigin])
    let width = ceil(bounds.width) + 4, height = ceil(bounds.height)
    let left = title.align == .center ? title.x - width / 2 : title.x
    let rise = title.typed == nil ? 26 * (1 - enter) : 0
    let rect = CGRect(x: left, y: CGFloat(outH) - title.y - height - rise, width: width + 40, height: height)
    ctx.saveGState()
    ctx.setAlpha(alpha)
    if title.pill {
        let box = CGRect(x: left - 30, y: rect.minY - 20, width: width + 60 + 30, height: height + 40)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 18, cornerHeight: 18, transform: nil))
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.5))
        ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 18, cornerHeight: 18, transform: nil))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
        ctx.setLineWidth(1.5)
        ctx.strokePath()
    }
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    withGraphics(ctx) {
        shown.draw(with: title.align == .center ? CGRect(x: left, y: rect.minY, width: width, height: height) : rect, options: [.usesLineFragmentOrigin])
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

// MARK: - What gets printed

@MainActor
enum Prints {
    static let now = Date()
    /// 今天的某个钟点，和镜头里菜单栏的时钟对上。
    static func today(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
    }

    static func receipt(_ source: String) -> PrintJob {
        let content = ReceiptContent(picture: nil, body: .lines(ReceiptMarkup.parse(source)))
        return PrintJob(PaperSheet(.thermal) { ReceiptView(content: content) }, reveal: .progressive(lineHeight: ReceiptType.feedLine), autoRetract: .never)
    }

    static func hello() -> PrintJob {
        receipt("# 你好。\n\n^ 我住在屏幕顶上，\n^ 纸就从这里出来。\n---\n^ > NOTCHFAX · 第 1 张")
    }

    static func memory() -> PrintJob {
        let image = PrintSamples.landscape(width: 1440, height: 1080, variant: 0)
        let date = Calendar.current.date(byAdding: .year, value: -3, to: now) ?? now
        let layout = MemoryPrintLayout(imageAspect: 4.0 / 3.0)
        let sheet = PaperSheet(.glossyPhoto, size: layout.sheetSize) {
            MemoryPrintContent(image: image, date: date, caption: "3 年前的今天", layout: layout)
        }
        return PrintJob(sheet, autoRetract: .never)
    }

    static func strip() -> PrintJob {
        let frames = (0..<4).map { PrintSamples.portrait(width: 864, height: 648, variant: $0) }
        var job = BoothStrip.job(BoothStrip.Developed(frames: frames, printFrames: frames), date: today(15, 7))
        job.autoRetract = .never
        return job
    }

    static func fax(page: Int) -> PrintJob {
        let model = page == 1
            ? FaxPageModel(
                time: today(22, 40), alias: "4F2A", page: 1,
                body: .text("你好，陌生人。\n今晚的月亮很圆，我这边刚下过雨，路面像一张刚洗出来的照片。\n\n如果你也还没睡，回我一句吧。"),
                footer: "回复后线路接通，可发图片"
            )
            : FaxPageModel(
                time: today(22, 47), alias: "4F2A", page: 2,
                body: .text("收到啦！\n这边是凌晨两点，窗外在下雪。\n\n原来真的有人在。"),
                footer: "对方回复了，线路已接通"
            )
        return PrintJob(model.sheet(), reveal: .progressive(lineHeight: 14), autoRetract: .never)
    }

    static func bill() -> PrintJob {
        receipt("""
        # CLAUDE CODE
        ^ > 会话小票 No.EC484591
        ---
        项目\tnotchfax
        用时\t1 小时 12 分
        对话\t9 问 · 214 次调用
        ---
        ## Fable 5.2\t$6.42
        > 输入 1.2M\t$1.86
        > 输出 86K\t$4.56
        ---
        # 合计\t$6.42
        ^ > 按 API 标价估算
        ===
        ^ > 谢谢惠顾 · 欢迎再来
        """)
    }
}

// MARK: - The film

@MainActor
func makeFilm(sfx: SFXTrack) -> (shots: [any Shot], titles: [Title]) {
    var titles: [Title] = []
    let left: CGFloat = 150

    func chapter(_ kicker: String, _ headline: String, from t0: Double, to t1: Double) {
        titles.append(Title(text: kicker, size: 34, weight: .bold, x: left + 3, y: 372, t0: t0, t1: t1, color: orange, tracking: 7))
        titles.append(Title(text: headline, size: 92, weight: .bold, x: left, y: 440, t0: t0 + 0.18, t1: t1, tracking: 1, lineSpacing: 14))
    }

    // 一、刘海
    let intro = ScreenShot(start: 0, end: 12.0, palette: .ink, clock: "11月13日 周五  21:41", sfx: sfx)
    intro.fadeIn = 1.6
    intro.camera = [
        CameraKey(t: 0, x: 450, y: 285, zoom: 1.5),
        CameraKey(t: 1.0, x: 450, y: 285, zoom: 1.5),
        CameraKey(t: 4.9, x: 450, y: 62, zoom: 5.4),
        CameraKey(t: 5.6, x: 450, y: 62, zoom: 5.5),
        CameraKey(t: 7.6, x: 355, y: 150, zoom: 3.2),
        CameraKey(t: 12.0, x: 355, y: 152, zoom: 3.3),
    ]
    intro.print(at: 7.0, seed: 21) { Prints.hello() }
    intro.tearOff(at: 10.9)
    titles.append(Title(text: "Notchfax", size: 150, weight: .bold, x: left - 6, y: 380, t0: 8.9, t1: 11.6, tracking: -2))
    titles.append(Title(text: "住在刘海里的小打印机", size: 44, weight: .medium, x: left, y: 580, t0: 9.3, t1: 11.6, color: CGColor(gray: 1, alpha: 0.72), tracking: 3))

    // 二、那年今日
    let memories = ScreenShot(start: 12.0, end: 24.0, palette: .dusk, clock: "11月13日 周五  08:30", sfx: sfx)
    memories.camera = [CameraKey(t: 0, x: 355, y: 148, zoom: 3.2), CameraKey(t: 12, x: 352, y: 152, zoom: 3.42)]
    memories.print(at: 0.7, seed: 12) { Prints.memory() }
    memories.gesture(at: 5.6, "swing")
    memories.gesture(at: 8.0, "carry")
    chapter("那年今日", "往年的今天，\n印给今天的你。", from: 12.6, to: 23.6)

    // 三、大头贴
    let booth = ScreenShot(start: 24.0, end: 34.5, palette: .candy, clock: "11月13日 周五  15:07", sfx: sfx)
    booth.camera = [CameraKey(t: 0, x: 355, y: 160, zoom: 3.1), CameraKey(t: 10.5, x: 352, y: 166, zoom: 3.25)]
    booth.booth = (show: 0.3, hide: 3.9, counts: [0.85, 1.25, 1.65])
    booth.sound(at: 0.3, .slip)
    for t in [0.85, 1.25, 1.65] { booth.sound(at: t, .tick) }
    for t in [2.05, 2.55, 3.05, 3.55] { booth.flash(at: t) }
    booth.sound(at: 4.05, .thunk)
    booth.print(at: 4.4, seed: 13) { Prints.strip() }
    booth.gesture(at: 8.6, "swing")
    chapter("大头贴", "倒数三秒，\n连拍四张。", from: 24.5, to: 34.1)

    // 四、传真
    let fax = ScreenShot(start: 34.5, end: 49.5, palette: .night, clock: "11月13日 周五  22:40", sfx: sfx)
    fax.camera = [CameraKey(t: 0, x: 355, y: 158, zoom: 3.1), CameraKey(t: 15, x: 352, y: 164, zoom: 3.28)]
    fax.print(at: 0.8, seed: 11) { Prints.fax(page: 1) }
    fax.gesture(at: 6.3, "rip")
    fax.print(at: 8.2, seed: 17) { Prints.fax(page: 2) }
    chapter("传真", "写给一位\n陌生人。", from: 35.1, to: 41.2)
    chapter("传真", "然后，\n等一张回信。", from: 41.6, to: 49.1)

    // 五、命令行
    let cli = ScreenShot(start: 49.5, end: 57.0, palette: .terminal, clock: "11月13日 周五  23:58", sfx: sfx)
    cli.camera = [CameraKey(t: 0, x: 355, y: 170, zoom: 3.0), CameraKey(t: 7.5, x: 353, y: 176, zoom: 3.12)]
    cli.print(at: 2.0, seed: 31) { Prints.bill() }
    titles.append(Title(text: "命令行", size: 34, weight: .bold, x: left + 3, y: 330, t0: 49.9, t1: 56.6, color: orange, tracking: 7))
    titles.append(Title(text: "终端里的事，\n也能落在纸上。", size: 84, weight: .bold, x: left, y: 398, t0: 50.1, t1: 56.6, tracking: 1, lineSpacing: 12))
    titles.append(Title(text: "$ notchfax print 小票.md", size: 36, weight: .medium, x: left + 30, y: 690, t0: 50.2, t1: 56.6, color: rgb(0.72, 0.95, 0.78), mono: true, typed: 22, pill: true))

    // 六、片尾
    let ending = EndShot(start: 57.0, end: filmLength, iconAt: 5.25)
    titles.append(Title(text: "有些话，有些时刻，\n值得被印出来。", size: 96, weight: .bold, x: 960, y: 400, align: .center, t0: 57.5, t1: 61.8, tracking: 3, lineSpacing: 22))
    titles.append(Title(text: "Notchfax", size: 104, weight: .bold, x: 960, y: 448, align: .center, t0: 62.6, t1: filmLength, tracking: -1))
    titles.append(Title(text: "住在刘海里的小打印机", size: 40, weight: .medium, x: 960, y: 590, align: .center, t0: 63.0, t1: filmLength, color: CGColor(gray: 1, alpha: 0.7), tracking: 4))
    titles.append(Title(text: "brew install --cask kadaliao/tap/notchfax", size: 27, weight: .regular, x: 960, y: 760, align: .center, t0: 64.0, t1: filmLength, color: CGColor(gray: 1, alpha: 0.5), mono: true))

    return ([intro, memories, booth, fax, cli, ending], titles)
}

@MainActor
func main() throws {
    _ = NSApplication.shared
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    var args = Array(CommandLine.arguments.dropFirst())
    var single: Double?
    var range = 0.0...filmLength
    while !args.isEmpty {
        let arg = args.removeFirst()
        if arg == "--frame", let v = args.first.flatMap(Double.init) { single = v; args.removeFirst() }
        if arg == "--range", args.count >= 2, let a = Double(args[0]), let b = Double(args[1]) { range = a...b; args.removeFirst(2) }
    }

    let sfx = SFXTrack(seconds: filmLength + 1)
    let film = makeFilm(sfx: sfx)
    let ctx = CGContext(
        data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: outW * 4, space: srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )!

    func render(_ t: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ctx.saveGState()
        if let shot = film.shots.first(where: { t >= $0.start && t < $0.end }) ?? film.shots.last {
            shot.draw(in: ctx, at: t - shot.start)
        }
        for title in film.titles { draw(title, in: ctx, at: t) }
        ctx.restoreGState()
        CATransaction.commit()
    }

    if let single {
        render(single)
        let url = outDir.appendingPathComponent(String(format: "frame-%05.2f.png", single))
        try PaperRenderer.pngData(ctx.makeImage()!)?.write(to: url)
        print(url.path)
        return
    }

    let whole = range == 0.0...filmLength
    let video = outDir.appendingPathComponent(whole ? "video.mp4" : "part.mp4")
    let ffmpeg = Process()
    ffmpeg.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    ffmpeg.arguments = [
        "ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "bgra", "-s", "\(outW)x\(outH)", "-r", "\(fps)", "-i", "-",
        "-c:v", "libx264", "-preset", "medium", "-crf", "15", "-pix_fmt", "yuv420p",
        "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-movflags", "+faststart", video.path,
    ]
    let pipe = Pipe()
    ffmpeg.standardInput = pipe
    try ffmpeg.run()
    let first = Int(range.lowerBound * Double(fps)), last = Int(range.upperBound * Double(fps))
    let began = Date()
    for frame in first..<last {
        autoreleasepool {
            render(Double(frame) / Double(fps))
            pipe.fileHandleForWriting.write(Data(bytesNoCopy: ctx.data!, count: outW * outH * 4, deallocator: .none))
        }
        if frame % 300 == 0 { FileHandle.standardError.write("\(frame - first)/\(last - first)  \(Int(Date().timeIntervalSince(began)))s\n".data(using: .utf8)!) }
    }
    try pipe.fileHandleForWriting.close()
    ffmpeg.waitUntilExit()
    if whole { try sfx.write(to: outDir.appendingPathComponent("sfx.wav")) }
    print(video.path)
}

try MainActor.assumeIsolated { try main() }
