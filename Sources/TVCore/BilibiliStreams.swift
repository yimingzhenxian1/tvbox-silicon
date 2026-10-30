import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

/// Bilibili serves each quality as separate DASH video and audio files (fragmented MP4), which
/// AVPlayer cannot open. Every file starts with a `sidx` index of its fragments, so the same files
/// can be described as HLS byte ranges instead: a media playlist per file and a master playlist that
/// pairs each video quality with the audio. AVPlayer reads the playlists through a resource loader,
/// fetches the fragments straight from the CDN, and picks the quality by bandwidth.
public enum BilibiliStreams {
    public static let scheme = "tvbox-bili"

    /// The qualities a stream from `stream` can be switched to, best first; empty for any other address.
    public static func qualities(for url: URL) -> [StreamQuality] { url.scheme == scheme ? PlaylistStore.shared.qualities(url) : [] }

    /// The DASH files behind an address from `stream`: the quality its playlist names (a single-quality
    /// master), else `quality`, else the best. Nil for any other address.
    public static func files(for url: URL, quality: Int? = nil) -> DashFiles? {
        guard url.scheme == scheme else { return nil }
        let sources = PlaylistStore.shared.sources(url)
        let named = url.lastPathComponent.legacyFirstMatch(#"^master-(\d+)\.m3u8$"#).flatMap { Int($0.1) }
        if let wanted = named ?? quality, let match = sources.first(where: { $0.quality == wanted }) { return match }
        return named == nil ? sources.first : nil
    }

    /// An asset for an address from `stream`, or nil for any other address.
    public static func asset(for url: URL) -> AVURLAsset? {
        guard url.scheme == scheme else { return nil }
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": Bilibili.mediaHeaders,
                                                   AVURLAssetHTTPUserAgentKey: Bilibili.userAgent])
        asset.resourceLoader.setDelegate(PlaylistLoader.shared, queue: PlaylistLoader.shared.queue)
        return asset
    }

    /// Bilibili declined to play the item (membership, region, login); no other format will work either.
    struct Refusal: Error { let message: String }

    /// The master playlist address for a video part or PGC episode (or a PGC episode's single MP4),
    /// or nil when it has neither.
    static func stream(aid: String, cid: String, episode: String?, session: URLSession = .shared) async throws -> URL? {
        let info = try await playInfo(aid: aid, cid: cid, episode: episode, session: session)
        // Members-only PGC answers a few minutes' preview instead of the episode.
        if info["is_preview"]?.int == 1 { throw Refusal(message: L10n.text("This episode needs a Bilibili premium membership. Only a short preview is available.")) }
        guard let dash = info["dash"]?.object else {
            // Some PGC episodes come only as one MP4, which AVPlayer opens directly.
            let files = info["durl"]?.array ?? []
            guard episode != nil, files.count == 1, let address = files[0].object?["url"]?.string else { return nil }
            let url = try WebAddress.resolve(address)
            DanmakuSource.register(url, bilibiliCID: cid, duration: info["timelength"]?.int.map { Double($0) / 1000 })
            return url
        }
        let videos = choose((dash["video"]?.array ?? []).compactMap { $0.object.flatMap(Representation.init) })
        guard !videos.isEmpty else { return nil }
        let audio = (dash["audio"]?.array ?? []).compactMap { $0.object.flatMap(Representation.init) }.max { $0.bandwidth < $1.bandwidth }

        // Each index is a small range request; a quality whose files are unreachable is left out.
        let indexed = await withTaskGroup(of: (Int, SegmentIndex?).self) { group in
            for (position, item) in (videos + [audio].compactMap { $0 }).enumerated() {
                group.addTask { (position, try? await index(item, session: session)) }
            }
            var found: [Int: SegmentIndex] = [:]
            for await (position, index) in group { found[position] = index }
            return found
        }
        let video = videos.indices.compactMap { position in indexed[position].map { (videos[position], $0) } }
        guard !video.isEmpty else { throw TVError.unsupported(L10n.text("Bilibili's video servers could not be reached. Try again later.")) }
        let sound = audio.flatMap { audio in indexed[videos.count].map { (audio, $0) } }

        // Absolute addresses: AVFoundation resolves nothing relative to a custom scheme.
        let token = PlaylistStore.token()
        func address(_ name: String) -> String { "\(scheme)://\(token)/\(name)" }
        var files: [String: String] = [:]
        var master = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        if let sound {
            files["audio.m3u8"] = media(sound.1)
            master.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"\(address("audio.m3u8"))\"")
        }
        // Each quality also gets a master of its own, which the player switches to when it is chosen.
        let header = master
        var qualities: [StreamQuality] = []
        var streamInfo: [Int: String] = [:]
        for (position, (item, index)) in video.enumerated() {
            let name = "video-\(position).m3u8"
            files[name] = media(index)
            let rates = [index.bitRates, sound?.1.bitRates].compactMap { $0 }
            var attributes = ["BANDWIDTH=\(rates.reduce(0) { $0 + $1.peak })", "AVERAGE-BANDWIDTH=\(rates.reduce(0) { $0 + $1.average })",
                              "CODECS=\"\([item.codecs, sound?.0.codecs].compactMap { $0 }.joined(separator: ","))\"",
                              "RESOLUTION=\(item.width)x\(item.height)", "VIDEO-RANGE=\(item.quality == 125 ? "PQ" : "SDR")"]
            if let rate = item.frameRate { attributes.append(String(format: "FRAME-RATE=%.3f", rate)) }
            if sound != nil { attributes.append("AUDIO=\"audio\"") }
            streamInfo[item.quality] = attributes.joined(separator: ",")
            let variant = ["#EXT-X-STREAM-INF:" + attributes.joined(separator: ","), address(name)]
            master += variant
            let single = "master-\(item.quality).m3u8"
            files[single] = (header + variant).joined(separator: "\n") + "\n"
            if let url = URL(string: address(single)) { qualities.append(StreamQuality(id: item.quality, label: StreamQuality.label(item.quality, height: item.height), url: url)) }
        }
        files["master.m3u8"] = master.joined(separator: "\n") + "\n"
        let duration = info["timelength"]?.int.map { Double($0) / 1000 } ?? dash["duration"]?.int.map(Double.init)
        // The files themselves, for downloads: the address whose index answered first.
        let sources = video.map { item, index in
            DashFiles(quality: item.quality, label: StreamQuality.label(item.quality, height: item.height),
                      video: [index.url] + item.urls.filter { $0 != index.url },
                      audio: sound.map { audio, index in [index.url] + audio.urls.filter { $0 != index.url } } ?? [],
                      videoInitialization: item.initialization, videoIndex: item.index,
                      audioInitialization: sound?.0.initialization, audioIndex: sound?.0.index,
                      streamInfo: streamInfo[item.quality] ?? "", cid: cid, duration: duration)
        }
        PlaylistStore.shared.add(files, token: token, qualities: qualities, sources: sources)
        Diagnostics.shared.record(.info, "bilibili", "dash aid=\(aid) cid=\(cid) qualities=\(video.map { "\($0.0.quality)/\($0.0.codecs)" }.joined(separator: ",")) audio=\(sound?.0.codecs ?? "-") host=\(video[0].1.url.host ?? "-")")
        guard let master = URL(string: address("master.m3u8")) else { return nil }
        DanmakuSource.register(master, bilibiliCID: cid, duration: duration)
        return master
    }

    /// The playurl answer's media object: `data` for videos, `result.video_info` for PGC episodes.
    private static func playInfo(aid: String, cid: String, episode: String?, session: URLSession) async throws -> [String: JSONValue] {
        let account = BilibiliAccount.load()
        let signer = BilibiliSigner.shared
        let cookie = await signer.cookie(account: account.cookie, session: session)
        let reply: [String: JSONValue]
        if let episode {
            var components = URLComponents(string: "https://api.bilibili.com/pgc/player/web/v2/playurl")!
            components.queryItems = ["ep_id": episode, "cid": cid, "qn": "127", "fnval": "4048", "fnver": "0", "fourk": "1"]
                .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            reply = try await signer.json(components.url!, cookie: cookie, session: session)
        } else {
            // The web player's parameters. Guests get 720P/1080P only with `try_look`; the dm_* fields
            // must be present (random values, as the web player's are) or the request meets risk control.
            var parameters = ["avid": aid, "cid": cid, "qn": account.signedIn ? "127" : "80", "fnval": "4048", "fnver": "0", "fourk": "1",
                              "web_location": "1315873", "gaia_source": "pre-load", "isGaiaAvoided": "true",
                              "dm_img_list": "[]", "dm_img_str": noise(16...64), "dm_cover_img_str": noise(32...128),
                              "dm_img_inter": #"{"ds":[],"wh":[0,0,0],"of":[0,0,0]}"#]
            if !account.signedIn { parameters["try_look"] = "1" }
            let query = try await signer.sign(parameters, cookie: cookie, session: session)
            reply = try await signer.json(URL(string: "https://api.bilibili.com/x/player/wbi/playurl?" + query)!, cookie: cookie, session: session)
        }
        guard reply["code"]?.int == 0 else {
            let message = reply["message"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("Bilibili refused the request. Try again later.")
            throw Refusal(message: message)
        }
        return (episode == nil ? reply["data"] : reply["result"]?.object?["video_info"])?.object ?? [:]
    }

    private static func noise(_ length: ClosedRange<Int>) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        let text = String((0..<Int.random(in: length)).map { _ in letters.randomElement()! })
        return String(Data(text.utf8).base64EncodedString().dropLast(2))
    }

    /// One stream per quality, in the codec this device decodes best: HEVC where it is hardware
    /// decoded, else AVC, else AV1 where that is. Highest quality first, which AVPlayer starts with.
    /// Dolby Vision (126) is left out: its CODECS needs a profile mapping the files don't state.
    static func choose(_ streams: [Representation]) -> [Representation] {
        let hevc = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        let av1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        func rank(_ item: Representation) -> Int? {
            switch item.codecID {
            case 12: hevc ? 0 : nil
            case 7: item.quality == 125 ? nil : 1
            case 13: av1 ? 2 : nil
            default: nil
            }
        }
        let usable = streams.filter { $0.quality != 126 && rank($0) != nil }
        return Dictionary(grouping: usable, by: \.quality).values
            .compactMap { $0.min { rank($0)! < rank($1)! } }
            .sorted { $0.quality > $1.quality }
    }

    static func media(_ index: SegmentIndex) -> String {
        let address = index.url.absoluteString
        let longest = index.references.map { Double($0.duration) / Double(index.timescale) }.max() ?? 1
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(max(1, Int(longest.rounded(.up))))", "#EXT-X-MEDIA-SEQUENCE:0",
                     "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS",
                     "#EXT-X-MAP:URI=\"\(address)\",BYTERANGE=\"\(index.initialization.count)@\(index.initialization.lowerBound)\""]
        for reference in index.references {
            lines.append(String(format: "#EXTINF:%.5f,", Double(reference.duration) / Double(index.timescale)))
            lines.append("#EXT-X-BYTERANGE:\(reference.size)@\(reference.offset)")
            lines.append(address)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads a stream's fragment index, trying its addresses in order.
    private static func index(_ item: Representation, session: URLSession) async throws -> SegmentIndex {
        var failure: Error = TVError.invalidURL
        for url in item.urls {
            do {
                var request = URLRequest(url: url, timeoutInterval: 8)
                Bilibili.mediaHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                request.setValue("bytes=\(item.index.lowerBound)-\(item.index.upperBound)", forHTTPHeaderField: "Range")
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 206, data.count == item.index.count else { throw TVError.http(status) }
                return try SegmentIndex(sidx: data, at: item.index.lowerBound, initialization: item.initialization, url: url)
            } catch { failure = error }
        }
        Diagnostics.shared.record(.warning, "bilibili", "index failed quality=\(item.quality) codec=\(item.codecs): \(failure.localizedDescription)")
        throw failure
    }
}

/// One quality of a Bilibili stream, by Bilibili's quality number (qn).
public struct StreamQuality: Sendable, Hashable, Identifiable {
    public let id: Int
    public let label: String
    public let url: URL
    public init(id: Int, label: String, url: URL) { self.id = id; self.label = label; self.url = url }

    static func label(_ quality: Int, height: Int) -> String {
        switch quality {
        case 127: "8K"
        case 126: "Dolby Vision"
        case 125: "HDR"
        case 120: "4K"
        case 116: "1080P60"
        case 112: "1080P+"
        case 80: "1080P"
        case 74: "720P60"
        case 64: "720P"
        case 32: "480P"
        case 16: "360P"
        default: height > 0 ? "\(height)P" : "\(quality)"
        }
    }
}

/// One quality's DASH files: video and audio, each with its mirror addresses in the order to try them.
public struct DashFiles: Sendable, Hashable {
    public let quality: Int
    public let label: String
    public let video: [URL]
    /// Empty when the stream has no separate audio.
    public let audio: [URL]
    /// Where each file's initialization section and `sidx` index lie, to describe the files as HLS again.
    let videoInitialization: ClosedRange<Int>
    let videoIndex: ClosedRange<Int>
    let audioInitialization: ClosedRange<Int>?
    let audioIndex: ClosedRange<Int>?
    /// The master playlist's EXT-X-STREAM-INF attributes for this quality.
    let streamInfo: String
    public let cid: String
    public let duration: Double?
}

/// A DASH representation from playurl (`data.dash.video[]` / `audio[]`).
struct Representation: Sendable {
    let quality: Int
    let codecID: Int
    let codecs: String
    let width: Int
    let height: Int
    let bandwidth: Int
    let frameRate: Double?
    /// Main and backup addresses, origin CDN first: peer CDNs (PCDN) are slower and often refuse ranges.
    let urls: [URL]
    let initialization: ClosedRange<Int>
    let index: ClosedRange<Int>

    init?(_ json: [String: JSONValue]) {
        func range(_ text: String?) -> ClosedRange<Int>? {
            let parts = (text ?? "").split(separator: "-").compactMap { Int($0) }
            return parts.count == 2 && parts[0] <= parts[1] ? parts[0]...parts[1] : nil
        }
        let base = json["segment_base"]?.object ?? json["SegmentBase"]?.object
        guard let quality = json["id"]?.int, let codecs = json["codecs"]?.string, !codecs.contains("\""),
              let initialization = range(base?["initialization"]?.string ?? base?["Initialization"]?.string),
              let index = range(base?["index_range"]?.string ?? base?["indexRange"]?.string) else { return nil }
        let addresses = [json["base_url"] ?? json["baseUrl"]].compactMap { $0?.string } + (json["backup_url"]?.array ?? json["backupUrl"]?.array ?? []).compactMap(\.string)
        func peer(_ url: URL) -> Bool {
            let host = url.host ?? ""
            return host.contains("mcdn.bilivideo") || host.contains("szbdyd.com") || host.contains("mountaintoys") || (url.port != nil && url.port != 443)
        }
        let urls = addresses.compactMap { URL(string: $0) }.filter { $0.scheme == "https" || $0.scheme == "http" }
        guard !urls.isEmpty else { return nil }
        self.urls = urls.filter { !peer($0) } + urls.filter(peer)
        self.quality = quality; self.codecs = codecs; self.initialization = initialization; self.index = index
        codecID = json["codecid"]?.int ?? 0
        width = json["width"]?.int ?? 0
        height = json["height"]?.int ?? 0
        bandwidth = json["bandwidth"]?.int ?? 0
        let rate = (json["frame_rate"] ?? json["frameRate"])?.string ?? ""
        let fraction = rate.split(separator: "/").compactMap { Double($0) }
        frameRate = fraction.count == 2 && fraction[1] > 0 ? fraction[0] / fraction[1] : Double(rate)
    }
}

/// A fragmented MP4's `sidx` box: where each fragment is and how long it plays.
struct SegmentIndex: Sendable {
    struct Reference: Sendable { let offset: Int; let size: Int; let duration: Int }
    let timescale: Int
    let references: [Reference]
    let initialization: ClosedRange<Int>
    let url: URL

    /// `data` is the box itself, read from byte `start` of the file.
    init(sidx data: Data, at start: Int, initialization: ClosedRange<Int>, url: URL) throws {
        let bytes = [UInt8](data)
        func number(_ at: Int, _ count: Int) -> Int { (at..<at + count).reduce(0) { $0 << 8 | Int(bytes[$1]) } }
        guard bytes.count >= 32, String(decoding: bytes[4..<8], as: UTF8.self) == "sidx" else { throw TVError.unsupported("no sidx box") }
        let size = number(0, 4)
        let version = bytes[8]
        var cursor = 16  // size, type, version/flags, reference_ID
        let timescale = number(cursor, 4); cursor += 4
        let wide = version == 0 ? 4 : 8
        guard bytes.count >= cursor + 2 * wide + 4 else { throw TVError.unsupported("short sidx box") }
        cursor += wide  // earliest_presentation_time
        let firstOffset = number(cursor, wide); cursor += wide
        cursor += 2
        let count = number(cursor, 2); cursor += 2
        guard timescale > 0, count > 0, bytes.count >= cursor + count * 12 else { throw TVError.unsupported("short sidx box") }
        var offset = start + size + firstOffset
        var references: [Reference] = []
        for _ in 0..<count {
            let word = number(cursor, 4)
            // A reference to another sidx (hierarchical index) is not a media fragment.
            guard word >> 31 == 0 else { throw TVError.unsupported("hierarchical sidx") }
            let length = word & 0x7fff_ffff
            references.append(Reference(offset: offset, size: length, duration: number(cursor + 4, 4)))
            offset += length; cursor += 12
        }
        self.timescale = timescale; self.references = references; self.initialization = initialization; self.url = url
    }

    /// Peak and average bits per second over the fragments, for the master playlist.
    var bitRates: (peak: Int, average: Int) {
        let seconds = references.reduce(0.0) { $0 + Double($1.duration) } / Double(timescale)
        let bytes = references.reduce(0) { $0 + $1.size }
        let peak = references.map { Double($0.size * 8) / max(0.001, Double($0.duration) / Double(timescale)) }.max() ?? 0
        return (Int(peak), seconds > 0 ? Int(Double(bytes * 8) / seconds) : Int(peak))
    }
}

/// The generated playlists, kept for the few most recent playbacks.
final class PlaylistStore: @unchecked Sendable {
    static let shared = PlaylistStore()
    private let lock = NSLock()
    private var streams: [String: [String: String]] = [:]
    private var choices: [String: [StreamQuality]] = [:]
    private var files: [String: [DashFiles]] = [:]
    private var order: [String] = []

    /// A new playback's identity, used as the playlist addresses' host.
    static func token() -> String { UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "") }
    func add(_ playlists: [String: String], token: String, qualities: [StreamQuality] = [], sources: [DashFiles] = []) {
        lock.withLock {
            streams[token] = playlists; choices[token] = qualities; files[token] = sources; order.append(token)
            while order.count > 4 { let old = order.removeFirst(); streams[old] = nil; choices[old] = nil; files[old] = nil }
        }
    }
    func sources(_ url: URL) -> [DashFiles] {
        guard let token = url.host else { return [] }
        return lock.withLock { files[token] ?? [] }
    }
    func qualities(_ url: URL) -> [StreamQuality] {
        guard let token = url.host else { return [] }
        return lock.withLock { choices[token] ?? [] }
    }
    func playlist(_ url: URL) -> String? {
        guard let token = url.host else { return nil }
        return lock.withLock { streams[token]?[url.lastPathComponent] }
    }
}

/// Answers AVPlayer's requests for `tvbox-bili://` playlists; media requests go to the CDN directly.
final class PlaylistLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let shared = PlaylistLoader()
    let queue = DispatchQueue(label: "tvbox.bilibili.playlists")

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == BilibiliStreams.scheme else { return false }
        guard let text = PlaylistStore.shared.playlist(url) else {
            loadingRequest.finishLoading(with: TVError.unsupported(L10n.text("This playback has expired. Open the video again.")))
            return true
        }
        loadingRequest.dataRequest?.respond(with: Data(text.utf8))
        loadingRequest.finishLoading()
        return true
    }
}
