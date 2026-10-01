import SwiftUI

struct LyricsTranslationPicker: View {
    @Binding var selection: String

    var body: some View {
        Picker(tr("Translation", "翻译"), selection: $selection) {
            Text(tr("Off", "关闭")).tag("off")
            Text("English").tag("en")
            Text("简体中文").tag("zh-Hans")
            Text("繁體中文").tag("zh-Hant")
        }
    }
}

struct LyricsSettingsView: View {
    @AppStorage(PrefKey.lyricsSource) private var lyricsSource = "auto"
    @AppStorage(PrefKey.lyricsIntelligence) private var intelligentMatching = true
    @AppStorage(PrefKey.lyricsTranslationLanguage) private var translationTarget = "off"
    @AppStorage(PrefKey.lyricsRomanization) private var romanization = false
    @State private var availability = LyricsIntelligence.availability

    var body: some View {
        Section {
            LyricsTranslationPicker(selection: $translationTarget)
                .disabled(!supportsTranslation)
            Toggle(tr("Romanization", "音译"), isOn: $romanization)
                .disabled(availability != .available && !romanization)
        } header: { Text(tr("Display", "显示")).font(MusesTypography.headline.weight(.semibold)) }
        Section {
            Picker(tr("Preferred source", "优先来源", zhHant: "優先來源"), selection: $lyricsSource) {
                Text(tr("Automatic", "自动", zhHant: "自動")).tag("auto")
                Text("LRCLIB").tag("lrclib")
                Text("Musixmatch").tag("musixmatch")
                Text("Lyrics.ovh").tag("lyricsOVH")
            }
            .pickerStyle(.menu)
            .help(tr("Try other sources when no lyrics are found", "未找到歌词时尝试其他来源", zhHant: "未找到歌詞時嘗試其他來源"))
            Toggle(tr("Intelligent matching", "智能匹配"), isOn: $intelligentMatching)
                .disabled(availability != .available && !intelligentMatching)
            LabeledContent("Apple Intelligence", value: availability.message)
                .font(MusesTypography.caption).foregroundStyle(.secondary)
        } header: { Text(tr("Matching", "匹配")).font(MusesTypography.headline.weight(.semibold)) }
        .onAppear { availability = LyricsIntelligence.availability }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            availability = LyricsIntelligence.availability
        }
    }

    private var supportsTranslation: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }
}

struct LyricsSupportView: View {
    let availability: LyricsIntelligence.Availability

    var body: some View {
        Section {
            DisclosureGroup(tr("Lyrics & translation", "歌词与翻译")) {
                Text(tr("Lyrics come from sources, never generated from memory.", "歌词来自检索来源，不凭记忆生成。"))
                    .font(MusesTypography.caption).foregroundStyle(.secondary)
                Text(tr("Automatic translation and romanization may contain errors. Original lyrics remain available.",
                        "自动翻译和音译可能有误，原文歌词始终保留。"))
                    .font(MusesTypography.caption).foregroundStyle(.secondary)
            }
            LabeledContent(tr("Intelligence support", "智能功能支持")) {
                SettingsIconButton(title: tr("Apple Intelligence availability", "Apple Intelligence 可用性"), symbol: "arrow.up.right") {
                    NSWorkspace.shared.open(URL(string: "https://support.apple.com/121115")!)
                }
            }
        } header: { Text(tr("Information", "说明")) }
    }
}
