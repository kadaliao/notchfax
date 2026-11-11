import CoreGraphics
import Foundation
import ImageIO
import PrintKit
import Testing
@testable import Memories

// MARK: - Fixtures

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
}()

private let memoryCalendar = MemoryCalendar(calendar: utc, maxYearsBack: 30)

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, _ second: Int = 0) -> Date {
    utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
}

private func photo(
    _ id: String, _ at: Date, favorite: Bool = false, screenshot: Bool = false, edited: Bool = false,
    burst: String? = nil, size: (Int, Int) = (4032, 3024)
) -> MemoryCandidate {
    MemoryCandidate(
        id: id, date: at, pixelWidth: size.0, pixelHeight: size.1,
        isFavorite: favorite, isScreenshot: screenshot, hasAdjustments: edited, burstIdentifier: burst
    )
}

// MARK: - Calendar

@Suite struct MemoryCalendarTests {
    @Test func windowsCoverTheSameDayInEarlierYears() throws {
        let windows = MemoryCalendar(calendar: utc, maxYearsBack: 3).windows(for: date(2026, 11, 11, 9))
        #expect(windows.count == 3)
        let first = try #require(windows.first)
        #expect(first.start == date(2025, 11, 11, 0))
        #expect(first.end == date(2025, 11, 12, 0))
        #expect(windows.last?.start == date(2023, 11, 11, 0))
    }

    @Test func leapDayPhotosComeRoundOnTheTwentyEighth() {
        let windows = MemoryCalendar(calendar: utc, maxYearsBack: 4).windows(for: date(2026, 2, 28))
        let starts = windows.map(\.start)
        #expect(starts.contains(date(2024, 2, 29, 0)))
        #expect(starts.contains(date(2024, 2, 28, 0)))
        #expect(windows.count == 5)
    }

    @Test func leapDayOnlyMatchesLeapYears() {
        let windows = MemoryCalendar(calendar: utc, maxYearsBack: 8).windows(for: date(2028, 2, 29))
        #expect(windows.map(\.start) == [date(2024, 2, 29, 0), date(2020, 2, 29, 0)])
    }

    @Test(arguments: [(2025, "去年的今天"), (2023, "3 年前的今天"), (2016, "10 年前的今天")])
    func captions(year: Int, expected: String) {
        #expect(memoryCalendar.caption(for: date(year, 11, 11), today: date(2026, 11, 11)) == expected)
    }

    @Test func dayKeyFollowsTheCalendarTimeZone() {
        // 23:30 in Shanghai is still the 11th there, though it is the 11th 15:30 UTC.
        #expect(memoryCalendar.dayKey(for: date(2026, 11, 11, 23, 30)) == "2026-11-11")
    }
}

// MARK: - Selection

@Suite struct MemorySelectorTests {
    let selector = MemorySelector(calendar: memoryCalendar)

    @Test func screenshotsTinyImagesAndPanoramasAreSkipped() {
        let picks = selector.ranking([
            photo("shot", date(2024, 11, 11), screenshot: true),
            photo("thumb", date(2023, 11, 11), size: (320, 240)),
            photo("pano", date(2022, 11, 11), size: (12000, 2400)),
            photo("real", date(2021, 11, 11)),
        ])
        #expect(picks.map(\.id) == ["real"])
    }

    @Test func aBurstPrintsOnce() {
        let picks = selector.ranking([
            photo("b1", date(2022, 11, 11, 10, 0, 0), burst: "B"),
            photo("b2", date(2022, 11, 11, 10, 0, 1), burst: "B"),
            photo("b3", date(2022, 11, 11, 10, 0, 2), favorite: true, burst: "B"),
        ])
        #expect(picks.map(\.id) == ["b3"])
    }

    @Test func nearDuplicatesCollapseToTheBestPicture() {
        let moments = selector.moments([
            photo("a", date(2022, 11, 11, 10, 0, 0)),
            photo("b", date(2022, 11, 11, 10, 0, 40), edited: true),
            photo("c", date(2022, 11, 11, 10, 1, 30)),
            photo("later", date(2022, 11, 11, 15, 0, 0)),
        ])
        #expect(moments.count == 2)
        #expect(moments.first?.members.map(\.id) == ["a", "b", "c"])
        #expect(moments.first?.representative.id == "b")
    }

    @Test func favouritesWinTheDailyPrint() {
        let picks = selector.dailyPicks(from: [
            photo("plain-2025", date(2025, 11, 11)),
            photo("fav-2019", date(2019, 11, 11), favorite: true),
            photo("plain-2021", date(2021, 11, 11)),
        ], limit: 1)
        #expect(picks.map(\.id) == ["fav-2019"])
    }

