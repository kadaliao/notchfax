import Foundation
import os
import Testing

@testable import FaxKit

private func line(_ state: LineState, id: String = "L1", role: LineRole = .recipient, updatedAt: Int64 = 10) -> Line {
    Line(id: id, state: state, role: role, myAlias: "A3F2", peerAlias: "9C01", createdAt: 1, updatedAt: updatedAt)
}

private func message(_ id: String, line: String = "L1", from: MessageSender = .peer, sentAt: Int64, text: String = "hi") -> Message {
    Message(id: id, lineId: line, from: from, kind: .text, text: text, sentAt: sentAt)
}

@Suite struct ArchiveTests {
    @Test func `the same message id is only taken once`() {
        var archive = FaxArchive()
        archive.upsert(line(.delivered), at: 0)
        guard case .new = archive.ingest(message("M1", sentAt: 5), at: 6) else { Issue.record("first copy should be new"); return }
        #expect(archive.ingest(message("M1", sentAt: 5), at: 7) == .duplicate)
        #expect(archive.pendingPrints.map(\.id) == ["M1"])
    }

    @Test func `pages go pending, printed, acknowledged`() {
        var archive = FaxArchive()
        _ = archive.ingest(message("M1", sentAt: 5), at: 6)
        _ = archive.ingest(message("M2", sentAt: 4), at: 6)
        #expect(archive.pendingPrints.map(\.id) == ["M2", "M1"], "oldest first")
        archive.markPrinted("M2")
        #expect(archive.pendingPrints.map(\.id) == ["M1"])
        #expect(archive.pendingAcks.map(\.id) == ["M2"])
        archive.markAcknowledged("M2")
        #expect(archive.pendingAcks.isEmpty)
        // Text stays here: the server deletes it on ack.
        #expect(archive.message("M2")?.message.text == "hi")
    }

    @Test func `page numbers count both directions in order`() {
        var archive = FaxArchive()
        archive.upsert(line(.connected), at: 0)
        _ = archive.ingest(message("P1", sentAt: 1), at: 1)
        archive.recordSent(LineMessage(line: line(.connected), message: message("Me1", from: .me, sentAt: 2)), at: 2)
        _ = archive.ingest(message("P2", sentAt: 3), at: 3)
        #expect(archive.page(of: "P1") == 1)
        #expect(archive.page(of: "Me1") == 2)
        #expect(archive.page(of: "P2") == 3)
        #expect(archive.lastPeerMessage(inLine: "L1")?.id == "P2")
        #expect(archive.message("Me1")?.status == .sent)
    }

    @Test func `state changes are reported once, and closed lines never reopen`() {
        var archive = FaxArchive()
        #expect(archive.upsert(line(.delivered), at: 0)?.previous == nil)
        #expect(archive.upsert(line(.delivered), at: 0) == nil)
        #expect(archive.upsert(line(.connected, updatedAt: 20), at: 0)?.previous == .delivered)
        #expect(archive.upsert(line(.delivered, updatedAt: 15), at: 0) == nil, "a late, older snapshot is ignored")
        #expect(archive.upsert(line(.closed, updatedAt: 30), at: 0)?.previous == .connected)
        #expect(archive.upsert(line(.connected, updatedAt: 40), at: 0) == nil)
        #expect(archive.line("L1")?.line.state == .closed)
    }

    @Test func `lines the server no longer lists are closed`() {
        var archive = FaxArchive()
        archive.upsert(line(.connected, id: "A"), at: 0)
        archive.upsert(line(.delivered, id: "B"), at: 0)
        let changes = archive.reconcile(openLines: [line(.connected, id: "A")], at: 0)
        #expect(changes.map(\.line.id) == ["B"])
        #expect(archive.line("B")?.line.state == .closed)
        #expect(archive.openLines.map(\.id) == ["A"])
    }

    @Test func `pruning forgets old closed lines but never an unprinted page`() {
        var archive = FaxArchive()
        archive.upsert(line(.closed, id: "old", updatedAt: 0), at: 0)
        _ = archive.ingest(message("printed", line: "old", sentAt: 0), at: 0)
        archive.markPrinted("printed")
        archive.markAcknowledged("printed")
        archive.upsert(line(.closed, id: "kept", updatedAt: 0), at: 0)
        _ = archive.ingest(message("unprinted", line: "kept", sentAt: 0), at: 0)
        _ = archive.prune(now: 40 * 86_400_000)
        #expect(archive.line("old") == nil)
        #expect(archive.message("printed") == nil)
        #expect(archive.message("unprinted") != nil)
    }
}

@Suite @MainActor struct StoreTests {
    @Test func `the archive and pictures survive a relaunch`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("faxkit-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FaxStore(directory: directory)
        store.update { archive in
            archive.upsert(line(.connected), at: 0)
            _ = archive.ingest(message("M1", sentAt: 1, text: "你好，陌生人"), at: 1)
        }
        let file = try store.writeImage(Data([1, 2, 3]), name: "M1")
        store.update { $0.setImageFile(file, for: "M1") }

        let reopened = FaxStore(directory: directory)
        #expect(reopened.archive == store.archive)
        #expect(reopened.archive.message("M1")?.message.text == "你好，陌生人")
        #expect(reopened.archive.pendingPrints.map(\.id) == ["M1"])
        #expect(reopened.readImage(file) == Data([1, 2, 3]))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("store.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func `an unreadable store is set aside, not overwritten`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("faxkit-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: directory.appendingPathComponent("store.json"))
        let store = FaxStore(directory: directory)
        #expect(store.archive == FaxArchive())
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.contains { $0.hasPrefix("store-unreadable-") })
    }

    @Test func `file names from the server cannot escape the folder`() {
        #expect(FaxStore.safeFileName("../../etc/passwd") == "etcpasswd")
        #expect(FaxStore.safeFileName("6f1c-uuid") == "6f1c-uuid")
    }
}

