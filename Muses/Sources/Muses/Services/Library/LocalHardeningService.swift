import Foundation
import CryptoKit

/// Phase 27 — Local Music hardening(可选,`ffLocalHardening` 默认关闭)。
///
/// 提供:
/// 1. 前 64KB 内容指纹(SHA-256)用于**移动/重命名后**重新关联既有 Track 行——
///    绝不用于内容完整性校验,仅作"同一文件换了路径"的识别。
/// 2. AVFoundation 支持格式清单 + 文件扩展名归类(支持/不支持/未知)。
/// 3. 纯匹配逻辑:在已有 unavailable Track 中按指纹找候选,用于 re-link 而非重复插入。
///
/// "off = no-op":`ffLocalHardening` 关闭时所有公共入口立即返回 nil / 不动作。
/// 文件 I/O 通过 injectable `readProvider` 隔离,便于无盘单元测试。
enum LocalHardeningService {

    /// 前 64KB 内容指纹。读取失败/文件过小(无内容)→ nil。绝不抛出。
    /// `readProvider` 注入便于无盘单元测试;默认走 FileHandle 读前 64KB。
    static func partialHash(of url: URL,
                            readProvider: @Sendable (URL) -> Data? = defaultRead) -> String? {
        guard let data = readProvider(url), !data.isEmpty else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 在候选(通常为本次根目录下 unavailable 的本地 Track)中查找匹配指纹。
    /// 命中 → 返回该 Track 的 id;无匹配/指纹缺失 → nil。纯值,不触 SwiftData。
    /// `newFilePath` 用于排除"新扫描路径即候选自身"的情况(非移动,而是原地重扫)。
    static func matchRelinkCandidate(hash: String?,
                                     newFilePath: String,
                                     unavailableTracks: [(id: UUID, hash: String?, filePath: String?)]) -> UUID? {
        guard let hash = hash else { return nil }
        for c in unavailableTracks {
            guard let h = c.hash, h == hash, let fp = c.filePath, fp != newFilePath else { continue }
            return c.id
        }
        return nil
    }

    // MARK: - 格式支持

    /// AVFoundation 在 macOS 上原生支持的音频容器/编码扩展名集合(经验值,以运行时测试为准)。
    /// 详见 §11 Phase 27:MP3/AAC/M4A/ALAC/FLAC/WAV/CAF;Opus in CAF;raw OGG/Opus 可能不支持。
    static let supportedExtensions: Set<String> = [
        "mp3", "aac", "m4a", "m4b", "m4p", "alac", "flac", "wav", "caf", "aiff", "aif", "aifc"
    ]
    /// 已知 AVFoundation **不**原生支持的扩展名(需转码/容器封装)。
    static let unsupportedExtensions: Set<String> = [
        "ogg", "opus", "wma", "ape", "tak", "ofr"
    ]

    enum FormatSupport: Equatable, Sendable {
        case supported
        case unsupported
        case unknown   // 扩展名不在任一名单(如 .dsf/.amr)——交由运行时 AVAsset 判定。
    }

    /// 纯函数:按扩展名归类。小写、去点。
    static func classify(_ url: URL) -> FormatSupport {
        let ext = url.pathExtension.lowercased()
        if supportedExtensions.contains(ext) { return .supported }
        if unsupportedExtensions.contains(ext) { return .unsupported }
        return .unknown
    }

    // MARK: - I/O 注入点

    private static let defaultRead: @Sendable (URL) -> Data? = { url in
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: 64 * 1024)
    }
}