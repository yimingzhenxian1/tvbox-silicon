import SwiftUI
import AVKit

struct Site: Identifiable { let id: String; let name: String; let api: URL }
struct Video: Identifiable { let id: String; let name: String }
struct Episode: Identifiable { let id = UUID(); let name: String; let url: URL }
struct Playback: Identifiable { let id = UUID(); let player: AVPlayer }
enum Failure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
func request(_ url: URL) async throws -> [String: Any] {
    let (data, response) = try await URLSession.shared.data(from: url)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw Failure.message("服务器请求失败") }
    guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.message("接口没有返回 JSON 对象") }
    return result
}
func string(_ value: Any?) -> String { value.map { String(describing: $0) } ?? "" }
@main struct SubscriptionPlayerApp: App {
    var body: some Scene { WindowGroup { SubscriptionView() } }
}
struct SubscriptionView: View {
    @AppStorage("subscription") private var saved = ""
    @State private var address = ""
    @State private var sites: [Site] = []
    @State private var error = ""
    @State private var busy = false
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("TVBox 订阅")) {
                    TextField("https://…/config.json", text: $address).keyboardType(.URL).autocapitalization(.none).disableAutocorrection(true)
                    Button("导入 / 刷新") { Task { await load() } }.disabled(busy)
                    if busy { ProgressView() }
                    if !error.isEmpty { Text(error).foregroundColor(.red) }
                }
                Section(header: Text("标准 JSON 视频源")) {
                    ForEach(sites) { site in NavigationLink(site.name) { CatalogView(site: site) } }
                    if sites.isEmpty { Text("导入后选择视频源。暂不支持 JAR、JS 和网页解析源。").foregroundColor(.secondary) }
                }
            }.navigationTitle("订阅影院")
        }.navigationViewStyle(.stack).task { address = saved; if !saved.isEmpty { await load() } }
    }
    @MainActor func load() async {
        guard !busy else { return }; busy = true; error = ""; defer { busy = false }
        do {
            guard let url = URL(string: address), ["https", "http"].contains(url.scheme ?? "") else { throw Failure.message("请输入有效的 HTTP 订阅地址") }
            let json = try await request(url)
            let entries = json["sites"] as? [[String: Any]] ?? []
            var seen = Set<String>()
            let found = entries.compactMap { item -> Site? in
                let type = string(item["type"])
                guard ["1", "4"].contains(type), let api = URL(string: string(item["api"]), relativeTo: url)?.absoluteURL, ["http", "https"].contains(api.scheme ?? "") else { return nil }
                let key = string(item["key"]).isEmpty ? api.absoluteString : string(item["key"])
                guard seen.insert(key).inserted else { return nil }
                return Site(id: key, name: string(item["name"]), api: api)
            }
            guard !found.isEmpty else { throw Failure.message("没有找到支持的 type 1/4 JSON 视频源；原有列表已保留") }
            sites = found; saved = address
        } catch { self.error = error.localizedDescription }
    }
}
struct CatalogView: View {
    let site: Site
    @State private var query = ""
    @State private var videos: [Video] = []
    @State private var categories: [(String, String)] = []
    @State private var category = ""
    @State private var page = 1
    @State private var error = ""
    @State private var busy = false
    var body: some View {
        List {
            if !error.isEmpty { Text(error).foregroundColor(.red) }
            if busy { ProgressView() }
            if !categories.isEmpty {
                Picker("分类", selection: $category) { Text("首页").tag(""); ForEach(categories, id: \.0) { Text($0.1).tag($0.0) } }
                    .onChange(of: category) { _ in page = 1; Task { await load() } }
            }
            ForEach(videos) { video in NavigationLink(video.name) { DetailView(site: site, video: video) } }
            HStack {
                Button("上一页") { page -= 1; Task { await load() } }.disabled(page <= 1 || busy)
                Spacer(); Text("第 \(page) 页"); Spacer()
                Button("下一页") { page += 1; Task { await load() } }.disabled(busy || videos.isEmpty)
            }
        }.navigationTitle(site.name).searchable(text: $query, prompt: "搜索影片")
        .onSubmit(of: .search) { page = 1; Task { await load() } }
        .task { await load() }
    }
    @MainActor func load() async {
        guard !busy else { return }; busy = true; error = ""; defer { busy = false }
        do {
            var c = URLComponents(url: site.api, resolvingAgainstBaseURL: true)!
            let params = ["ac": "detail", "pg": String(page), "wd": query, "t": query.isEmpty ? category : ""]
            c.queryItems = (c.queryItems ?? []).filter { params[$0.name] == nil } + params.map { URLQueryItem(name: $0.key, value: $0.value) }
            let json = try await request(c.url!)
            if let classes = json["class"] as? [[String: Any]] { categories = classes.map { (string($0["type_id"]), string($0["type_name"])) } }
            var seen = Set<String>()
            videos = (json["list"] as? [[String: Any]] ?? []).compactMap { item in
                let id = string(item["vod_id"]); guard !id.isEmpty, seen.insert(id).inserted else { return nil }
                return Video(id: id, name: string(item["vod_name"]))
            }
        } catch { self.error = error.localizedDescription }
    }
}
struct DetailView: View {
    let site: Site; let video: Video
    @State private var lines: [(String, [Episode])] = []
    @State private var error = ""
    @State private var playback: Playback?
    var body: some View {
        List {
            if !error.isEmpty { Text(error).foregroundColor(.red) }
            ForEach(lines.indices, id: \.self) { index in
                Section(header: Text(lines[index].0)) {
                    ForEach(lines[index].1) { episode in Button(episode.name) { playback = Playback(player: AVPlayer(url: episode.url)) } }
                }
            }
        }.navigationTitle(video.name).task { await load() }
        .sheet(item: $playback) { item in VideoPlayer(player: item.player).onAppear { item.player.play() }.onDisappear { item.player.pause() } }
    }
    @MainActor func load() async {
        do {
            var c = URLComponents(url: site.api, resolvingAgainstBaseURL: true)!
            c.queryItems = (c.queryItems ?? []).filter { !["ac", "ids"].contains($0.name) } + [URLQueryItem(name: "ac", value: "detail"), URLQueryItem(name: "ids", value: video.id)]
            let json = try await request(c.url!)
            guard let item = (json["list"] as? [[String: Any]])?.first else { throw Failure.message("接口未返回影片详情") }
            let names = string(item["vod_play_from"]).components(separatedBy: "$$$")
            lines = string(item["vod_play_url"]).components(separatedBy: "$$$").enumerated().map { index, text in
                let episodes = text.components(separatedBy: "#").compactMap { part -> Episode? in
                    let pair = part.split(separator: "$", maxSplits: 1).map(String.init)
                    guard pair.count == 2, let url = URL(string: pair[1]), ["http", "https"].contains(url.scheme ?? "") else { return nil }
                    return Episode(name: pair[0], url: url)
                }
                return (index < names.count ? names[index] : "线路 \(index + 1)", episodes)
            }
            if lines.allSatisfy({ $0.1.isEmpty }) { error = "没有可播放的 HTTP 剧集，暂不支持插件解析" }
        } catch { self.error = error.localizedDescription }
    }
}
