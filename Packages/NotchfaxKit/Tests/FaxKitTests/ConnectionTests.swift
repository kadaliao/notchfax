import Foundation
import os
import Testing

@testable import FaxKit

@Suite struct BackoffTests {
    @Test func `delays double with equal jitter and stop at the cap`() {
        let backoff = Backoff(base: 1, factor: 2, cap: 60)
        #expect(backoff.delay(attempt: 0, random: 0) == 0.5)
        #expect(backoff.delay(attempt: 0, random: 1) == 1)
        #expect(backoff.delay(attempt: 3, random: 0) == 4)
        #expect(backoff.delay(attempt: 3, random: 0.999) < 8)
        #expect(backoff.delay(attempt: 20, random: 0) == 30)
        #expect(backoff.delay(attempt: 20, random: 1) == 60)
    }

    @Test(arguments: 0..<12)
    func `jitter always stays inside the window`(attempt: Int) {
        let backoff = Backoff()
        for random in stride(from: 0.0, to: 1.0, by: 0.1) {
            let window = min(60, pow(2, Double(attempt)))
            let delay = backoff.delay(attempt: attempt, random: random)
            #expect(delay >= window / 2 && delay <= window)
        }
    }
}

@Suite struct ConnectionMachineTests {
    @Test func `start connects, open starts the heartbeat and a catch-up`() {
        var machine = ConnectionMachine()
        #expect(machine.handle(.start) == [.connect])
        #expect(machine.phase == .connecting)
        #expect(machine.handle(.opened) == [.startHeartbeat, .catchUp])
        #expect(machine.phase == .open)
    }

    @Test func `an unexpected close backs off, then reconnects`() {
        var machine = ConnectionMachine()
        _ = machine.handle(.start)
        _ = machine.handle(.opened)
        #expect(machine.handle(.closed(code: 1006), random: 0) == [.stopHeartbeat, .disconnect, .scheduleRetry(seconds: 0.5)])
        #expect(machine.phase == .waiting)
        #expect(machine.handle(.retryDue) == [.connect])
        // Each failure in a row waits longer.
        #expect(machine.handle(.failed, random: 0) == [.disconnect, .scheduleRetry(seconds: 1)])
        _ = machine.handle(.retryDue)
        #expect(machine.handle(.failed, random: 0) == [.disconnect, .scheduleRetry(seconds: 2)])
        _ = machine.handle(.retryDue)
        _ = machine.handle(.opened)
        #expect(machine.failures == 0)
    }

    @Test func `close code 4000 never reconnects by itself`() {
        var machine = ConnectionMachine()
        _ = machine.handle(.start)
        _ = machine.handle(.opened)
        #expect(machine.handle(.closed(code: 4000)) == [.stopHeartbeat, .disconnect, .cancelRetry])
        #expect(machine.phase == .replaced)
        // Waking up or getting the network back must not bring it back either.
        #expect(machine.handle(.pause(.sleeping)) == [])
        #expect(machine.handle(.resume(.sleeping)) == [])
        #expect(machine.handle(.retryDue) == [])
        #expect(machine.phase == .replaced)
        // Only the person can take the line back.
        #expect(machine.handle(.reconnectNow).last == .connect)
        #expect(machine.phase == .connecting)
    }

    @Test func `sleep closes the socket and waking reconnects at once`() {
        var machine = ConnectionMachine()
        _ = machine.handle(.start)
        _ = machine.handle(.opened)
        #expect(machine.handle(.pause(.sleeping)) == [.stopHeartbeat, .disconnect, .cancelRetry])
        #expect(machine.phase == .paused)
        // A close reported for the old socket while asleep changes nothing.
        #expect(machine.handle(.closed(code: 1006)) == [])
        #expect(machine.handle(.resume(.sleeping)) == [.connect])
        #expect(machine.phase == .connecting)
    }

    @Test func `both sleep and network loss must clear before reconnecting`() {
        var machine = ConnectionMachine()
        _ = machine.handle(.start)
        _ = machine.handle(.failed, random: 0)
        #expect(machine.handle(.pause(.offline)) == [.stopHeartbeat, .disconnect, .cancelRetry])
        _ = machine.handle(.pause(.sleeping))
        #expect(machine.handle(.resume(.sleeping)) == [])
        #expect(machine.handle(.resume(.offline)) == [.connect])
        #expect(machine.failures == 0)
    }

    @Test func `starting while offline waits for the network`() {
        var machine = ConnectionMachine()
        _ = machine.handle(.pause(.offline))
        #expect(machine.handle(.start) == [])
        #expect(machine.phase == .paused)
        #expect(machine.handle(.resume(.offline)) == [.connect])
    }

    @Test func `a missed heartbeat is treated as a dead connection`() {
        var machine = ConnectionMachine()
        _ = machine.handle(.start)
        _ = machine.handle(.opened)
        #expect(machine.handle(.heartbeatTimedOut, random: 0) == [.stopHeartbeat, .disconnect, .scheduleRetry(seconds: 0.5)])
    }

