import Foundation

// The data objects of docs/protocol.md §5, exactly as they travel over the wire.
// Times are Unix milliseconds.

public enum LineState: String, Codable, Sendable, CaseIterable {
    case queued, delivered, connected, closed
}

public enum LineRole: String, Codable, Sendable {
    case initiator, recipient
}

/// One anonymous conversation between two devices, seen from this device.
public struct Line: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var state: LineState
    public var role: LineRole
    public var myAlias: String
    /// `nil` until the first fax has been matched to a recipient.
    public var peerAlias: String?
    public var createdAt: Int64
    public var updatedAt: Int64

    public init(
        id: String, state: LineState, role: LineRole, myAlias: String, peerAlias: String?,
        createdAt: Int64, updatedAt: Int64
    ) {
        self.id = id
        self.state = state
        self.role = role
        self.myAlias = myAlias
        self.peerAlias = peerAlias
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Only the recipient may answer a delivered line; a connected line is open to both.
    public var canSendText: Bool {
        switch state {
        case .connected: true
        case .delivered: role == .recipient
        case .queued, .closed: false
        }
    }

    public var canSendImage: Bool { state == .connected }
    public var isOpen: Bool { state != .closed }
}

public enum MessageSender: String, Codable, Sendable {
    case me, peer
}

public enum MessageKind: String, Codable, Sendable {
    case text, image
}

public struct Message: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var lineId: String
    public var from: MessageSender
    public var kind: MessageKind
    public var text: String?
    public var imageId: String?
    public var width: Int?
    public var height: Int?
    public var sentAt: Int64

    public init(
        id: String, lineId: String, from: MessageSender, kind: MessageKind, text: String? = nil,
        imageId: String? = nil, width: Int? = nil, height: Int? = nil, sentAt: Int64
    ) {
        self.id = id
        self.lineId = lineId
        self.from = from
        self.kind = kind
        self.text = text
        self.imageId = imageId
        self.width = width
        self.height = height
        self.sentAt = sentAt
    }
}

public struct Quota: Codable, Sendable, Equatable {
    public var newFaxesLeft: Int
    public var newFaxesPerDay: Int
    public var resetsAt: Int64
}

public struct Me: Codable, Sendable, Equatable {
    public var deviceId: String
    public var quota: Quota
    public var suspendedUntil: Int64?
}

// MARK: - Request and response bodies

struct SessionRequest: Codable, Sendable, Equatable {
    var publicKey: String
    var timestamp: Int64
    var signature: String
}

struct SessionResponse: Codable, Sendable, Equatable {
    var token: String
    var expiresAt: Int64
    var deviceId: String
}

struct TextBody: Codable, Sendable, Equatable {
    var text: String
}

struct TearBody: Codable, Sendable, Equatable {
    var report: Bool
}

/// `{ line, message }`, returned by every send.
public struct LineMessage: Codable, Sendable, Equatable {
    public var line: Line
    public var message: Message
}

struct LineEnvelope: Codable, Sendable, Equatable {
    var line: Line
}

struct LinesEnvelope: Codable, Sendable, Equatable {
    var lines: [Line]
}

/// Messages that have not been acknowledged yet, and the lines they belong to.
public struct Inbox: Codable, Sendable, Equatable {
    public var messages: [Message]
    public var lines: [Line]
}

struct ErrorEnvelope: Codable, Sendable {
    struct Body: Codable, Sendable {
        var code: String
        var message: String?
    }

    var error: Body
}

// MARK: - Real-time frames

/// One frame from the server on the WebSocket (protocol §4).
public enum ServerEvent: Sendable, Equatable {
    case fax(line: Line, message: Message)
    case lineUpdated(Line)
    case pong
    /// A frame this client does not understand; ignored, never fatal.
    case unknown(type: String)
}

extension ServerEvent: Decodable {
    private enum CodingKeys: String, CodingKey { case type, line, message }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "fax":
            self = .fax(
                line: try container.decode(Line.self, forKey: .line),
                message: try container.decode(Message.self, forKey: .message)
            )
        case "line.updated":
            self = .lineUpdated(try container.decode(Line.self, forKey: .line))
        case "pong":
            self = .pong
        default:
            self = .unknown(type: type)
        }
    }

    /// Decodes a text frame. Returns `nil` for anything that is not a JSON object with a `type`.
    public static func decode(frame: String) -> ServerEvent? {
        try? JSONDecoder().decode(ServerEvent.self, from: Data(frame.utf8))
    }
}

/// The only frame a client ever sends. Byte-for-byte as in protocol §4: no spaces.
let heartbeatPingFrame = #"{"type":"ping"}"#

// MARK: - Time

extension Date {
    init(unixMilliseconds ms: Int64) {
        self.init(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }

    var unixMilliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }
}
