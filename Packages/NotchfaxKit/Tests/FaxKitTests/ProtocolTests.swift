import CryptoKit
import Foundation
import os
import Testing

@testable import FaxKit

@Suite struct ProtocolDecodingTests {
    // The examples of docs/protocol.md, verbatim where the document gives them.
    static let lineJSON = #"{ "id": "L1", "state": "delivered", "role": "initiator", "myAlias": "A3F2", "peerAlias": "9C01", "createdAt": 1794400000000, "updatedAt": 1794400000500 }"#
    static let textJSON = #"{ "id": "M1", "lineId": "L1", "from": "me", "kind": "text", "text": "你好，陌生人", "sentAt": 1794400000000 }"#
    static let imageJSON = #"{ "id": "M2", "lineId": "L1", "from": "peer", "kind": "image", "imageId": "I1", "width": 384, "height": 512, "sentAt": 0 }"#

    @Test func `a line decodes with every field`() throws {
        let line = try JSONDecoder().decode(Line.self, from: Data(Self.lineJSON.utf8))
        #expect(line == Line(id: "L1", state: .delivered, role: .initiator, myAlias: "A3F2", peerAlias: "9C01", createdAt: 1_794_400_000_000, updatedAt: 1_794_400_000_500))
    }

    @Test func `a queued line has no peer alias yet`() throws {
        let json = #"{ "id": "L", "state": "queued", "role": "initiator", "myAlias": "A3F2", "peerAlias": null, "createdAt": 0, "updatedAt": 0 }"#
        let line = try JSONDecoder().decode(Line.self, from: Data(json.utf8))
        #expect(line.peerAlias == nil)
        #expect(line.state == .queued)
        #expect(!line.canSendText)
    }

    @Test func `text and image messages decode`() throws {
        let text = try JSONDecoder().decode(Message.self, from: Data(Self.textJSON.utf8))
        #expect(text.kind == .text && text.text == "你好，陌生人" && text.from == .me && text.imageId == nil)
        let image = try JSONDecoder().decode(Message.self, from: Data(Self.imageJSON.utf8))
        #expect(image.kind == .image && image.imageId == "I1" && image.width == 384 && image.height == 512 && image.text == nil)
    }

    @Test func `the send response pairs a line and a message`() throws {
        let json = #"{ "line": \#(Self.lineJSON), "message": \#(Self.textJSON) }"#
        let sent = try JSONDecoder().decode(LineMessage.self, from: Data(json.utf8))
        #expect(sent.line.id == "L1" && sent.message.id == "M1")
    }

