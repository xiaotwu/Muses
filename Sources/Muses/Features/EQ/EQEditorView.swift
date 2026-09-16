import SwiftUI
import SwiftData

/// 10-band graphic EQ editor: vertical slider bars + a smooth curve + preset management (built-in + custom).
/// Changes are pushed to PlaybackService.setEQ in real time. During AVPlayer streaming
/// the engine treats setEQ as a no-op until playback switches to the local file.
struct EQEditorView: View {
    @Environment(PlaybackService.self) private var playback
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \EQPreset.createdAt, order: .reverse) private var customPresets: [EQPreset]

    @AppStorage(PrefKey.eqActivePresetId) private var activePresetIdRaw: String = "Flat"
    @Environment(\.dismiss) private var dismiss
    @State private var bands: [EQBand] = EQPresets.flat
    @State private var showSaveDialog = false
    @State private var newPresetName = ""

    private let gainRange: ClosedRange<Float> = -24...24

    var body: some View {
        VStack(spacing: 16) {
            header
            curveView
            bandControls
            presetSection
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .musesFloatingChrome(cornerRadius: 16)
        .onAppear {
            bands = playback.eqBands
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tr("Equalizer", "均衡器")).font(.title2).fontWeight(.bold)
                    .foregroundStyle(BrandColors.textPrimary)
                Spacer()
                Button { playback.setEQBypassed(!playback.eqBypassed) } label: {
                    Image(systemName: "power")
                }
                .tint(playback.eqBypassed ? BrandColors.textSecondary : BrandColors.accent)
                .help(tr("Bypass equalizer", "旁路均衡器", zhHant: "旁路均衡器"))
                .accessibilityLabel(tr("Bypass equalizer", "旁路均衡器", zhHant: "旁路均衡器"))
                .accessibilityValue(playback.eqBypassed ? tr("On", "开", zhHant: "開") : tr("Off", "关", zhHant: "關"))
                Button {
                    bands = EQPresets.flat
                    applyBands()
                    activePresetIdRaw = "Flat"
                } label: { Image(systemName: "arrow.counterclockwise") }
                .help(tr("Reset", "重置"))
                .accessibilityLabel(tr("Reset", "重置"))
                .musesAction()
                .tint(BrandColors.accent)
            .focusEffectDisabled()
                Button(tr("Close", "关闭"), systemImage: "xmark") { dismiss() }
                    .labelStyle(ActionIconLabelStyle())
                    .help(tr("Close", "关闭"))
                    .keyboardShortcut(.cancelAction)
            }
            StreamingEQAvailabilityNote()
        }
    }

    // MARK: - Curve view

    private var curveView: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                drawGrid(ctx: ctx, size: size)
                drawCurve(ctx: ctx, size: size)
            }
        }
        .frame(height: 160)
        .background(BrandColors.surface)
        .cornerRadius(8)
    }

    private func drawGrid(ctx: GraphicsContext, size: CGSize) {
        // Horizontal 0dB center line
        let midY = size.height / 2
        ctx.stroke(
            Path { p in p.move(to: CGPoint(x: 0, y: midY)); p.addLine(to: CGPoint(x: size.width, y: midY)) },
            with: .color(BrandColors.textSecondary.opacity(0.3)),
            lineWidth: 0.5
        )
        // ±12dB reference lines
        for db in [-12, 12] {
            let y = midY - CGFloat(db) / 24.0 * (size.height / 2)
            ctx.stroke(
                Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) },
                with: .color(BrandColors.textSecondary.opacity(0.15)),
                lineWidth: 0.5
            )
        }
    }

    private func drawCurve(ctx: GraphicsContext, size: CGSize) {
        guard !bands.isEmpty else { return }
        let n = bands.count
        let stepX = size.width / CGFloat(max(1, n - 1))
        let midY = size.height / 2
        var path = Path()
        for (i, band) in bands.enumerated() {
            let x = CGFloat(i) * stepX
            let y = midY - CGFloat(band.gain) / 24.0 * (size.height / 2)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.stroke(path, with: .color(BrandColors.accent), lineWidth: 2)

        // Band points
        for (i, band) in bands.enumerated() {
            let x = CGFloat(i) * stepX
            let y = midY - CGFloat(band.gain) / 24.0 * (size.height / 2)
            ctx.fill(
                Circle().path(in: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)),
                with: .color(BrandColors.accent)
            )
        }
    }

    // MARK: - Band controls

    private var bandControls: some View {
        HStack(spacing: 0) {
            ForEach(Array(bands.enumerated()), id: \.offset) { idx, _ in
                VStack(spacing: 4) {
                    Text(String(format: "%.0f", bands[idx].gain))
                        .font(.caption2)
                        .foregroundStyle(BrandColors.textSecondary)
                    Slider(value: Binding(
                        get: { Double(bands[idx].gain) },
                        set: { v in
                            bands[idx].gain = Float(v)
                            activePresetIdRaw = "Custom"
                            applyBands()
                        }), in: Double(gainRange.lowerBound)...Double(gainRange.upperBound))
                    .accessibilityLabel(formatFreq(bands[idx].frequency) + " Hz")
                    .accessibilityValue(String(format: "%+.1f dB", bands[idx].gain))
                    .labelsHidden()
                    .tint(BrandColors.accent)
            .focusEffectDisabled()
                    .rotationEffect(.degrees(-90))
                    .frame(width: 30, height: 80)
                    Text(formatFreq(bands[idx].frequency))
                        .font(.system(size: 9))
                        .foregroundStyle(BrandColors.textSecondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Presets

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tr("Presets", "预设")).font(.headline).foregroundStyle(BrandColors.textPrimary)
                Spacer()
                Button {
                    showSaveDialog = true
                } label: { Label(tr("Save As", "另存为"), systemImage: "plus") }
                    .labelStyle(.iconOnly)
                    .help(tr("Save As", "另存为"))
                    .musesAction()
                    .tint(BrandColors.accent)
            .focusEffectDisabled()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(BuiltinEQPresets.all, id: \.name) { preset in
                        presetChip(name: preset.name, isActive: activePresetIdRaw == preset.name) {
                            bands = preset.bands
                            applyBands()
                            activePresetIdRaw = preset.name
                        }
                    }
                    ForEach(customPresets) { preset in
                        presetChip(name: preset.name, isActive: activePresetIdRaw == preset.id.uuidString) {
                            bands = preset.bands
                            applyBands()
                            activePresetIdRaw = preset.id.uuidString
                        }
                        .contextMenu { Button(tr("Delete", "删除"), role: .destructive) { deletePreset(preset) } }
                    }
                }
            }
        }
        .alert(tr("Save Preset", "保存预设"), isPresented: $showSaveDialog) {
            TextField(tr("Name", "名称"), text: $newPresetName)
            Button(tr("Save", "保存")) { savePreset() }
            Button(tr("Cancel", "取消"), role: .cancel) {}
        }
    }

    private func presetChip(name: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name).font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(isActive ? BrandColors.accent.opacity(0.3) : BrandColors.surface)
                .foregroundStyle(isActive ? BrandColors.accent : BrandColors.textPrimary)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func applyBands() {
        playback.setEQ(bands)
    }

    private func savePreset() {
        guard !newPresetName.isEmpty else { return }
        let preset = EQPreset(name: newPresetName, bandsJSON: EQPreset.encode(bands))
        modelContext.insert(preset)
        try? modelContext.save()
        activePresetIdRaw = preset.id.uuidString
        newPresetName = ""
    }

    private func deletePreset(_ preset: EQPreset) {
        modelContext.delete(preset)
        try? modelContext.save()
        if activePresetIdRaw == preset.id.uuidString {
            bands = EQPresets.flat
            applyBands()
            activePresetIdRaw = "Flat"
        }
    }

    private func formatFreq(_ hz: Double) -> String {
        hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))"
    }
}

