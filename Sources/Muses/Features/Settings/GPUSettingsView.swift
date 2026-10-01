import SwiftUI

/// GPU acceleration settings (Metal spectrum rendering toggle).
struct GPUSettingsView: View {
    @AppStorage(PrefKey.gpuAcceleration) var gpuAcceleration = true

    var body: some View {
        Section {
            SettingsExplainedToggle(title: tr("Metal spectrum", "Metal 频谱"), isOn: $gpuAcceleration,
                information: tr("Applies to the spectrum display in Audio Info.",
                                "用于音频信息中的频谱显示。"))
        } header: { Text(tr("Performance", "性能")).font(MusesTypography.headline.weight(.semibold)) }
    }
}
