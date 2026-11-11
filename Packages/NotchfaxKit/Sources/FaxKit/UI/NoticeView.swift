import PrintKit
import SwiftUI

/// A one-line acknowledgement that grows out of the slot for a moment: a line connected,
/// a line hung up, a fax delivered.
struct FaxNotice: Equatable, Sendable {
    enum Kind: Sendable {
        case connected, closed, delivered, searching, problem
    }

    var kind: Kind
    var title: String
    var detail: String?
    /// Notices about the same thing replace each other instead of queueing.
    var key: String

    var symbol: String {
        switch kind {
        case .connected: "phone.connection.fill"
        case .closed: "phone.down.fill"
        case .delivered: "checkmark.circle.fill"
        case .searching: "dot.radiowaves.left.and.right"
        case .problem: "exclamationmark.circle.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .connected: Color(red: 0.36, green: 0.86, blue: 0.48)
        case .closed: Color(white: 0.72)
        case .delivered: Color(red: 0.36, green: 0.86, blue: 0.48)
        case .searching: Color(red: 0.98, green: 0.78, blue: 0.32)
        case .problem: Color(red: 1, green: 0.45, blue: 0.36)
        }
    }
}

struct NoticeView: View {
    let notice: FaxNotice
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: notice.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(notice.tint)
                .symbolEffect(.bounce, value: appeared)
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                if let detail = notice.detail {
                    Text(detail)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: 240, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 12)
        .onAppear {
            guard !reduceMotion else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(260))
                appeared = true
            }
        }
    }
}

/// Asks before reporting: reporting hangs up and keeps the two of you from being matched again.
struct ReportConfirmView: View {
    let alias: String
    let confirm: @MainActor () -> Void
    let cancel: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("举报线路 #\(alias)？")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text("线路会挂断，你们以后不会再被配对。对方不会知道是谁举报的。")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("取消", action: cancel)
                    .buttonStyle(PillStyle(fill: Color.white.opacity(0.14)))
                    .keyboardShortcut(.cancelAction)
                Button("举报并挂断", action: confirm)
                    .buttonStyle(PillStyle(fill: Color(red: 0.86, green: 0.22, blue: 0.18)))
            }
        }
        .frame(width: 228)
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }
}

private struct PillStyle: ButtonStyle {
    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.75), value: configuration.isPressed)
    }
}
