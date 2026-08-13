import SwiftUI

/// YouTube Music 合并页:搜索 + 导入,通过 SegmentedControl 切换。
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
            // 标题 + Tab 切换
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

            // 内容区
            switch selectedTab {
            case .search:
                YouTubeSearchView()
            case .imports:
                YouTubeImportsView()
            }
        }
        .background(BrandColors.background)
    }
}