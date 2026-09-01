import Foundation
import SwiftData

/// User-defined EQ preset (persisted via SwiftData). Built-in presets come from the `EQPresets` enum and are not stored.
@Model
final class EQPreset {
    @Attribute(.unique) var id: UUID
    var name: String
    var bandsJSON: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, bandsJSON: String, createdAt: Date = .init()) {
        self.id = id
        self.name = name
        self.bandsJSON = bandsJSON
        self.createdAt = createdAt
    }

    /// Decodes the stored JSON into an `[EQBand]`; falls back to the flat preset when decoding fails.
    var bands: [EQBand] {
        guard let data = bandsJSON.data(using: .utf8) else { return EQPresets.flat }
        return (try? JSONDecoder().decode([EQBand].self, from: data)) ?? EQPresets.flat
    }

    static func encode(_ bands: [EQBand]) -> String {
        (try? String(data: JSONEncoder().encode(bands), encoding: .utf8)) ?? "[]"
    }
}

/// Built-in EQ presets (not persisted).
enum BuiltinEQPresets {
    /// Resolve the persisted `PrefKey.eqActivePresetId` (builtin name or custom UUID).
    static func bands(forStoredId id: String, container: ModelContainer) -> [EQBand] {
        if let builtin = all.first(where: { $0.name == id }) { return builtin.bands }
        guard let uuid = UUID(uuidString: id) else { return EQPresets.flat }
        let ctx = ModelContext(container)
        let descriptor = FetchDescriptor<EQPreset>(
            predicate: #Predicate { $0.id == uuid }
        )
        return (try? ctx.fetch(descriptor).first)?.bands ?? EQPresets.flat
    }

    static let all: [(name: String, bands: [EQBand])] = [
        ("Flat", EQPresets.flat),
        ("HiFi", hifi()),
        ("Bass Boost", bassBoost()),
        ("Vocal", vocal()),
    ]

    static func hifi() -> [EQBand] {
        // Slight lift at the frequency extremes, mids left flat
        var b = EQPresets.flat
        let boosts: [(Double, Float)] = [(31, 3), (62, 2), (125, 1), (8000, 2), (16000, 3)]
        for (freq, gain) in boosts {
            if let i = b.firstIndex(where: { $0.frequency == freq }) { b[i].gain = gain }
        }
        return b
    }

    static func bassBoost() -> [EQBand] {
        var b = EQPresets.flat
        let boosts: [(Double, Float)] = [(31, 6), (62, 5), (125, 3), (250, 1)]
        for (freq, gain) in boosts {
            if let i = b.firstIndex(where: { $0.frequency == freq }) { b[i].gain = gain }
        }
        return b
    }

    static func vocal() -> [EQBand] {
        var b = EQPresets.flat
        let boosts: [(Double, Float)] = [(500, 2), (1000, 3), (2000, 3), (4000, 2)]
        for (freq, gain) in boosts {
            if let i = b.firstIndex(where: { $0.frequency == freq }) { b[i].gain = gain }
        }
        return b
    }
}