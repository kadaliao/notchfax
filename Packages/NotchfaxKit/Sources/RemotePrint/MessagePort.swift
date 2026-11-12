import CoreFoundation
import Foundation

/// The app's end: a named local message port on the main run loop. Each request is
/// answered synchronously by `handler`, which runs on the main actor.
@MainActor
final class PrintPortServer {
    private let name: String
    private let handler: @MainActor (Data) -> Data
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?

    init(name: String = Wire.portName, handler: @escaping @MainActor (Data) -> Data) {
        self.name = name
        self.handler = handler
    }

    /// False when another process already holds the name (a second copy of the app).
    func start() -> Bool {
        guard port == nil else { return true }
        var context = CFMessagePortContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        var shouldFreeInfo: DarwinBoolean = false
        let callback: CFMessagePortCallBack = { _, _, data, info in
            guard let info else { return nil }
            let server = Unmanaged<PrintPortServer>.fromOpaque(info).takeUnretainedValue()
            let request = data.map { $0 as Data } ?? Data()
            // The source is scheduled on the main run loop, so this is the main thread.
            let reply = MainActor.assumeIsolated { server.handler(request) }
            // The port releases the reply once it has been sent.
            return Unmanaged.passRetained(reply as CFData)
        }
        guard let port = CFMessagePortCreateLocal(nil, name as CFString, callback, &context, &shouldFreeInfo),
              // Set when this process already has a port by that name and got it back unchanged.
              !shouldFreeInfo.boolValue else {
            return false
        }
        let source = CFMessagePortCreateRunLoopSource(nil, port, 0)
        // Common modes: requests are still served while a menu is open.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.port = port
        self.source = source
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMessagePortInvalidate(port) }
        port = nil
        source = nil
    }
}

/// The command line's end.
enum PrintPortClient {
    enum Failure: Error, Equatable {
        /// Nobody has registered the port: the app is not running (or is too old to listen).
        case notListening
        case timedOut
        case transport(Int32)
    }

    static func isListening(name: String = Wire.portName) -> Bool {
        CFMessagePortCreateRemote(nil, name as CFString) != nil
    }

    static func send(_ data: Data, name: String = Wire.portName, timeout: TimeInterval = 15) throws(Failure) -> Data {
        guard let remote = CFMessagePortCreateRemote(nil, name as CFString) else { throw .notListening }
        defer { CFMessagePortInvalidate(remote) }
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(
            remote, Wire.printMessage, data as CFData,
            timeout, timeout, CFRunLoopMode.defaultMode.rawValue, &reply
        )
        switch status {
        case kCFMessagePortSuccess:
            return reply.map { $0.takeRetainedValue() as Data } ?? Data()
        case kCFMessagePortSendTimeout, kCFMessagePortReceiveTimeout:
            throw .timedOut
        case kCFMessagePortIsInvalid:
            throw .notListening
        default:
            throw .transport(status)
        }
    }
}