    @Test func dailyPicksAreCappedAndComeFromDifferentYears() {
        var library: [MemoryCandidate] = []
        for year in 2015...2025 {
            for hour in [9, 13, 18] {
                library.append(photo("\(year)-\(hour)", date(year, 11, 11, hour)))
            }
        }
        let picks = selector.dailyPicks(from: library, limit: 3)
        #expect(picks.count == 3)
        #expect(Set(picks.map { utc.component(.year, from: $0.date) }).count == 3)
    }

    @Test func printAnotherVisitsEveryYearBeforeRepeatingOne() {
        let library = [
            photo("2020-a", date(2020, 11, 11, 9), favorite: true),
            photo("2020-b", date(2020, 11, 11, 17), favorite: true),
            photo("2022-a", date(2022, 11, 11, 9)),
            photo("2024-a", date(2024, 11, 11, 9)),
        ]
        var printed = Set<String>()
        var years: [Int] = []
        while let next = selector.next(from: library, excluding: printed) {
            printed.insert(next.id)
            years.append(utc.component(.year, from: next.date))
        }
        #expect(printed.count == 4)
        #expect(Set(years.prefix(3)) == [2020, 2022, 2024])
        #expect(years.last == 2020)
    }

    @Test func alreadyPrintedPicturesAreNotPickedAgain() {
        let library = [photo("x", date(2020, 11, 11), favorite: true), photo("y", date(2021, 11, 11))]
        #expect(selector.dailyPicks(from: library, limit: 3, excluding: ["x"]).map(\.id) == ["y"])
    }

    @Test func rankingIsStableForASeed() {
        let library = (0..<12).map { photo("p\($0)", date(2010 + $0, 11, 11)) }
        #expect(selector.ranking(library, seed: 7) == selector.ranking(library, seed: 7))
    }

    @Test func emptyLibraryHasNoPicks() {
        #expect(selector.dailyPicks(from: [], limit: 3).isEmpty)
        #expect(selector.next(from: [], excluding: []) == nil)
    }
}

// MARK: - Daily schedule

@Suite struct DailyScheduleTests {
    let schedule = DailySchedule(hour: 9)

    @Test func notDueBeforeTheHour() {
        #expect(!schedule.isDue(now: date(2026, 11, 11, 8, 59), lastPrintedDay: nil, calendar: memoryCalendar))
        #expect(schedule.nextCheck(after: date(2026, 11, 11, 8, 0), lastPrintedDay: nil, calendar: memoryCalendar) == date(2026, 11, 11, 9))
    }

    @Test func dueFromTheHourUntilMidnight() {
        #expect(schedule.isDue(now: date(2026, 11, 11, 9, 0), lastPrintedDay: "2026-11-10", calendar: memoryCalendar))
        // Mac woke up late in the evening: still today's print.
        #expect(schedule.isDue(now: date(2026, 11, 11, 23, 50), lastPrintedDay: "2026-11-10", calendar: memoryCalendar))
    }

    @Test func neverTwiceOnTheSameDay() {
        let now = date(2026, 11, 11, 14)
        #expect(!schedule.isDue(now: now, lastPrintedDay: "2026-11-11", calendar: memoryCalendar))
        #expect(schedule.nextCheck(after: now, lastPrintedDay: "2026-11-11", calendar: memoryCalendar) == date(2026, 11, 12, 9))
    }

    @Test func dayRolloverMakesItDueAgain() {
        // Printed late yesterday; the Mac slept through midnight and wakes at 10:00.
        #expect(schedule.isDue(now: date(2026, 11, 12, 10), lastPrintedDay: "2026-11-11", calendar: memoryCalendar))
        // Woken just after midnight: wait for the hour.
        #expect(!schedule.isDue(now: date(2026, 11, 12, 0, 5), lastPrintedDay: "2026-11-11", calendar: memoryCalendar))
    }

    @Test func hoursAreClamped() {
        #expect(DailySchedule(hour: 30).hour == 23)
        #expect(DailySchedule(hour: -2).hour == 0)
    }
}

// MARK: - Print layout and export

@Suite struct MemoryPrintTests {
    @Test func landscapePrintsAreFullWidth() {
        let layout = MemoryPrintLayout(imageAspect: 4.0 / 3.0)
        #expect(layout.sheetSize.width == Paper.glossyPhoto.defaultSize.width)
        #expect(layout.photoRect.width > layout.photoRect.height)
        #expect(abs(layout.photoRect.width / layout.photoRect.height - 4.0 / 3.0) < 0.02)
    }

    @Test func portraitPrintsStandUpright() {
        let layout = MemoryPrintLayout(imageAspect: 3.0 / 4.0)
        #expect(layout.photoRect.height > layout.photoRect.width)
        #expect(layout.sheetSize.width < Paper.glossyPhoto.defaultSize.width)
    }

