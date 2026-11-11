import SwiftUI

/// Asks a relay whether it is there, without identifying this Mac.
enum ServerCheck {
    enum Result: Equatable {
        case reachable
        case failed(String)
    }

    static func run(_ url: URL) async -> Result {
        var request = URLRequest(url: url.appendingPathComponent("healthz"))
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed("对方没有按预期回应") }
            return http.statusCode == 200 ? .reachable : .failed("对方回应了 \(http.statusCode)，不像是传真服务器")
        } catch let error as URLError {
            switch error.code {
            case .timedOut: return .failed("等了 8 秒没有回应")
            case .cannotFindHost, .dnsLookupFailed: return .failed("找不到这个地址")
            case .cannotConnectToHost: return .failed("那边没有服务在听")
            case .notConnectedToInternet, .networkConnectionLost: return .failed("这台 Mac 现在没有网络")
            case .secureConnectionFailed, .serverCertificateUntrusted: return .failed("安全连接建立不了")
            default: return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

@MainActor
@Observable
final class ServerSettingsModel {
    enum Status: Equatable {
        case untested, checking, reachable
        case failed(String)
    }

    var address: String { didSet { if address != oldValue { status = .untested } } }
    var status: Status = .untested
    let inUse: URL?
    let overriddenByLaunch: Bool
    /// An address was saved before this panel opened; emptying the field then means clearing it.
    let hadSavedAddress: Bool

    init(address: String, inUse: URL?, overriddenByLaunch: Bool) {
        self.address = address
        hadSavedAddress = !address.isEmpty
        self.inUse = inUse
        self.overriddenByLaunch = overriddenByLaunch
    }

    private var trimmed: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The address as a URL; a bare host is taken to mean https.
    var url: URL? {
        guard !trimmed.isEmpty else { return nil }
        return FaxLaunchOptions.validServer(trimmed.contains("://") ? trimmed : "https://" + trimmed)
    }

    var isEmpty: Bool { trimmed.isEmpty }
    var canSave: Bool { isEmpty ? hadSavedAddress : url != nil }

    func check() {
        guard let url, status != .checking else { return }
        status = .checking
        let asked = address
        Task {
            let result = await ServerCheck.run(url)
            // The address may have been edited while the request was out.
            guard address == asked else { return }
            status = result == .reachable ? .reachable : { if case .failed(let why) = result { return .failed(why) } else { return .untested } }()
        }
    }
}

/// Server address and a connection check, in the machine's own black.
struct ServerSettingsView: View {
    @Bindable var model: ServerSettingsModel
    let save: (URL?) -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("传真服务器")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("传真经由一台中继服务器转交。部署好以后，把它的地址贴在这里。")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("https://…", text: $model.address)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white)
                .autocorrectionDisabled()
                .focused($focused)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.09)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(focused ? 0.28 : 0.12), lineWidth: 1))
                .onSubmit { if model.url != nil { model.check() } }
            statusLine
            HStack(spacing: 8) {
                Button("检查连接") { model.check() }
                    .disabled(model.url == nil || model.status == .checking)
                Spacer(minLength: 12)
                Button("取消", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(model.isEmpty && model.hadSavedAddress ? "清除" : "保存") { save(model.url) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(width: 318)
        .environment(\.colorScheme, .dark)
        .onAppear { focused = true }
    }

    private var statusLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch model.status {
            case .checking:
                ProgressView().controlSize(.mini)
            case .reachable:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(red: 0.36, green: 0.82, blue: 0.47))
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(red: 1, green: 0.66, blue: 0.24))
            case .untested:
                Image(systemName: "circle.dotted").foregroundStyle(.white.opacity(0.4))
            }
            Text(statusText)
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .frame(minHeight: 28, alignment: .topLeading)
        .animation(.easeOut(duration: 0.15), value: model.status)
    }

    private var statusText: String {
        switch model.status {
        case .checking: return "正在连接…"
        case .reachable: return "连得上。保存后马上改用这台服务器。"
        case .failed(let why): return "连不上：\(why)"
        case .untested:
            if !model.isEmpty, model.url == nil { return "这不像一个网址。以 https:// 开头，或直接写域名。" }
            if model.overriddenByLaunch, let inUse = model.inUse {
                return "这次运行由启动参数指定了 \(inUse.absoluteString)，保存的地址下次启动生效。"
            }
            if model.isEmpty, let inUse = model.inUse { return "没有填写。调试版默认连接 \(inUse.absoluteString)。" }
            if model.isEmpty { return "没有填写。传真功能暂时不可用。" }
            return "还没有检查过这个地址。"
        }
    }
}
