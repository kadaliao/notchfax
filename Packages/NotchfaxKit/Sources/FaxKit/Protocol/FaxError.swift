import Foundation

/// The error codes of protocol §6.
public enum FaxErrorCode: String, Sendable, CaseIterable {
    case staleTimestamp = "stale_timestamp"
    case badSignature = "bad_signature"
    case tokenExpired = "token_expired"
    case unauthorized
    case invalidText = "invalid_text"
    case invalidImage = "invalid_image"
    case quotaExceeded = "quota_exceeded"
    case suspended
    case awaitingReply = "awaiting_reply"
    case lineNotConnected = "line_not_connected"
    case lineNotReady = "line_not_ready"
    case lineClosed = "line_closed"
    case notFound = "not_found"
    case `internal`
}

/// Everything that can go wrong talking to the fax server.
public enum FaxError: Error, Sendable, Equatable {
    /// The server answered with an error body. `code` is `nil` for a code this client does not know.
    case server(code: FaxErrorCode?, rawCode: String, status: Int)
    /// The request never got an answer.
    case network(URLError.Code)
    /// The server answered with something that is not the protocol.
    case invalidResponse(status: Int)
    case notConfigured
    /// The device key could not be read or created.
    case identityUnavailable
    /// The picture could not be read, or could not be made small enough.
    case unreadableImage

    public var code: FaxErrorCode? {
        if case .server(let code, _, _) = self { return code }
        return nil
    }

    /// True when retrying the same request later may succeed.
    public var isTransient: Bool {
        switch self {
        case .network: true
        case .server(let code, _, let status): code == .internal || status >= 500
        case .invalidResponse(let status): status >= 500 || status == 0
        default: false
        }
    }

    static func from(_ error: any Error) -> FaxError {
        if let error = error as? FaxError { return error }
        if let error = error as? URLError { return .network(error.code) }
        return .network(.unknown)
    }
}

/// What the user was doing when an error happened; the same code reads differently
/// for a new fax and for a picture.
public enum FaxOperation: Sendable {
    case newFax
    case reply
    case image
    case tear
    case report
    case connect
}

extension FaxError {
    /// Plain, warm Simplified Chinese for the person at the keyboard.
    public func userMessage(for operation: FaxOperation, resetsAt: Date? = nil, suspendedUntil: Date? = nil) -> String {
        switch self {
        case .server(let code, _, _):
            guard let code else { return "服务器回了一个看不懂的答复，稍后再试。" }
            return Self.message(for: code, operation: operation, resetsAt: resetsAt, suspendedUntil: suspendedUntil)
        case .network(let code):
            switch code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "这台 Mac 现在没有联网，连上网络后再试。"
            case .timedOut:
                return "服务器没有回应，稍后再试。"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "连不上传真服务器，稍后再试。"
            case .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed,
                 .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
                return "和服务器之间的安全连接没有建立起来。"
            case .cancelled:
                return "已取消。"
            default:
                return "网络出了点问题，没有发出去。稍后再试。"
            }
        case .invalidResponse:
            return "服务器回了一个看不懂的答复，稍后再试。"
        case .notConfigured:
            return "还没有设置传真服务器。"
        case .identityUnavailable:
            return "读不到这台 Mac 的传真身份（钥匙串），所以暂时无法收发。"
        case .unreadableImage:
            return "这张图片读不出来，换一张试试。"
        }
    }

    static func message(
        for code: FaxErrorCode, operation: FaxOperation, resetsAt: Date?, suspendedUntil: Date?
    ) -> String {
        switch code {
        case .staleTimestamp:
            return "这台 Mac 的时钟和服务器差得太多。打开“系统设置 › 通用 › 日期与时间”里的自动设置，再试一次。"
        case .badSignature:
            return "这台 Mac 的身份没有通过校验，稍后再试。"
        case .tokenExpired:
            return "连接已过期，正在重新连接。"
        case .unauthorized:
            return "服务器暂时不认得这台 Mac，正在重新登记。"
        case .invalidText:
            return "传真要写 1 到 500 个字。"
        case .invalidImage:
            return "这张图片没能通过检查，换一张试试。"
        case .quotaExceeded:
            if operation == .image {
                return "这条线路今天已经发了 10 张图片，明天再发吧。"
            }
            if let resetsAt {
                return "今天的新传真发完了，\(FaxFormat.resetTime(resetsAt))可以再发。回复别人不受限制。"
            }
            return "今天的新传真发完了，明天可以再发。回复别人不受限制。"
        case .suspended:
            if let suspendedUntil {
                return "因为多次被举报，这台 Mac 暂时不能发送，\(FaxFormat.day(suspendedUntil))恢复。"
            }
            return "因为多次被举报，这台 Mac 暂时不能发送。"
        case .awaitingReply:
            return "对方还没有回复。等回复后，线路接通，才能继续写。"
        case .lineNotConnected:
            return "线路还没接通。等对方回复后，才能发图片。"
        case .lineNotReady:
            return "这封传真还在找收件人，找到后才能继续写。"
        case .lineClosed:
            return "这条线路已经挂断了。"
        case .notFound:
            return operation == .tear || operation == .report
                ? "这条线路已经不在了。"
                : "找不到这条线路，可能已经挂断了。"
        case .internal:
            return "服务器出了点问题，稍后再试。"
        }
    }
}

/// Small, shared formatting for dates in copy.
enum FaxFormat {
    static let locale = Locale(identifier: "zh_Hans_CN")

    /// "今天 08:00" / "明天 08:00" / "11月13日 08:00".
    static func resetTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
        if calendar.isDate(date, inSameDayAs: now) { return "今天 \(time) " }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "明天 \(time) "
        }
        return "\(day(date)) \(time) "
    }

    /// "11月18日".
    static func day(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().month(.defaultDigits).day().locale(locale))
    }

    /// "11-11 22:40", the time on a fax header.
    static func headerTime(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        return String(format: "%02d-%02d %02d:%02d", c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// "2026-11-11 22.40", for file names.
    static func fileStamp(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d.%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// "刚刚" / "3 分钟前" / "昨天".
    static func relative(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "刚刚" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