/// Solid caption used by the EQ editor and Audio Info. Readable under Reduce Transparency.
struct StreamingEQAvailabilityNote: View {
    @Environment(PlaybackService.self) private var playback

    private var message: String {
        if playback.eqBypassed {
            return tr("Equalizer bypassed. Your settings are saved.", "均衡器已旁路，设置已保留。", zhHant: "均衡器已旁路，設定已保留。")
        }
        switch playback.transportState.audioProcessing {
        case .available:
            return tr("Equalizer and spectrum are available.", "均衡器和频谱可用。", zhHant: "均衡器和頻譜可用。")
        case .waitingForDownload:
            return tr("EQ settings will apply when the download finishes.", "下载完成后会应用均衡器设置。", zhHant: "下載完成後會套用均衡器設定。")
        case .streamOnly:
            return tr("This stream cannot use EQ or spectrum. Your settings are saved.", "此流无法使用均衡器或频谱，设置已保留。", zhHant: "此串流無法使用均衡器或頻譜，設定已保留。")
        case .unavailable:
            return tr("EQ settings are saved for supported playback.", "均衡器设置已保存，将在支持的播放模式中应用。", zhHant: "均衡器設定已儲存，將在支援的播放模式中套用。")
        }
    }

    var body: some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(BrandColors.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
