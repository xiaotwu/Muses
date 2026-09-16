import SwiftUI
import AppKit

/// Settings categories and compatibility redirects for saved selections.
enum SettingsCategory: String, Hashable, CaseIterable, Identifiable {
    case general, playback, audioQuality, appearance, youtube, lyrics, desktop, updates, about, diagnostics, identity, help

    static let allCases: [SettingsCategory] = [.general, .playback, .appearance, .youtube, .lyrics, .diagnostics, .identity, .about, .help]

    /// Preserve saved selections and existing deep links after regrouping.
    var destination: SettingsCategory {
        switch self {
        case .audioQuality: return .playback
        case .desktop: return .appearance
        case .updates: return .about
        default: return self
        }
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .diagnostics: return tr("Diagnostics", "诊断", zhHant: "診斷")
        case .identity: return tr("Library Review", "资料库核对", zhHant: "資料庫核對")
        case .help: return tr("Help & Privacy", "帮助与隐私", zhHant: "說明與隱私")
        case .general:      return tr("General", "通用")
        case .playback:     return tr("Playback & Quality", "播放与音质")
        case .audioQuality: return tr("Quality", "清晰度")
        case .appearance:   return tr("Appearance & Desktop", "外观与桌面")
        case .youtube:      return tr("Account & Content", "账号与内容")
        case .lyrics:       return tr("Lyrics & Intelligence", "歌词与智能")
        case .desktop:      return tr("Desktop", "桌面")
        case .updates:      return tr("Updates", "更新")
        case .about:        return tr("About & Updates", "关于与更新")
        }
    }

    var sidebarLabel: String {
        switch destination {
        case .general: return tr("General", "通用", zhHant: "一般")
        case .playback: return tr("Playback", "播放", zhHant: "播放")
        case .appearance: return tr("Appearance", "外观", zhHant: "外觀")
        case .youtube: return tr("Account", "账号", zhHant: "帳號")
        case .lyrics: return tr("Lyrics", "歌词", zhHant: "歌詞")
        case .diagnostics, .identity, .help: return label
        default: return tr("About", "关于", zhHant: "關於")
        }
    }

    var toolbarIcon: String {
        switch self {
        case .diagnostics: return "stethoscope"
        case .identity: return "checklist"
        case .help: return "questionmark.circle"
        case .general:      return "gearshape"
        case .playback:     return "play.circle"
        case .audioQuality: return "sparkles.tv"
        case .appearance:   return "paintbrush"
        case .youtube:      return "person.crop.circle"
        case .lyrics:       return "text.alignleft"
        case .desktop:      return "menubar.rectangle"
        case .updates:      return "arrow.triangle.2.circlepath"
        case .about:        return "info.circle"
        }
    }
}

/// Integrated settings destination; shares the main window and app services.
enum SettingsDestination: String, Hashable, Codable {
    case desktop, graphics, help, account, webHome, playbackAccess, diagnostics, identity, lyricsSupport
}

struct SettingsPage: View {
    @Binding var path: [SettingsDestination]
    @AppStorage(PrefKey.settingsLastPane) private var paneRaw = SettingsCategory.general.rawValue
    @AppStorage(PrefKey.language) private var languageRaw = AppLanguage.system.rawValue

    private var currentCategory: SettingsCategory {
        (SettingsCategory(rawValue: paneRaw) ?? .general).destination
    }

    var body: some View {
        Group {
            if currentCategory == .identity {
                CatalogIdentityReviewView()
                    .padding(24)
            } else {
                ScrollView {
                    Form {
                        switch currentCategory {
                        case .general:
                            LanguageSettingsView()
                            NotificationsSettingsView()
                        case .playback, .audioQuality:
                            PlaybackSettingsView()
                            AudioQualitySettingsView()
                        case .appearance, .desktop:
                            ThemeSettingsView()
                            DesktopSettingsView()
                            GPUSettingsView()
                        case .youtube:
                            YouTubeSettingsView()
                        case .lyrics:
                            LyricsSettingsView()
                            LyricsSupportView(availability: LyricsIntelligence.availability)
                        case .diagnostics:
                            YouTubeSettingsView(destination: .diagnostics)
                        case .about, .updates:
                            AboutSettingsView()
                            UpdatesSettingsView()
                        case .help:
                            SettingsHelpView()
                        case .identity:
                            EmptyView()
                        }
                    }
                    .formStyle(SettingsContentStyle())
                    .frame(maxWidth: 860, alignment: .leading)
                    .padding(32)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .settingsPageTitle(currentCategory.label)
            }
        }
        .onChange(of: languageRaw) { _, value in LanguagePreferences.shared.update(value) }
        .padding(.bottom, OverlayChromeMetrics.scrollBottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandColors.background)
        .tint(BrandColors.accent)
    }
}

/// Open sections share consistent spacing without nested scroll views or cards.
struct SettingsContentStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            configuration.content
        }
        .font(.system(size: 13))
        .lineSpacing(4)
        .controlSize(.large)
        .toggleStyle(.switch)
    }
}

/// About settings page: logo + version + GitHub link + compliance notice.
/// Update checking lives in the dedicated Updates pane.
struct AboutSettingsView: View {
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        Section {
            HStack(spacing: 16) {
                MusesMark(size: 56)
                    .accessibilityLabel("Muses")
                VStack(alignment: .leading) {
                    Text("Muses").font(BrandFont.muses(30))
                        .foregroundStyle(BrandColors.textPrimary)
                    Text("\(tr("Version", "版本")) \(appVersion)")
                        .font(.caption).foregroundStyle(BrandColors.textSecondary)
                }
                Spacer()
            }

            Button {
                if let url = URL(string: "https://github.com/xiaotwu/Muses") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label(tr("GitHub Project", "GitHub 项目"), systemImage: "link")
            }
            .labelStyle(ActionIconLabelStyle())
            .help(tr("GitHub Project", "GitHub 项目"))

        } header: { Text(tr("About", "关于")).font(.headline.weight(.semibold)) }
    }
}

/// Settings headings belong to their content pane, never the shared window toolbar.
extension View {
    func settingsPageTitle(_ title: String, showsBack: Bool = true) -> some View {
        modifier(SettingsPageTitle(title: title, showsBack: showsBack))
    }
}

private struct SettingsPageTitle: ViewModifier {
    let title: String
    let showsBack: Bool

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(BrandColors.background)
            }
            .background(BrandColors.background)
    }
}
