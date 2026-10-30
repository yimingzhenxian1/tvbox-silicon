import Foundation
import CryptoKit
import QuickJS

/// The live platforms built into the app. Each lists its rooms by area, searches them, and turns a
/// room into a playable HLS stream when it starts: stream addresses expire, so channels carry
/// `<scheme>://room/<id>` and `LiveCatalog.resolve` fetches the address at play time.
public enum LivePlatform: String, CaseIterable, Identifiable, Sendable {
    case bilibili, douyu, huya, douyin

    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .bilibili: L10n.text("Bilibili Live")
        case .douyu: L10n.text("Douyu Live")
        case .huya: L10n.text("Huya Live")
        case .douyin: L10n.text("Douyin Live")
        }
    }
    /// Bilibili keeps the scheme its saved favorites already use.
    public var scheme: String { self == .bilibili ? BilibiliLive.scheme : rawValue + "-live" }
    public var source: LiveSource { LiveSource(name: name, url: URL(string: "\(scheme)://rooms")!) }
    /// Douyin answers searches only for signed-in accounts.
    public var searchable: Bool { self != .douyin || DouyinAccount.load().signedIn }

    public init?(scheme: String?) {
        guard let platform = Self.allCases.first(where: { $0.scheme == scheme }) else { return nil }
        self = platform
    }
}

/// A group of rooms a platform lists together: a game, a category, or its recommendations (empty id).
public struct LiveArea: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
    static var recommended: LiveArea { LiveArea(id: "", name: L10n.text("Recommended")) }
}

/// A live room as the room lists show it.
public struct LiveRoom: Identifiable, Hashable, Sendable {
    public let platform: LivePlatform
    public let roomID: String
    public let title: String
    public let host: String
    public let cover: URL?
    /// Viewers (or the platform's popularity figure), 0 when unknown.
    public let online: Int
    public let area: String
    public var id: String { platform.rawValue + ":" + roomID }
    public var url: URL { URL(string: "\(platform.scheme)://room/\(roomID)")! }
    /// The room as a playable channel; its stream is resolved when it plays.
    public var channel: Channel {
        Channel(name: [host, title].filter { !$0.isEmpty }.joined(separator: " · "), group: area, url: url, logo: cover)
    }

    init(platform: LivePlatform, roomID: String, title: String, host: String, cover: String?, online: Int, area: String) {
        self.platform = platform; self.roomID = roomID; self.online = online
        self.title = LiveText.plain(title); self.host = LiveText.plain(host); self.area = LiveText.plain(area)
        self.cover = cover.flatMap(LiveText.imageURL)
    }
}

public enum LiveCatalog {
    public static func areas(_ platform: LivePlatform) async throws -> [LiveArea] {
        switch platform {
        case .bilibili: try await BilibiliLive.areas()
        case .douyu: try await DouyuLive.areas()
        case .huya: try await HuyaLive.areas()
        case .douyin: try await DouyinLive.areas()
        }
    }

    /// One page (from 1) of an area's rooms, busiest first; empty past the last page.
    public static func rooms(_ platform: LivePlatform, area: LiveArea, page: Int) async throws -> [LiveRoom] {
        switch platform {
        case .bilibili: try await BilibiliLive.rooms(area: area, page: page)
        case .douyu: try await DouyuLive.rooms(area: area, page: page)
        case .huya: try await HuyaLive.rooms(area: area, page: page)
        case .douyin: try await DouyinLive.rooms(area: area, page: page)
        }
    }

    /// Rooms whose title or streamer matches `keyword`.
    public static func search(_ platform: LivePlatform, keyword: String, page: Int = 1) async throws -> [LiveRoom] {
        switch platform {
        case .bilibili: try await BilibiliLive.search(keyword, page: page)
        case .douyu: try await DouyuLive.search(keyword, page: page)
        case .huya: try await HuyaLive.search(keyword, page: page)
        case .douyin: try await DouyinLive.search(keyword, page: page)
        }
    }

    /// The first area's rooms, as channels (the live source's channel list).
    public static func channels(_ platform: LivePlatform) async throws -> [Channel] {
        let area = try await areas(platform).first ?? .recommended
        let rooms = try await self.rooms(platform, area: area, page: 1)
        guard !rooms.isEmpty else { throw TVError.unsupported(L10n.text("%@ could not be reached. Try again later.", platform.name)) }
        return rooms.map(\.channel)
    }

    /// The platform and room of a room channel's address.
    public static func room(_ url: URL) -> (platform: LivePlatform, id: String)? {
        guard url.host == "room", let platform = LivePlatform(scheme: url.scheme) else { return nil }
        let id = url.lastPathComponent
        return id.isEmpty || id == "/" ? nil : (platform, id)
    }
    public static func isRoom(_ url: URL) -> Bool { room(url) != nil }

