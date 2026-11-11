import AppKit
import PrintKit

/// 传真: anonymous faxes to strangers, printed on thermal paper out of the notch.
///
/// Launch arguments are read straight from the command line (see `FaxLaunchOptions`
/// and `FaxDebugScript`), so the app shell needs no changes for them.
@MainActor
public final class FaxFeature: FeatureModule {
    private let controller: FaxController
    private let launch: FaxLaunchOptions

    public init(printer: Printer) {
        launch = FaxLaunchOptions(arguments: CommandLine.arguments)
        controller = FaxController(printer: printer, launch: launch)
        printer.menu.addSection(id: "fax", order: 30) { [weak controller] in
            controller?.menuEntries() ?? []
        }
    }

    public func start() {
        if let directory = launch.renderSamplesDirectory {
            // `--fax-render-samples <dir>`: draw sample pages offscreen, then quit.
            do {
                for url in try FaxSamples.render(to: URL(fileURLWithPath: directory, isDirectory: true)) {
                    print(url.path)
                }
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("渲染传真样张失败：\(error.localizedDescription)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        controller.start()
    }
}
