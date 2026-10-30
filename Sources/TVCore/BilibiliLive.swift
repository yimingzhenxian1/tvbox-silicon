import Foundation

/// Bilibili Live as a built-in live platform: the busiest rooms of each area (and, signed in, the
/// rooms the account follows). A room's stream address expires, so channels carry
/// `bilibili-live://room/<id>` and the player resolves it when it starts.
public enum BilibiliLive {
    public static let scheme = "bilibili-live"
    /// Parent areas in the order Bilibili's live home lists them.
    static let parentAreas: [(Int, String)] = [(1, "娱乐"), (2, "网游"), (3, "手游"), (6, "单机游戏"), (9, "虚拟主播"), (10, "生活"), (11, "知识"), (13, "赛事"), (5, "电台")]
    private static let following = "following"

    public static func room(_ url: URL) -> Int? {
        guard url.scheme == scheme, url.host == "room" else { return nil }
        return Int(url.lastPathComponent)
    }

    /// The playable channel for a room channel (at the `qn` its address asks for, else the original),
    /// with the room's qualities and the one served; any other channel is returned unchanged.
    public static func resolve(_ channel: Channel) async throws -> (channel: Channel, qualities: [StreamQuality], current: Int?) {
        guard let room = room(channel.url) else { return (channel, [], nil) }
        let asked = URLComponents(url: channel.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "qn" }?.value.flatMap(Int.init)
        let live = try await Bilibili.liveStream(room: room, quality: asked ?? 10000)
        let name = channel.name.isEmpty ? live.channel.name : channel.name
        return (Channel(name: name, group: channel.group, url: live.channel.url, logo: channel.logo, headers: live.channel.headers), live.qualities, live.current)
    }

    /// The followed rooms when some are live (signed in), then the parent areas.
    static func areas() async throws -> [LiveArea] {
        let followed = LiveArea(id: following, name: L10n.text("Following"))
        var live = false
        if BilibiliAccount.load().signedIn { live = !((try? await rooms(area: followed, page: 1)) ?? []).isEmpty }
        return (live ? [followed] : []) + parentAreas.map { LiveArea(id: String($0.0), name: $0.1) }
    }

    static func rooms(area: LiveArea, page: Int) async throws -> [LiveRoom] {
        let signer = BilibiliSigner.shared
        let cookie = await signer.cookie(account: BilibiliAccount.load().cookie)
        if area.id == following {
            let url = URL(string: "https://api.live.bilibili.com/xlive/web-ucenter/user/following?page=\(page)&page_size=29&ignoreRecord=1&hit_ab=true")!
            let rooms = try await signer.json(url, cookie: cookie)["data"]?.object?["list"]?.array?.compactMap(\.object) ?? []
            return rooms.filter { $0["live_status"]?.int == 1 }.compactMap { self.room($0, area: area.name) }
        }
        let url = URL(string: "https://api.live.bilibili.com/room/v1/area/getRoomList?parent_area_id=\(area.id)&page=\(page)&page_size=40&sort_type=online")!
        let rooms = try await signer.json(url, cookie: cookie)["data"]?.array?.compactMap(\.object) ?? []
        return rooms.compactMap { room($0, area: area.name) }
    }

    static func search(_ keyword: String, page: Int) async throws -> [LiveRoom] {
        let signer = BilibiliSigner.shared
        let cookie = await signer.cookie(account: BilibiliAccount.load().cookie)
        let query = try await signer.sign(["search_type": "live_room", "keyword": keyword, "page": "\(page)"], cookie: cookie)
        let reply = try await signer.json(URL(string: "https://api.bilibili.com/x/web-interface/wbi/search/type?" + query)!, cookie: cookie)
        guard reply["code"]?.int == 0 else { throw TVError.unsupported(L10n.text("Bilibili refused the request. Try again later.")) }
        let rooms = reply["data"]?.object?["result"]?.array?.compactMap(\.object) ?? []
        return rooms.filter { ($0["live_status"]?.int ?? 1) == 1 }.compactMap { room($0, area: $0["cate_name"]?.string ?? L10n.text("Bilibili Live")) }
    }

    private static func room(_ room: [String: JSONValue], area: String) -> LiveRoom? {
        guard let id = (room["roomid"] ?? room["room_id"])?.int, id > 0 else { return nil }
        let cover = [room["user_cover"], room["room_cover"], room["cover"], room["system_cover"], room["keyframe"], room["face"]]
            .compactMap { $0?.string }.first { !$0.isEmpty }
        return LiveRoom(platform: .bilibili, roomID: String(id), title: room["title"]?.string ?? "", host: room["uname"]?.string ?? "",
                        cover: cover, online: room["online"]?.int ?? room["watched_show"]?.object?["num"]?.int ?? 0, area: area)
    }
}
