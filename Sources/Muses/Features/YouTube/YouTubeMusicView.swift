import SwiftUI

/// Combined YouTube Music page: search + import, switched with a segmented control.
struct YouTubeMusicView: View {
    @State private var selectedTab: YTMTab = .search

    enum YTMTab: String, CaseIterable {
        case search, imports
        var label: String {
            switch self {
            case .search:  return tr("Search", "搜索")
            case .imports: return tr("Imports", "导入")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title + tab switch
            HStack {
                Text(tr("YouTube Music", "YouTube Music"))
                    .font(.largeTitle).fontWeight(.bold)
                    .foregroundStyle(BrandColors.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Picker("", selection: $selectedTab) {
                ForEach(YTMTab.allCases, id: \.self) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)

            // Content area
            switch selectedTab {
            case .search:
                YouTubeSearchView()
            case .imports:
                YouTubeImportsView(embedded: true)
            }
        }
        .background(BrandColors.background)
    }
}