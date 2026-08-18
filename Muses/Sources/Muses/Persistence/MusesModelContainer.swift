import Foundation
import SwiftData

enum MusesSchema {
    static var v1: Schema {
        Schema([Track.self, Album.self, Artist.self, ScanRoot.self, QueueState.self, EQPreset.self,
                YouTubeImport.self, YouTubeImportItem.self,
                Playlist.self, PlaylistItem.self,
                ListeningEvent.self,
                ListeningSession.self])
    }
}

func makeModelContainer(inMemory: Bool = false, storeURL: URL? = nil) throws -> ModelContainer {
    let config: ModelConfiguration
    if inMemory {
        config = ModelConfiguration(isStoredInMemoryOnly: true)
    } else {
        let url = storeURL ?? musesDefaultStoreURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        config = ModelConfiguration(url: url)
    }
    return try ModelContainer(for: MusesSchema.v1, configurations: config)
}

/// on-disk 数据库默认路径: `~/Library/Application Support/Muses/muses.sqlite`。
/// 抽出为函数,供 `makeModelContainerWithFallback` 与测试共享同一路径推导。
func musesDefaultStoreURL() -> URL {
    URL.homeDirectory.appending(path: "Library/Application Support/Muses/muses.sqlite")
}

/// 带故障保护的容器构造:供 `MusesApp` 使用。若 on-disk 容器构造失败(如迁移失败 /
/// 数据库损坏),先把数据库文件备份为 `muses-corrupt-<时间>.sqlite`(-wal/-shm 同备份),
/// 再回退到内存容器,使播放可继续;**绝不**删除或覆盖原数据库。
/// 失败信息记入日志,便于用户上报。
/// `storeURL` 仅用于测试指向临时路径;生产调用留空,使用 `musesDefaultStoreURL()`。
func makeModelContainerWithFallback(storeURL: URL? = nil) -> ModelContainer {
    do {
        return try makeModelContainer(inMemory: false, storeURL: storeURL)
    } catch {
        let log = AppLog.for("MusesModelContainer")
        log.error("on-disk container failed; backing up DB and falling back to in-memory: \(error)")
        backupCorruptStore(at: storeURL ?? musesDefaultStoreURL())
        // 回退到内存容器:应用仍可运行(需重新扫描),用户数据备份保留在磁盘。
        do {
            return try makeModelContainer(inMemory: true)
        } catch {
            // 极端情况:内存容器也构造失败(几乎不可能,除非 schema 编译期有误)。
            // 再备份一次并以 fatalError 终止——比静默继续更安全。
            log.error("in-memory fallback also failed: \(error)")
            backupCorruptStore(at: storeURL ?? musesDefaultStoreURL())
            fatalError("Muses: unable to construct any ModelContainer: \(error)")
        }
    }
}

/// 把 on-disk 数据库文件备份到同目录 `<stem>-corrupt-<时间>.sqlite{,-wal,-shm}`。
/// 已存在同名备份时跳过,避免覆盖。永不删除原文件。
/// `storeURL` 指定要备份的 store 路径;默认使用 `musesDefaultStoreURL()`。
func backupCorruptStore(at storeURL: URL) {
    let dir = storeURL.deletingLastPathComponent()
    let stem = storeURL.deletingPathExtension().lastPathComponent  // 如 "muses"
    let ext = storeURL.pathExtension                                 // 如 "sqlite"
    let stamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
    let suffixes = ["", "-wal", "-shm"]
    for suffix in suffixes {
        let src = dir.appending(path: "\(stem).\(ext)\(suffix)")
        let dst = dir.appending(path: "\(stem)-corrupt-\(stamp).\(ext)\(suffix)")
        guard FileManager.default.fileExists(atPath: src.path) else { continue }
        if FileManager.default.fileExists(atPath: dst.path) { continue }
        try? FileManager.default.copyItem(at: src, to: dst)
    }
}