    @Test func `stop is final until started again`() {
        var machine = ConnectionMachine()
        _ = machine.handle(.start)
        #expect(machine.handle(.stop) == [.stopHeartbeat, .disconnect, .cancelRetry])
        #expect(machine.handle(.retryDue) == [])
        #expect(machine.handle(.resume(.sleeping)) == [])
        #expect(machine.handle(.start) == [.connect])
    }
}

@Suite struct HeartbeatTests {
    @Test func `pings every 30 seconds`() {
        var beat = Heartbeat(openedAt: 100)
        #expect(beat.poll(at: 110) == nil)
        #expect(beat.poll(at: 130) == .ping)
        #expect(beat.poll(at: 131) == nil)
        beat.receivedPong(at: 130.05)
        #expect(beat.poll(at: 160) == .ping)
        #expect(beat.nextDeadline == 190)
    }

    @Test func `seventy seconds without a pong times out`() {
        var beat = Heartbeat(openedAt: 0)
        #expect(beat.poll(at: 30) == .ping)
        beat.receivedPong(at: 30)
        #expect(beat.poll(at: 60) == .ping)
        #expect(beat.poll(at: 90) == .ping)
        #expect(beat.poll(at: 99.9) == nil)
        #expect(beat.poll(at: 100) == .timedOut)
    }
}

// MARK: - FaxConnection with a fake transport

private final class FakeAuthority: SocketAuthority, Sendable {
    let invalidations = OSAllocatedUnfairLock(initialState: 0)
    let failNext = OSAllocatedUnfairLock(initialState: 0)

    func socketURL() async throws -> URL {
        let fail = failNext.withLock { count -> Bool in
            defer { count = max(0, count - 1) }
            return count > 0
        }
        if fail { throw FaxError.network(.cannotConnectToHost) }
        return URL(string: "ws://fake.invalid/v1/socket?token=t")!
    }

    func invalidateSession() async {
        invalidations.withLock { $0 += 1 }
    }
}

private final class FakeSocket: FaxSocket, Sendable {
    let continuation: AsyncStream<SocketSignal>.Continuation
    let sent = OSAllocatedUnfairLock<[String]>(initialState: [])
    let closed = OSAllocatedUnfairLock(initialState: false)
    /// Answer pings with pongs, like the server's auto-response.
    let answersPings: Bool

    init(continuation: AsyncStream<SocketSignal>.Continuation, answersPings: Bool) {
        self.continuation = continuation
        self.answersPings = answersPings
    }

    func send(_ text: String) async throws {
        sent.withLock { $0.append(text) }
        if answersPings, text == #"{"type":"ping"}"# { continuation.yield(.text(#"{"type":"pong"}"#)) }
    }

    func close() {
        closed.withLock { $0 = true }
        continuation.finish()
    }
}

private final class FakeFactory: FaxSocketFactory, Sendable {
    let sockets = OSAllocatedUnfairLock<[FakeSocket]>(initialState: [])
    let answersPings: Bool
    let opensImmediately: Bool

    init(answersPings: Bool = true, opensImmediately: Bool = true) {
        self.answersPings = answersPings
        self.opensImmediately = opensImmediately
    }

    func open(url: URL) -> (socket: any FaxSocket, signals: AsyncStream<SocketSignal>) {
        let (stream, continuation) = AsyncStream.makeStream(of: SocketSignal.self)
        let socket = FakeSocket(continuation: continuation, answersPings: answersPings)
        sockets.withLock { $0.append(socket) }
        if opensImmediately { continuation.yield(.opened) }
        return (socket, stream)
    }

    var count: Int { sockets.withLock { $0.count } }
    var last: FakeSocket? { sockets.withLock { $0.last } }
}

