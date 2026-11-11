import Foundation
import os

/// What happens on one WebSocket, in order. The stream ends after `.closed` or `.failed`.
enum SocketSignal: Sendable, Equatable {
    case opened
    case text(String)
    /// An open socket closed; `code` is the close code if the peer sent one.
    case closed(code: Int?)
    /// The socket never opened. `httpStatus` is the handshake response status, if any.
    case failed(httpStatus: Int?)
}

protocol FaxSocket: Sendable {
    func send(_ text: String) async throws
    /// Closes from this side. No further signals are delivered for this socket.
    func close()
}

protocol FaxSocketFactory: Sendable {
    func open(url: URL) -> (socket: any FaxSocket, signals: AsyncStream<SocketSignal>)
}

struct URLSessionSocketFactory: FaxSocketFactory {
    func open(url: URL) -> (socket: any FaxSocket, signals: AsyncStream<SocketSignal>) {
        let (stream, continuation) = AsyncStream.makeStream(of: SocketSignal.self, bufferingPolicy: .unbounded)
        let socket = URLSessionFaxSocket(url: url, continuation: continuation)
        socket.start()
        return (socket, stream)
    }
}

/// `URLSessionWebSocketTask` with its delegate callbacks folded into one ordered stream.
///
/// `@unchecked Sendable`: the only mutable state is behind `state`'s lock; `session`
/// and `task` are assigned once in `init` and never change.
final class URLSessionFaxSocket: NSObject, FaxSocket, URLSessionWebSocketDelegate, @unchecked Sendable {
    private struct State {
        var opened = false
        var finished = false
    }

    private let continuation: AsyncStream<SocketSignal>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!

    init(url: URL, continuation: AsyncStream<SocketSignal>.Continuation) {
        self.continuation = continuation
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 1 << 20
    }

    func start() {
        task.resume()
        receiveNext()
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func close() {
        let first = state.withLock { state -> Bool in
            defer { state.finished = true }
            return !state.finished
        }
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
        if first { continuation.finish() }
    }

    private func receiveNext() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                self.yield(.text(text))
                self.receiveNext()
            case .success(.data(let data)):
                self.yield(.text(String(decoding: data, as: UTF8.self)))
                self.receiveNext()
            case .success:
                self.receiveNext()
            case .failure:
                // The close frame's code may only be reported by the delegate a moment later.
                let code = self.task.closeCode
                if code != .invalid {
                    self.finish(closeCode: code.rawValue)
                } else {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                        let late = self.task.closeCode
                        self.finish(closeCode: late == .invalid ? nil : late.rawValue)
                    }
                }
            }
        }
    }

    private func yield(_ signal: SocketSignal) {
        let live = state.withLock { !$0.finished }
        if live { continuation.yield(signal) }
    }

    private func finish(closeCode: Int?) {
        let outcome = state.withLock { state -> (first: Bool, opened: Bool) in
            defer { state.finished = true }
            return (!state.finished, state.opened)
        }
        guard outcome.first else { return }
        if outcome.opened {
            continuation.yield(.closed(code: closeCode))
        } else {
            let status = (task.response as? HTTPURLResponse)?.statusCode
            continuation.yield(.failed(httpStatus: status))
        }
        continuation.finish()
        session.finishTasksAndInvalidate()
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        let live = state.withLock { state -> Bool in
            state.opened = true
            return !state.finished
        }
        if live { continuation.yield(.opened) }
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        finish(closeCode: closeCode.rawValue)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let code = self.task.closeCode
        finish(closeCode: code == .invalid ? nil : code.rawValue)
    }
}
