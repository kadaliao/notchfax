import AppKit

/// A feature of the app. Each module exposes one conforming class; the app shell
/// creates it with the shared printer and keeps it alive.
@MainActor
public protocol FeatureModule: AnyObject {
    /// Register menu items and keep a reference to the printer here. Do no heavy work.
    init(printer: Printer)
    /// Called once the app has finished launching and the slot is on screen.
    func start()
}

extension FeatureModule {
    public func start() {}
}

/// One entry in the menu-bar menu.
public enum MenuEntry {
    case action(MenuAction)
    case submenu(title: String, systemImage: String? = nil, items: [MenuEntry])
    case separator
    /// A dimmed, non-interactive line of text.
    case label(String)

    /// Shorthand for the common case.
    public static func action(
        _ title: String,
        systemImage: String? = nil,
        isOn: Bool? = nil,
        isEnabled: Bool = true,
        shortcut: MenuShortcut? = nil,
        handler: @escaping @MainActor () -> Void
    ) -> MenuEntry {
        .action(MenuAction(title: title, systemImage: systemImage, isOn: isOn, isEnabled: isEnabled, shortcut: shortcut, handler: handler))
    }
}

/// A key combination shown beside a menu item. It works while the menu is open; a
/// feature that wants it everywhere registers its own global hot key as well.
public struct MenuShortcut: Sendable, Equatable {
    /// The key, lowercase (for example `"b"`).
    public var key: String
    public var modifiers: NSEvent.ModifierFlags

    public init(_ key: String, modifiers: NSEvent.ModifierFlags = .command) {
        self.key = key
        self.modifiers = modifiers
    }
}

public struct MenuAction {
    public var title: String
    public var systemImage: String?
    /// Non-nil shows a checkmark state.
    public var isOn: Bool?
    public var isEnabled: Bool
    public var shortcut: MenuShortcut?
    public var handler: @MainActor () -> Void

    public init(
        title: String,
        systemImage: String? = nil,
        isOn: Bool? = nil,
        isEnabled: Bool = true,
        shortcut: MenuShortcut? = nil,
        handler: @escaping @MainActor () -> Void
    ) {
        self.shortcut = shortcut
        self.title = title
        self.systemImage = systemImage
        self.isOn = isOn
        self.isEnabled = isEnabled
        self.handler = handler
    }
}

/// Collects the menu sections features contribute. Sections are rebuilt every time
/// the menu opens, so their closures can reflect current state.
@MainActor
public final class MenuRegistry {
    public struct Section {
        public var id: String
        /// Lower numbers appear higher in the menu.
        public var order: Int
        public var items: @MainActor () -> [MenuEntry]
    }

    public private(set) var sections: [Section] = []

    public init() {}

    /// Adds a section, replacing any existing one with the same id.
    public func addSection(id: String, order: Int = 100, items: @escaping @MainActor () -> [MenuEntry]) {
        sections.removeAll { $0.id == id }
        sections.append(Section(id: id, order: order, items: items))
        sections.sort { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    public func removeSection(id: String) {
        sections.removeAll { $0.id == id }
    }

    /// Every section's current entries, with separators between non-empty sections.
    public func entries() -> [MenuEntry] {
        var result: [MenuEntry] = []
        for section in sections {
            let items = section.items()
            guard !items.isEmpty else { continue }
            if !result.isEmpty { result.append(.separator) }
            result.append(contentsOf: items)
        }
        return result
    }
}

extension MenuEntry {
    /// Builds `NSMenuItem`s for a list of entries.
    @MainActor
    public static func menuItems(for entries: [MenuEntry]) -> [NSMenuItem] {
        entries.map { entry in
            switch entry {
            case .separator:
                return NSMenuItem.separator()
            case .label(let text):
                let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                item.isEnabled = false
                return item
            case .submenu(let title, let systemImage, let items):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.image = systemImage.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                let submenu = NSMenu(title: title)
                submenu.autoenablesItems = false
                menuItems(for: items).forEach(submenu.addItem)
                item.submenu = submenu
                return item
            case .action(let action):
                let item = ClosureMenuItem(title: action.title, handler: action.handler)
                item.image = action.systemImage.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                item.isEnabled = action.isEnabled
                if let isOn = action.isOn { item.state = isOn ? .on : .off }
                if let shortcut = action.shortcut {
                    item.keyEquivalent = shortcut.key
                    item.keyEquivalentModifierMask = shortcut.modifiers
                }
                return item
            }
        }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc @MainActor private func run() {
        handler()
    }
}
