import SwiftUI

/// GPU 加速设置(Metal 频谱渲染开关)。
struct GPUSettingsView: View {
    @AppStorage(PrefKey.gpuAcceleration) var gpuAcceleration = true

    var body: some View {
        Section(tr("Performance", "性能")) {
            Toggle(tr("GPU Acceleration (Metal spectrum)", "GPU 加速(Metal 频谱)"), isOn: $gpuAcceleration)
            Text(tr("Use Metal for hardware-accelerated spectrum visualization.",
                    "使用 Metal 硬件加速频谱可视化。"))
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
        }
    }
}