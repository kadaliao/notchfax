import Foundation

/// A message as this Mac keeps it. Text is deleted on the server once acknowledged, so
/// this copy is the only one.
struct StoredMessage: Codable, Sendable, Equatable, Identifiable {
    enum Status: String, Codable, Sendable {
        /// Received, not printed yet. Survives a quit mid-print.
        case pending
        /// Printed; the acknowledgement has not reached the server yet.
        case printed
        case acknowledged
        /// Written on this Mac.
        case sent
    }

    var message: Message
    var status: Status
    /// File name under the store's `images` folder, once the picture is on disk.
    var imageFile: String?
    var receivedAt: Int64

    var id: String { message.id }
    var isFromPeer: Bool { message.from == .peer }
}

struct StoredLine: Codable, Sendable, Equatable, Identifiable {
    var line: Line
    var lastActivityAt: Int64
    var id: String { line.id }
}

/// Everything the fax feature remembers, as one value. Pure: no I/O, no clocks.
struct FaxArchive: Codable, Sendable, Equatable {
    var version = 1
    private(set) var lines: [String: StoredLine] = [:]
    private(set) var messages: [String: StoredMessage] = [:]

    enum Ingest: Equatable {
        case new(StoredMessage)
        /// Already known by id: a repeated `fax` frame or an inbox entry seen before.
        case duplicate
    }

    /// A line whose state changed, with the state it had before.
    struct LineChange: Equatable {
        var line: Line
        var previous: LineState?
    }

    // MARK: Lines

    /// Records the server's view of a line. Returns the change when the state is new.
    @discardableResult
    mutating func upsert(_ line: Line, at now: Int64) -> LineChange? {
        let existing = lines[line.id]
        if let existing {
            // Closed is final, and an older snapshot that arrives late must not move a line backwards.
            if existing.line.state == .closed, line.state != .closed { return nil }
            if existing.line.updatedAt > line.updatedAt, existing.line.state != line.state { return nil }
        }
        let activity = max(existing?.lastActivityAt ?? 0, line.updatedAt)
        lines[line.id] = StoredLine(line: line, lastActivityAt: activity)
        guard existing?.line.state != line.state else { return nil }
        return LineChange(line: line, previous: existing?.line.state)
    }

    /// Marks lines this Mac still thinks are open as closed when the server no longer lists them.
    mutating func reconcile(openLines: [Line], at now: Int64) -> [LineChange] {
        let listed = Set(openLines.map(\.id))
        var changes: [LineChange] = []
        for line in openLines {
            if let change = upsert(line, at: now) { changes.append(change) }
        }
        for (id, stored) in lines where stored.line.isOpen && !listed.contains(id) {
            var closed = stored.line
            closed.state = .closed
            lines[id] = StoredLine(line: closed, lastActivityAt: stored.lastActivityAt)
            changes.append(LineChange(line: closed, previous: stored.line.state))
        }
        return changes
    }

    func line(_ id: String) -> StoredLine? { lines[id] }

    /// Lines that are not closed, most recently active first.
    var openLines: [StoredLine] {
        lines.values.filter { $0.line.isOpen }.sorted { ($0.lastActivityAt, $0.id) > ($1.lastActivityAt, $1.id) }
    }

    // MARK: Messages

    /// Adds a message from the peer, de-duplicated by id.
    mutating func ingest(_ message: Message, at now: Int64) -> Ingest {
        guard messages[message.id] == nil else { return .duplicate }
        let stored = StoredMessage(
            message: message,
            status: message.from == .peer ? .pending : .sent,
            imageFile: nil,
            receivedAt: now
        )
        messages[message.id] = stored
        touch(lineId: message.lineId, at: message.sentAt)
        return .new(stored)
    }

    /// Records something this Mac sent.
    mutating func recordSent(_ sent: LineMessage, imageFile: String? = nil, at now: Int64) {
        upsert(sent.line, at: now)
        var stored = StoredMessage(message: sent.message, status: .sent, imageFile: imageFile, receivedAt: now)
        stored.message.from = .me
        messages[sent.message.id] = stored
        touch(lineId: sent.line.id, at: sent.message.sentAt)
    }

    func message(_ id: String) -> StoredMessage? { messages[id] }

    mutating func setImageFile(_ file: String, for id: String) {
        messages[id]?.imageFile = file
    }

    mutating func markPrinted(_ id: String) {
        guard let status = messages[id]?.status, status == .pending else { return }
        messages[id]?.status = .printed
    }

    mutating func markAcknowledged(_ id: String) {
        guard messages[id] != nil else { return }
        messages[id]?.status = .acknowledged
    }

    /// Received but not printed, oldest first.
    var pendingPrints: [StoredMessage] {
        messages.values.filter { $0.status == .pending }.sorted(by: Self.chronological)
    }

    /// Printed but not yet acknowledged to the server.
    var pendingAcks: [StoredMessage] {
        messages.values.filter { $0.status == .printed }.sorted(by: Self.chronological)
    }

    /// A line's messages, oldest first.
    func messages(inLine lineId: String) -> [StoredMessage] {
        messages.values.filter { $0.message.lineId == lineId }.sorted(by: Self.chronological)
    }

    /// 1-based position of a message on its line, counting both directions.
    func page(of id: String) -> Int {
        guard let target = messages[id] else { return 1 }
        return messages(inLine: target.message.lineId).firstIndex { $0.id == id }.map { $0 + 1 } ?? 1
    }

    /// The newest message from the peer on a line, for reply context.
    func lastPeerMessage(inLine lineId: String) -> StoredMessage? {
        messages(inLine: lineId).last { $0.isFromPeer }
    }

    // MARK: Housekeeping

    /// Forgets closed lines that have been quiet for `closedRetention`, and keeps at most
    /// `perLine` messages on any line. Never drops a message that still needs printing
    /// or acknowledging. Returns the image files that are no longer referenced.
    mutating func prune(now: Int64, closedRetention: Int64 = 30 * 86_400_000, perLine: Int = 200) -> [String] {
        var droppedFiles: [String] = []
        let keepStatuses: Set<StoredMessage.Status> = [.pending, .printed]
        for (id, stored) in lines where stored.line.state == .closed && now - stored.lastActivityAt > closedRetention {
            let inLine = messages(inLine: id)
            guard !inLine.contains(where: { keepStatuses.contains($0.status) }) else { continue }
            for message in inLine {
                messages.removeValue(forKey: message.id)
                if let file = message.imageFile { droppedFiles.append(file) }
            }
            lines.removeValue(forKey: id)
        }
        for id in lines.keys {
            let inLine = messages(inLine: id)
            guard inLine.count > perLine else { continue }
            for message in inLine.prefix(inLine.count - perLine) where !keepStatuses.contains(message.status) {
                messages.removeValue(forKey: message.id)
                if let file = message.imageFile { droppedFiles.append(file) }
            }
        }
        return droppedFiles
    }

    private mutating func touch(lineId: String, at time: Int64) {
        guard var stored = lines[lineId] else { return }
        stored.lastActivityAt = max(stored.lastActivityAt, time)
        lines[lineId] = stored
    }

    private static func chronological(_ a: StoredMessage, _ b: StoredMessage) -> Bool {
        (a.message.sentAt, a.receivedAt, a.id) < (b.message.sentAt, b.receivedAt, b.id)
    }
}
