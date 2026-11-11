import Foundation

/// Exponential backoff with "equal jitter": half of each window is fixed and half is
/// random, so retries never hammer the server in lock-step yet never fire instantly.
struct Backoff: Sendable, Equatable {
    var base: Double = 1
    var factor: Double = 2
    var cap: Double = 60

    /// Seconds to wait before retry number `attempt` (0-based), for `random` in 0..<1.
    func delay(attempt: Int, random: Double) -> Double {
        let window = min(cap, base * pow(factor, Double(max(0, attempt))))
        return window / 2 + window / 2 * min(max(random, 0), 1)
    }
}

/// The life of the real-time connection, as a pure state machine: events in, effects
/// out. `FaxConnection` performs the effects; tests drive this directly.
struct ConnectionMachine: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        /// Not started yet.
        case idle
        case connecting
        case open
        /// Waiting out a backoff before the next attempt.
        case waiting
        /// The Mac is asleep or offline; resumes on its own.
        case paused
        /// Closed with code 4000: another connection with the same identity took over.
        /// Never reconnects on its own, or two instances would keep kicking each other off.
        case replaced
        case stopped
    }

    struct Pauses: OptionSet, Sendable, Hashable {
        let rawValue: Int
        static let sleeping = Pauses(rawValue: 1 << 0)
        static let offline = Pauses(rawValue: 1 << 1)
    }

    enum Event: Sendable, Equatable {
        case start
        case opened
        /// The attempt never opened (no session, handshake refused, unreachable).
        case failed
        /// An open (or opening) socket closed. `code` is the WebSocket close code, if any.
        case closed(code: Int?)
        case heartbeatTimedOut
        case retryDue
        case pause(Pauses)
        case resume(Pauses)
        /// The user asked to reconnect, for example after being replaced.
        case reconnectNow
        case stop
    }

    enum Effect: Sendable, Equatable {
        case connect
        case disconnect
        case scheduleRetry(seconds: Double)
        case cancelRetry
        case startHeartbeat
        case stopHeartbeat
        /// Fetch the inbox and line states: run after every successful connect.
        case catchUp
    }

    /// The close code the server uses when a newer connection replaces this one.
    static let replacedCloseCode = 4000

    private(set) var phase: Phase = .idle
    private(set) var pauses: Pauses = []
    /// Consecutive attempts that failed since the last successful open.
    private(set) var failures = 0
    var backoff = Backoff()

    mutating func handle(_ event: Event, random: Double = Double.random(in: 0..<1)) -> [Effect] {
        switch event {
        case .start:
            guard phase == .idle || phase == .stopped else { return [] }
            failures = 0
            if !pauses.isEmpty {
                phase = .paused
                return []
            }
            phase = .connecting
            return [.connect]

        case .opened:
            guard phase == .connecting else { return [] }
            phase = .open
            failures = 0
            return [.startHeartbeat, .catchUp]

        case .failed:
            guard phase == .connecting else { return [] }
            return retry(random: random, effects: [.disconnect])

        case .closed(let code):
            guard phase == .open || phase == .connecting else { return [] }
            if code == Self.replacedCloseCode {
                phase = .replaced
                return [.stopHeartbeat, .disconnect, .cancelRetry]
            }
            return retry(random: random, effects: [.stopHeartbeat, .disconnect])

        case .heartbeatTimedOut:
            guard phase == .open else { return [] }
            return retry(random: random, effects: [.stopHeartbeat, .disconnect])

        case .retryDue:
            guard phase == .waiting else { return [] }
            phase = .connecting
            return [.connect]

        case .pause(let reason):
            pauses.insert(reason)
            switch phase {
            case .connecting, .open, .waiting:
                phase = .paused
                return [.stopHeartbeat, .disconnect, .cancelRetry]
            case .idle, .paused, .replaced, .stopped:
                return []
            }

        case .resume(let reason):
            pauses.remove(reason)
            guard pauses.isEmpty, phase == .paused else { return [] }
            // Waking up or getting the network back is a fresh start, not another failure.
            failures = 0
            phase = .connecting
            return [.connect]

        case .reconnectNow:
            switch phase {
            case .idle, .stopped, .paused, .connecting:
                return []
            case .open, .waiting, .replaced:
                failures = 0
                phase = .connecting
                return [.stopHeartbeat, .disconnect, .cancelRetry, .connect]
            }

        case .stop:
            guard phase != .stopped else { return [] }
            phase = .stopped
            return [.stopHeartbeat, .disconnect, .cancelRetry]
        }
    }

    private mutating func retry(random: Double, effects: [Effect]) -> [Effect] {
        let delay = backoff.delay(attempt: failures, random: random)
        failures += 1
        phase = .waiting
        return effects + [.scheduleRetry(seconds: delay)]
    }
}

/// Client-initiated heartbeat (protocol §4): a ping every 30 s; no pong for 70 s means
/// the connection is dead. Times are seconds on a monotonic clock.
struct Heartbeat: Sendable, Equatable {
    enum Action: Sendable, Equatable { case ping, timedOut }

    var interval: Double = 30
    var timeout: Double = 70
    private(set) var lastPingAt: Double
    private(set) var lastPongAt: Double

    init(openedAt: Double, interval: Double = 30, timeout: Double = 70) {
        self.interval = interval
        self.timeout = timeout
        lastPingAt = openedAt
        lastPongAt = openedAt
    }

    mutating func receivedPong(at time: Double) {
        lastPongAt = max(lastPongAt, time)
    }

    /// What is due at `time`. A ping that is due is considered sent.
    mutating func poll(at time: Double) -> Action? {
        if time - lastPongAt >= timeout { return .timedOut }
        if time - lastPingAt >= interval {
            lastPingAt = time
            return .ping
        }
        return nil
    }

    /// When `poll` next has something to do.
    var nextDeadline: Double {
        min(lastPingAt + interval, lastPongAt + timeout)
    }
}
