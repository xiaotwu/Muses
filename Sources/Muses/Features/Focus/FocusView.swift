import SwiftUI

/// Focus mode panel (Final Spec §10.9 Feature 9).
///
/// Start/stop a focus session: pick duration (25/45/60/90/custom/untimed), expiry behavior,
/// queue lock, and Pomodoro. While running it shows a countdown and the current phase.
/// Visually subordinate to the existing Now Playing (does not rebuild the main UI).
/// Gated by `PrefKey.ffFocusMode`: the entry point is hidden when off (Final Spec §15).
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
        .musesFloatingChrome(cornerRadius: 16)
    }

    // MARK: - Active session

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

    // MARK: - Configuration

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Pomodoro locks the 25/5 cycle and hides the duration picker.
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