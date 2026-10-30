import Foundation

/// An HTTP answer for music requests: status and headers are kept, and the body stops at a byte
/// limit, so probing a server that ignores Range never downloads a whole song.
public struct MusicHTTPResponse: Sendable {
    public var status: Int
    /// Lowercased names.
    public var headers: [String: String]
    public var body: Data
    /// The body was cut off at the limit.
    public var truncated: Bool
    public init(status: Int, headers: [String: String] = [:], body: Data, truncated: Bool = false) {
        self.status = status; self.headers = headers; self.body = body; self.truncated = truncated
    }

    /// Seconds or an HTTP date, as `Retry-After` allows.
    public func retryAfter(now: Date = Date()) -> Date? {
        guard let value = headers["retry-after"]?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let seconds = Double(value) { return now.addingTimeInterval(seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}

public protocol MusicTransport: Sendable {
    /// Sends `request` and reads at most `limit` bytes of the body.
    func send(_ request: URLRequest, limit: Int) async throws -> MusicHTTPResponse
}

public struct URLSessionMusicTransport: MusicTransport {
    public let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest, limit: Int) async throws -> MusicHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MusicProviderError.invalidResponse("not HTTP") }
        var body = Data()
        body.reserveCapacity(min(limit, max(0, Int(http.expectedContentLength))))
        var truncated = false
        var chunk = [UInt8]()
        chunk.reserveCapacity(16_384)
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count == 16_384 { body.append(contentsOf: chunk); chunk.removeAll(keepingCapacity: true) }
            if body.count + chunk.count >= limit { truncated = true; break }
        }
        body.append(contentsOf: chunk)
        if body.count > limit { body = body.prefix(limit) }
        // Leaving the loop early cancels the rest of the transfer.
        bytes.task.cancel()
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
        }
        return MusicHTTPResponse(status: http.statusCode, headers: headers, body: body, truncated: truncated)
    }
}

enum MusicHTTP {
    /// GD Studio turned away a script's default user agent; a browser's works everywhere.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36"
    /// Catalog and provider answers are small JSON documents.
    static let jsonLimit = 2_000_000

    static func request(_ url: URL, timeout: TimeInterval, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    static func url(_ base: String, _ query: [(String, String)]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        // URLComponents leaves "+" alone, which servers read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// Sends a JSON request within `timeout`, mapping HTTP failures to provider errors.
    static func json(_ transport: MusicTransport, _ request: URLRequest, timeout: TimeInterval) async throws -> JSONValue {
        let response = try await withTimeout(timeout) { try await transport.send(request, limit: jsonLimit) }
        switch response.status {
        case 200..<300: break
        case 429: throw MusicProviderError.rateLimited(until: response.retryAfter())
        case 401, 403: throw MusicProviderError.authRequired
        default: throw MusicProviderError.invalidResponse("HTTP \(response.status)")
        }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: response.body) else {
            throw MusicProviderError.invalidResponse("not JSON")
        }
        return value
    }

    /// Runs `operation`, throwing `MusicProviderError.timeout` once `seconds` pass. The operation is
    /// cancelled, so a late answer never arrives.
    static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard seconds > 0 else { throw MusicProviderError.timeout }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.legacySleep(for: .seconds(seconds))
                throw MusicProviderError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw MusicProviderError.timeout }
            return first
        }
    }
}

extension JSONValue {
    var double: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        default: nil
        }
    }
    subscript(_ key: String) -> JSONValue? { object?[key] }
    subscript(path keys: String...) -> JSONValue? {
        keys.reduce(Optional(self)) { $0?.object?[$1] }
    }
}