// MARK: - HTTP client

private final class FakeHTTP: HTTPTransport, Sendable {
    struct Call: Sendable {
        var method: String
        var path: String
        var authorization: String?
        var body: Data?
    }

    let calls = OSAllocatedUnfairLock<[Call]>(initialState: [])
    let handler: @Sendable (Call, Int) -> (Int, String)
    private let counter = OSAllocatedUnfairLock(initialState: 0)

    init(handler: @escaping @Sendable (Call, Int) -> (Int, String)) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let call = Call(
            method: request.httpMethod ?? "GET",
            path: request.url?.path ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            body: request.httpBody
        )
        calls.withLock { $0.append(call) }
        let index = counter.withLock { value -> Int in
            defer { value += 1 }
            return value
        }
        let (status, body) = handler(call, index)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

@Suite struct FaxAPITests {
    static let identity = try! DeviceIdentity(privateKeyRaw: IdentityTests.seed)
    static let now: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_794_400_000) }

    private static func session(_ token: String) -> String {
        #"{ "token": "\#(token)", "expiresAt": 1794486400000, "deviceId": "\#(identity.deviceId)" }"#
    }

    @Test func `the first request opens a signed session and then carries the token`() async throws {
        let http = FakeHTTP { call, _ in
            if call.path == "/v1/session" { return (200, Self.session("T1")) }
            return (200, #"{ "lines": [] }"#)
        }
        let api = FaxAPI(baseURL: URL(string: "http://127.0.0.1:8788")!, identity: Self.identity, transport: http, now: Self.now)
        _ = try await api.lines()
        let calls = http.calls.withLock { $0 }
        #expect(calls.map(\.path) == ["/v1/session", "/v1/lines"])
        #expect(calls[1].authorization == "Bearer T1")
        let body = try JSONDecoder().decode(SessionRequest.self, from: try #require(calls[0].body))
        #expect(body.timestamp == 1_794_400_000_000)
        #expect(body.publicKey == Base64URL.encode(Self.identity.publicKeyRaw))
    }

    @Test func `an expired token is renewed once, transparently`() async throws {
        let http = FakeHTTP { call, index in
            if call.path == "/v1/session" { return (200, Self.session(index == 0 ? "OLD" : "NEW")) }
            if call.authorization == "Bearer OLD" { return (401, #"{ "error": { "code": "token_expired", "message": "x" } }"#) }
            return (204, "")
        }
        let api = FaxAPI(baseURL: URL(string: "http://h")!, identity: Self.identity, transport: http, now: Self.now)
        try await api.ack(messageId: "M1")
        let calls = http.calls.withLock { $0 }
        #expect(calls.map(\.path) == ["/v1/session", "/v1/messages/M1/ack", "/v1/session", "/v1/messages/M1/ack"])
        #expect(calls.last?.authorization == "Bearer NEW")
    }

    @Test func `a protocol error surfaces with its code`() async {
        let http = FakeHTTP { call, _ in
            if call.path == "/v1/session" { return (200, Self.session("T")) }
            return (403, #"{ "error": { "code": "line_not_connected", "message": "images can only be sent on a connected line" } }"#)
        }
        let api = FaxAPI(baseURL: URL(string: "http://h")!, identity: Self.identity, transport: http, now: Self.now)
        await #expect(throws: FaxError.server(code: .lineNotConnected, rawCode: "line_not_connected", status: 403)) {
            _ = try await api.sendImage(lineId: "L1", png: Data([0x89]))
        }
    }

    @Test func `concurrent first requests share one session`() async throws {
        let http = FakeHTTP { call, _ in
            if call.path == "/v1/session" { return (200, Self.session("T")) }
            return (200, #"{ "messages": [], "lines": [] }"#)
        }
        let api = FaxAPI(baseURL: URL(string: "http://h")!, identity: Self.identity, transport: http, now: Self.now)
        async let a = api.inbox()
        async let b = api.inbox()
        _ = try await (a, b)
        #expect(http.calls.withLock { $0.filter { $0.path == "/v1/session" }.count } == 1)
    }

    @Test func `the socket URL swaps the scheme and carries the token`() async throws {
        let http = FakeHTTP { _, _ in (200, Self.session("TOK")) }
        let secure = FaxAPI(baseURL: URL(string: "https://fax.example")!, identity: Self.identity, transport: http, now: Self.now)
        #expect(try await secure.socketURL().absoluteString == "wss://fax.example/v1/socket?token=TOK")
        let local = FaxAPI(baseURL: URL(string: "http://127.0.0.1:8788")!, identity: Self.identity, transport: http, now: Self.now)
        #expect(try await local.socketURL().absoluteString == "ws://127.0.0.1:8788/v1/socket?token=TOK")
    }
}

@Suite struct ComposeRuleTests {
    @Test func `counting follows the server: trimmed, in Unicode scalars`() {
        #expect(ComposeRules.count("  你好  \n") == 2)
        #expect(ComposeRules.count("👍🏽") == 2, "emoji with a modifier is two scalars")
        #expect(ComposeRules.count("") == 0)
        #expect(ComposeRules.prefix("你好世界", scalars: 2) == "你好")
    }
}
