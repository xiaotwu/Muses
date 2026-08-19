import Foundation

/// 非持久化元数据富集缓存(磁盘 JSON + 负缓存 + SWR)。
///
/// 缓存 enrichment 结果(`BrowsableAlbum`/`BrowsableArtist` JSON)与负查找(网络
/// 失败/无匹配),避免对同一派生候选重复打 MusicBrainz。cache-first:视图先读缓存
/// 立即上屏,后台 SWR 增量刷新。缓存格式为 `<id>.json` / `<id>.neg`,可手动清除。
///
/// 线程安全:内部 NSLock;纯 I/O,不在主线程/音频路径调用。
final class MetadataEnrichmentCache: @unchecked Sendable {
    /// 单条缓存条目:富集后的 Browsable JSON + 写入时间 + 是否负缓存。
    struct Entry: Sendable {
        let payload: Data       // Codable Browsable JSON
        let storedAt: Date
        let isNegative: Bool
    }

    private let directory: URL
    private let lock = NSLock()
    private var memory: [String: Entry] = [:]

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
    }

    /// 临时目录缓存(测试用)。
    static func temporary() -> MetadataEnrichmentCache {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("muses-enrich-\(UUID().uuidString)")
        return MetadataEnrichmentCache(directory: dir)
    }

    // MARK: - Read

    func get(_ id: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        if let cached = memory[id] { return cached }
        let url = fileURL(for: id)
        guard let data = try? Data(contentsOf: url),
              let entry = decode(data) else { return nil }
        memory[id] = entry
        return entry
    }

    func isFresh(_ id: String, freshWindow: TimeInterval) -> Bool {
        guard let entry = get(id) else { return false }
        return !entry.isNegative && Date().timeIntervalSince(entry.storedAt) < freshWindow
    }

    // MARK: - Write

    func set(payload: Data, for id: String) {
        let entry = Entry(payload: payload, storedAt: Date(), isNegative: false)
        store(entry, for: id)
    }

    /// 负缓存:记录一次失败/无匹配,`ttl` 内跳过重试。
    func setNegative(_ id: String, ttl: TimeInterval) {
        let entry = Entry(payload: Data(), storedAt: Date(), isNegative: true)
        store(entry, for: id)
        // ttl 过期后自动失效:负条目只在 ttl 内有效;isFresh 仍按 storedAt 判断,
        // 但负条目过期判定见 `isNegativeFresh`。
        _ = ttl
    }

    /// 负缓存是否仍有效(在 ttl 内)。
    func isNegativeFresh(_ id: String, ttl: TimeInterval) -> Bool {
        guard let entry = get(id), entry.isNegative else { return false }
        return Date().timeIntervalSince(entry.storedAt) < ttl
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        memory.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory,
                                                  withIntermediateDirectories: true)
    }

    // MARK: - Private

    private func store(_ entry: Entry, for id: String) {
        lock.lock(); defer { lock.unlock() }
        memory[id] = entry
        let url = fileURL(for: id)
        if let data = encode(entry) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func fileURL(for id: String) -> URL {
        // id 形如 "ytalbum:..." 含冒号;转为安全文件名。
        let safe = id.replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent("\(safe).json")
    }

    private func encode(_ entry: Entry) -> Data? {
        let dict: [String: Any] = [
            "payload": entry.payload.base64EncodedString(),
            "storedAt": entry.storedAt.timeIntervalSince1970,
            "isNegative": entry.isNegative
        ]
        return try? JSONSerialization.data(withJSONObject: dict)
    }

    private func decode(_ data: Data) -> Entry? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payloadB64 = dict["payload"] as? String,
              let payload = Data(base64Encoded: payloadB64),
              let storedTs = dict["storedAt"] as? TimeInterval,
              let isNegative = dict["isNegative"] as? Bool else { return nil }
        return Entry(payload: payload, storedAt: Date(timeIntervalSince1970: storedTs),
                     isNegative: isNegative)
    }
}