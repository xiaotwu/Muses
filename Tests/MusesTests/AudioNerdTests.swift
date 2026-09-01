import Testing
import Foundation
@testable import Muses

/// Audio Nerd Mode pure-logic tests.
/// Only `AudioInfoModel.rows` and the static `AudioDevice` initializers are tested; Core Audio / SwiftUI / resource loading are never touched.
@Suite("Audio Nerd Mode")
struct AudioNerdTests {

    private let unknown = tr("Unknown", "未知")

    // MARK: - nil / all-empty snapshot → every optional field is Unknown

    @Test("nil track → codec/sr/depth/rate/channels/replayGain Unknown; lossless Unknown; source Unknown")
    func nilTrackFallbacks() {
        let rows = AudioInfoModel.rows(track: nil, defaultDeviceName: nil,
                                       eqPresetId: "", volume: 0.0)
        let byLabel = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0.value) })
        #expect(byLabel[tr("Codec", "编码")] == unknown)
        #expect(byLabel[tr("Lossless", "无损")] == unknown)
        #expect(byLabel[tr("Sample Rate", "采样率")] == unknown)
        #expect(byLabel[tr("Bit Depth", "位深")] == unknown)
        #expect(byLabel[tr("Bit Rate", "比特率")] == unknown)
        #expect(byLabel[tr("Channels", "声道")] == unknown)
        #expect(byLabel[tr("Source", "来源")] == unknown)
        #expect(byLabel[tr("Output Device", "输出设备")] == unknown)
        #expect(byLabel[tr("ReplayGain", "回放增益")] == unknown)
        #expect(byLabel[tr("EQ Preset", "EQ 预设")] == unknown)
        // Volume is always computable, even with no track.
        #expect(byLabel[tr("Volume", "音量")] == "0%")
    }

    @Test("nil device name → Output Device Unknown (绝不伪造)")
    func nilDeviceNameFallback() {
        let t = makeYouTubeTrack()
        let rows = AudioInfoModel.rows(track: t, defaultDeviceName: nil,
                                       eqPresetId: "Flat", volume: 0.5)
        let byLabel = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0.value) })
        #expect(byLabel[tr("Output Device", "输出设备")] == unknown)
        // The remaining fields still come from the track snapshot.
        #expect(byLabel[tr("Codec", "编码")] == "FLAC")
        #expect(byLabel[tr("Sample Rate", "采样率")] == "96 kHz")
    }

    // MARK: - Populated fields

    @Test("YouTube 高保真快照 → 全字段填充")
    func populatedYouTubeSnapshot() {
        let t = makeYouTubeTrack() // 96kHz/24-bit/5000kbps/2ch/FLAC/lossless/replayGain -6.3
        let rows = AudioInfoModel.rows(track: t, defaultDeviceName: "Built-in Speakers",
                                       eqPresetId: "Flat", volume: 0.73)
        let byLabel = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0.value) })
        #expect(byLabel[tr("Codec", "编码")] == "FLAC")
        #expect(byLabel[tr("Lossless", "无损")] == tr("Yes", "是"))
        #expect(byLabel[tr("Sample Rate", "采样率")] == "96 kHz")
        #expect(byLabel[tr("Bit Depth", "位深")] == "24-bit")
        #expect(byLabel[tr("Bit Rate", "比特率")] == "5000 kbps")
        #expect(byLabel[tr("Channels", "声道")] == tr("Stereo", "立体声"))
        #expect(byLabel[tr("Source", "来源")] == "YouTube")
        #expect(byLabel[tr("Output Device", "输出设备")] == "Built-in Speakers")
        #expect(byLabel[tr("ReplayGain", "回放增益")] == "-6.3 dB")
        #expect(byLabel[tr("EQ Preset", "EQ 预设")] == "Flat")
        #expect(byLabel[tr("Volume", "音量")] == "73%")
    }

    @Test("YouTube 来源区分 + 有损 + mono")
    func youTubeSourceLossyMono() {
        let t = TrackSnapshot(
            id: UUID(), title: "YT", artist: "A",
            albumTitle: nil, durationSeconds: 180,
            youTubeId: "vid123",
            artworkUrl: "https://i.ytimg.com/vi/vid123/hqdefault.jpg",
            sampleRate: 44100, bitDepth: nil, codec: "opus", isLossless: false,
            liked: false, lyrics: nil, replayGain: nil,
            bitRate: 128_000, channels: 1, lyricsOffsetMs: nil)
        let rows = AudioInfoModel.rows(track: t, defaultDeviceName: nil,
                                       eqPresetId: "Rock", volume: 1.0)
        let byLabel = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0.value) })
        #expect(byLabel[tr("Source", "来源")] == "YouTube")
        #expect(byLabel[tr("Lossless", "无损")] == tr("No", "否"))
        #expect(byLabel[tr("Bit Depth", "位深")] == unknown) // YouTube has no bit depth
        #expect(byLabel[tr("Channels", "声道")] == tr("Mono", "单声道"))
        #expect(byLabel[tr("Sample Rate", "采样率")] == "44 kHz")
        #expect(byLabel[tr("Bit Rate", "比特率")] == "128 kbps")
        #expect(byLabel[tr("ReplayGain", "回放增益")] == unknown)
        #expect(byLabel[tr("EQ Preset", "EQ 预设")] == "Rock")
        #expect(byLabel[tr("Volume", "音量")] == "100%")
    }

    @Test("5.1 多声道 → 显示数字")
    func multichannelNumeric() {
        let t = TrackSnapshot(
            id: UUID(), title: "Surround", artist: "A",
            albumTitle: nil, durationSeconds: 100,
            youTubeId: "test-video",
            artworkUrl: nil,
            sampleRate: 48000, bitDepth: 24, codec: "FLAC", isLossless: true,
            liked: false, lyrics: nil, replayGain: 0.0,
            bitRate: 4_600_000, channels: 6, lyricsOffsetMs: nil)
        let rows = AudioInfoModel.rows(track: t, defaultDeviceName: "AVR",
                                       eqPresetId: "Flat", volume: 0.5)
        let byLabel = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0.value) })
        #expect(byLabel[tr("Channels", "声道")] == "6")
        #expect(byLabel[tr("ReplayGain", "回放增益")] == "+0.0 dB")
    }

    @Test("空 EQ 预设 id → Unknown")
    func emptyEQPresetFallback() {
        let t = makeYouTubeTrack()
        let rows = AudioInfoModel.rows(track: t, defaultDeviceName: nil,
                                       eqPresetId: "", volume: 0.0)
        let byLabel = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0.value) })
        #expect(byLabel[tr("EQ Preset", "EQ 预设")] == unknown)
    }

    @Test("行数固定 11 + 标签唯一")
    func rowCountAndUniqueLabels() {
        let rows = AudioInfoModel.rows(track: nil, defaultDeviceName: nil,
                                       eqPresetId: "", volume: 0.0)
        #expect(rows.count == 11)
        let labels = rows.map(\.label)
        #expect(Set(labels).count == labels.count)
    }

    // MARK: - AudioDevice initializers (pure values, no Core Audio)

    @Test("AudioDevice 等价性与可识别")
    func audioDeviceValueSemantics() {
        let a = AudioDeviceService.AudioDevice(id: 42, name: "Dev A", channels: 2)
        let b = AudioDeviceService.AudioDevice(id: 42, name: "Dev A", channels: 2)
        let c = AudioDeviceService.AudioDevice(id: 43, name: "Dev A", channels: 2)
        #expect(a == b)
        #expect(a != c)
        #expect(a.id == 42)
    }

    // MARK: - helpers

    private func makeYouTubeTrack() -> TrackSnapshot {
        TrackSnapshot(
            id: UUID(), title: "Song", artist: "Artist",
            albumTitle: "Album", durationSeconds: 240,
            youTubeId: "test-video",
            artworkUrl: nil,
            sampleRate: 96000, bitDepth: 24, codec: "FLAC", isLossless: true,
            liked: true, lyrics: nil, replayGain: -6.3,
            bitRate: 5_000_000, channels: 2, lyricsOffsetMs: nil)
    }
}
