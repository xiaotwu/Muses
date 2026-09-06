import SwiftUI
import UserNotifications

/// Notification settings: opt-in switch for track-change notifications.
struct NotificationsSettingsView: View {
    @AppStorage(PrefKey.notificationsTrackChange) private var trackChangeEnabled = false
    @State private var authorizationRequested = false

    var body: some View {
        Section(tr("Notifications", "通知")) {
            Toggle(tr("Notify on Track Change", "换歌时通知"), isOn: $trackChangeEnabled)
                .tint(BrandColors.magenta)
                .onChange(of: trackChangeEnabled) { _, on in
                    if on && !authorizationRequested {
                        Task { _ = try? await UNUserNotificationCenter.current()
                            .requestAuthorization(options: [.alert]) }
                        authorizationRequested = true
                    }
                }
        }
    }
}