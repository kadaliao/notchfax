import AppKit

/// The facts about a display that decide where the paper slot goes.
public struct ScreenDescriptor: Sendable, Equatable {
    /// Global frame in AppKit coordinates (origin bottom-left).
    public var frame: CGRect
    public var safeAreaTop: CGFloat
    /// Width of the usable strip left of the notch, if the display reports one.
    public var topLeftAuxWidth: CGFloat?
    public var topRightAuxWidth: CGFloat?
    public var isBuiltIn: Bool
    public var isMain: Bool

    public init(
        frame: CGRect,
        safeAreaTop: CGFloat = 0,
        topLeftAuxWidth: CGFloat? = nil,
        topRightAuxWidth: CGFloat? = nil,
        isBuiltIn: Bool = false,
        isMain: Bool = false
    ) {
        self.frame = frame
        self.safeAreaTop = safeAreaTop
        self.topLeftAuxWidth = topLeftAuxWidth
        self.topRightAuxWidth = topRightAuxWidth
        self.isBuiltIn = isBuiltIn
        self.isMain = isMain
    }

    /// The physical notch in screen-local, top-left-origin coordinates.
    public var notchRect: CGRect? {
        guard safeAreaTop > 0, let left = topLeftAuxWidth, let right = topRightAuxWidth else { return nil }
        let width = frame.width - left - right
        guard width > 20 else { return nil }
        return CGRect(x: left, y: 0, width: width, height: safeAreaTop)
    }
}

/// Where the paper comes out. All coordinates are local to the screen with the
/// origin at its top-left corner and y pointing down.
public struct SlotGeometry: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A real hardware notch.
        case notch
        /// A drawn notch, for developing on a display that has none.
        case simulatedNotch
        /// A drawn paper slot at the top edge of a display without a notch.
        case drawnSlot
    }

    public var kind: Kind
    public var screenSize: CGSize
    /// The notch, or the drawn slot's housing.
    public var mouth: CGRect
    /// Paper is hidden above this line and visible below it.
    public var slotLineY: CGFloat
    public var centerX: CGFloat
    /// Sheets wider than this are scaled down to fit through.
    public var maxPaperWidth: CGFloat
    /// Corner radius of the mouth's lower corners.
    public var cornerRadius: CGFloat

    /// The point paper hangs from.
    public var anchor: CGPoint { CGPoint(x: centerX, y: slotLineY) }

    public static let simulatedNotchSize = CGSize(width: 185, height: 32)
    public static let drawnSlotSize = CGSize(width: 204, height: 10)

    public static func make(for screen: ScreenDescriptor, simulateNotch: Bool = false) -> SlotGeometry {
        let size = screen.frame.size
        let centre = (size.width / 2).rounded()
        if let notch = screen.notchRect {
            return SlotGeometry(
                kind: .notch,
                screenSize: size,
                mouth: notch,
                slotLineY: notch.maxY,
                centerX: notch.midX,
                maxPaperWidth: max(60, notch.width - 20),
                cornerRadius: 9
            )
        }
        if simulateNotch {
            let s = simulatedNotchSize
            return SlotGeometry(
                kind: .simulatedNotch,
                screenSize: size,
                mouth: CGRect(x: centre - s.width / 2, y: 0, width: s.width, height: s.height),
                slotLineY: s.height,
                centerX: centre,
                maxPaperWidth: s.width - 20,
                cornerRadius: 9
            )
        }
        let s = drawnSlotSize
        return SlotGeometry(
            kind: .drawnSlot,
            screenSize: size,
            mouth: CGRect(x: centre - s.width / 2, y: 0, width: s.width, height: s.height),
            slotLineY: 5.5,
            centerX: centre,
            maxPaperWidth: 168,
            cornerRadius: 5
        )
    }

    /// Which display hosts the slot: one with a notch, else the built-in one, else the main one.
    public static func preferredScreenIndex(_ screens: [ScreenDescriptor]) -> Int? {
        guard !screens.isEmpty else { return nil }
        if let i = screens.firstIndex(where: { $0.notchRect != nil }) { return i }
        if let i = screens.firstIndex(where: \.isBuiltIn) { return i }
        if let i = screens.firstIndex(where: \.isMain) { return i }
        return 0
    }

    /// Uniform scale that lets a sheet of `width` through the slot.
    public func fittingScale(forPaperWidth width: CGFloat) -> CGFloat {
        guard width > maxPaperWidth, width > 0 else { return 1 }
        return maxPaperWidth / width
    }
}

extension ScreenDescriptor {
    @MainActor
    public init(_ screen: NSScreen) {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let builtIn = number.map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false
        self.init(
            frame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            topLeftAuxWidth: screen.auxiliaryTopLeftArea?.width,
            topRightAuxWidth: screen.auxiliaryTopRightArea?.width,
            isBuiltIn: builtIn,
            isMain: screen == NSScreen.screens.first
        )
    }
}
