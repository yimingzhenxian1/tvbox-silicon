import Foundation

/// Huya (虎牙) as a built-in live platform. Room lists and search are plain JSON; a room's HLS lines
/// come from its mobile page, each with an anti-hotlinking token that is re-signed for this client.
enum HuyaLive {
    /// Areas are the games of the busiest rooms, so the chips follow what is on now.
    static func areas() async throws -> [LiveArea] {
        let rooms = try await listing(game: nil, page: 1)
        var seen = Set<String>()
        let games = rooms.compactMap { room -> LiveArea? in
            guard let id = room["gid"]?.string, let name = room["gameFullName"]?.string, seen.insert(id).inserted else { return nil }
            return LiveArea(id: id, name: name)
        }
        return [.recommended] + games.prefix(14)
    }

    static func rooms(area: LiveArea, page: Int) async throws -> [LiveRoom] {
        try await listing(game: area.id.isEmpty ? nil : area.id, page: page).compactMap { room in
            guard let id = room["profileRoom"]?.string else { return nil }
            let introduction = room["introduction"]?.string ?? ""
            return LiveRoom(platform: .huya, roomID: id, title: introduction.isEmpty ? room["roomName"]?.string ?? "" : introduction,
                            host: room["nick"]?.string ?? "", cover: room["screenshot"]?.string, online: room["totalCount"]?.int ?? 0,
                            area: room["gameFullName"]?.string ?? area.name)
        }
    }

    private static func listing(game: String?, page: Int) async throws -> [[String: JSONValue]] {
        var query = [("m", "LiveList"), ("do", "getLiveListByPage"), ("tagAll", "0"), ("page", "\(page)")]
        if let game { query.append(("gameId", game)) }
        let reply = try await LiveHTTP.json(LiveHTTP.url("https://www.huya.com/cache.php", query))
        let data = reply["data"]?.object
        if let pages = data?["totalPage"]?.int, page > pages { return [] }
        return data?["datas"]?.array?.compactMap(\.object) ?? []
    }

    static func search(_ keyword: String, page: Int) async throws -> [LiveRoom] {
        let url = LiveHTTP.url("https://search.cdn.huya.com/", [("m", "Search"), ("do", "getSearchContent"), ("q", keyword), ("uid", "0"), ("v", "4"),
                                                                ("typ", "-5"), ("livestate", "0"), ("rows", "20"), ("start", "\((page - 1) * 20)")])
        let reply = try await LiveHTTP.json(url)
        let docs = reply["response"]?.object?["3"]?.object?["docs"]?.array?.compactMap(\.object) ?? []
        return docs.compactMap { room in
            guard let id = room["room_id"]?.string else { return nil }
            let introduction = room["game_introduction"]?.string ?? ""
            return LiveRoom(platform: .huya, roomID: id, title: introduction.isEmpty ? room["game_roomName"]?.string ?? "" : introduction,
                            host: room["game_nick"]?.string ?? "", cover: room["game_screenshot"]?.string,
                            online: room["game_total_count"]?.int ?? 0, area: room["gameName"]?.string ?? LivePlatform.huya.name)
        }
    }

