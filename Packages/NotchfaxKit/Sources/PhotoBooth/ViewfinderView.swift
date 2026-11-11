import AppKit
import SwiftUI

/// What the booth is showing before and during a sitting.
@MainActor
@Observable
final class BoothViewModel {
    enum Stage {
        /// Deciding on a camera (the permission prompt may be up).
        case opening
        case denied
        case live(BoothSession)
    }

    var stage: Stage = .opening
    var look: BoothLook
    let reduceMotion: Bool

    init(look: BoothLook, reduceMotion: Bool) {
        self.look = look
        self.reduceMotion = reduceMotion
    }
}

/// The booth hanging from the slot: the live picture in a window the shape of a strip
/// frame, and under it the looks, the shutter and the four frames filling in.
struct ViewfinderView: View {
    static let previewWidth: CGFloat = 252
    static var previewHeight: CGFloat { (previewWidth / BoothStrip.frameAspect).rounded() }

    let model: BoothViewModel
    let close: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 11) {
            screen
                .frame(width: Self.previewWidth, height: Self.previewHeight)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(.white.opacity(0.09), lineWidth: 0.5)
                }
                .overlay(alignment: .topLeading) {
                    CloseButton(action: close).padding(8)
                }
            controls
                .frame(width: Self.previewWidth, height: 38)
        }
        .padding(.horizontal, 13)
        .padding(.top, 3)
        .padding(.bottom, 13)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var screen: some View {
        switch model.stage {
        case .opening:
            Placeholder(symbol: nil, text: "正在打开摄像头…")
        case .denied:
            Placeholder(symbol: "video.slash", text: "Notchfax 没有使用摄像头的权限", action: ("打开隐私设置", openSettings))
        case .live(let session):
            LiveScreen(session: session, reduceMotion: model.reduceMotion)
        }
    }

    @ViewBuilder private var controls: some View {
        switch model.stage {
        case .live(let session):
            BoothControls(session: session, look: Binding(get: { model.look }, set: { model.look = $0; session.look = $0 }))
        default:
            BoothControls(session: nil, look: Binding(get: { model.look }, set: { model.look = $0 }))
        }
    }
}

// MARK: - Screen

private struct LiveScreen: View {
    let session: BoothSession
    let reduceMotion: Bool
    @State private var flash = 0.0

    var body: some View {
        ZStack {
            PreviewLayerView(sink: session.sink)
            overlay
            Color.white
                .opacity(flash)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            if session.isSimulated, session.phase == .ready || session.phase == .starting {
                Text("模拟画面")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.32), in: Capsule())
                    .padding(8)
                    .transition(.opacity)
                    .help("这台 Mac 没有摄像头，用的是模拟画面")
            } else if let shot = session.phase.shot {
                Text("\(shot) / \(session.script.shots)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.32), in: Capsule())
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if let notice = session.notice {
                Text(notice)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 9)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: session.phase)
        .animation(.spring(response: 0.35, dampingFraction: 1), value: session.notice)
        .onChange(of: session.flashCount) {
            // The picture whites out at once and comes back as the flash dies away.
            flash = reduceMotion ? 0.5 : 0.95
            withAnimation(.easeOut(duration: 0.5)) { flash = 0 }
        }
    }

    @ViewBuilder private var overlay: some View {
        switch session.phase {
        case .starting:
            Placeholder(symbol: nil, text: "正在打开摄像头…")
        case .ready:
            Hint(text: "按快门或空格键开始")
        case .countdown(let shot, let value):
            Countdown(value: value, reduceMotion: reduceMotion)
                .id("\(shot)-\(value)")
        case .repose(let next):
            Hint(text: next == session.script.shots ? "最后一张" : "换个姿势")
        case .review:
            EmptyView()
        case .developing, .finished:
            ZStack {
                Color.black.opacity(0.38)
                Text("正在冲印…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .transition(.opacity)
        case .cancelled:
            Color.black.opacity(0.5)
        case .unavailable(let message):
            Placeholder(symbol: "video.slash", text: message)
        }
    }
}

/// One big number, popping in and settling, the way a booth's countdown lamp does.
private struct Countdown: View {
    let value: Int
    let reduceMotion: Bool
    @State private var shown = false

    var body: some View {
        Text("\(value)")
            .font(.system(size: 66, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 10, y: 2)
            .scaleEffect(reduceMotion ? 1 : (shown ? 1 : 1.32))
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.68)) {
                    shown = true
                }
            }
            .transition(.opacity.animation(.easeOut(duration: 0.12)))
    }
}

