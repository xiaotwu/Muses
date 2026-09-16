import SwiftUI
import AppKit

/// Shared volume and output control:
/// [Mute] [graduated volume scale] [percentage] [output selector]
///
/// A graduated scale supports continuous drag, keyboard adjustment, audio device selection,
/// and instant mute toggle with remembered audible volume restoration.
struct LiquidGlassVolumeBar: View {
    @Environment(PlaybackService.self) private var playback
    @Environment(AudioDeviceService.self) private var audioDevices: AudioDeviceService?

    var width: CGFloat = 220
    var height: CGFloat = 36
    var onDeviceSelected: (() -> Void)? = nil

    @State private var isDragging = false
    @State private var dragVolume: Float = 0

    private var currentVolume: Float {
        isDragging ? dragVolume : playback.volume
    }

    private var outputDevices: [AudioDeviceService.AudioDevice] {
        guard let service = audioDevices else { return [] }
        return NowPlayingOutputDevicePolicy.visibleDevices(service.devices)
    }

    var body: some View {
        HStack(spacing: 10) {
            speakerButton
            sliderTrack.frame(maxWidth: .infinity)
            Text("\(Int((currentVolume * 100).rounded()))%")
                .font(.caption.monospacedDigit()).frame(width: 34)
                .accessibilityHidden(true)
            outputMenu
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: height)
        .musesGlass(in: Capsule(), role: .compactControl)

    }

    // MARK: - Audio Output Menu

    private var currentOutputName: String? {
        outputDevices.first { $0.id == audioDevices?.defaultDeviceID }?.name
    }

    private var outputMenu: some View {
        Menu {
            if outputDevices.isEmpty {
                Text(tr("No audio outputs available", "无可用音频输出"))
            } else {
                ForEach(outputDevices) { device in
                    Button {
                        _ = audioDevices?.setDefault(device.id)
                        onDeviceSelected?()
                    } label: {
                        Label {
                            Text(device.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } icon: {
                            Image(systemName: device.id == audioDevices?.defaultDeviceID
                                ? "checkmark"
                                : AudioOutputGlyphPolicy.systemImage(forDeviceName: device.name))
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "hifispeaker.and.homepod")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BrandColors.textPrimary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26, height: 26)
        .help(AudioOutputGlyphPolicy.accessibilityLabel(forDeviceName: currentOutputName))
        .accessibilityLabel(AudioOutputGlyphPolicy.accessibilityLabel(forDeviceName: currentOutputName))
    }

    // MARK: - Graduated Volume Scale

    private var sliderTrack: some View {
        GeometryReader { geo in
            let availableWidth = max(10, geo.size.width)
            let fraction = CGFloat(min(1.0, max(0.0, currentVolume)))

            HStack(spacing: 2) {
                ForEach(0..<24, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Double(index) / 24 < Double(fraction)
                              ? BrandColors.accent : BrandColors.textPrimary.opacity(0.15))
                        .frame(maxWidth: .infinity)
                        .frame(height: 8 + CGFloat(index) * 0.45)
                }
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        dragVolume = VolumeScaleMapping.volume(at: value.location.x, width: availableWidth)
                        playback.setVolume(dragVolume)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: height)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { playback.setVolume(max(0, playback.volume - 0.05)); return .handled }
        .onKeyPress(.rightArrow) { playback.setVolume(min(1, playback.volume + 0.05)); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Volume", "音量"))
        .accessibilityValue("\(Int((currentVolume * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                let newVol = min(1.0, playback.volume + 0.05)
                playback.setVolume(newVol)
            case .decrement:
                let newVol = max(0.0, playback.volume - 0.05)
                playback.setVolume(newVol)
            @unknown default:
                break
            }
        }
    }

    // MARK: - Speaker Button

    private var speakerButton: some View {
        Button(action: toggleMute) {
            Image(systemName: volumeIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BrandColors.textPrimary.opacity(0.85))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(playback.volume <= 0.001 ? tr("Unmute", "取消静音") : tr("Mute", "静音"))
        .accessibilityLabel(playback.volume <= 0.001 ? tr("Unmute", "取消静音") : tr("Mute", "静音"))
        .accessibilityValue("\(Int((currentVolume * 100).rounded()))%")
    }

    private var volumeIcon: String {
        let v = currentVolume
        if v <= 0.001 { return "speaker.slash.fill" }
        if v < 0.33 { return "speaker.fill" }
        if v < 0.66 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    private func toggleMute() { playback.toggleMute() }
}

/// Pointer positions map to the full visible scale, independently of window width.
enum VolumeScaleMapping {
    static func volume(at x: CGFloat, width: CGFloat) -> Float {
        guard x.isFinite, width.isFinite, width > 0 else { return 0 }
        return Float(min(1, max(0, x / width)))
    }
}
