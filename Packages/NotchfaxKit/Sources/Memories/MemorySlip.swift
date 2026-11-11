import AppKit
import PrintKit
import SwiftUI

/// A short thermal note, printed when 那年今日 was asked for and has no picture to give.
///
/// The machine answering on paper keeps the reply in the same world as the prints; a
/// dialog would break it, and silence would look like nothing happened. Only requests
/// made by hand get a slip: the daily print stays quiet when there is nothing to show.
enum MemorySlip {
    enum Reason: Equatable {
        case nothingToday(limited: Bool)
        case noAccess
        case unavailable
    }

    static let privacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")

    @MainActor
    static func job(_ reason: Reason, today: Date, calendar: Calendar = .current) -> PrintJob {
        let day = calendar.dateComponents([.year, .month, .day], from: today)
        let dateLine = String(format: "%04d.%02d.%02d", day.year ?? 0, day.month ?? 1, day.day ?? 1)
        var actions: [PaperAction] = []
        if reason == .noAccess || reason == .nothingToday(limited: true), let url = privacySettings {
            actions.append(PaperAction(id: "settings", title: "打开设置", systemImage: "gearshape") { handle in
                NSWorkspace.shared.open(url)
                handle.retract()
            })
        }
        return PrintJob(
            PaperSheet(.thermal) { SlipPage(dateLine: dateLine, lines: lines(for: reason)) },
            reveal: .progressive(lineHeight: 14),
            autoRetract: .after(9),
            actions: actions
        )
    }

    static func lines(for reason: Reason) -> (String, String) {
        switch reason {
        case .nothingToday(limited: false):
            ("往年的今天没有照片。", "明天再来看看。")
        case .nothingToday(limited: true):
            ("允许访问的照片里，没有往年今天拍的。", "可以在设置里允许 Notchfax 访问更多照片。")
        case .noAccess:
            ("还不能读取照片图库。", "请在「系统设置 › 隐私与安全性 › 照片」中允许 Notchfax。")
        case .unavailable:
            ("照片还在 iCloud 里，没能及时取回。", "稍后再试一次。")
        }
    }
}

private struct SlipPage: View {
    let dateLine: String
    let lines: (String, String)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("那年今日").font(.system(size: 8, weight: .heavy)).tracking(1.2)
                Spacer()
                Text(dateLine).font(.system(size: 7, weight: .medium, design: .monospaced))
            }
            Rectangle().frame(height: 0.75)
            Text(lines.0)
                .font(.system(size: 11, weight: .semibold))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            Text(lines.1)
                .font(.system(size: 9, weight: .medium))
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.black)
    }
}
