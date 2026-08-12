import SwiftUI

/// 设置页主视图: 库管理 / 音质 / EQ 入口 / 歌词 / 主题 / 关于。
struct SettingsView: View {
    @State private var showEQEditor = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("设置").font(.largeTitle).fontWeight(.bold)
                    .foregroundStyle(BrandColors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 16)

                Form {
                    ScanRootsSettingsView()
                    AudioQualitySettingsView()
                    LyricsSettingsView()

                    Section("Equalizer") {
                        Button { showEQEditor = true } label: {
                            Label("打开 EQ 编辑器", systemImage: "slider.vertical.3")
                        }
                        .buttonStyle(.bordered)
                        .tint(BrandColors.cyan)
                    }

                    ThemeSettingsView()
                    AboutView()
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
            .padding(24)
        }
        .background(BrandColors.background)
        .sheet(isPresented: $showEQEditor) {
            EQEditorView()
        }
    }
}