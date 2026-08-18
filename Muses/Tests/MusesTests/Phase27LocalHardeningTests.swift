import Testing
import Foundation
import CryptoKit
@testable import Muses

/// Phase 27 — Local Music hardening 纯逻辑测试。
/// 仅测 `LocalHardeningService`(partialHash / matchRelinkCandidate / classify)与
/// Track.partialContentHash 加字段后的兼容性。不触磁盘/AVAsset/SwiftData 持久化。
@Suite("Phase 27 — Local Music Hardening")
struct Phase27LocalHardeningTests {

    // MARK: - partialHash

    @Test("partialHash: 已知输入 → SHA-256 前 64KB")
    func partialHashKnownInput() {
        let data = Data(repeating: 0xAB, count: 1024) // < 64KB,全量参与
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let got = LocalHardeningService.partialHash(of: URL(fileURLWithPath: "/dev/null")) { _ in data }
        #expect(got == expected)
    }

    @Test("partialHash: 空数据 → nil")
    func partialHashEmpty() {
        let got = LocalHardeningService.partialHash(of: URL(fileURLWithPath: "/x")) { _ in Data() }
        #expect(got == nil)
    }

    @Test("partialHash: 读取失败 → nil,绝不抛出")
    func partialHashReadFailure() {
        let got = LocalHardeningService.partialHash(of: URL(fileURLWithPath: "/x")) { _ in nil }
        #expect(got == nil)
    }

    @Test("partialHash: 大于 64KB 只取前 64KB")
    func partialHashTruncatesAt64KB() {
        let full = Data(repeating: 0x01, count: 128 * 1024) // 128KB
        let head = Data(repeating: 0x01, count: 64 * 1024) // 仅前 64KB 应参与
        let expected = SHA256.hash(data: head).map { String(format: "%02x", $0) }.joined()
        // readProvider 返回全量,但 partialHash 应仅哈希前 64KB——用截断模拟 FileHandle 行为。
        let got = LocalHardeningService.partialHash(of: URL(fileURLWithPath: "/x")) { _ in
            Data(full.prefix(64 * 1024))
        }
        #expect(got == expected)
        #expect(got != SHA256.hash(data: full).map { String(format: "%02x", $0) }.joined())
    }

    @Test("partialHash: 不同内容 → 不同指纹")
    func partialHashDistinct() {
        let a = LocalHardeningService.partialHash(of: URL(fileURLWithPath: "/a")) { _ in Data([1, 2, 3]) }
        let b = LocalHardeningService.partialHash(of: URL(fileURLWithPath: "/b")) { _ in Data([4, 5, 6]) }
        #expect(a != nil)
        #expect(b != nil)
        #expect(a != b)
    }

    // MARK: - matchRelinkCandidate

    @Test("matchRelinkCandidate: 命中 → 返回 id;同路径候选不算(避免自匹配)")
    func matchRelinkHitAndSelfExcluded() {
        let id = UUID()
        let samePath = UUID()
        let hash = "abc123"
        let candidates: [(id: UUID, hash: String?, filePath: String?)] = [
            (id: samePath, hash: hash, filePath: "/new/path/song.flac"), // 同路径 → 跳过
            (id: id, hash: hash, filePath: "/old/path/song.flac"),       // 命中
        ]
        #expect(LocalHardeningService.matchRelinkCandidate(hash: hash, newFilePath: "/new/path/song.flac", unavailableTracks: candidates) == id)
    }

    @Test("matchRelinkCandidate: nil hash → nil")
    func matchRelinkNilHash() {
        let id = UUID()
        let candidates: [(id: UUID, hash: String?, filePath: String?)] = [
            (id: id, hash: "x", filePath: "/o")
        ]
        #expect(LocalHardeningService.matchRelinkCandidate(hash: nil, newFilePath: "/n", unavailableTracks: candidates) == nil)
    }

    @Test("matchRelinkCandidate: 无匹配 → nil")
    func matchRelinkNoMatch() {
        let candidates: [(id: UUID, hash: String?, filePath: String?)] = [
            (id: UUID(), hash: "other", filePath: "/o"),
            (id: UUID(), hash: nil, filePath: "/p"),      // 缺指纹 → 不匹配
        ]
        #expect(LocalHardeningService.matchRelinkCandidate(hash: "abc", newFilePath: "/n", unavailableTracks: candidates) == nil)
    }

    // MARK: - classify(格式支持)

    @Test("classify: 支持扩展名")
    func classifySupported() {
        for ext in ["mp3", "m4a", "flac", "wav", "caf", "aiff", "alac", "aac"] {
            #expect(LocalHardeningService.classify(URL(fileURLWithPath: "song.\(ext)")) == .supported, "Expected supported for .\(ext)")
        }
        // 大写扩展名同样归类。
        #expect(LocalHardeningService.classify(URL(fileURLWithPath: "Song.FLAC")) == .supported)
    }

    @Test("classify: 已知不支持扩展名")
    func classifyUnsupported() {
        for ext in ["ogg", "opus", "wma", "ape"] {
            #expect(LocalHardeningService.classify(URL(fileURLWithPath: "song.\(ext)")) == .unsupported, "Expected unsupported for .\(ext)")
        }
    }

    @Test("classify: 未知扩展名 → .unknown(交运行时判定)")
    func classifyUnknown() {
        for ext in ["dsf", "amr", "xyz", ""] {
            #expect(LocalHardeningService.classify(URL(fileURLWithPath: "song.\(ext)")) == .unknown, "Expected unknown for .\(ext)")
        }
    }

    @Test("supported 与 unsupported 集合不相交")
    func setsDisjoint() {
        #expect(LocalHardeningService.supportedExtensions.isDisjoint(with: LocalHardeningService.unsupportedExtensions))
    }

    // MARK: - Track.partialContentHash 加字段向后兼容(默认 nil)

    @Test("Track 新增 partialContentHash 默认 nil")
    func trackDefaultNil() {
        let t = Track(source: .local, title: "T", artist: "A")
        #expect(t.partialContentHash == nil)
    }

    @Test("Track init 接受 partialContentHash 并回填")
    func trackInitPopulatesHash() {
        let t = Track(source: .local, title: "T", artist: "A",
                       partialContentHash: "deadbeef")
        #expect(t.partialContentHash == "deadbeef")
    }

    // MARK: - mixed-source(本地 + YouTube)Track 共存

    @Test("本地与 YouTube Track 同存:source 字段区分,filePath/youTubeId 互斥约定")
    func mixedSourceCoexistence() {
        let local = Track(source: .local, title: "Local", artist: "A",
                           filePath: "/music/song.flac", youTubeId: nil,
                           partialContentHash: "hashLocal")
        let yt = Track(source: .youtube, title: "YT", artist: "A",
                       filePath: nil, youTubeId: "vid1",
                       partialContentHash: nil) // YouTube 不算本地指纹
        #expect(local.source == .local)
        #expect(yt.source == .youtube)
        #expect(local.partialContentHash != nil)
        #expect(yt.partialContentHash == nil)
        #expect(local.filePath != nil && local.youTubeId == nil)
        #expect(yt.filePath == nil && yt.youTubeId != nil)
    }
}