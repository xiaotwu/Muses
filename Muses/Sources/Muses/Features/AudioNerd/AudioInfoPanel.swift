import SwiftUI

/// 音频信息面板(Final Spec §10.10 Feature 10 — Audio Nerd Mode)。
///
/// 展示**真实**元数据:codec/container/bitrate/sample rate/bit depth/channels/source/
/// output device/replayGain/EQ state/volume。任一字段不可得显示「Unknown」,绝不伪造(§15)。
/// 内嵌频谱(MetalSpectrumView,既有)+ 打开 EQ 编辑器入口。受 `ffAudioNerd` 约束。
struct AudioInfoPanel: View {
    @Environment(PlaybackService.self) private var playback
    @Environment(AudioDeviceService.self) private var deviceService
    @AppStorage(PrefKey.eqActivePresetId) private var eqPresetId: String = "Flat"
    @State private var showEQ = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Audio Info", "音频信息"))
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(BrandColors.textPrimary)

            // 元数据行(纯模型驱动)。
            let rows = AudioInfoModel.rows(
                track: playback.state.track, defaultDeviceName: currentDeviceName,
                eqPresetId: eqPresetId, volume: Double(playback.volume))
            GroupBox(tr("Track", "曲目")) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows, id: \.label) { row in
                        HStack {
                            Text(row.label).foregroundStyle(BrandColors.textSecondary)
                            Spacer()
                            Text(row.value).foregroundStyle(BrandColors.textPrimary)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }
                .padding(8)
            }

            // 输出设备选择。
            GroupBox(tr("Output Device", "输出设备")) {
                devicePicker.padding(8)
            }

            // 频谱(既有,复用)。
            GroupBox(tr("Spectrum", "频谱")) {
                MetalSpectrumView()
                    .frame(height: 90)
                    .padding(8)
            }

            // EQ 入口。
            Button {
                showEQ = true
            } label: {
                Label(tr("Open EQ Editor", "打开 EQ 编辑器"), systemImage: "slider.vertical.3")
            }
            .buttonStyle(.bordered)
            .tint(BrandColors.magenta)
        }
        .padding(20)
        .frame(width: 420)
        .background(.regularMaterial)
        .sheet(isPresented: $showEQ) { EQEditorView() }
        .onAppear { deviceService.refresh() }
    }

    private var currentDeviceName: String? {
        guard let id = deviceService.defaultDeviceID else { return nil }
        return deviceService.devices.first { $0.id == id }?.name
    }

    private var devicePicker: some View {
        Picker(tr("Device", "设备"), selection: Binding(
            get: { deviceService.defaultDeviceID ?? 0 },
            set: { deviceService.setDefault($0) })) {
            if deviceService.devices.isEmpty {
                Text(tr("Unknown", "未知")).tag(UInt32(0))
            } else {
                ForEach(deviceService.devices) { d in
                    Text(d.name).tag(d.id)
                }
            }
        }
        .pickerStyle(.menu)
    }
}

/// 音频信息行模型(纯值,便于无 UI 依赖的单元测试)。
enum AudioInfoModel {
    struct Row: Equatable, Sendable { let label: String; let value: String }

    static let unknown = tr("Unknown", "未知")

    /// 由曲目快照 + 输出设备名 + EQ 预设 id + 音量 → 有序信息行。nil 字段 → "Unknown"。
    static func rows(track: TrackSnapshot?, defaultDeviceName: String?,
                     eqPresetId: String, volume: Double) -> [Row] {
        let src: String
        if let t = track { src = t.youTubeId != nil ? "YouTube" : "Local" }
        else { src = unknown }
        return [
            Row(label: tr("Codec", "编码"), value: track?.codec ?? unknown),
            Row(label: tr("Lossless", "无损"),
                value: track.map { $0.isLossless ? tr("Yes", "是") : tr("No", "否") } ?? unknown),
            Row(label: tr("Sample Rate", "采样率"),
                value: track?.sampleRate.map { "\($0 / 1000) kHz" } ?? unknown),
            Row(label: tr("Bit Depth", "位深"),
                value: track?.bitDepth.map { "\($0)-bit" } ?? unknown),
            Row(label: tr("Bit Rate", "比特率"),
                value: track?.bitRate.map { "\($0 / 1000) kbps" } ?? unknown),
            Row(label: tr("Channels", "声道"),
                value: track?.channels.map { $0 == 1 ? tr("Mono", "单声道")
                                       : $0 == 2 ? tr("Stereo", "立体声")
                                       : "\($0)" } ?? unknown),
            Row(label: tr("Source", "来源"), value: src),
            Row(label: tr("Output Device", "输出设备"), value: defaultDeviceName ?? unknown),
            Row(label: tr("ReplayGain", "回放增益"),
                value: track?.replayGain.map { String(format: "%+.1f dB", $0) } ?? unknown),
            Row(label: tr("EQ Preset", "EQ 预设"), value: eqPresetId.isEmpty ? unknown : eqPresetId),
            Row(label: tr("Volume", "音量"), value: String(format: "%.0f%%", volume * 100))
        ]
    }
}