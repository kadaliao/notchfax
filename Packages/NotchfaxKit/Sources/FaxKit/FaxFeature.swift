import AppKit
import PrintKit

/// 传真: anonymous faxes to strangers, printed on thermal paper out of the notch.
///
/// Launch arguments are read straight from the command line (see `FaxLaunchOptions`
/// and `FaxDebugScript`), so the app shell needs no changes for them.
@MainActor
public final class FaxFeature: FeatureModule {
    private let printer: Printer
    private let launch: FaxLaunchOptions
    private var controller: FaxController
    private var settings: SlotPresentation?

    public init(printer: Printer) {
        self.printer = printer
        launch = FaxLaunchOptions(arguments: CommandLine.arguments)
        controller = FaxController(printer: printer, launch: launch)
        printer.menu.addSection(id: "fax", order: 30) { [weak self] in
            guard let self else { return [] }
            return self.controller.menuEntries() + [
                .action("传真服务器…", systemImage: "network") { [weak self] in self?.openServerSettings() },
            ]
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
        if launch.showsServerSettings {
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                openServerSettings()
            }
        }
    }

    // MARK: Server

    /// A small panel under the slot: the relay's address, and whether it answers.
    private func openServerSettings() {
        guard settings == nil else { return }
        let defaults = UserDefaults.standard
        let model = ServerSettingsModel(
            address: defaults.string(forKey: FaxEnvironment.serverDefaultsKey) ?? "",
            inUse: controller.environment.server,
            overriddenByLaunch: launch.server != nil
        )
        settings = printer.present(options: .init(
            chrome: .machine,
            acceptsKeyboard: true,
            onDismiss: { [weak self] in self?.settings = nil }
        )) { [weak self] presentation in
            ServerSettingsView(model: model) { url in
                self?.useServer(url)
                presentation.dismiss()
            } cancel: {
                presentation.dismiss()
            }
        }
    }

    /// Saves the address and reconnects with it at once.
    private func useServer(_ url: URL?) {
        let defaults = UserDefaults.standard
        if let url {
            defaults.set(url.absoluteString, forKey: FaxEnvironment.serverDefaultsKey)
        } else {
            defaults.removeObject(forKey: FaxEnvironment.serverDefaultsKey)
        }
        // A server given on the command line wins for this run; the saved one applies next time.
        guard launch.server == nil else { return }
        controller.stop()
        controller = FaxController(printer: printer, launch: launch)
        controller.start()
    }
}
