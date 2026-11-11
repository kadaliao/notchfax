import AppKit
import QuartzCore

/// The booth's flash: the whole screen lights up for an instant, brightest at the top
/// where the camera is, and fades out like a strobe's afterglow.
///
/// On a real camera this also lights the face, as Photo Booth does; the shot is taken
/// while it is bright.
@MainActor
final class ScreenFlash {
    private var panel: NSPanel?
    private var glow: CAGradientLayer?
    private var generation = 0

    /// - Parameter peak: opacity at the brightest moment. Kept well below 1: soft, not blinding.
    func fire(on screen: NSScreen?, peak: Float) {
        guard let screen = screen ?? NSScreen.main else { return }
        let (panel, glow) = prepare()
        panel.setFrame(screen.frame, display: false)
        glow.frame = CGRect(origin: .zero, size: screen.frame.size)
        panel.orderFrontRegardless()

        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, peak, peak * 0.4, peak * 0.12, 0]
        animation.keyTimes = [0, 0.06, 0.28, 0.6, 1]
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeIn),
        ]
        animation.duration = 0.62
        glow.opacity = 0
        glow.removeAllAnimations()
        glow.add(animation, forKey: "flash")

        generation += 1
        let current = generation
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(680))
            guard let self, self.generation == current else { return }
            self.panel?.orderOut(nil)
        }
    }

    func hide() {
        generation += 1
        glow?.removeAllAnimations()
        panel?.orderOut(nil)
    }

    private func prepare() -> (NSPanel, CAGradientLayer) {
        if let panel, let glow { return (panel, glow) }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // Above the paper and the machine: the flash lights everything.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = NSView()
        view.wantsLayer = true
        let glow = CAGradientLayer()
        glow.type = .radial
        // Layer space is y-up: the light comes from the top centre, where the slot is.
        glow.startPoint = CGPoint(x: 0.5, y: 1)
        glow.endPoint = CGPoint(x: 1.35, y: -0.45)
        glow.colors = [
            CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            CGColor(red: 1, green: 0.995, blue: 0.985, alpha: 0.82),
            CGColor(red: 1, green: 0.99, blue: 0.97, alpha: 0.55),
        ]
        glow.locations = [0, 0.45, 1]
        glow.opacity = 0
        view.layer?.addSublayer(glow)
        panel.contentView = view
        self.panel = panel
        self.glow = glow
        return (panel, glow)
    }
}
