import AppKit
import PrintKit

let application = NSApplication.shared
let arguments = CommandLine.arguments

// `--render-gallery <dir>`: draw every paper type to PNG offscreen, then exit.
if let index = arguments.firstIndex(of: "--render-gallery") {
    let path = index + 1 < arguments.count ? arguments[index + 1] : "gallery"
    do {
        for url in try Gallery.render(to: URL(fileURLWithPath: path, isDirectory: true)) {
            print(url.path)
        }
        exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(Data("渲染样张失败：\(error.localizedDescription)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

let delegate = AppDelegate(launch: LaunchOptions(arguments: arguments))
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
