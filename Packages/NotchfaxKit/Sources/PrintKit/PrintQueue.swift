import Foundation

/// Bookkeeping for the single paper slot. One job occupies the slot at a time; the
/// rest wait: ordinary jobs first, in order, then ambient ones. The queue can be
/// paused (while something else hangs from the slot), which stops new jobs starting
/// without disturbing the one already there. Holds no UI state so it can be tested directly.
public struct PrintQueue<ID: Hashable & Sendable>: Sendable {
    public enum Cancellation: Sendable, Equatable {
        /// The job was waiting and has been removed.
        case removedPending
        /// The job is in the slot; the caller must take the sheet away and then call `finishActive()`.
        case isActive
        case unknown
    }

    public private(set) var active: ID?
    private var normal: [ID] = []
    private var ambient: [ID] = []
    public private(set) var isPaused = false

    public init() {}

    /// Every waiting job, in the order they will print.
    public var pending: [ID] { normal + ambient }

    public var isIdle: Bool { active == nil && normal.isEmpty && ambient.isEmpty }

    /// True when a sheet is in the slot and an ordinary job is waiting behind it,
    /// which is the cue to move the hanging sheet along. Ambient jobs never hurry anyone.
    public var shouldHurryActive: Bool { active != nil && !normal.isEmpty }

    /// Adds a job. Returns it if the slot is free and it should start now.
    public mutating func enqueue(_ id: ID, ambient isAmbient: Bool = false) -> ID? {
        guard id != active, !normal.contains(id), !ambient.contains(id) else { return nil }
        if isAmbient { ambient.append(id) } else { normal.append(id) }
        return startNextIfPossible()
    }

    /// The slot has been vacated. Returns the next job to start, if any.
    public mutating func finishActive() -> ID? {
        active = nil
        return startNextIfPossible()
    }

    /// Stops new jobs from starting. The active job, if any, is unaffected.
    public mutating func pause() {
        isPaused = true
    }

    /// Lets jobs start again. Returns the next job to start, if the slot is free.
    public mutating func resume() -> ID? {
        isPaused = false
        return startNextIfPossible()
    }

    public mutating func cancel(_ id: ID) -> Cancellation {
        if active == id { return .isActive }
        if let index = normal.firstIndex(of: id) {
            normal.remove(at: index)
            return .removedPending
        }
        if let index = ambient.firstIndex(of: id) {
            ambient.remove(at: index)
            return .removedPending
        }
        return .unknown
    }

    /// Drops every waiting job and returns them. The active job is untouched.
    public mutating func removeAllPending() -> [ID] {
        defer {
            normal.removeAll()
            ambient.removeAll()
        }
        return pending
    }

    private mutating func startNextIfPossible() -> ID? {
        guard active == nil, !isPaused else { return nil }
        if !normal.isEmpty {
            active = normal.removeFirst()
        } else if !ambient.isEmpty {
            active = ambient.removeFirst()
        }
        return active
    }
}
