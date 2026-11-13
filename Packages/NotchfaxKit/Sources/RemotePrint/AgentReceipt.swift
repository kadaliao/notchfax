import AppKit
import SwiftUI

/// AI 会话小票: a receipt each time an AI coding agent finishes a session.
///
/// Every agent wires hooks up its own way, and those ways keep changing, so Notchfax does not
/// install anything into them. It hands the person a prompt for their agent, which knows its
/// own hooks and logs, and prints through the `notchfax` command.
enum AgentReceipt {
    /// Working setups for several agents, with the conventions they share and the receipt layout.
    static let samples = "https://github.com/kadaliao/notchfax/tree/main/integrations"

    /// Agents with a ready-made setup in `samples`, by the directory it lives in.
    static let readyMade: [(agent: String, directory: String)] = [
        ("Claude Code", "claude-code"),
        ("Pi", "pi"),
        ("OpenCode", "opencode"),
        ("DeepSeek Harness 桌面版", "dsh"),
    ]

    /// `executable`: the command's full path. Hooks often run with a bare PATH (agents opened
    /// from the Dock get only the system folders), so the script should not rely on `notchfax`.
    static func prompt(executable: String) -> String {
        let ready = readyMade.map { "- \($0.agent)：\($0.directory)/" }.joined(separator: "\n")
        return """
        帮我装一个功能：每次和你的会话结束时，让 Notchfax 从屏幕刘海里打印一张小票。

        Notchfax 是这台 Mac 上的一个 App，它的命令行在：
        \(executable)
        先运行它的 help 子命令，看打印选项和小票的排版标记；打印用 print 子命令。钩子运行时 PATH 可能不全，脚本里请用上面这个完整路径。

        要求：
        1. 用你自己支持的钩子、插件或通知机制，在会话结束时触发。先查你自己的官方文档，确认有哪些机制，不要猜。
        2. 小票写项目目录名、开始和结束时间、用时、模型、输入和输出 token、按官方标价算的花费和合计。只写会话记录或日志里能查实的数字，查不到的那一行就不印，不要估算。同一个会话恢复后再结束，只算新增的部分。
        3. 钩子要马上返回，打印放到后台做，不能拖慢会话结束。打印失败就安静退出，错误写进 ~/Library/Logs/Notchfax/ 下的日志。
        4. 只给我手动开的交互式会话打印，脚本、CI 和子任务不打。
        5. 装好后先打一张样票给我看，再告诉我装在了哪、怎么关掉。

        动手前先看现成的样例：
        \(samples)
        它的 README 写了几家共同的做法和小票的统一格式，照着做。下面这几家已经有现成的实现，你是其中一家就用对应目录里的，按里面的 README 安装，再对照你这里的实际版本核对一遍：
        \(ready)
        不是的话，就参考触发方式和你最像的那一个。
        """
    }

    /// A made-up receipt in the shared layout the samples print, so people can see what
    /// they would get before they set anything up. It says it is a sample, top and bottom.
    static func sample(endingAt end: Date) -> String {
        let start = end.addingTimeInterval(-45 * 60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return """
        # AI 会话小票
        ^ > 样票 · 数字是编的
        ---
        项目\tnotchfax
        开始\t\(formatter.string(from: start))
        结束\t\(formatter.string(from: end))
        用时\t45 分
        对话\t12 问 · 86 次调用
        ---
        ## 示例模型\t$1.84
        > 输入 5.2万\t$0.26
        > 输出 3.2万\t$1.58
        ---
        # 合计\t$1.84
        ^ > 按 API 标价估算
        ===
        ^ > 谢谢惠顾 · 欢迎再来
        """
    }
}

/// The prompt, a button that copies it, and one that prints a sample, in the machine's own black.
struct AgentReceiptView: View {
    let prompt: String
    let printSample: () -> Void
    let close: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("AI 会话小票")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("让 Claude Code、Codex、Cursor、OpenCode 这类编程助手每干完一次活，就从刘海里吐一张小票：用了哪些模型、多少 token、花了多少钱。")
                    .fixedSize(horizontal: false, vertical: true)
                Text("各家装钩子的方式不一样，所以这一步交给它自己：把下面这段话发给你的 AI，它会装好，再打一张样票给你看。")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.58))

            ScrollView {
                Text(prompt)
                    .font(.system(size: 11))
                    .lineSpacing(2)
                    .foregroundStyle(.white.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
            }
            .frame(height: 176)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))

            Text("想关掉的话，也跟它说一声就行。")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.58))

            HStack(spacing: 8) {
                Button("打一张样票", action: printSample)
                Spacer(minLength: 12)
                Button("取消", action: close)
                    .keyboardShortcut(.cancelAction)
                Button(copied ? "已拷贝" : "拷贝提示词", action: copy)
                    .keyboardShortcut(.defaultAction)
                    .disabled(copied)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(width: 360)
        .environment(\.colorScheme, .dark)
    }

    /// Copies, says so for a moment, then gets out of the way: the next step is in the agent.
    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            close()
        }
    }
}
