import Foundation

/// A release number such as `0.2.2`, `v0.3.0` or `1.0.0-beta.2`, compared the way
/// semantic versioning orders them: number by number, a missing number counts as zero,
/// and a pre-release comes before the release it leads up to.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let numbers: [Int]
    public let prerelease: String?

    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        // Build metadata never takes part in ordering.
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
        var prerelease: String?
        if let dash = text.firstIndex(of: "-") {
            prerelease = String(text[text.index(after: dash)...])
            text = String(text[..<dash])
            guard prerelease?.isEmpty == false else { return nil }
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        self.numbers = numbers
        self.prerelease = prerelease
    }

    public var description: String {
        numbers.map(String.init).joined(separator: ".") + (prerelease.map { "-\($0)" } ?? "")
    }

    /// `0.2` and `0.2.0` are the same release.
    private var significant: [Int] {
        var numbers = numbers
        while numbers.count > 1, numbers.last == 0 { numbers.removeLast() }
        return numbers
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool {
        a.significant == b.significant && a.prerelease == b.prerelease
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(significant)
        hasher.combine(prerelease)
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let count = max(a.numbers.count, b.numbers.count)
        for index in 0..<count {
            let x = index < a.numbers.count ? a.numbers[index] : 0
            let y = index < b.numbers.count ? b.numbers[index] : 0
            if x != y { return x < y }
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case (let x?, let y?): return x.compare(y, options: [.numeric]) == .orderedAscending
        }
    }
}

extension AppVersion: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let version = AppVersion(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a version: \(string)")
        }
        self = version
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
