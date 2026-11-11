import Foundation

/// Sends one HTTP request. Abstracted so tests can answer without a server.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FaxError.invalidResponse(status: 0) }
        return (data, http)
    }
}

/// Every HTTP endpoint of protocol §3, plus the session that authorises them.
///
/// The session is opened lazily and shared by concurrent callers. A request rejected
/// with `token_expired` (or `unauthorized`, e.g. after the server rotated its secret)
/// re-opens the session once and is retried transparently.
actor FaxAPI {
    nonisolated let baseURL: URL
    private let loadIdentity: @Sendable () throws -> DeviceIdentity
    private var identity: DeviceIdentity?
    private var identityFailed = false
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private var session: SessionResponse?
    private var opening: Task<SessionResponse, any Error>?

    /// - Parameter identity: reads (or creates) the device key. Called once, lazily, the first
    ///   time a session is needed, on this actor rather than the main thread. A failure is
    ///   remembered: a key store that refused once is not asked again (and cannot prompt again).
    init(
        baseURL: URL,
        identity: @escaping @Sendable () throws -> DeviceIdentity,
        transport: any HTTPTransport,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.baseURL = baseURL
        loadIdentity = identity
        self.transport = transport
        self.now = now
    }

    init(baseURL: URL, identity: DeviceIdentity, transport: any HTTPTransport, now: @escaping @Sendable () -> Date = Date.init) {
        self.init(baseURL: baseURL, identity: { identity }, transport: transport, now: now)
    }

    /// This Mac's device id, once the identity has been loaded.
    var deviceId: String? { identity?.deviceId }

    private func currentIdentity() throws -> DeviceIdentity {
        if let identity { return identity }
        guard !identityFailed else { throw FaxError.identityUnavailable }
        do {
            let loaded = try loadIdentity()
            identity = loaded
            return loaded
        } catch {
            identityFailed = true
            throw FaxError.identityUnavailable
        }
    }

    // MARK: Session

    /// A token that is valid for at least another minute.
    func token() async throws -> String {
        if let session, Date(unixMilliseconds: session.expiresAt).timeIntervalSince(now()) > 60 {
            return session.token
        }
        return try await openSession().token
    }

    /// Forgets the current token; the next request opens a new session.
    func invalidateSession() {
        session = nil
    }

    @discardableResult
    func openSession() async throws -> SessionResponse {
        if let opening { return try await opening.value }
        let task = Task { try await self.requestSession() }
        opening = task
        defer { opening = nil }
        let result = try await task.value
        session = result
        return result
    }

    private func requestSession() async throws -> SessionResponse {
        let body = try currentIdentity().sessionRequest(timestamp: now().unixMilliseconds)
        var request = URLRequest(url: endpoint("session"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await transmit(request)
        guard (200..<300).contains(response.statusCode) else { throw Self.error(from: data, status: response.statusCode) }
        return try Self.decode(SessionResponse.self, from: data, status: response.statusCode)
    }

    // MARK: Endpoints

    func me() async throws -> Me {
        try await call("GET", "me", as: Me.self)
    }

    func sendFax(text: String) async throws -> LineMessage {
        try await call("POST", "faxes", json: TextBody(text: text), as: LineMessage.self)
    }

    func sendText(lineId: String, text: String) async throws -> LineMessage {
        try await call("POST", "lines", lineId, "messages", json: TextBody(text: text), as: LineMessage.self)
    }

    func sendImage(lineId: String, png: Data) async throws -> LineMessage {
        let (data, response) = try await perform("POST", ["lines", lineId, "images"], body: png, contentType: "image/png")
        return try Self.decode(LineMessage.self, from: data, status: response.statusCode)
    }

    func image(id: String) async throws -> Data {
        try await perform("GET", ["images", id], body: nil, contentType: nil).0
    }

    func tear(lineId: String, report: Bool) async throws -> Line {
        try await call("POST", "lines", lineId, "tear", json: TearBody(report: report), as: LineEnvelope.self).line
    }

    func lines() async throws -> [Line] {
        try await call("GET", "lines", as: LinesEnvelope.self).lines
    }

    func inbox() async throws -> Inbox {
        try await call("GET", "inbox", as: Inbox.self)
    }

    func ack(messageId: String) async throws {
        _ = try await perform("POST", ["messages", messageId, "ack"], body: nil, contentType: nil)
    }

    /// `ws(s)://…/v1/socket?token=…` with a fresh-enough token.
    func socketURL() async throws -> URL {
        let token = try await token()
        guard var components = URLComponents(url: endpoint("socket"), resolvingAgainstBaseURL: false) else {
            throw FaxError.notConfigured
        }
        components.scheme = components.scheme?.lowercased() == "https" ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else { throw FaxError.notConfigured }
        return url
    }

    // MARK: Plumbing

    private func call<Response: Decodable>(_ method: String, _ path: String..., as type: Response.Type) async throws -> Response {
        let (data, response) = try await perform(method, path, body: nil, contentType: nil)
        return try Self.decode(type, from: data, status: response.statusCode)
    }

    private func call<Body: Encodable, Response: Decodable>(
        _ method: String, _ path: String..., json body: Body, as type: Response.Type
    ) async throws -> Response {
        let (data, response) = try await perform(method, path, body: try JSONEncoder().encode(body), contentType: "application/json")
        return try Self.decode(type, from: data, status: response.statusCode)
    }

    private func perform(_ method: String, _ path: [String], body: Data?, contentType: String?) async throws -> (Data, HTTPURLResponse) {
        var retried = false
        while true {
            let token = try await token()
            var request = URLRequest(url: endpoint(path))
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            request.httpBody = body
            let (data, response) = try await transmit(request)
            if (200..<300).contains(response.statusCode) { return (data, response) }
            let error = Self.error(from: data, status: response.statusCode)
            if !retried, error.code == .tokenExpired || error.code == .unauthorized {
                retried = true
                if session?.token == token { session = nil }
                continue
            }
            throw error
        }
    }

    private func transmit(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch {
            throw FaxError.from(error)
        }
    }

    private nonisolated func endpoint(_ path: String...) -> URL {
        endpoint(path)
    }

    private nonisolated func endpoint(_ path: [String]) -> URL {
        (["v1"] + path).reduce(baseURL) { $0.appendingPathComponent($1, isDirectory: false) }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, status: Int) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw FaxError.invalidResponse(status: status)
        }
    }

    static func error(from data: Data, status: Int) -> FaxError {
        guard let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) else {
            return .invalidResponse(status: status)
        }
        return .server(code: FaxErrorCode(rawValue: envelope.error.code), rawCode: envelope.error.code, status: status)
    }
}