/// Waits for a condition, polling; fails the test after `timeout`. Generous on purpose: it returns as
/// soon as the condition holds, and CI machines run every suite in parallel on few cores.
private func eventually(_ timeout: Double = 10, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@Suite struct FaxConnectionTests {
    private static let fast = FaxConnection.Timing(heartbeatInterval: 0.05, heartbeatTimeout: 0.2, backoff: Backoff(base: 0.02, factor: 2, cap: 0.08))

    @Test func `opens, reports online and asks for a catch-up`() async {
        let factory = FakeFactory()
        let connection = FaxConnection(authority: FakeAuthority(), factory: factory, timing: Self.fast, random: { 0 })
        let outputs = Task {
            var seen: [FaxConnection.Output] = []
            for await output in connection.outputs {
                seen.append(output)
                if output == .opened { break }
            }
            return seen
        }
        await connection.start()
        let seen = await outputs.value
        #expect(seen.contains(.status(.online)))
        #expect(seen.last == .opened)
        await connection.stop()
    }

    @Test func `an unexpected close reconnects after a backoff`() async {
        let factory = FakeFactory()
        let connection = FaxConnection(authority: FakeAuthority(), factory: factory, timing: Self.fast, random: { 0 })
        await connection.start()
        #expect(await eventually { await connection.phase == .open })
        factory.last?.continuation.yield(.closed(code: 1006))
        #expect(await eventually { factory.count == 2 })
        #expect(await eventually { await connection.phase == .open })
        await connection.stop()
    }

    @Test func `close code 4000 stays down`() async {
        let factory = FakeFactory()
        let connection = FaxConnection(authority: FakeAuthority(), factory: factory, timing: Self.fast, random: { 0 })
        await connection.start()
        #expect(await eventually { await connection.phase == .open })
        factory.last?.continuation.yield(.closed(code: 4000))
        #expect(await eventually { await connection.phase == .replaced })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(factory.count == 1, "must not reconnect after being replaced")
        await connection.reconnectNow()
        #expect(await eventually { factory.count == 2 })
        await connection.stop()
    }

    @Test func `heartbeats are the exact ping frame and pongs keep the line up`() async {
        let factory = FakeFactory(answersPings: true)
        // A pong crosses a few tasks and the actor before it counts. On a loaded CI machine that once
        // took longer than the 0.2 s `fast` allows, so give it 0.6 s here, and then keep watching for
        // more than twice that: pongs that were ignored would still force a reconnect in that time.
        var timing = Self.fast
        timing.heartbeatTimeout = 0.6
        let connection = FaxConnection(authority: FakeAuthority(), factory: factory, timing: timing, random: { 0 })
        await connection.start()
        #expect(await eventually { (factory.last?.sent.withLock { $0.count } ?? 0) >= 3 })
        try? await Task.sleep(for: .seconds(1.5))
        let sent = factory.last?.sent.withLock { $0 } ?? []
        #expect(sent.allSatisfy { $0 == #"{"type":"ping"}"# })
        #expect(factory.count == 1, "answered pings must not trigger a reconnect")
        await connection.stop()
    }

    @Test func `no pong within the timeout drops and reconnects`() async {
        let factory = FakeFactory(answersPings: false)
        let connection = FaxConnection(authority: FakeAuthority(), factory: factory, timing: Self.fast, random: { 0 })
        await connection.start()
        #expect(await eventually { factory.count >= 2 })
        #expect(factory.sockets.withLock { $0.first?.closed.withLock { $0 } } == true)
        await connection.stop()
    }

    @Test func `a refused handshake with 401 renews the session before retrying`() async {
        let factory = FakeFactory(opensImmediately: false)
        let authority = FakeAuthority()
        let connection = FaxConnection(authority: authority, factory: factory, timing: Self.fast, random: { 0 })
        await connection.start()
        #expect(await eventually { factory.count == 1 })
        factory.last?.continuation.yield(.failed(httpStatus: 401))
        #expect(await eventually { authority.invalidations.withLock { $0 } == 1 })
        #expect(await eventually { factory.count == 2 })
        await connection.stop()
    }

    @Test func `no session yet means a retry, not a crash`() async {
        let factory = FakeFactory()
        let authority = FakeAuthority()
        authority.failNext.withLock { $0 = 2 }
        let connection = FaxConnection(authority: authority, factory: factory, timing: Self.fast, random: { 0 })
        await connection.start()
        #expect(await eventually { await connection.phase == .open })
        #expect(factory.count == 1)
        await connection.stop()
    }

    @Test func `sleep closes, wake opens a fresh socket`() async {
        let factory = FakeFactory()
        let connection = FaxConnection(authority: FakeAuthority(), factory: factory, timing: Self.fast, random: { 0 })
        await connection.start()
        #expect(await eventually { await connection.phase == .open })
        await connection.pause(.sleeping)
        #expect(factory.last?.closed.withLock { $0 } == true)
        #expect(await connection.phase == .paused)
        await connection.resume(.sleeping)
        #expect(await eventually { factory.count == 2 })
        #expect(await eventually { await connection.phase == .open })
        await connection.stop()
    }

    @Test func `events from the server come through in order`() async {
        let factory = FakeFactory()
        let connection = FaxConnection(authority: FakeAuthority(), factory: factory, timing: Self.fast, random: { 0 })
        let collected = Task {
            var events: [ServerEvent] = []
            for await output in connection.outputs {
                if case .event(let event) = output { events.append(event) }
                if events.count == 2 { break }
            }
            return events
        }
        await connection.start()
        #expect(await eventually { await connection.phase == .open })
        let line = ProtocolDecodingTests.lineJSON
        factory.last?.continuation.yield(.text(#"{ "type": "line.updated", "line": \#(line) }"#))
        factory.last?.continuation.yield(.text(#"{ "type": "fax", "line": \#(line), "message": \#(ProtocolDecodingTests.textJSON) }"#))
        let events = await collected.value
        guard case .lineUpdated? = events.first, case .fax? = events.last else {
            Issue.record("unexpected order: \(events)")
            return
        }
        await connection.stop()
    }
}
