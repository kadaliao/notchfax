import SwiftUI

// MARK: - Date stamp

/// The orange dot-matrix date a film camera burns into the corner of a picture.
public struct DateStamp: View {
    private let text: String
    private let dot: CGFloat

    /// - Parameter dotSize: diameter of one dot in points.
    public init(text: String, dotSize: CGFloat = 1) {
        self.text = text
        dot = dotSize
    }

    /// Formats as `'98 11 11`.
    public init(_ date: Date, calendar: Calendar = .current, dotSize: CGFloat = 1) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let year = String(format: "%02d", (c.year ?? 0) % 100)
        self.init(text: "'\(year) \(c.month ?? 1) \(c.day ?? 1)", dotSize: dotSize)
    }

    /// 4/3 of a dot lands on whole pixels at the 3x scale photo paper is rendered at.
    private var pitch: CGFloat { dot * 4 / 3 }
    private var glyphs: [[String]] { text.map { DotFont.glyph($0) } }

    private var stampSize: CGSize {
        let columns = glyphs.reduce(0) { $0 + ($1.first?.count ?? 3) + 1 } - 1
        return CGSize(width: CGFloat(max(1, columns)) * pitch + dot, height: 7 * pitch + dot)
    }

    public var body: some View {
        Canvas { context, _ in
            let core = Color(red: 1.0, green: 0.60, blue: 0.20)
            let glow = Color(red: 1.0, green: 0.30, blue: 0.04)
            var dots = Path()
            var x: CGFloat = dot / 2
            for glyph in glyphs {
                for (row, line) in glyph.enumerated() {
                    for (column, cell) in line.enumerated() where cell == "#" {
                        let centre = CGPoint(x: x + CGFloat(column) * pitch, y: dot / 2 + CGFloat(row) * pitch)
                        dots.addRoundedRect(
                            in: CGRect(x: centre.x - dot / 2, y: centre.y - dot / 2, width: dot, height: dot),
                            cornerSize: CGSize(width: dot * 0.3, height: dot * 0.3)
                        )
                    }
                }
                x += CGFloat((glyph.first?.count ?? 3) + 1) * pitch
            }
            // Light bleeding into the emulsion around each dot.
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: dot * 0.75))
                layer.fill(dots, with: .color(glow.opacity(0.7)))
            }
            context.fill(dots, with: .color(core))
        }
        .frame(width: stampSize.width, height: stampSize.height)
        .padding(dot * 2)
        .accessibilityLabel(text)
    }
}

private enum DotFont {
    static func glyph(_ character: Character) -> [String] {
        table[character] ?? table[" "] ?? []
    }

    private static let table: [Character: [String]] = [
        "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
        "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
        "3": ["#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."],
        "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
        "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
        "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
        "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
        "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
        "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
        "'": [".#", ".#", "#.", "..", "..", "..", ".."],
        " ": [".", ".", ".", ".", ".", ".", "."],
        ".": [".", ".", ".", ".", ".", ".", "#"],
        ":": [".", ".", "#", ".", "#", ".", "."],
        "-": ["...", "...", "...", "###", "...", "...", "..."],
        "/": ["..#", "..#", ".#.", ".#.", ".#.", "#..", "#.."],
    ]
}

// MARK: - Ready-made content

/// A photograph filling the content area of a `.glossyPhoto` sheet, with an optional date stamp.
public struct PhotoPrintContent: View {
    private let image: CGImage
    private let stamp: DateStamp?

    public init(image: CGImage, date: Date? = nil) {
        self.image = image
        stamp = date.map { DateStamp($0) }
    }

    public init(image: CGImage, stampText: String) {
        self.image = image
        stamp = DateStamp(text: stampText)
    }

    public var body: some View {
        GeometryReader { proxy in
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if let stamp {
                        stamp.padding(.trailing, 4).padding(.bottom, 3)
                    }
                }
                .photoEmulsionEdge()
        }
    }
}

