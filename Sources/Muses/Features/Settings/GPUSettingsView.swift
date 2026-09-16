import SwiftUI

/// GPU acceleration settings (Metal spectrum rendering toggle).
struct GPUSettingsView: View {
    @AppStorage(PrefKey.gpuAcceleration) var gpuAcceleration = true

    var body: some View {
        Section {
            Toggle(tr("Metal Spectrum Rendering", "Metal 频谱渲染", zhHant: "Metal 頻譜算繪"), isOn: $gpuAcceleration)
                .tint(BrandColors.accent)
            Text(tr("Applies to the spectrum display in Audio Info.",
                    "仅作用于音频信息中的频谱显示。"))
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
        } header: { Text(tr("Performance", "性能")).font(.headline.weight(.semibold)) }
    }
}
