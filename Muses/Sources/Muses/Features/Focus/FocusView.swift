import SwiftUI

/// 专注模式面板(Final Spec §10.9 Feature 9)。
///
/// 开始/停止专注会话:选择时长(25/45/60/90/自定义/不限时)、到期行为、队列锁、Pomodoro。
/// 进行中显示倒计时与阶段。视觉从属于既有 Now Playing(不重做主界面)。
/// 受 `PrefKey.ffFocusMode` 约束:关闭时入口不可见(Final Spec §15)。
struct FocusView: View {
    @Environment(FocusService.self) private var focus
    @Environment(\.dismiss) private var dismiss

    @State private var minutes: Int = 25
    @State private var noTimer = false
    @State private var expiration: FocusExpiration = .pause
    @State private var queueLocked = false
    @State private var pomodoro = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(tr("Focus Mode", "专注模式"))
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(BrandColors.textPrimary)

            if focus.isActive {
                activeSection
            } else {
                configSection
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(.regularMaterial)
    }

    // MARK: - 进行中

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(focus.isPomodoro
                     ? (focus.pomodoroPhase == .focus ? tr("Focus", "专注") : tr("Break", "休息"))
                     : tr("Focusing", "专注中"))
                    .font(.headline).foregroundStyle(BrandColors.textPrimary)
                Spacer()
                if focus.totalSeconds > 0 {
                    Text(focus.remainingFormatted)
                        .font(.system(.title3, design: .monospaced))
                        .foregroundStyle(BrandColors.magenta)
                } else {
                    Text(tr("No timer", "无时限"))
                        .foregroundStyle(BrandColors.textSecondary)
                }
            }
            if focus.isQueueLocked {
                Label(tr("Queue locked", "队列已锁定"), systemImage: "lock")
                    .font(.caption).foregroundStyle(BrandColors.textSecondary)
            }
            Button(role: .destructive) {
                focus.stop()
                dismiss()
            } label: {
                Label(tr("End Focus", "结束专注"), systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandColors.magenta)
        }
    }

    // MARK: - 配置

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Pomodoro 开启时锁定 25/5 循环,隐藏时长选择。
            Toggle(tr("Pomodoro (25 focus + 5 break)", "番茄钟(25 专注 + 5 休息)"),
                   isOn: $pomodoro)
            if !pomodoro {
                Toggle(tr("No timer", "不限时"), isOn: $noTimer)
                if !noTimer {
                    Picker(tr("Duration", "时长"), selection: $minutes) {
                        Text("25 min").tag(25)
                        Text("45 min").tag(45)
                        Text("60 min").tag(60)
                        Text("90 min").tag(90)
                    }.pickerStyle(.segmented)
                }
            }
            Picker(tr("On expiry", "到期行为"), selection: $expiration) {
                ForEach(FocusExpiration.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
            Toggle(tr("Lock queue", "锁定队列"), isOn: $queueLocked)
            Button {
                focus.start(minutes: noTimer && !pomodoro ? nil : minutes,
                            queueLocked: queueLocked, expiration: expiration, pomodoro: pomodoro)
                dismiss()
            } label: {
                Label(tr("Start Focus", "开始专注"), systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandColors.magenta)
            .disabled(!focus.isEnabled)
        }
    }
}