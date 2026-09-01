import Foundation
import AppKit

/// Runtime capability detection: lets features gate their UI by SUPPORTED / LIMITED /
/// UNSUPPORTED instead of assuming platform support. Capabilities, once determined, never
/// change within the process lifetime, hence the lets + construction-time probing.
@Observable
@MainActor
final class RuntimeCapabilities {

    enum Status { case supported, limited, unsupported }

    let globalHotkeys: Status
    let mediaKeys: Status
    let tray: Status
    let miniWindow: Status
    let desktopLyrics: Status
    let activeApplicationDetection: Status
    let outputDeviceEnumeration: Status
    let outputDeviceSwitching: Status
    let headphoneDetection: Status
    let wordSyncedLyrics: Status
    let translationLyrics: Status
    let audioAnalysis: Status
    let weatherContext: Status

    init() {
        // Native capabilities on macOS 14+. Carbon RegisterEventHotKey still works;
        // NSStatusItem / NSPanel / NSWorkspace.frontmostApplication / Core Audio are all system APIs.
        globalHotkeys = .supported
        mediaKeys = .supported
        tray = .supported
        miniWindow = .supported
        desktopLyrics = .supported
        activeApplicationDetection = .supported
        outputDeviceEnumeration = .supported
        // AVAudioEngine routes to the system default device; per-device routing would need a
        // manual graph / AVAudioIONNode, done best-effort.
        outputDeviceSwitching = .limited
        // No system API directly detects headphones; relies on a device-name/transport-type
        // heuristic, which is unreliable.
        headphoneDetection = .limited
        // No free word-sync/translation lyrics provider; the structure supports it, but the
        // data falls back line → plain.
        wordSyncedLyrics = .limited
        translationLyrics = .limited
        audioAnalysis = .supported
        // Weather context needs network + location, out of scope for a local-first music app;
        // not implemented.
        weatherContext = .unsupported
    }

    /// Convenience: maps a Status to a "usable" boolean (limited still counts as usable;
    /// the UI should explain the limitation separately).
    func isUsable(_ s: Status) -> Bool { s != .unsupported }

    /// User-readable localized explanation (for disabled-state UI).
    func explanation(for s: Status) -> String {
        switch s {
        case .supported:  return tr("Supported", "支持")
        case .limited:    return tr("Supported with limitations", "受限支持")
        case .unsupported: return tr("Not supported on this platform", "此平台不支持")
        }
    }
}
