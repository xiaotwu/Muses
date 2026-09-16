import Foundation
import AppKit

/// Platform capability hints. Conditional integrations report limited until
/// their owning service confirms an operation; audio processing follows the
/// active engine instead of the presence of the underlying system APIs.
@Observable
@MainActor
final class RuntimeCapabilities {

    enum Status { case supported, limited, unsupported }

    var globalHotkeys: Status {
        guard let hotkeys, hotkeys.isEnabled else { return .unsupported }
        _ = hotkeys.revision
        return hotkeys.registeredCount > 0 && hotkeys.failedActions.isEmpty ? .supported : .limited
    }
    var hotkeyFailures: [String] { hotkeys?.failedActions ?? [] }
    let mediaKeys: Status
    let tray: Status
    let miniWindow: Status
    let desktopLyrics: Status
    let activeApplicationDetection: Status
    var outputDeviceEnumeration: Status {
        guard let devices else { return .limited }
        return devices.lastError == nil && !devices.devices.isEmpty ? .supported : .limited
    }
    private weak var playback: PlaybackService?
    private weak var hotkeys: GlobalHotkeyService?
    private weak var devices: AudioDeviceService?
    var audioAnalysis: Status {
        guard playback?.transportState.error == nil else { return .unsupported }
        switch playback?.transportState.audioProcessing {
        case .available: return .supported
        case .waitingForDownload: return .limited
        default: return .unsupported
        }
    }

    init(playback: PlaybackService? = nil, hotkeys: GlobalHotkeyService? = nil, devices: AudioDeviceService? = nil) {
        self.playback = playback
        self.hotkeys = hotkeys
        self.devices = devices
        // Native capabilities on macOS 14+. Carbon RegisterEventHotKey still works;
        // NSStatusItem / NSPanel / NSWorkspace.frontmostApplication / Core Audio are all system APIs.
        mediaKeys = .limited
        tray = .supported
        miniWindow = .supported
        desktopLyrics = .supported
        activeApplicationDetection = .supported
    }
}
