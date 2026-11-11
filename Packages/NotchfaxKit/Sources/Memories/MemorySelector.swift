import Foundation

/// Chooses which of today's old photos to print.
///
/// The library usually holds several pictures of the same moment (a burst, five tries
/// at the same group shot), screenshots, and saved images that were never memories.
/// The selector skips the junk, keeps one picture per moment, prefers favourites, and
/// spreads its picks across the years so "print another" goes somewhere new.
public struct MemorySelector: Sendable {
    public var calendar: MemoryCalendar
    /// Photos closer together than this belong to the same moment.
    public var momentGap: TimeInterval
    /// Pictures smaller than this on their short side are skipped (saved thumbnails, stickers).
    public var minimumShortSide: Int
    /// Wider or taller than this is a panorama or a long scroll capture.
    public var aspectRange: ClosedRange<Double>

    public init(
        calendar: MemoryCalendar = MemoryCalendar(),
        momentGap: TimeInterval = 90,
        minimumShortSide: Int = 480,
        aspectRange: ClosedRange<Double> = 0.4...2.6
    ) {
        self.calendar = calendar
        self.momentGap = momentGap
        self.minimumShortSide = minimumShortSide
        self.aspectRange = aspectRange
    }

    /// A run of photos taken together, represented by its best picture.
    public struct Moment: Sendable, Equatable {
        public var representative: MemoryCandidate
        public var members: [MemoryCandidate]
        public var year: Int
        public var score: Double
    }

    // MARK: Picks

    /// Up to `limit` pictures for the automatic daily print, each from a different year,
    /// best first, leaving out any already printed.
    public func dailyPicks(
        from candidates: [MemoryCandidate],
        limit: Int,
        excluding printed: Set<String> = [],
        seed: UInt64 = 0
    ) -> [MemoryCandidate] {
        var years = Set<Int>()
        var picks: [MemoryCandidate] = []
        for moment in rankedMoments(candidates, seed: seed) where picks.count < limit {
            guard !years.contains(moment.year), !printed.contains(moment.representative.id) else { continue }
            years.insert(moment.year)
            picks.append(moment.representative)
        }
        return picks
    }

    /// The best picture not printed yet. Successive calls (adding each pick to `printed`)
    /// visit every year before returning to one already shown.
    public func next(from candidates: [MemoryCandidate], excluding printed: Set<String>, seed: UInt64 = 0) -> MemoryCandidate? {
        ranking(candidates, seed: seed).first { !printed.contains($0.id) }
    }

    /// Every usable moment's picture, in the order they should be printed.
    public func ranking(_ candidates: [MemoryCandidate], seed: UInt64 = 0) -> [MemoryCandidate] {
        rankedMoments(candidates, seed: seed).map(\.representative)
    }

    // MARK: Moments

    /// Moments ordered in rounds: the best moment of every year (strongest first), then
    /// every year's second best, and so on.
    public func rankedMoments(_ candidates: [MemoryCandidate], seed: UInt64 = 0) -> [Moment] {
        let byYear = Dictionary(grouping: moments(candidates, seed: seed), by: \.year)
            .mapValues { $0.sorted(by: Self.better) }
        let rounds = byYear.values.map(\.count).max() ?? 0
        var result: [Moment] = []
        for round in 0..<rounds {
            let tier = byYear.values.compactMap { round < $0.count ? $0[round] : nil }
            result += tier.sorted(by: Self.better)
        }
        return result
    }

    /// Usable photos grouped into moments.
    public func moments(_ candidates: [MemoryCandidate], seed: UInt64 = 0) -> [Moment] {
        let usable = collapseBursts(candidates.filter(isUsable))
            .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        var groups: [[MemoryCandidate]] = []
        for candidate in usable {
            if let last = groups.last?.last, candidate.date.timeIntervalSince(last.date) <= momentGap,
               calendar.calendar.isDate(candidate.date, inSameDayAs: last.date) {
                groups[groups.count - 1].append(candidate)
            } else {
                groups.append([candidate])
            }
        }
        return groups.compactMap { members in
            guard let best = members.max(by: { Self.pictureOrder($1, $0) }) else { return nil }
            return Moment(
                representative: best,
                members: members,
                year: calendar.calendar.component(.year, from: best.date),
                score: score(members, representative: best, seed: seed)
            )
        }
    }

    // MARK: Rules

    func isUsable(_ candidate: MemoryCandidate) -> Bool {
        guard !candidate.isScreenshot else { return false }
        guard min(candidate.pixelWidth, candidate.pixelHeight) >= minimumShortSide else { return false }
        return aspectRange.contains(candidate.aspectRatio)
    }

    /// Keeps one frame of each burst.
    private func collapseBursts(_ candidates: [MemoryCandidate]) -> [MemoryCandidate] {
        var bestOfBurst: [String: MemoryCandidate] = [:]
        var singles: [MemoryCandidate] = []
        for candidate in candidates {
            guard let burst = candidate.burstIdentifier else {
                singles.append(candidate)
                continue
            }
            if let current = bestOfBurst[burst], !Self.pictureOrder(candidate, current) { continue }
            bestOfBurst[burst] = candidate
        }
        return singles + bestOfBurst.values
    }

    private func score(_ members: [MemoryCandidate], representative: MemoryCandidate, seed: UInt64) -> Double {
        var score = 0.0
        if members.contains(where: \.isFavorite) { score += 100 }
        if members.contains(where: \.hasAdjustments) { score += 12 }
        // Many pictures of one moment usually means the moment mattered.
        score += Double(min(members.count, 6)) * 2
        if Self.isComfortable(representative.aspectRatio) { score += 4 }
        // A little variety between days with otherwise equal candidates.
        score += Self.jitter(representative.id, seed: seed) * 3
        return score
    }

    /// True if `a` is the better picture to stand for its moment.
    static func pictureOrder(_ a: MemoryCandidate, _ b: MemoryCandidate) -> Bool {
        if a.isFavorite != b.isFavorite { return a.isFavorite }
        if a.hasAdjustments != b.hasAdjustments { return a.hasAdjustments }
        let ac = isComfortable(a.aspectRatio), bc = isComfortable(b.aspectRatio)
        if ac != bc { return ac }
        let ap = a.pixelWidth * a.pixelHeight, bp = b.pixelWidth * b.pixelHeight
        if ap != bp { return ap > bp }
        return a.id < b.id
    }

    private static func better(_ a: Moment, _ b: Moment) -> Bool {
        if a.score != b.score { return a.score > b.score }
        return a.representative.id < b.representative.id
    }

    private static func isComfortable(_ aspect: Double) -> Bool {
        (0.62...1.8).contains(aspect)
    }

    /// Deterministic 0…1 from an identifier and a seed (FNV-1a), stable across launches.
    static func jitter(_ id: String, seed: UInt64) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 ^ seed
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        hash ^= hash >> 33
        hash &*= 0xff51_afd7_ed55_8ccd
        hash ^= hash >> 33
        return Double(hash % 10_000) / 10_000
    }
}