    @Test func `me, inbox and lines decode`() throws {
        let me = try JSONDecoder().decode(Me.self, from: Data(#"{ "deviceId": "d", "quota": { "newFaxesLeft": 3, "newFaxesPerDay": 3, "resetsAt": 1794441600000 }, "suspendedUntil": null }"#.utf8))
        #expect(me.quota.newFaxesLeft == 3 && me.suspendedUntil == nil)
        let inbox = try JSONDecoder().decode(Inbox.self, from: Data(#"{ "messages": [\#(Self.imageJSON)], "lines": [\#(Self.lineJSON)] }"#.utf8))
        #expect(inbox.messages.count == 1 && inbox.lines.count == 1)
        let lines = try JSONDecoder().decode(LinesEnvelope.self, from: Data(#"{ "lines": [\#(Self.lineJSON)] }"#.utf8))
        #expect(lines.lines.first?.myAlias == "A3F2")
    }

    @Test func `socket frames decode to events`() {
        #expect(ServerEvent.decode(frame: #"{"type":"pong"}"#) == .pong)
        let fax = ServerEvent.decode(frame: #"{ "type": "fax", "line": \#(Self.lineJSON), "message": \#(Self.imageJSON) }"#)
        guard case .fax(let line, let message)? = fax else { Issue.record("not a fax: \(String(describing: fax))"); return }
        #expect(line.id == "L1" && message.id == "M2")
        let updated = ServerEvent.decode(frame: #"{ "type": "line.updated", "line": \#(Self.lineJSON) }"#)
        guard case .lineUpdated(let changed)? = updated else { Issue.record("not line.updated"); return }
        #expect(changed.state == .delivered)
    }

    @Test func `unknown and malformed frames never crash`() {
        #expect(ServerEvent.decode(frame: #"{"type":"hello"}"#) == .unknown(type: "hello"))
        #expect(ServerEvent.decode(frame: "not json") == nil)
        #expect(ServerEvent.decode(frame: #"{"type":"fax"}"#) == nil)
    }

    @Test func `the heartbeat frame is byte-for-byte the documented one`() {
        #expect(Array(heartbeatPingFrame.utf8) == Array(#"{"type":"ping"}"#.utf8))
    }

    @Test func `request bodies use the documented field names`() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(String(decoding: try encoder.encode(TextBody(text: "hi")), as: UTF8.self) == #"{"text":"hi"}"#)
        #expect(String(decoding: try encoder.encode(TearBody(report: true)), as: UTF8.self) == #"{"report":true}"#)
        let session = SessionRequest(publicKey: "pk", timestamp: 1_794_400_000_000, signature: "sig")
        #expect(String(decoding: try encoder.encode(session), as: UTF8.self) == #"{"publicKey":"pk","signature":"sig","timestamp":1794400000000}"#)
    }

    @Test func `error bodies map to codes`() {
        let error = FaxAPI.error(from: Data(#"{ "error": { "code": "line_not_connected", "message": "..." } }"#.utf8), status: 403)
        #expect(error == .server(code: .lineNotConnected, rawCode: "line_not_connected", status: 403))
        let unknown = FaxAPI.error(from: Data(#"{ "error": { "code": "brand_new" } }"#.utf8), status: 400)
        #expect(unknown.code == nil)
        #expect(FaxAPI.error(from: Data("<html>".utf8), status: 502) == .invalidResponse(status: 502))
    }
}

@Suite struct ErrorCopyTests {
    @Test(arguments: FaxErrorCode.allCases)
    func `every protocol error has plain Chinese copy`(code: FaxErrorCode) {
        for operation in [FaxOperation.newFax, .reply, .image, .tear, .report, .connect] {
            let text = FaxError.server(code: code, rawCode: code.rawValue, status: 400).userMessage(for: operation)
            #expect(!text.isEmpty)
            #expect(!text.contains(code.rawValue), "copy must not leak the raw code")
            #expect(text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, "copy should be Chinese")
        }
    }

    @Test func `quota reads differently for pictures and new faxes`() {
        let error = FaxError.server(code: .quotaExceeded, rawCode: "quota_exceeded", status: 429)
        #expect(error.userMessage(for: .image).contains("10 张"))
        #expect(error.userMessage(for: .newFax).contains("新传真"))
    }

    @Test func `the refusal for an early picture says why`() {
        let error = FaxError.server(code: .lineNotConnected, rawCode: "line_not_connected", status: 403)
        #expect(error.userMessage(for: .image) == "线路还没接通。等对方回复后，才能发图片。")
    }

    @Test func `network failures are explained without jargon`() {
        #expect(FaxError.network(.notConnectedToInternet).userMessage(for: .newFax).contains("联网"))
        #expect(FaxError.network(.timedOut).userMessage(for: .reply).contains("没有回应"))
    }
}

@Suite struct IdentityTests {
    /// Seed 0x00…0x1F; public key and id computed independently with Node's crypto.
    static let seed = Data((0..<32).map(UInt8.init))

    @Test func `device id matches an independent implementation`() throws {
        let identity = try DeviceIdentity(privateKeyRaw: Self.seed)
        #expect(identity.publicKeyRaw.map { String(format: "%02x", $0) }.joined() == "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8")
        #expect(identity.deviceId == "Vkdap1RjR0wChd9dvyvKtz")
        #expect(identity.deviceId.count == 22)
    }

    @Test func `the session request is a valid Ed25519 signature over the documented string`() throws {
        let identity = try DeviceIdentity(privateKeyRaw: Self.seed)
        let request = try identity.sessionRequest(timestamp: 1_794_400_000_000)
        #expect(request.timestamp == 1_794_400_000_000)
        let publicKey = try #require(Base64URL.decode(request.publicKey))
        let signature = try #require(Base64URL.decode(request.signature))
        #expect(publicKey.count == 32)
        #expect(signature.count == 64)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        #expect(key.isValidSignature(signature, for: Data("notchfax-session:1794400000000".utf8)))
        #expect(!key.isValidSignature(signature, for: Data("notchfax-session:1794400000001".utf8)))
    }

    @Test func `base64url has no padding and no plus or slash`() throws {
        let identity = try DeviceIdentity(privateKeyRaw: Self.seed)
        let request = try identity.sessionRequest(timestamp: 1)
        for field in [request.publicKey, request.signature] {
            #expect(!field.contains("=") && !field.contains("+") && !field.contains("/"))
        }
        #expect(Base64URL.encode(Data([0xFB, 0xFF])) == "-_8")
        #expect(Base64URL.decode("-_8") == Data([0xFB, 0xFF]))
        #expect(Base64URL.decode("a") == nil)
    }

    @Test func `a key store keeps one identity across launches`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("faxkit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileKeyStore(url: directory.appendingPathComponent("identity.key"))
        let first = try DeviceIdentity.loadOrCreate(from: store)
        let second = try DeviceIdentity.loadOrCreate(from: store)
        #expect(first.deviceId == second.deviceId)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func `launch options parse profiles, servers and scripts`() {
        let options = FaxLaunchOptions(arguments: [
            "Notchfax", "--fax-profile", "a", "--fax-server", "http://127.0.0.1:8788",
            "--fax-debug-send", "你好", "--fax-debug-early-image", "3", "--demo", "fax",
        ])
        #expect(options.profile == "a")
        #expect(options.server?.absoluteString == "http://127.0.0.1:8788")
        #expect(options.script.sendText == "你好")
        #expect(options.script.earlyImageDelay == 3)
        #expect(FaxLaunchOptions(arguments: ["x", "--fax-profile", "../evil"]).profile == nil)
        #expect(FaxLaunchOptions(arguments: ["x", "--fax-server", "ftp://nope"]).server == nil)
    }

    @Test func `profiles get their own directory and a file key`() {
        let named = FaxEnvironment.make(launch: FaxLaunchOptions(arguments: ["x", "--fax-profile", "b"]), defaults: UserDefaults(suiteName: "faxkit-test-\(UUID().uuidString)")!)
        #expect(named.directory.path.hasSuffix("Notchfax/Fax/profiles/b"))
        #expect(named.keyStore is FileKeyStore)
        let main = FaxEnvironment.make(launch: FaxLaunchOptions(arguments: ["x"]), defaults: UserDefaults(suiteName: "faxkit-test-\(UUID().uuidString)")!)
        #expect(main.directory.path.hasSuffix("Notchfax/Fax/default"))
        #if DEBUG
        // Ad-hoc Debug builds never touch the keychain, so rebuilding never prompts.
        #expect((main.keyStore as? FileKeyStore)?.url.path.hasSuffix("Notchfax/Fax/default/identity.key") == true)
        #else
        #expect(main.keyStore is KeychainKeyStore)
        #endif
    }

    @Test func `the identity is read lazily, once, and a refusal is not retried`() async throws {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let api = FaxAPI(
            baseURL: URL(string: "http://h")!,
            identity: {
                reads.withLock { $0 += 1 }
                throw KeyStoreError.keychain(-25293)
            },
            transport: URLSessionTransport(session: .shared)
        )
        #expect(reads.withLock { $0 } == 0, "creating the client must not read the key")
        await #expect(throws: FaxError.identityUnavailable) { _ = try await api.socketURL() }
        await #expect(throws: FaxError.identityUnavailable) { _ = try await api.socketURL() }
        #expect(reads.withLock { $0 } == 1)
    }
}
