import SwiftUI

struct ListeningHeatmapView: View {
    enum Presentation: String, CaseIterable {
        case chart
        case table
    }

    let heatmap: ListeningHeatmap

    @Environment(\.locale) private var locale
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var presentation: Presentation = .chart
    @State private var selectedCellID: String?
    @FocusState private var focusedCellID: String?

    private let cellSize: CGFloat = 42
    private let rowLabelWidth: CGFloat = 118

    private var selectedCell: ListeningHeatmapCell? {
        let id = selectedCellID ?? heatmap.peakCell?.id
        return heatmap.rows.flatMap(\.cells).first { $0.id == id }
    }

    private var mostActiveRow: ListeningHeatmapRow? {
        heatmap.rows.max {
            $0.cells.reduce(0) { $0 + $1.intensityMs }
                < $1.cells.reduce(0) { $0 + $1.intensityMs }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Listening heatmap", "收听热力图"))
                        .font(.title3.weight(.bold))
                    Text(tr("Calendar days by local hour. The scale is fixed across ranges.",
                            "按本地日期与小时显示；切换范围时使用固定色阶。"))
                        .font(.caption)
                        .foregroundStyle(BrandColors.textSecondary)
                }
                Spacer()
                Picker(tr("Heatmap presentation", "热力图显示方式"), selection: $presentation) {
                    Label(tr("Heatmap", "热力图"), systemImage: "square.grid.3x3.fill")
                        .tag(Presentation.chart)
                    Label(tr("Data Table", "数据表"), systemImage: "tablecells")
                        .tag(Presentation.table)
                }
                .pickerStyle(.segmented)
                .frame(width: 230)
            }