    /// The playable channel for a room channel (at the quality its address asks for, else the best),
    /// with the room's qualities and the one served; any other channel is returned unchanged.
    public static func resolve(_ channel: Channel) async throws -> (channel: Channel, qualities: [StreamQuality], current: Int?) {
        guard let (platform, id) = room(channel.url) else { return (channel, [], nil) }
        if platform == .bilibili { return try await BilibiliLive.resolve(channel) }
        let asked = URLComponents(url: channel.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value.flatMap(Int.init)
        let stream: LiveStream = switch platform {
        case .douyu: try await DouyuLive.stream(room: id, quality: asked)
        case .huya: try await HuyaLive.stream(room: id, quality: asked)
        default: try await DouyinLive.stream(room: id, quality: asked)
        }
        let qualities = stream.qualities.compactMap { quality in
            URL(string: "\(platform.scheme)://room/\(id)?q=\(quality.id)").map { StreamQuality(id: quality.id, label: quality.label, url: $0) }
        }
        let name = channel.name.isEmpty ? (stream.title ?? platform.name) : channel.name
        return (Channel(name: name, group: channel.group.isEmpty ? platform.name : channel.group, url: stream.url, logo: channel.logo, headers: stream.headers),
                qualities, stream.current)
    }

    /// A playlist channel whose FLV address is a Huya stream, directly or through a relay, as the HLS
    /// line of the same stream; any other channel is returned unchanged.
    public static func playable(_ channel: Channel) async -> Channel { await playable(channel, session: LiveHTTP.unredirected) }
    static func playable(_ channel: Channel, session: URLSession) async -> Channel {
        guard channel.url.pathExtension.lowercased() == "flv",
              let url = await HuyaLive.hlsAddress(relay: channel.url, headers: channel.headers, session: session) else { return channel }
        Diagnostics.shared.record(.info, "player", "huya flv as hls relay=\(channel.url.host ?? "-") line=\(url.host ?? "-")")
        return Channel(name: channel.name, group: channel.group, url: url, logo: channel.logo, headers: channel.headers, skipScope: channel.skipScope,
                       historyContext: channel.historyContext, resumePosition: channel.resumePosition)
    }
}

/// A room's current stream address.
struct LiveStream {
    let url: URL
    var headers: [String: String] = [:]
    var title: String?
    /// The room's qualities, best first; ids are the platform's own (a rate or bit rate).
    var qualities: [(id: Int, label: String)] = []
    var current: Int?
}

extension LiveSource {
    /// Offered with every subscription, after the subscription's own live playlists.
    public static let bilibili = LivePlatform.bilibili.source
    public static var builtIn: [LiveSource] { LivePlatform.allCases.map(\.source) }
    public var platform: LivePlatform? { LivePlatform(scheme: url.scheme) }
    public var isBuiltIn: Bool { platform != nil }
}

/// HTTP for the live platforms' web APIs.
enum LiveHTTP {
    static let desktopAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    static let mobileAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private final class Redirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    /// Answers redirects instead of following them.
    static let unredirected = URLSession(configuration: .ephemeral, delegate: Redirects(), delegateQueue: nil)

    static func data(_ url: URL, headers: [String: String] = [:], form: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(desktopAgent, forHTTPHeaderField: "User-Agent")
        if let form {
            request.httpMethod = "POST"
            request.httpBody = Data(form.utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TVError.invalidURL }
        guard (200..<300).contains(http.statusCode) else { throw TVError.http(http.statusCode) }
        return (data, http)
    }
    static func text(_ url: URL, headers: [String: String] = [:], form: String? = nil) async throws -> String {
        String(decoding: try await data(url, headers: headers, form: form).0, as: UTF8.self)
    }
    static func json(_ url: URL, headers: [String: String] = [:], form: String? = nil) async throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: try await data(url, headers: headers, form: form).0)
    }
    static func url(_ base: String, _ query: [(String, String)]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        // `+` is a space to these servers; URLComponents leaves it as is.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
    static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func randomHex(_ count: Int) -> String {
        String((0..<count).map { _ in "0123456789abcdef".randomElement()! })
    }
}

enum LiveText {
    /// Search results mark the matched words with `<em>` and escape entities.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func imageURL(_ text: String) -> URL? {
        guard !text.isEmpty else { return nil }
        let address = text.hasPrefix("//") ? "https:" + text : text.replacingOccurrences(of: "http://", with: "https://")
        return URL(string: address)
    }
    /// "1.2万" and similar popularity figures.
    static func count(_ text: String?) -> Int {
        guard var text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return 0 }
        var scale = 1.0
        if text.hasSuffix("万") { scale = 10_000; text.removeLast() } else if text.hasSuffix("亿") { scale = 100_000_000; text.removeLast() }
        return Int((Double(text) ?? 0) * scale)
    }
}

/// Runs a platform's signing script in a fresh QuickJS context, on a thread with room for its stack.
/// `CryptoJS.MD5` is provided natively, which is all the platforms' sign functions use from it.
enum LiveScript {
    static func evaluate(_ source: String, then expression: String) async throws -> String {
        let thread = ScriptThread(label: "live sign")
        thread.start()
        defer { thread.cancel() }
        let result: Result<String, TVError> = await thread.run {
            guard let script = tv_script_create(nil, liveScriptHost, 64 << 20, 8 << 20) else { return .failure(.unsupported("QuickJS could not start")) }
            defer { tv_script_free(script) }
            func call(_ code: String) -> Result<JSONValue?, TVError> {
                guard let output = tv_script_call(script, code, 10) else { return .failure(.unsupported("The script runtime stopped")) }
                defer { free(output) }
                let envelope = try? JSONDecoder().decode([String: JSONValue].self, from: Data(String(cString: output).utf8))
                if let error = envelope?["error"]?.string { return .failure(.unsupported(String(error.prefix(300)))) }
                return .success(envelope?["value"])
            }
            let prelude = "var window = globalThis; var CryptoJS = { MD5: function (text) { var hex = __host('md5', String(text)); return { toString: function () { return hex; } }; } };"
            if case .failure(let error) = call(prelude + "\n" + source + "\n;0") { return .failure(error) }
            switch call(expression) {
            case .failure(let error): return .failure(error)
            case .success(let value):
                guard let text = value?.string, !text.isEmpty else { return .failure(.unsupported("The sign function returned nothing")) }
                return .success(text)
            }
        }
        return try result.get()
    }
}

private let liveScriptHost: TVScriptHost = { _, operation, argument in
    guard let operation, String(cString: operation) == "md5" else { return nil }
    return strdup(LiveHTTP.md5(argument.map { String(cString: $0) } ?? ""))
}