    /// `quality` is a bit rate in kbps; 0 is the original.
    static func stream(room: String, quality: Int?) async throws -> LiveStream {
        let page = try await LiveHTTP.text(URL(string: "https://m.huya.com/\(room)")!, headers: ["User-Agent": LiveHTTP.mobileAgent])
        guard let state = initialState(page), let info = state["roomInfo"]?.object else {
            throw TVError.unsupported(L10n.text("%@ could not be reached. Try again later.", LivePlatform.huya.name))
        }
        guard info["eLiveStatus"]?.int == 2, let live = info["tLiveInfo"]?.object else {
            throw TVError.unsupported(L10n.text("This live room is not broadcasting right now."))
        }
        let streams = live["tLiveStreamInfo"]?.object?["vStreamInfo"]?.object?["value"]?.array?.compactMap(\.object) ?? []
        guard let line = streams.first(where: { !($0["sHlsUrl"]?.string ?? "").isEmpty && !($0["sHlsAntiCode"]?.string ?? "").isEmpty }),
              let base = line["sHlsUrl"]?.string, let name = line["sStreamName"]?.string, let token = line["sHlsAntiCode"]?.string,
              let signed = antiCode(token, stream: name) else {
            throw TVError.unsupported(L10n.text("This live room has no stream this device can play."))
        }
        let rates = (live["tLiveStreamInfo"]?.object?["vBitRateInfo"]?.object?["value"]?.array?.compactMap(\.object) ?? []).compactMap { rate -> (Int, String)? in
            guard let bits = rate["iBitRate"]?.int, let name = rate["sDisplayName"]?.string else { return nil }
            return (bits, name)
        }
        let bitRate = quality ?? 0
        let suffix = line["sHlsUrlSuffix"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "m3u8"
        let address = base.replacingOccurrences(of: "http://", with: "https://") + "/\(name).\(suffix)?\(signed)" + (bitRate > 0 ? "&ratio=\(bitRate)" : "")
        guard let url = URL(string: address) else { throw TVError.invalidURL }
        let title = live["sIntroduction"]?.string ?? live["sRoomName"]?.string
        return LiveStream(url: url, headers: ["User-Agent": LiveHTTP.mobileAgent], title: title,
                          qualities: rates.map { (id: $0.0, label: $0.1) }, current: bitRate)
    }

    /// The HLS address of a Huya FLV address (`<line>.flv.huya.com/src/<stream>.flv?<token>`): the same
    /// stream and token on the line's HLS host, which accepts them. AVPlayer can't play FLV.
    static func hlsAddress(flv url: URL) -> URL? {
        let suffix = ".flv.huya.com"
        guard url.pathExtension.lowercased() == "flv", let host = url.host?.lowercased(), host.hasSuffix(suffix),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "https"
        components.host = String(host.dropLast(suffix.count)) + ".hls.huya.com"
        components.percentEncodedPath = String(components.percentEncodedPath.dropLast(3)) + "m3u8"
        return components.url
    }

    /// The HLS address of the Huya stream an FLV address lands on, itself or through the redirects of a
    /// relay (such as one serving `/huya/<room>.flv`); nil for any other stream. `session` must not
    /// follow redirects.
    static func hlsAddress(relay url: URL, headers: [String: String], session: URLSession) async -> URL? {
        var address = url
        for _ in 0..<4 {
            if let hls = hlsAddress(flv: address) { return hls }
            var request = URLRequest(url: address, timeoutInterval: 8)
            // Relays made for Android TVBox can refuse other clients.
            request.setValue(HTTPClient.subscriptionUserAgent, forHTTPHeaderField: "User-Agent")
            headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            guard let (bytes, response) = try? await session.bytes(for: request) else { return nil }
            bytes.task.cancel() // A live stream's body never ends.
            guard let http = response as? HTTPURLResponse, (300..<400).contains(http.statusCode),
                  let location = http.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: location, relativeTo: address)?.absoluteURL else { return nil }
            address = next
        }
        return nil
    }

    /// The page's `window.HNF_GLOBAL_INIT` object, without the functions it embeds.
    static func initialState(_ page: String) -> [String: JSONValue]? {
        guard let start = page.range(of: #"window\.HNF_GLOBAL_INIT\s*=\s*"#, options: .regularExpression),
              let end = page.range(of: "</script>", range: start.upperBound..<page.endIndex) else { return nil }
        let text = String(page[start.upperBound..<end.lowerBound])
            .replacingOccurrences(of: #"function\s*\w*\s*\([^)]*\)\s*\{[^{}]*\}"#, with: "\"\"", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ";")))
        return try? JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8))
    }

    /// Re-signs the page's HLS token (`wsSecret`) for a mobile web client with its own viewer id, as
    /// Huya's H5 player does. The page's token as served is refused.
    static func antiCode(_ token: String, stream: String) -> String? {
        let fields = Dictionary(token.split(separator: "&").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1].removingPercentEncoding ?? parts[1]) : nil
        }) { first, _ in first }
        guard let time = fields["wsTime"], let fm = fields["fm"], let decoded = Data(base64Encoded: fm),
              let prefix = String(data: decoded, encoding: .utf8)?.components(separatedBy: "_").first else { return nil }
        let viewer = Int64.random(in: 1_400_000_000_000..<1_500_000_000_000)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let sequence = now + viewer, type = "tars_mobile", platform = "103"
        let hash = LiveHTTP.md5("\(sequence)|\(type)|\(platform)")
        let secret = LiveHTTP.md5("\(prefix)_\(viewer)_\(stream)_\(hash)_\(time)")
        let session = now % 10_000_000_000 * 1000 % 0xFFFF_FFFF
        let query: [(String, String)] = [("wsSecret", secret), ("wsTime", time), ("seqid", "\(sequence)"), ("ctype", type), ("ver", "1"),
                                         ("fs", fields["fs"] ?? "bgct"), ("uid", "\(viewer)"), ("uuid", "\(session)"), ("t", platform), ("sv", "2110211124")]
        return query.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }
}
