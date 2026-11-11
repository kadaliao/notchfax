import CoreGraphics
import Foundation
import PrintKit

/// A made-up library of procedural pictures, dated on today's day in earlier years.
/// Used by `--memories-sample` and the debug entry so the whole path can be shown on a
/// Mac with an empty library or nobody there to answer the permission prompt.
///
/// It deliberately contains things the selector must skip: a screenshot, a burst, and
/// several near-identical shots of one moment.
struct SampleMemoryLibrary: MemoryLibrary {
    let name = "样张"

    /// What each sample picture looks like.
    enum Picture: Sendable, Equatable {
        case landscape(variant: Int, width: Int, height: Int)
        case portrait(variant: Int, width: Int, height: Int)
    }

    struct Entry: Sendable {
        var yearsBack: Int
        var secondsIntoDay: TimeInterval
        var picture: Picture
        var isFavorite = false
        var isScreenshot = false
        var burst: String?
    }

    static let entries: [Entry] = [
        // Three years ago: a favourite dusk shot, the strongest memory of the day.
        Entry(yearsBack: 3, secondsIntoDay: 17.5 * 3600, picture: .landscape(variant: 0, width: 1600, height: 1200), isFavorite: true),
        // Five years ago: a burst of portraits; one frame should stand for all of them.
        Entry(yearsBack: 5, secondsIntoDay: 12 * 3600, picture: .portrait(variant: 2, width: 1200, height: 1600), burst: "burst-5"),
        Entry(yearsBack: 5, secondsIntoDay: 12 * 3600 + 1, picture: .portrait(variant: 1, width: 1200, height: 1600), burst: "burst-5"),
        Entry(yearsBack: 5, secondsIntoDay: 12 * 3600 + 2, picture: .portrait(variant: 3, width: 1200, height: 1600), burst: "burst-5"),
        // Last year: two tries at the same view a few seconds apart.
        Entry(yearsBack: 1, secondsIntoDay: 8 * 3600, picture: .landscape(variant: 1, width: 1600, height: 1067)),
        Entry(yearsBack: 1, secondsIntoDay: 8 * 3600 + 20, picture: .landscape(variant: 1, width: 1600, height: 1067)),
        // Two years ago: only a screenshot, which is never a memory.
        Entry(yearsBack: 2, secondsIntoDay: 22 * 3600, picture: .landscape(variant: 2, width: 1170, height: 2532), isScreenshot: true),
        // Seven years ago: an upright evening view.
        Entry(yearsBack: 7, secondsIntoDay: 19 * 3600, picture: .landscape(variant: 2, width: 1200, height: 1600)),
    ]

    func access() -> MemoryAccess { .authorized }
    func requestAccess() async -> MemoryAccess { .authorized }

    func candidates(in windows: [DateInterval]) async throws -> [MemoryCandidate] {
        let calendar = Calendar.current
        let thisYear = calendar.component(.year, from: Date())
        let byYearsBack = Dictionary(
            windows.map { (thisYear - calendar.component(.year, from: $0.start), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return Self.entries.enumerated().compactMap { index, entry in
            guard let window = byYearsBack[entry.yearsBack] else { return nil }
            let size = entry.picture.size
            return MemoryCandidate(
                id: "sample-\(index)",
                date: window.start.addingTimeInterval(entry.secondsIntoDay),
                pixelWidth: size.width,
                pixelHeight: size.height,
                isFavorite: entry.isFavorite,
                isScreenshot: entry.isScreenshot,
                burstIdentifier: entry.burst
            )
        }
    }

    @concurrent
    func image(for candidate: MemoryCandidate, maxPixel: Int, timeout: Duration) async throws -> CGImage {
        guard let index = Int(candidate.id.dropFirst("sample-".count)), Self.entries.indices.contains(index) else {
            throw MemoryLibraryError.imageUnavailable
        }
        let picture = Self.entries[index].picture
        let size = picture.size
        let factor = min(1, Double(maxPixel) / Double(max(size.width, size.height)))
        let width = Int((Double(size.width) * factor).rounded())
        let height = Int((Double(size.height) * factor).rounded())
        switch picture {
        case .landscape(let variant, _, _): return PrintSamples.landscape(width: width, height: height, variant: variant)
        case .portrait(let variant, _, _): return PrintSamples.portrait(width: width, height: height, variant: variant)
        }
    }
}

extension SampleMemoryLibrary.Picture {
    var size: (width: Int, height: Int) {
        switch self {
        case .landscape(_, let width, let height), .portrait(_, let width, let height): (width, height)
        }
    }
}
