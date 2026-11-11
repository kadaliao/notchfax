import Foundation

/// What 那年今日 remembers between launches.
@MainActor
final class MemoriesSettings {
    private let defaults: UserDefaults
    private let prefix: String

    /// - Parameter prefix: keeps the sample library's state apart from the real one.
    init(defaults: UserDefaults = .standard, prefix: String = "memories.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    private func key(_ name: String) -> String { prefix + name }

    /// Print one memory a day on its own. On by default: it is the point of the feature,
    /// and it never asks for photo access by itself.
    var autoPrint: Bool {
        get { defaults.object(forKey: key("autoPrint")) as? Bool ?? true }
        set { defaults.set(newValue, forKey: key("autoPrint")) }
    }

    /// Hour of the day from which the daily print is due.
    var hour: Int {
        get { defaults.object(forKey: key("hour")) as? Int ?? 9 }
        set { defaults.set(min(23, max(0, newValue)), forKey: key("hour")) }
    }

    /// The day (`yyyy-MM-dd`) today's memory was last printed, by schedule or by hand.
    var lastPrintedDay: String? {
        get { defaults.string(forKey: key("lastPrintedDay")) }
        set { defaults.set(newValue, forKey: key("lastPrintedDay")) }
    }

    /// Pictures already printed on `day`, so "再来一张" moves on to new ones.
    func printed(on day: String) -> [String] {
        guard defaults.string(forKey: key("printedDay")) == day else { return [] }
        return defaults.stringArray(forKey: key("printed")) ?? []
    }

    func recordPrinted(_ id: String, on day: String) {
        var list = printed(on: day)
        list.removeAll { $0 == id }
        list.append(id)
        defaults.set(day, forKey: key("printedDay"))
        defaults.set(list, forKey: key("printed"))
    }

    func resetPrinted(on day: String, keeping last: String?) {
        defaults.set(day, forKey: key("printedDay"))
        defaults.set(last.map { [$0] } ?? [], forKey: key("printed"))
    }
}