private struct Hint: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                .padding(.bottom, 11)
        }
        .transition(.opacity)
    }
}

private struct Placeholder: View {
    let symbol: String?
    let text: String
    var action: (String, () -> Void)?

    var body: some View {
        ZStack {
            Color(white: 0.07)
            VStack(spacing: 9) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.white.opacity(0.5))
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                if let action {
                    Button(action.0, action: action.1)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

private struct CloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.8))
                .frame(width: 19, height: 19)
                .background(.black.opacity(hovering ? 0.5 : 0.32), in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("关闭")
        .help("关闭（esc）")
    }
}

// MARK: - Controls

private struct BoothControls: View {
    let session: BoothSession?
    @Binding var look: BoothLook

    private var phase: BoothSession.Phase { session?.phase ?? .starting }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                LookPicker(look: $look)
                    .disabled(phase == .developing || phase == .finished)
                Spacer(minLength: 0)
                FrameSlots(thumbnails: session?.thumbnails ?? [], current: phase.shot, total: session?.script.shots ?? 4)
            }
            Shutter(phase: phase, progress: Double(session?.stills.count ?? 0) / Double(session?.script.shots ?? 4)) {
                session?.begin()
            }
        }
    }
}

private struct LookPicker: View {
    @Binding var look: BoothLook
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(BoothLook.allCases) { option in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 1)) { look = option }
                } label: {
                    Text(option.title)
                        .font(.system(size: 10.5, weight: look == option ? .semibold : .medium))
                        .foregroundStyle(.white.opacity(look == option ? 0.95 : 0.5))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background {
                            if look == option {
                                Capsule().fill(.white.opacity(0.15)).matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .opacity(isEnabled ? 1 : 0.5)
    }

    @Namespace private var namespace
}

/// Four little frames that fill in as the shots are taken.
private struct FrameSlots: View {
    let thumbnails: [CGImage]
    let current: Int?
    let total: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<total, id: \.self) { index in
                ZStack {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(.white.opacity(0.1))
                    if index < thumbnails.count {
                        Image(decorative: thumbnails[index], scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .transition(.scale(scale: 1.6).combined(with: .opacity))
                    }
                }
                .frame(width: 17, height: (17 / BoothStrip.frameAspect).rounded())
                .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(.white.opacity(current == index + 1 && index >= thumbnails.count ? 0.75 : 0.16), lineWidth: 0.75)
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: thumbnails.count)
        .animation(.easeOut(duration: 0.2), value: current)
        .accessibilityElement()
        .accessibilityLabel("已拍 \(thumbnails.count) 张，共 \(total) 张")
    }
}

/// The big button. Before a sitting it starts one; during it, its ring fills a quarter
/// per shot.
private struct Shutter: View {
    let phase: BoothSession.Phase
    let progress: Double
    let action: () -> Void

    private var isReady: Bool { phase == .ready }
    private var isShooting: Bool { phase.isShooting || phase == .developing || phase == .finished }

    var body: some View {
        ZStack {
            // Hidden twin so Return works as well as Space.
            Button("", action: action).keyboardShortcut(.defaultAction).opacity(0).frame(width: 0, height: 0)
            Button(action: action) {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.22), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: isShooting ? progress : 0)
                        .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Circle()
                        .fill(isShooting ? Color(red: 1, green: 0.27, blue: 0.23) : .white)
                        .padding(isShooting ? 11 : 4.5)
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(ShutterStyle())
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!isReady)
            .opacity(isReady || isShooting ? 1 : 0.35)
            .animation(.spring(response: 0.38, dampingFraction: 0.78), value: isShooting)
            .animation(.spring(response: 0.5, dampingFraction: 1), value: progress)
            .accessibilityLabel("开始拍摄")
            .help("开始拍摄（空格）")
        }
    }
}

private struct ShutterStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Live picture

/// A plain layer the frame pipeline writes into directly.
private struct PreviewLayerView: NSViewRepresentable {
    let sink: PreviewSink

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        if let layer = view.layer {
            layer.contentsGravity = .resizeAspectFill
            layer.backgroundColor = CGColor(gray: 0.07, alpha: 1)
            layer.contents = sink.current
            layer.masksToBounds = true
        }
        sink.layer = view.layer
        sink.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
