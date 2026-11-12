import Foundation

/// What `notchfax print` asks the running app to print.
public struct PrintRequest: Codable, Sendable, Equatable {
    public enum Stock: String, Codable, Sendable {
        /// Thermal receipt paper: text, a dithered picture, or both.
        case receipt
        /// Glossy photo paper: one picture, nothing else.
        case photo
    }

    /// Bumped when the request changes in a way an older app would misread.
    public var version = PrintRequest.currentVersion
    public var stock: Stock
    public var text: String?
    /// The bytes of an image file in any format ImageIO reads.
    public var image: Data?
    /// Read `text` as receipt markup (`ReceiptMarkup`); otherwise print it exactly as given.
    public var markup: Bool
    /// Leave the sheet out until someone takes it, instead of drawing it back in after a while.
    public var keep: Bool
    /// File name (without extension) when the sheet is dragged out.
    public var name: String?

    public static let currentVersion = 1

    public init(stock: Stock = .receipt, text: String? = nil, image: Data? = nil, markup: Bool = true, keep: Bool = false, name: String? = nil) {
        self.stock = stock
        self.text = text
        self.image = image
        self.markup = markup
        self.keep = keep
        self.name = name
    }
}

/// The app's answer, sent back as soon as the job is queued (not when it has printed).
public struct PrintReply: Codable, Sendable, Equatable {
    public var accepted: Bool
    /// One line for the person at the terminal.
    public var message: String
    /// Sheets ahead of this one when it was queued, counting one that is out.
    public var ahead: Int?

    public init(accepted: Bool, message: String, ahead: Int? = nil) {
        self.accepted = accepted
        self.message = message
        self.ahead = ahead
    }

    public static func rejected(_ message: String) -> PrintReply {
        PrintReply(accepted: false, message: message)
    }
}

/// How requests travel: a binary property list over a local Mach message port that the
/// app registers in the login session. Any process of the same user can reach it, nothing else.
enum Wire {
    static let portName = "com.kadaliao.notchfax.print"
    static let printMessage: Int32 = 1
    /// Image files larger than this are refused before they are sent.
    static let maxImageBytes = 40 * 1024 * 1024
    static let maxTextCharacters = 20_000

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try PropertyListDecoder().decode(type, from: data)
    }
}
