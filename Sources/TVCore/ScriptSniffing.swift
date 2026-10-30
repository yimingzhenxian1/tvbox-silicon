import Foundation

extension Site {
    /// A type 3 api that is a web address naming no `.js` or `.py` file, such as a short link.
    /// A JAR class name is never an address, so what the address serves decides how it runs.
    var needsSniffing: Bool {
        guard type == 3, detectedRuntime == nil, runtime == .jar else { return false }
        let scheme = URL(string: api.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    /// What a downloaded spider is, when its content says so. Python spiders all build on the
    /// shell's `base.spider` module.
    static func sniffedRuntime(_ data: Data) -> SourceRuntime? {
        guard !data.starts(with: Data("PK".utf8)) else { return nil }
        let text = String(decoding: data.prefix(256 * 1024), as: UTF8.self)
        let python = #"(?m)^[ \t]*(from[ \t]+base(\.spider)?[ \t]+import|import[ \t]+base\.spider)\b"#
        return (text.range(of: python, options: .regularExpression) != nil) ? .python : nil
    }
}

extension Subscription {
    /// Downloads each source `Site.needsSniffing` names and records what it turned out to be.
    /// One that fails to download or isn't recognized stays a JAR class, as TVBox reads it.
    func sniffingScripts(http: HTTPClient) async -> Subscription {
        let pending = sites.indices.filter { sites[$0].needsSniffing }
        guard !pending.isEmpty else { return self }
        var sites = sites
        let found = await withTaskGroup(of: (Int, SourceRuntime?).self) { group in
            for index in pending {
                let site = sites[index], origin = origin
                group.addTask {
                    guard let url = try? site.scriptURL(origin: origin),
                          let (data, _) = try? await http.get(url) else { return (index, nil) }
                    return (index, Site.sniffedRuntime(data))
                }
            }
            var found: [(Int, SourceRuntime?)] = []
            for await result in group { found.append(result) }
            return found
        }
        for (index, runtime) in found {
            sites[index].detectedRuntime = runtime
            Diagnostics.shared.record(.info, "subscription", "sniffed source=\(sites[index].key) host=\(URL(string: sites[index].api)?.host ?? "-") runtime=\(runtime.map { "\($0)" } ?? "unknown")")
        }
        return Subscription(origin: origin, importedAt: importedAt, sites: sites, lives: lives, raw: raw)
    }
}
