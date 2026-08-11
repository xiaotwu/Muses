import SwiftUI
import AppKit

struct SidebarView: View {
    @Binding var selection: SidebarSection
    @Environment(PlaybackService.self) private var playback

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Muses") {
                    Label("Home", systemImage: "house").tag(SidebarSection.home)
                    Label("Albums", systemImage: "square.stack").tag(SidebarSection.albums)
                    Label("Songs", systemImage: "music.note").tag(SidebarSection.songs)
                    Label("Liked", systemImage: "heart").tag(SidebarSection.liked)
                }
                Section("Settings") {
                    Label("Settings", systemImage: "gear").tag(SidebarSection.settings)
                }
            }
            Divider()
            miniNow
        }
        .frame(width: 220)
        .background(BrandColors.surface)
    }

    private var miniNow: some View {
        HStack(spacing: 10) {
            if let h = playback.state.track?.artworkHash,
               let p = ArtworkCache.default.path(forHash: h) {
                Image(nsImage: NSImage(byReferencing: p)).resizable().scaledToFill()
                    .frame(width: 44, height: 44).clipped().cornerRadius(6)
            } else {
                Rectangle().fill(BrandColors.surface)
                    .frame(width: 44, height: 44).cornerRadius(6)
            }
            VStack(alignment: .leading) {
                Text(playback.state.track?.title ?? "Not Playing").font(.callout).lineLimit(1)
                Text(playback.state.track?.artist ?? "").font(.caption)
                    .foregroundStyle(BrandColors.textSecondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
    }
}