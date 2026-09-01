import SwiftUI

/// Legacy top-bar implementation retained for source compatibility.
/// The current Apple Music Web shell uses the left navigation pane instead.
struct AppTopBar: View {
    @Binding var section: SidebarSection
    @Binding var showSettings: Bool
    @Environment(YouTubeAccountService.self) private var youTubeAccount
    @Environment(GlobalSearchService.self) private var search
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 16) {
            TrafficLightsPad()
            Text("Muses")
                .font(BrandFont.muses(22))
                .foregroundStyle(BrandColors.textPrimary)
                .padding(.leading, 4)
            tabs
            Spacer(minLength: 12)
            searchField
            avatar
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(BrandColors.background)
        .onReceive(NotificationCenter.default.publisher(for: .musesFocusSearch)) { _ in
            searchFocused = true
        }
    }

    private var tabs: some View {
        HStack(spacing: 18) {
            ForEach(AppTopTab.allCases, id: \.self) { tab in
                let on = AppTopTab.from(section) == tab
                Button {
                    switch tab {
                    case .home: section = .home
                    case .new: section = .new
                    case .library:
                        if !section.isLibrary { section = .songs }
                    }
                } label: {
                    Text(tab.label)
                        .font(.subheadline.weight(on ? .semibold : .regular))
                        .foregroundStyle(BrandColors.textPrimary)
                        .opacity(on ? 1 : 0.7)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BrandColors.textSecondary)
            TextField(tr("Search", "搜索"), text: Binding(
                get: { search.query },
                set: { search.query = $0 }
            ))
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand {
                    search.reset()
                    searchFocused = false
                }
        }
        .padding(.horizontal, 10)
        .frame(width: 196, height: 28)
        .background(BrandColors.surface, in: Capsule())
        .help(tr("Search", "搜索"))
        .accessibilityLabel(tr("Search", "搜索"))
    }

    private var avatar: some View {
        Button {
            showSettings = true
        } label: {
            ChromeGlyph(
                systemName: "person.crop.circle.fill",
                selected: youTubeAccount.isConnected,
                size: 18,
                hit: 28
            )
        }
        .buttonStyle(.plain)
        .help(tr("Settings", "设置"))
        .accessibilityLabel(tr("Open Settings", "打开设置"))
    }
}