    @Test func extremeShapesAreCroppedToPrintShapes() {
        #expect(MemoryPrintLayout(imageAspect: 3).aspect == 1.5)
        #expect(abs(MemoryPrintLayout(imageAspect: 0.3).aspect - 2.0 / 3.0) < 0.0001)
    }

    @Test func contentAreaIsThePictureAndTheCaptionBandOnTheBorder() {
        let layout = MemoryPrintLayout(imageAspect: 1.5)
        let content = Paper.glossyPhoto.contentRect(in: layout.sheetSize)
        #expect(content.origin == layout.photoRect.origin && content.width == layout.photoRect.width)
        #expect(content.height == layout.photoRect.height + MemoryPrintLayout.captionBand)
        // The caption starts below the picture, on white paper.
        #expect(layout.captionOrigin.y > layout.photoRect.maxY)
        #expect(layout.captionOrigin.y + 9 <= content.maxY, "the caption's text box must fit inside the content area or it is clipped")
    }

    @MainActor
    @Test func exportIsAHighResolutionPicture() async throws {
        let image = PrintSamples.landscape(width: 1600, height: 1200, variant: 0)
        let layout = MemoryPrintLayout(imageAspect: 4.0 / 3.0)
        let export = MemoryPrint.exportRecipe(image, date: date(2023, 11, 11), caption: "3 年前的今天", layout: layout)
        let png = try await export.png()
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width >= 1500)
        #expect(abs(Double(decoded.width) / Double(decoded.height) - layout.sheetSize.width / layout.sheetSize.height) < 0.01)
        try writeIfRequested(png, "memory-export")
    }

    /// Renders prints offscreen for a visual check: `NOTCHFAX_RENDER_DIR=/tmp/x swift test`.
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOTCHFAX_RENDER_DIR"] != nil))
    func renderPrintsForInspection() async throws {
        let library = SampleMemoryLibrary()
        let today = Date()
        let candidates = try await library.candidates(in: MemoryCalendar().windows(for: today))
        for candidate in MemorySelector().ranking(candidates) {
            let image = try await library.image(for: candidate, maxPixel: MemoryPrint.printPixels, timeout: .seconds(5))
            let job = MemoryPrint.job(
                .init(candidate: candidate, printImage: image, exportImage: image),
                today: today, calendar: MemoryCalendar(), actions: []
            )
            let png = try #require(job.sheet.pngData(scale: 3))
            try writeIfRequested(png, "memory-\(candidate.id)")
        }
    }
}

// MARK: - Slips and settings

@Suite @MainActor struct MemorySlipTests {
    @Test(arguments: [
        MemorySlip.Reason.nothingToday(limited: false), .nothingToday(limited: true), .noAccess, .unavailable,
    ])
    func slipsAreShortThermalNotes(reason: MemorySlip.Reason) throws {
        let job = MemorySlip.job(reason, today: date(2026, 11, 11))
        #expect(job.sheet.paper == .thermal)
        let size = job.sheet.resolvedSize()
        #expect(size.height < 200, "a slip, not a page")
        // Only the slips that can be fixed in Settings offer to open it.
        let offersSettings = job.actions.contains { $0.id == "settings" }
        #expect(offersSettings == (reason == .noAccess || reason == .nothingToday(limited: true)))
        let png = try #require(job.sheet.pngData(scale: 2))
        try writeIfRequested(png, "slip-\(String(describing: reason))")
    }
}

@Suite @MainActor struct MemoriesSettingsTests {
    let defaults: UserDefaults = {
        let name = "notchfax.tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }()

    @Test func defaultsAreDailyAtNine() {
        let settings = MemoriesSettings(defaults: defaults)
        #expect(settings.autoPrint)
        #expect(settings.hour == 9)
        #expect(settings.lastPrintedDay == nil)
    }

    @Test func printedListBelongsToItsDay() {
        let settings = MemoriesSettings(defaults: defaults)
        settings.recordPrinted("a", on: "2026-11-11")
        settings.recordPrinted("b", on: "2026-11-11")
        settings.recordPrinted("a", on: "2026-11-11")
        #expect(settings.printed(on: "2026-11-11") == ["b", "a"])
        #expect(settings.printed(on: "2026-11-12").isEmpty)
        settings.recordPrinted("c", on: "2026-11-12")
        #expect(settings.printed(on: "2026-11-12") == ["c"])
    }

    @Test func sampleStateIsKeptApart() {
        let real = MemoriesSettings(defaults: defaults)
        let sample = MemoriesSettings(defaults: defaults, prefix: "memories.sample.")
        sample.lastPrintedDay = "2026-11-11"
        #expect(real.lastPrintedDay == nil)
    }
}

private func writeIfRequested(_ data: Data, _ name: String) throws {
    guard let directory = ProcessInfo.processInfo.environment["NOTCHFAX_RENDER_DIR"] else { return }
    let url = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try data.write(to: url.appendingPathComponent(name).appendingPathExtension("png"))
}
