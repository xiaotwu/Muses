import Testing
import Foundation
import CoreAudio
import Carbon.HIToolbox
@testable import Muses

@MainActor
@Suite("Stage two audio boundaries")
struct StageTwoAudioTests {
    @Test("quiet volume survives cross-surface mute and facade restart")
    func quietMute() throws {
        let suite = "volume-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = PlaybackService(engine: RecordingEngine(), queue: QueueService(), volumeDefaults: defaults)
        service.setVolume(0.03)
        service.toggleMute()
        #expect(service.volume == 0)
        let restored = PlaybackService(engine: RecordingEngine(), queue: QueueService(), volumeDefaults: defaults)
        restored.toggleMute()
        #expect(abs(restored.volume - 0.03) < 0.0001)
        let video = restored.beginVideoSession(videoId: "video00000a")
        video.didBecomeReady()
        video.receiveVolume(percent: 0)
        restored.toggleMute()
        #expect(abs(video.volume - 0.03) < 0.0001)
        restored.finishVideoSession(video, resume: false)
    }

    @Test("Carbon hotkey payload reads the event ID after the signature and rejects foreign events")
    func hotkeyPayload() throws {
        var event: EventRef?
        #expect(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event) == noErr)
        let created = try #require(event)
        defer { ReleaseEvent(created) }
        let previous = GlobalHotkeyService.actionById
        defer { GlobalHotkeyService.actionById = previous }
        GlobalHotkeyService.actionById[77] = "test.play"
        var payload = EventHotKeyID(signature: 0x4D757373, id: 77)
        #expect(SetEventParameter(created, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &payload) == noErr)
        #expect(GlobalHotkeyService.action(for: created) == "test.play")
        payload.signature = 0
        #expect(SetEventParameter(created, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &payload) == noErr)
        #expect(GlobalHotkeyService.action(for: created) == nil)
    }

    @Test("device refresh is read-only and excludes input-only devices; failed switch preserves identity")
    func deviceFailures() {
        var writes = 0
        let service = AudioDeviceService(enabledProvider: { true }, pollProvider: { false },
            enumerateDevices: { [.init(id: 1, name: "Input", channels: 0), .init(id: 2, name: "Output", channels: 2)] },
            readDefault: { 2 }, writeDefault: { _ in writes += 1; return kAudioHardwareIllegalOperationError })
        service.refresh()
        #expect(service.devices.map(\.id) == [2])
        #expect(writes == 0)
        #expect(service.setDefault(1) == kAudioHardwareBadDeviceError)
        #expect(writes == 0)
        #expect(service.setDefault(2) == kAudioHardwareIllegalOperationError)
        #expect(service.defaultDeviceID == 2)
        #expect(service.lastError != nil)
        #expect(RuntimeCapabilities(devices: service).outputDeviceEnumeration == .limited)
    }

    @Test("successful driver write without default-device readback is not reported as success")
    func outputReadback() {
        let service = AudioDeviceService(pollProvider: { false },
            enumerateDevices: { [.init(id: 2, name: "Output", channels: 2)] },
            readDefault: { nil }, writeDefault: { _ in noErr })
        service.refresh()
        #expect(service.setDefault(2) != noErr)
        #expect(service.defaultDeviceID == nil)
    }

    @Test("EQ edits and bypass survive facade recreation without opening the editor")
    func eqRestore() throws {
        let suite = "eq-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = RecordingEngine()
        let service = PlaybackService(engine: engine, queue: QueueService())
        service.restoreEQSettings(defaults: defaults, presetBands: EQPresets.flat)
        var edited = EQPresets.flat
        edited[2].gain = 5
        service.setEQ(edited)
        service.setEQBypassed(true)
        #expect(engine.eqBands == [])
        let restoredEngine = RecordingEngine()
        let restored = PlaybackService(engine: restoredEngine, queue: QueueService())
        restored.restoreEQSettings(defaults: defaults, presetBands: EQPresets.flat)
        #expect(restored.eqBands == edited)
        #expect(restored.eqBypassed)
        #expect(restoredEngine.eqBands == [])
        restored.setEQBypassed(false)
        #expect(restoredEngine.eqBands == edited)
        restored.setEQ([EQBand(frequency: .nan, gain: 1, q: 1)])
        #expect(restoredEngine.eqBands == edited)
    }
}

@Suite("Output disconnection intent")
@MainActor
struct OutputDisconnectionTests {
    @Test("Loss pauses once; reconnection and available-device switching never resume")
    func disconnectionPolicy() {
        let headphones = AudioDeviceService.AudioDevice(id: 1, name: "Headphones", channels: 2)
        let speakers = AudioDeviceService.AudioDevice(id: 2, name: "Speakers", channels: 2)
        var devices = [headphones, speakers]
        var selected: UInt32? = 1
        var pauses = 0
        let service = AudioDeviceService(enabledProvider: { false }, pollProvider: { false },
            enumerateDevices: { devices }, readDefault: { selected },
            writeDefault: { selected = $0; return noErr },
            onUnexpectedDisconnect: { pauses += 1 })
        service.refresh()
        selected = 2
        service.pollOutputChange()
        #expect(pauses == 0)
        #expect(service.setDefault(1) == noErr)
        service.pollOutputChange()
        #expect(pauses == 0)
        devices = [speakers]
        selected = 2
        service.pollOutputChange()
        #expect(pauses == 1)
        service.pollOutputChange()
        #expect(pauses == 1)
        devices = [headphones, speakers]
        selected = 1
        service.pollOutputChange()
        #expect(pauses == 1)
    }
}