extension View {
    /// The faint step where a photograph's emulsion meets the paper's white border. Put
    /// it on the picture itself when a `.glossyPhoto` sheet's content is more than the
    /// picture (a caption on the border, say).
    public func photoEmulsionEdge() -> some View {
        overlay(Rectangle().strokeBorder(Color.black.opacity(0.16), lineWidth: 0.5))
    }
}

/// A picture that is already 1-bit, for thermal paper: one image pixel per print-head
/// dot (`Paper.thermalDotsPerPoint`), never interpolated, so the dots that were
/// dithered are the dots that print. Pure black and white pass through the thermal
/// conversion unchanged apart from the print head's uneven density.
///
/// Keep the image no wider than `Paper.thermalContentDots` on a default-width sheet.
public struct ThermalBitmap: View {
    private let image: CGImage

    public init(_ image: CGImage) {
        self.image = image
    }

    /// The size the bitmap takes on paper, in points.
    public var size: CGSize {
        CGSize(width: CGFloat(image.width) / Paper.thermalDotsPerPoint, height: CGFloat(image.height) / Paper.thermalDotsPerPoint)
    }

    public var body: some View {
        Image(decorative: image, scale: Paper.thermalDotsPerPoint)
            .interpolation(.none)
            .antialiased(false)
            .frame(width: size.width, height: size.height)
    }
}

/// Four frames stacked on a `.photoStrip` sheet, with a caption in the footer.
public struct PhotoStripContent: View {
    private let frames: [CGImage]
    private let caption: String?

    public init(frames: [CGImage], caption: String? = nil) {
        self.frames = Array(frames.prefix(4))
        self.caption = caption
    }

    public var body: some View {
        GeometryReader { proxy in
            let rects = Paper.stripFrameRects(contentSize: proxy.size)
            ZStack(alignment: .topLeading) {
                ForEach(Array(rects.enumerated()), id: \.offset) { index, rect in
                    Group {
                        if index < frames.count {
                            Image(decorative: frames[index], scale: 1)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Color(white: 0.9)
                        }
                    }
                    .frame(width: rect.width, height: rect.height)
                    .clipped()
                    .overlay(Rectangle().strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5))
                    .offset(x: rect.minX, y: rect.minY)
                }
                if let caption {
                    Text(caption)
                        .font(.system(size: 6.5, weight: .medium, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(Color.black.opacity(0.5))
                        .frame(width: proxy.size.width, height: Paper.stripFooterHeight)
                        .offset(y: proxy.size.height - Paper.stripFooterHeight + 1)
                }
            }
        }
    }
}

// MARK: - Live paper

/// Paper as a SwiftUI surface, for content that is still being edited (a fax being
/// written). It uses the same stock as a printed sheet, so handing the finished
/// sheet to `SlotPresentation.feedIntoSlot` is seamless.
public struct PaperSurface<Content: View>: View {
    private let paper: Paper
    private let content: Content

    public init(_ paper: Paper, @ViewBuilder content: () -> Content) {
        self.paper = paper
        self.content = content()
    }

    public var body: some View {
        content
            .environment(\.colorScheme, .light)
            .padding(paper.contentInsets)
            .background(PaperStock(paper: paper))
    }
}

private struct PaperStock: View {
    let paper: Paper
    @State private var cache: (size: CGSize, image: CGImage)?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                if let cache {
                    Image(decorative: cache.image, scale: 1).resizable().interpolation(.high)
                } else {
                    Color(red: 0.968, green: 0.958, blue: 0.934)
                }
            }
            .shadow(color: .black.opacity(0.28), radius: 0.8, y: 0.6)
            .shadow(color: .black.opacity(0.22), radius: 9, y: 6)
            .task(id: "\(Int(size.width))x\(Int(size.height))") {
                guard size.width > 2, size.height > 2 else { return }
                cache = (size, PaperRenderer.blankStock(paper, size: size, scale: 2))
            }
        }
    }
}