            summary
            if presentation == .chart {
                chart
                legend
            } else {
                dataTable
            }
            selectedDetail
        }
        .padding(20)
        .background(BrandColors.surface.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: AppleMusicTokens.cardCorner,
                                         style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("Listening heatmap", "收听热力图"))
    }

    private var summary: some View {
        HStack(spacing: 22) {
            summaryValue(ListeningFormat.duration(heatmap.totalMs),
                         label: tr("Total", "总计"))
            summaryValue(heatmap.peakCell.map(cellTimeLabel) ?? "—",
                         label: tr("Peak interval", "高峰时段"))
            summaryValue(mostActiveRow.map(rowLabel) ?? "—",
                         label: heatmap.range == .allTime
                            ? tr("Most active weekday", "最活跃星期")
                            : tr("Most active date", "最活跃日期"))
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summaryAccessibilityLabel)
    }

    private func summaryValue(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(BrandColors.textSecondary)
        }
    }

    private var chart: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(tr("Date", "日期"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(BrandColors.textSecondary)
                        .frame(width: rowLabelWidth, alignment: .leading)
                    ForEach(0..<24, id: \.self) { hour in
                        Text(hour % 3 == 0 ? hourLabel(hour) : "")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(BrandColors.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                            .frame(width: cellSize)
                            .accessibilityLabel(tr("Hour \(hourLabel(hour))",
                                                   "小时 \(hourLabel(hour))"))
                    }
                }
                ForEach(heatmap.rows) { row in
                    HStack(spacing: 5) {
                        Text(rowLabel(row))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(BrandColors.textSecondary)
                            .lineLimit(1)
                            .frame(width: rowLabelWidth, alignment: .leading)
                        ForEach(row.cells) { cell in
                            heatmapCell(cell, row: row)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(rowLabel(row))
                }
            }
            .padding(.bottom, 4)
        }
        .frame(maxHeight: chartHeight)
        .accessibilityHint(tr(
            "Use arrow keys to move by hour and date. Switch to Data Table to skip empty intervals.",
            "使用方向键按小时和日期移动；切换到数据表可跳过空时段。"))
    }

    private func heatmapCell(_ cell: ListeningHeatmapCell,
                             row: ListeningHeatmapRow) -> some View {
        let level = ListeningHeatmapLevel(milliseconds: cell.intensityMs)
        let selected = selectedCellID == cell.id
        return Button {
            selectedCellID = cell.id
            focusedCellID = cell.id
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(cellFill(level))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(cellStroke(level, selected: selected),
                            lineWidth: selected ? 2.5 : level.strokeWidth(contrast: contrast))
                if cell.totalMs > 0 {
                    Text(minuteHint(cell.intensityMs))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(level >= .high ? Color.white : BrandColors.textPrimary)
                        .minimumScaleFactor(0.6)
                } else if differentiateWithoutColor {
                    Circle().fill(BrandColors.textSecondary.opacity(0.35))
                        .frame(width: 3, height: 3)
                }
            }
            .frame(width: cellSize, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focusedCellID, equals: cell.id)
        .onChange(of: focusedCellID) { _, newValue in
            if newValue == cell.id { selectedCellID = cell.id }
        }
        .onKeyPress(.leftArrow) { move(from: cell, rowDelta: 0, hourDelta: -1) }
        .onKeyPress(.rightArrow) { move(from: cell, rowDelta: 0, hourDelta: 1) }
        .onKeyPress(.upArrow) { move(from: cell, rowDelta: -1, hourDelta: 0) }
        .onKeyPress(.downArrow) { move(from: cell, rowDelta: 1, hourDelta: 0) }
        .help(cellAccessibilityLabel(cell, row: row))
        .accessibilityLabel("\(rowLabel(row)), \(cellTimeLabel(cell))")
        .accessibilityValue(cellAccessibilityValue(cell))
        .accessibilityHint(tr("Arrow keys move between heatmap cells",
                              "方向键可在热力图单元格之间移动"))
    }

    private var legend: some View {
        HStack(spacing: 10) {
            Text(tr("Daily time", "每日时长"))
                .font(.caption.weight(.semibold))
            ForEach(ListeningHeatmapLevel.allCases, id: \.self) { level in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(cellFill(level))
                        .overlay {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .stroke(BrandColors.textSecondary.opacity(0.35), lineWidth: 1)
                        }
                        .frame(width: 18, height: 12)
                    Text(level.label)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(BrandColors.textSecondary)
                }
            }
            Spacer()
            if heatmap.range == .allTime {
                Text(tr("All Time uses average time per matching weekday.",
                        "全部范围按对应星期的每日平均时长显示。"))
                    .font(.caption2)
                    .foregroundStyle(BrandColors.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr(
            "Fixed legend: none, under 5 minutes, 5 to 15, 15 to 30, 30 to 60, and 60 minutes or more.",
            "固定图例：无、少于 5 分钟、5 到 15 分钟、15 到 30 分钟、30 到 60 分钟、60 分钟以上。"))
    }

    private var dataTable: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if heatmap.nonzeroCells.isEmpty {
                    ContentUnavailableView(tr("No Listening Activity", "暂无收听活动"),
                                           systemImage: "tablecells")
                } else {
                    ForEach(heatmap.rows) { row in
                        let cells = row.cells.filter { $0.totalMs > 0 }
                        if !cells.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(rowLabel(row))
                                    .font(.headline)
                                ForEach(cells) { cell in
                                    Button {
                                        selectedCellID = cell.id
                                    } label: {
                                        HStack(spacing: 12) {
                                            Text(cellTimeLabel(cell))
                                                .font(.callout.monospacedDigit().weight(.semibold))
                                                .frame(width: 150, alignment: .leading)
                                            Text(ListeningFormat.duration(cell.totalMs))
                                                .font(.callout.monospacedDigit())
                                            Spacer()
                                            Text(tr("\(cell.trackCount) songs", "\(cell.trackCount) 首"))
                                            Text(tr("\(cell.artistCount) artists", "\(cell.artistCount) 位艺人"))
                                        }
                                        .font(.caption)
                                        .foregroundStyle(BrandColors.textPrimary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(selectedCellID == cell.id
                                                    ? BrandColors.magenta.opacity(0.12)
                                                    : Color.clear,
                                                    in: RoundedRectangle(cornerRadius: 7,
                                                                         style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(cellAccessibilityLabel(cell, row: row))
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 360)
        .accessibilityLabel(tr("Non-empty listening intervals", "非空收听时段"))
    }

    @ViewBuilder
    private var selectedDetail: some View {
        if let cell = selectedCell,
           let row = heatmap.rows.first(where: { $0.id == cell.rowID }) {
            Divider()
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(rowLabel(row)) · \(cellTimeLabel(cell))")
                        .font(.headline)
                    if heatmap.range == .allTime {
                        Text(tr("Average \(ListeningFormat.duration(cell.intensityMs)) per matching weekday; \(ListeningFormat.duration(cell.totalMs)) total across \(cell.sampleDayCount) days.",
                                "对应星期平均 \(ListeningFormat.duration(cell.intensityMs))；\(cell.sampleDayCount) 天共 \(ListeningFormat.duration(cell.totalMs))。"))
                            .font(.callout)
                    } else {
                        Text(ListeningFormat.duration(cell.totalMs))
                            .font(.callout.weight(.semibold))
                    }
                    Text(tr("\(cell.eventCount) plays · \(cell.trackCount) songs · \(cell.artistCount) artists",
                            "\(cell.eventCount) 次播放 · \(cell.trackCount) 首歌曲 · \(cell.artistCount) 位艺人"))
                        .font(.caption)
                        .foregroundStyle(BrandColors.textSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    ForEach(cell.slices.prefix(3)) { slice in
                        Text("\(slice.title) — \(slice.artist)")
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: 330, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(cellAccessibilityLabel(cell, row: row))
        }
    }

    private var chartHeight: CGFloat {
        let natural = CGFloat(heatmap.rows.count) * 35 + 42
        return min(max(natural, 86), heatmap.range == .month ? 420 : 330)
    }

    private func move(from cell: ListeningHeatmapCell,
                      rowDelta: Int, hourDelta: Int) -> KeyPress.Result {
        let targetRow = min(max(0, cell.rowIndex + rowDelta), heatmap.rows.count - 1)
        let targetHour = min(max(0, cell.hour + hourDelta), 23)
        let target = heatmap.rows[targetRow].cells[targetHour]
        selectedCellID = target.id
        focusedCellID = target.id
        return .handled
    }

    private func cellFill(_ level: ListeningHeatmapLevel) -> Color {
        guard level != .none else {
            return BrandColors.textSecondary.opacity(contrast == .increased ? 0.08 : 0.035)
        }
        return BrandColors.magenta.opacity(level.opacity)
    }

    private func cellStroke(_ level: ListeningHeatmapLevel, selected: Bool) -> Color {
        if selected { return BrandColors.textPrimary }
        if level == .none { return BrandColors.textSecondary.opacity(0.30) }
        return differentiateWithoutColor || contrast == .increased
            ? BrandColors.textPrimary.opacity(0.60) : BrandColors.magenta.opacity(0.62)
    }

    private func minuteHint(_ milliseconds: Int) -> String {
        guard milliseconds >= 60_000 else { return "<1" }
        let minutes = milliseconds / 60_000
        return minutes >= 60 ? "60+" : "\(minutes)"
    }

    private func rowLabel(_ row: ListeningHeatmapRow) -> String {
        if let date = row.date {
            var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
            style.locale = locale
            style.timeZone = timeZone
            return date.formatted(style)
        }
        guard let weekday = row.weekday else { return "—" }
        var calendar = Calendar(identifier: heatmap.calendarIdentifier)
        calendar.locale = locale
        return calendar.shortWeekdaySymbols[max(0, min(6, weekday - 1))]
    }

    private func hourLabel(_ hour: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = calendar.date(from: DateComponents(year: 2001, month: 1, day: 15,
                                                       hour: hour)) ?? .distantPast
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.locale = locale
        style.timeZone = timeZone
        return date.formatted(style)
    }

    private func cellTimeLabel(_ cell: ListeningHeatmapCell) -> String {
        "\(hourLabel(cell.hour))–\(hourLabel((cell.hour + 1) % 24))"
    }

    private var timeZone: TimeZone {
        TimeZone(identifier: heatmap.timeZoneIdentifier) ?? .current
    }

    private func cellAccessibilityLabel(_ cell: ListeningHeatmapCell,
                                        row: ListeningHeatmapRow) -> String {
        "\(rowLabel(row)), \(cellTimeLabel(cell)), \(cellAccessibilityValue(cell))"
    }

    private func cellAccessibilityValue(_ cell: ListeningHeatmapCell) -> String {
        guard cell.totalMs > 0 else { return tr("No listening", "没有收听") }
        if heatmap.range == .allTime {
            return tr(
                "Average \(ListeningFormat.duration(cell.intensityMs)), total \(ListeningFormat.duration(cell.totalMs)), \(cell.trackCount) songs, \(cell.artistCount) artists",
                "平均 \(ListeningFormat.duration(cell.intensityMs))，总计 \(ListeningFormat.duration(cell.totalMs))，\(cell.trackCount) 首歌曲，\(cell.artistCount) 位艺人")
        }
        return tr(
            "\(ListeningFormat.duration(cell.totalMs)), \(cell.trackCount) songs, \(cell.artistCount) artists",
            "\(ListeningFormat.duration(cell.totalMs))，\(cell.trackCount) 首歌曲，\(cell.artistCount) 位艺人")
    }

    private var summaryAccessibilityLabel: String {
        let peak = heatmap.peakCell.map(cellTimeLabel) ?? tr("none", "无")
        let active = mostActiveRow.map(rowLabel) ?? tr("none", "无")
        return tr(
            "Listening summary. Total \(ListeningFormat.duration(heatmap.totalMs)). Peak interval \(peak). Most active date \(active).",
            "收听摘要。总计 \(ListeningFormat.duration(heatmap.totalMs))。高峰时段 \(peak)。最活跃日期 \(active)。")
    }
}

private extension ListeningHeatmapLevel {
    var opacity: Double {
        switch self {
        case .none: 0.04
        case .trace: 0.16
        case .low: 0.30
        case .medium: 0.48
        case .high: 0.70
        case .peak: 0.92
        }
    }

    var label: String {
        switch self {
        case .none: tr("None", "无")
        case .trace: "<5m"
        case .low: "5–15m"
        case .medium: "15–30m"
        case .high: "30–60m"
        case .peak: "60m+"
        }
    }

    func strokeWidth(contrast: ColorSchemeContrast) -> CGFloat {
        if contrast == .increased { return self == .none ? 1.2 : 1.8 }
        return self == .none ? 0.8 : 1
    }
}
