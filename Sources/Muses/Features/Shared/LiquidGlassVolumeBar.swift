import SwiftUI
import AppKit

/// Liquid Glass volume bar, faithfully matching Figure 4:
/// [AirPlay (magenta)] | [=====O-------] [Speaker]
///
/// Features a custom pill-shaped knob, continuous drag scrubbing, audio device selection,
/// and instant mute toggle with remembered audible volume restoration.
struct LiquidGlassVolumeBar: View {
    @Environment(PlaybackService.self) private var playback
    @Environment(AudioDeviceService.self) private var audioDevices: AudioDeviceService?

    var width: CGFloat = 220
    var height: CGFloat = 36
    var onDeviceSelected: (() -> Void)? = nil

    @State private var isDragging = false
    @State private var dragVolume: Float = 0
    @State private var rememberedAudibleVolume: Float = 0.8
    @State private var isHovered = false

    private var currentVolume: Float {
        isDragging ? dragVolume : playback.volume
    }

    private var outputDevices: [AudioDeviceService.AudioDevice] {
        guard let service = audioDevices else { return [] }
        return NowPlayingOutputDevicePolicy.visibleDevices(service.devices)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Left: AirPlay icon in magenta with output menu
            airplayMenu

            // Divider: Vertical hairline
            Rectangle()
                .fill(Color.white.opacity(0.20))
                .frame(width: 1, height: 16)

            // Center: Custom slider track with white fill and pill knob
            sliderTrack
                .frame(maxWidth: .infinity)

            // Right: Speaker icon button toggling mute
            speakerButton
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: height)
        .musesGlass(in: Capsule(), role: .compactControl)
        .overlay(
            Capsule()
                .stroke(isHovered ? Color.white.opacity(0.25) : BrandColors.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        .onHover { isHovered = $0 }
        .onAppear {
            if playback.volume > 0.05 {
                rememberedAudibleVolume = playback.volume
            }
        }
    }

    // MARK: - AirPlay Output Menu

    private var airplayMenu: some View {
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
                                : "speaker.wave.2")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "airplayaudio")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BrandColors.magenta)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26, height: 26)
        .help(tr("Audio output", "音频输出"))
        .accessibilityLabel(tr("Choose audio output", "选择音频输出"))
    }

    // MARK: - Custom Slider Track (Figure 4)

    private var sliderTrack: some View {
        GeometryReader { geo in
            let availableWidth = max(10, geo.size.width)
            let knobWidth: CGFloat = 14
            let knobHeight: CGFloat = 18
            let travelWidth = max(1, availableWidth - knobWidth)
            let fraction = CGFloat(min(1.0, max(0.0, currentVolume)))
            let knobX = knobWidth / 2 + fraction * travelWidth

            ZStack(alignment: .leading) {
                // Inactive track: dark translucent capsule
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(height: 4.5)

                // Active filled track: solid white
                Capsule()
                    .fill(Color.white)
                    .frame(width: min(availableWidth, knobX), height: 4.5)

                // Distinct pill knob matching Fig 4
                Capsule()
                    .fill(Color.white)
                    .frame(width: knobWidth, height: knobHeight)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .position(x: knobX, y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let clampedX = min(travelWidth, max(0, value.location.x - knobWidth / 2))
                        let newFraction = Float(clampedX / travelWidth)
                        dragVolume = min(1.0, max(0.0, newFraction))
                        playback.setVolume(dragVolume)
                        if dragVolume > 0.05 {
                            rememberedAudibleVolume = dragVolume
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: height)
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

    private func toggleMute() {
        if playback.volume <= 0.001 {
            let target = rememberedAudibleVolume > 0.05 ? rememberedAudibleVolume : 0.7
            playback.setVolume(target)
        } else {
            rememberedAudibleVolume = playback.volume
            playback.setVolume(0)
        }
    }
}
