import Perception
import SwiftUI
import TVCore

struct CacheSettingsView: View {
    @State private var summary = MediaCache.shared.summary()
    @State private var confirmsClear = false
    @State private var clearing = false
    var body: some View {
        WithPerceptionTracking {
        SettingsPage(title: L10n.text("Local Cache"), symbol: "internaldrive") {
            SettingsGroup(title: L10n.text("Cached Content"), footer: L10n.text("Artwork is kept for 30 days, danmaku for 7 days and episode lists for 6 hours, up to 256 MB. History titles are prioritized. Only the latest 20 successful work address mappings are retained.")) {
                SettingsRow(symbol: "internaldrive", tint: Brand.cyan, title: ByteCountFormatter.string(fromByteCount: Int64(summary.bytes), countStyle: .file))
                SettingsRow(symbol: "photo", tint: .orange, title: L10n.text("Artwork: %lld", summary.artwork))
                SettingsRow(symbol: "text.bubble", tint: .blue, title: L10n.text("Episode danmaku: %lld", summary.danmaku))
                SettingsRow(symbol: "list.bullet", tint: .purple, title: L10n.text("Episode lists: %lld", summary.catalogs))
                SettingsRow(symbol: "link", tint: .gray, title: L10n.text("Recent work mappings: %lld / 20", summary.lookups))
            }
            SettingsGroup(footer: L10n.text("Clears artwork, episode lists, danmaku and address mappings. Playback history, subscriptions, pinned sources and skip settings are kept.")) {
                SettingsActionRow(title: L10n.text(clearing ? "Clearing…" : "Clear local cache"), destructive: true) { confirmsClear = true }
                    .disabled(clearing).accessibilityIdentifier("cache.clear")
            }
        }
        .task { summary = await Task.detached { MediaCache.shared.summary() }.value }
        .confirmationDialog(L10n.text("Clear all local cached content?"), isPresented: $confirmsClear, titleVisibility: .visible) {
            Button(L10n.text("Clear local cache"), role: .destructive) {
                clearing = true
                Task {
                    await Task.detached { MediaCache.shared.clear(); URLCache.shared.removeAllCachedResponses() }.value
                    summary = MediaCache.shared.summary(); clearing = false
                }
            }.accessibilityIdentifier("cache.confirmClear")
            Button(L10n.text("Cancel"), role: .cancel) {}
        }
        }
    }
}
