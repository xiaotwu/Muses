import SwiftUI
import SwiftData

/// 32 段图形 EQ 编辑器: 竖条滑杆 + 平滑曲线 + 预设管理(内置 + 自定义)。
/// 改动实时推送到 PlaybackService.setEQ。
struct EQEditorView: View {
    @Environment(PlaybackService.self) private var playback
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \EQPreset.createdAt, order: .reverse) private var customPresets: [EQPreset]

    @AppStorage(PrefKey.eqActivePresetId) private var activePresetIdRaw: String = "Flat"
    @State private var bands: [EQBand] = EQPresets.flat
    @State private var showSaveDialog = false
    @State private var newPresetName = ""

    private let gainRange: ClosedRange<Float> = -24...24
    private let bandFreqs: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

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
            if bands.count == 10, bands.allSatisfy({ $0.gain == 0 }) {
                loadPreset(named: activePresetIdRaw)
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack {
            Text(tr("Equalizer", "均衡器")).font(.title2).fontWeight(.bold)
                .foregroundStyle(BrandColors.textPrimary)
            Spacer()
            Button(tr("Reset", "重置")) {
                bands = EQPresets.flat
                applyBands()
                activePresetIdRaw = "Flat"
            }
            .buttonStyle(.bordered)
            .tint(BrandColors.magenta)
        }
    }

    // MARK: - 曲线视图

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
        // 水平 0dB 中线
        let midY = size.height / 2
        ctx.stroke(
            Path { p in p.move(to: CGPoint(x: 0, y: midY)); p.addLine(to: CGPoint(x: size.width, y: midY)) },
            with: .color(BrandColors.textSecondary.opacity(0.3)),
            lineWidth: 0.5
        )
        // ±12dB 参考线
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
        let stepX = size.width / CGFloat(n - 1)
        let midY = size.height / 2
        var path = Path()
        for (i, band) in bands.enumerated() {
            let x = CGFloat(i) * stepX
            let y = midY - CGFloat(band.gain) / 24.0 * (size.height / 2)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.stroke(path, with: .color(BrandColors.magenta), lineWidth: 2)

        // 频段点
        for (i, band) in bands.enumerated() {
            let x = CGFloat(i) * stepX
            let y = midY - CGFloat(band.gain) / 24.0 * (size.height / 2)
            ctx.fill(
                Circle().path(in: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)),
                with: .color(BrandColors.magenta)
            )
        }
    }

    // MARK: - 频段控制

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
                            applyBands()
                        }), in: Double(gainRange.lowerBound)...Double(gainRange.upperBound))
                    .labelsHidden()
                    .tint(BrandColors.magenta)
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

    // MARK: - 预设

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tr("Presets", "预设")).font(.headline).foregroundStyle(BrandColors.textPrimary)
                Spacer()
                Button {
                    showSaveDialog = true
                } label: { Label(tr("Save As", "另存为"), systemImage: "plus") }
                    .buttonStyle(.bordered)
                    .tint(BrandColors.magenta)
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
                .background(isActive ? BrandColors.magenta.opacity(0.3) : BrandColors.surface)
                .foregroundStyle(isActive ? BrandColors.magenta : BrandColors.textPrimary)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 操作

    private func applyBands() {
        playback.setEQ(bands)
    }

    private func loadPreset(named name: String) {
        if let builtin = BuiltinEQPresets.all.first(where: { $0.name == name }) {
            bands = builtin.bands
        } else if let custom = customPresets.first(where: { $0.id.uuidString == name }) {
            bands = custom.bands
        }
        applyBands()
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
