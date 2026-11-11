import PrintKit
import SwiftUI

/// The one sheet the app prints by itself the first time it runs: what it is, the three
/// things it does, and where to find them. Never printed again once it has come out.
@MainActor
enum WelcomeSlip {
    static let defaultsKey = "welcome.printed"

    static func shouldPrint(launch: LaunchOptions, defaults: UserDefaults = .standard) -> Bool {
        if launch.forcesWelcome { return true }
        return !defaults.bool(forKey: defaultsKey) && !launch.isScripted
    }

    static func job(defaults: UserDefaults = .standard) -> PrintJob {
        PrintJob(
            PaperSheet(.thermal) { WelcomePage() },
            reveal: .progressive(lineHeight: 15),
            autoRetract: .after(60),
            export: PNGExport(filename: "Notchfax 你好"),
            // Nobody asked for it: anything the person does first goes ahead of it.
            priority: .ambient,
            readingTime: 20,
            onEvent: { event, _ in
                // Only once it has actually come out: a launch that was quit early prints it next time.
                if event == .finishedFeeding { defaults.set(true, forKey: defaultsKey) }
            }
        )
    }
}

private struct WelcomePage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("NOTCHFAX").font(.system(size: 8, weight: .heavy, design: .monospaced)).tracking(1.2)
                Spacer()
                Text("第 1 张").font(.system(size: 7, weight: .medium, design: .monospaced))
            }
            Rule()
            Text("你好。")
                .font(.system(size: 13, weight: .semibold))
            Text("这台小机器住在屏幕顶上，纸就从这里出来。它会三件事：")
                .font(.system(size: 10.5, weight: .medium))
                .lineSpacing(3.5)
            VStack(alignment: .leading, spacing: 7) {
                Item(name: "那年今日", text: "把往年今天拍的照片印给你。")
                Item(name: "大头贴", text: "连拍四张，印成一条。")
                Item(name: "传真", text: "写给一位陌生人。对方回了，线路就接通。")
            }
            Text("想用的时候，点菜单栏上这张小纸条的图标。")
                .font(.system(size: 10.5, weight: .medium))
                .lineSpacing(3.5)
            Rule()
            Text("纸可以抓着晃、横着撕，也可以拖出去存成图片。放着不管，它会自己收回去。")
                .font(.system(size: 7.5, weight: .medium))
                .lineSpacing(2.5)
        }
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.black)
    }

    private struct Item: View {
        let name: String
        let text: String

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 10.5, weight: .bold))
                Text(text).font(.system(size: 9.5, weight: .medium)).lineSpacing(3)
            }
            .padding(.leading, 7)
            .overlay(alignment: .leading) { Rectangle().frame(width: 1.5) }
        }
    }

    private struct Rule: View {
        var body: some View {
            Canvas { context, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            .frame(height: 1)
        }
    }
}
