import SwiftUI

/// GPU acceleration settings (Metal spectrum rendering toggle).
struct GPUSettingsView: View {
    @AppStorage(PrefKey.gpuAcceleration) var gpuAcceleration = true

    var body: some View {
        Section(tr("Performance", "性能")) {
            Toggle(tr("GPU Acceleration", "GPU 加速"), isOn: $gpuAcceleration)
                .tint(BrandColors.magenta)
        }
    }
}