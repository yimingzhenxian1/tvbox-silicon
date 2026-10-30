import Foundation
import Perception

/// Owns the requested catalog location so retries and overlapping requests stay consistent.
@MainActor @Perceptible public final class CatalogBrowser {
    public enum Request: Equatable, Sendable {
        case home
        case list(category: String?, query: String, page: Int)
    }
    public private(set) var categories: [Category] = []
    public private(set) var videos: [Video] = []
    public private(set) var category = ""
    public private(set) var query = ""
    public private(set) var page = 1
    public private(set) var pageCount = 1
    public private(set) var busy = false
    public private(set) var loaded = false
    public private(set) var error: String?
    public private(set) var request: Request = .home
    private var generation = 0
    private var pending: Task<CatalogPage, Error>?
    private var pendingCategories: Task<CatalogPage, Error>?
    public init() {}

    /// Release this page's work without discarding already displayed content.
    public func cancel() {
        generation += 1
        pending?.cancel(); pending = nil
        pendingCategories?.cancel(); pendingCategories = nil
        if busy { loaded = false }
        busy = false
    }

    public func load(_ request: Request, client: CatalogClient) async {
        await load(request, context: client.reportContext) { request in
            switch request {
            case .home: return try await client.home()
            case let .list(category, query, page): return try await client.list(category: category, query: query, page: page)
            }
        }
    }

    /// The category bar for a page that opened on a search: categories only come with the home
    /// answer, so fetch it without touching the videos on screen.
    public func loadCategories(client: CatalogClient) async {
        guard !Task.isCancelled, categories.isEmpty, pendingCategories == nil else { return }
        let current = generation
        let task = Task { try await client.home() }
        pendingCategories = task
        defer { if generation == current { pendingCategories = nil } }
        let home = try? await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard generation == current, !Task.isCancelled, !task.isCancelled, categories.isEmpty, let home else { return }
        categories = home.categories
    }

    public func load(_ request: Request, context: String = "-", fetch: @escaping @Sendable (Request) async throws -> CatalogPage) async {
        guard !Task.isCancelled else { return }
        pending?.cancel()
        pendingCategories?.cancel(); pendingCategories = nil
        generation += 1
        let current = generation
        self.request = request
        busy = true; loaded = false; error = nil
        switch request {
        case .home: category = ""; query = ""; page = 1
        case let .list(category, query, page): self.category = category ?? ""; self.query = query; self.page = page
        }
        videos = []; pageCount = 1
        defer { if generation == current { pending = nil; busy = false; if !Task.isCancelled { loaded = true } } }
        func perform(_ request: Request) async throws -> CatalogPage {
            let task = Task { try await fetch(request) }
            pending = task
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }
        do {
            var result = try await perform(request)
            guard generation == current, !Task.isCancelled else { return }
            if request == .home {
                categories = result.categories
                if result.videos.isEmpty, let first = categories.first {
                    category = first.id
                    self.request = .list(category: first.id, query: "", page: 1)
                    result = try await perform(self.request)
                }
            }
            guard generation == current, !Task.isCancelled else { return }
            var seen = Set<String>()
            videos = result.videos.filter { seen.insert($0.id).inserted }
            pageCount = result.pageCount
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            Diagnostics.shared.failure("catalog", "\(request == .home ? "home" : "list") \(context)", error)
            self.error = error.localizedDescription
        }
    }
}
