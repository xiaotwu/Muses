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
    @AppStorage(PrefKey.lyricsSource) private var lyricsSource = "lrclib"
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
        } header: { Text(tr("Display", "显示")).font(.headline.weight(.semibold)) }
        Section {
            Picker(tr("Lyrics Source", "歌词来源"), selection: $lyricsSource) {
                Text("LRCLIB").tag("lrclib")
                Text("Musixmatch").tag("musixmatch")
            }
            .pickerStyle(.menu)
            Toggle(tr("Intelligent matching", "智能匹配"), isOn: $intelligentMatching)
                .disabled(availability != .available && !intelligentMatching)
            LabeledContent("Apple Intelligence", value: availability.message)
                .font(.caption).italic().foregroundStyle(.secondary)
        } header: { Text(tr("Matching", "匹配")).font(.headline.weight(.semibold)) }
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
        Group {
            Section {
                Text(tr("Muses checks the title, artist, duration and recording version before choosing lyrics. Apple Intelligence can help compare plausible candidates on this Mac. Use Match Lyrics when a result is uncertain; original lyrics are never generated from memory.",
                        "Muses 会核对标题、艺人、时长和录音版本，再选择歌词。Apple Intelligence 可以在此 Mac 上辅助比较候选。不确定的结果可通过「匹配歌词」手动选择，原文歌词不会由模型凭记忆生成。"))
            } header: { Text(tr("Accurate matching", "准确匹配")).font(.headline.weight(.semibold)) }
            Section {
                Text(tr("Translation uses Apple's Translation framework on macOS 15 or later, with supported language pairs and any required model downloads. Romanization uses Apple's on-device model on macOS 26 or later. Both are labeled as automatic and may contain errors; original lyrics remain available.",
                        "翻译使用 macOS 15 或更高版本的 Apple 翻译框架，需要受支持的语言组合，并可能需要下载语言模型。音译使用 macOS 26 或更高版本的 Apple 端侧模型。两者均会标注为自动处理，可能存在错误，原文歌词始终保留。"))
            } header: { Text(tr("Translation and pronunciation", "翻译与发音")).font(.headline.weight(.semibold)) }
            Section {
                Text(availability.message)
                Text(tr("Apple Intelligence requires a supported Mac, an enabled and downloaded model, and a supported language and region. Apple's current restrictions include devices purchased in China mainland, and devices used there with an Apple Account set to China mainland. Muses checks actual model availability; changing the app language does not unlock it. Ordinary lyric lookup works independently.",
                        "Apple Intelligence 需要受支持的 Mac、已启用并下载的模型，以及受支持的语言和地区。Apple 当前的限制包括中国大陆购买的设备，以及在中国大陆使用且 Apple 账号地区也设为中国大陆的设备。Muses 以实际模型可用状态为准，切换应用语言不能解锁。普通歌词检索独立运行。"))
                Link(tr("Latest availability from Apple", "Apple 最新可用性说明"), destination: URL(string: "https://support.apple.com/121115")!)
            } header: { Text(tr("Device and region availability", "设备与地区可用性")).font(.headline.weight(.semibold)) }
        }

    }
}
