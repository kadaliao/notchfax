import Foundation

/// How the fax line to the server is doing, for the menu.
public enum ConnectionStatus: Sendable, Equatable {
    /// No server is configured; the feature stays quiet.
    case notConfigured
    /// The identity could not be loaded.
    case unavailable
    case connecting
    case online
    /// Waiting before trying again.
    case retrying(at: Date)
    case offline
    case asleep
    /// Another Notchfax with this identity took over the connection.
    case replaced
    case stopped
}

/// Supplies what the socket needs from the HTTP side.
protocol SocketAuthority: Sendable {
    func socketURL() async throws -> URL
    func invalidateSession() async
}

extension FaxAPI: SocketAuthority {}

/// The real-time channel (protocol §4): opens the WebSocket, keeps it alive with the
/// client-initiated heartbeat, reconnects with backoff, pauses across sleep and network
/// loss, and never reconnects by itself after close code 4000.
actor FaxConnection {
    enum Output: Sendable, Equatable {
        case status(ConnectionStatus)
        /// A connection just opened: time to catch up on the inbox.
        case opened
        case event(ServerEvent)
    }

    struct Timing: Sendable {
        var heartbeatInterval: Double = 30
        var heartbeatTimeout: Double = 70
        var backoff = Backoff()
    }

    nonisolated let outputs: AsyncStream<Output>
    private let continuation: AsyncStream<Output>.Continuation
    private let authority: any SocketAuthority
    private let factory: any FaxSocketFactory
    private let timing: Timing
    private let random: @Sendable () -> Double
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    private var machine: ConnectionMachine
    private var generation = 0
    private var socket: (any FaxSocket)?
    private var heartbeat: Heartbeat?
    private var retryAt: Date?
    private var connectTask: Task<Void, Never>?
    private var readerTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var lastStatus: ConnectionStatus?

    init(
        authority: any SocketAuthority,
        factory: any FaxSocketFactory = URLSessionSocketFactory(),
        timing: Timing = Timing(),
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.authority = authority
        self.factory = factory
        self.timing = timing
        self.random = random
        machine = ConnectionMachine()
        machine.backoff = timing.backoff
        origin = clock.now
        (outputs, continuation) = AsyncStream.makeStream(of: Output.self, bufferingPolicy: .unbounded)
    }

    var phase: ConnectionMachine.Phase { machine.phase }

    func start() { handle(.start) }
    func stop() {
        handle(.stop)
        continuation.finish()
    }
    func pause(_ reason: ConnectionMachine.Pauses) { handle(.pause(reason)) }
    func resume(_ reason: ConnectionMachine.Pauses) { handle(.resume(reason)) }
    func reconnectNow() { handle(.reconnectNow) }

    // MARK: Machine

    private func handle(_ event: ConnectionMachine.Event) {
        let effects = machine.handle(event, random: random())
        for effect in effects { perform(effect) }
        publishStatus()
        // Report "online" before asking for the catch-up it triggers.
        if effects.contains(.catchUp) { continuation.yield(.opened) }
    }

    private func perform(_ effect: ConnectionMachine.Effect) {
        switch effect {
        case .connect:
            generation += 1
            let current = generation
            retryAt = nil
            connectTask = Task { await self.connect(generation: current) }
        case .disconnect:
            // Everything still in flight for the old socket is ignored from here on.
            generation += 1
            connectTask?.cancel()
            connectTask = nil
            readerTask?.cancel()
            readerTask = nil
            socket?.close()
            socket = nil
        case .scheduleRetry(let seconds):
            retryTask?.cancel()
            retryAt = Date().addingTimeInterval(seconds)
            let current = generation
            retryTask = Task {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self.retryDue(generation: current)
            }
        case .cancelRetry:
            retryTask?.cancel()
            retryTask = nil
            retryAt = nil
        case .startHeartbeat:
            heartbeat = Heartbeat(openedAt: now, interval: timing.heartbeatInterval, timeout: timing.heartbeatTimeout)
            let current = generation
            heartbeatTask?.cancel()
            heartbeatTask = Task { await self.runHeartbeat(generation: current) }
        case .stopHeartbeat:
            heartbeatTask?.cancel()
            heartbeatTask = nil
            heartbeat = nil
        case .catchUp:
            break
        }
    }

    private func publishStatus() {
        let status: ConnectionStatus = switch machine.phase {
        case .idle, .connecting: .connecting
        case .open: .online
        case .waiting: .retrying(at: retryAt ?? Date())
        case .paused: machine.pauses.contains(.sleeping) ? .asleep : .offline
        case .replaced: .replaced
        case .stopped: .stopped
        }
        guard status != lastStatus else { return }
        lastStatus = status
        continuation.yield(.status(status))
    }

    // MARK: Socket

    private func connect(generation current: Int) async {
        let url: URL
        do {
            url = try await authority.socketURL()
        } catch {
            guard current == generation else { return }
            if FaxError.from(error) == .identityUnavailable {
                // No key, no session: retrying cannot help, and must not ask the key store again.
                handle(.stop)
                lastStatus = .unavailable
                continuation.yield(.status(.unavailable))
                return
            }
            handle(.failed)
            return
        }
        guard current == generation, machine.phase == .connecting, !Task.isCancelled else { return }
        let (socket, signals) = factory.open(url: url)
        self.socket = socket
        readerTask = Task {
            for await signal in signals {
                await self.receive(signal, generation: current)
            }
        }
    }

    private func receive(_ signal: SocketSignal, generation current: Int) async {
        guard current == generation else { return }
        switch signal {
        case .opened:
            handle(.opened)
        case .text(let frame):
            switch ServerEvent.decode(frame: frame) {
            case .pong?:
                heartbeat?.receivedPong(at: now)
            case let event?:
                continuation.yield(.event(event))
            case nil:
                break
            }
        case .closed(let code):
            socket = nil
            handle(.closed(code: code))
        case .failed(let status):
            socket = nil
            if status == 401 { await authority.invalidateSession() }
            guard current == generation else { return }
            handle(.failed)
        }
    }

    private func retryDue(generation current: Int) {
        guard current == generation else { return }
        handle(.retryDue)
    }

    // MARK: Heartbeat

    private var now: Double {
        let elapsed = clock.now - origin
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private func runHeartbeat(generation current: Int) async {
        while !Task.isCancelled {
            guard current == generation, let beat = heartbeat else { return }
            let wait = max(0.01, beat.nextDeadline - now)
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, current == generation else { return }
            switch heartbeat?.poll(at: now) {
            case .ping?:
                if let socket {
                    Task { try? await socket.send(heartbeatPingFrame) }
                }
            case .timedOut?:
                handle(.heartbeatTimedOut)
                return
            case nil:
                break
            }
        }
    }
}
