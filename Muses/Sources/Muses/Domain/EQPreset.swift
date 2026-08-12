import Foundation
import SwiftData

/// 用户自定义 EQ 预设(SwiftData 持久化)。内置预设由 `EQPresets` enum 提供,不入库。
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

    /// 解码出 EQBand 数组; 解码失败返回 flat 预设。
    var bands: [EQBand] {
        guard let data = bandsJSON.data(using: .utf8) else { return EQPresets.flat }
        return (try? JSONDecoder().decode([EQBand].self, from: data)) ?? EQPresets.flat
    }

    static func encode(_ bands: [EQBand]) -> String {
        (try? String(data: JSONEncoder().encode(bands), encoding: .utf8)) ?? "[]"
    }
}

/// 内置 EQ 预设(不入库)。
enum BuiltinEQPresets {
    static let all: [(name: String, bands: [EQBand])] = [
        ("Flat", EQPresets.flat),
        ("HiFi", hifi()),
        ("Bass Boost", bassBoost()),
        ("Vocal", vocal()),
    ]

    static func hifi() -> [EQBand] {
        // 轻微提升高低频,中频平直
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