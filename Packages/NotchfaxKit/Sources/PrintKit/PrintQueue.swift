import Foundation

/// First-in, first-out bookkeeping for the single paper slot. One job occupies the
/// slot at a time; the rest wait. Holds no UI state so it can be tested directly.
public struct PrintQueue<ID: Hashable & Sendable>: Sendable {
    public enum Cancellation: Sendable, Equatable {
        /// The job was waiting and has been removed.
        case removedPending
        /// The job is in the slot; the caller must take the sheet away and then call `finishActive()`.
        case isActive
        case unknown
    }

    public private(set) var active: ID?
    public private(set) var pending: [ID] = []

    public init() {}

    public var isIdle: Bool { active == nil && pending.isEmpty }

    /// True when a sheet is in the slot and another job is waiting behind it,
    /// which is the cue to hurry the hanging sheet along.
    public var shouldHurryActive: Bool { active != nil && !pending.isEmpty }

    /// Adds a job. Returns it if the slot is free and it should start now.
    public mutating func enqueue(_ id: ID) -> ID? {
        guard id != active, !pending.contains(id) else { return nil }
        if active == nil {
            active = id
            return id
        }
        pending.append(id)
        return nil
    }

    /// The slot has been vacated. Returns the next job to start, if any.
    public mutating func finishActive() -> ID? {
        active = pending.isEmpty ? nil : pending.removeFirst()
        return active
    }

    public mutating func cancel(_ id: ID) -> Cancellation {
        if active == id { return .isActive }
        if let index = pending.firstIndex(of: id) {
            pending.remove(at: index)
            return .removedPending
        }
        return .unknown
    }

    /// Drops every waiting job and returns them. The active job is untouched.
    public mutating func removeAllPending() -> [ID] {
        defer { pending.removeAll() }
        return pending
    }
}
