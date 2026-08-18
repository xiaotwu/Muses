import Foundation
import CryptoKit

/// 通用 stale-while-revalidate 缓存:内存 + 磁盘 JSON,带 `fetchedAt` 时间戳。
///
/// 语义:
///  - `get(_:)` 返回缓存值及其年龄(无论新鲜与否);调用方决定是否后台刷新。
///  - `set(_:value:)` 写入内存并异步落盘。
///  - `isFresh(age:freshWindow:)` 判定是否在新鲜窗口内。
///
/// `T` 需 `Codable & Sendable`。磁盘文件为 `{dir}/{key-hex}.json`,key 经 SHA-256
/// 归一化避免非法字符。`@MainActor` 与 `StreamURLCache` 一致;磁盘 I/O 在 detached
/// 任务中执行,不阻塞主线程。
@MainActor
final class SWRCache<T: Codable & Sendable> {
    struct Cached: Sendable {
        let value: T
        let fetchedAt: Date
        var age: TimeInterval { Date().timeIntervalSince(fetchedAt) }
    }

    private struct DiskEnvelope: Codable {
        let value: T
        let fetchedAt: Date
    }

    private let memory: NSCache<NSString, CacheBox> = .init()
    private let directory: URL

    /// 内存值包装(NSCache 存引用类型)。
    final class CacheBox {
        let cached: Cached
        init(_ cached: Cached) { self.cached = cached }
    }

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory,
                                                  withIntermediateDirectories: true)
    }

    /// 读取缓存值(内存优先,回退磁盘)。无缓存返回 nil。
    func get(_ key: String) -> Cached? {
        let nsKey = key as NSString
        if let box = memory.object(forKey: nsKey) {
            return box.cached
        }
        // 磁盘回填内存。
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(DiskEnvelope.self, from: data) else {
            return nil
        }
        let cached = Cached(value: envelope.value, fetchedAt: envelope.fetchedAt)
        memory.setObject(CacheBox(cached), forKey: nsKey)
        return cached
    }

    /// 写入内存并异步落盘。
    func set(_ key: String, value: T, fetchedAt: Date = .init()) {
        let cached = Cached(value: value, fetchedAt: fetchedAt)
        memory.setObject(CacheBox(cached), forKey: key as NSString)
        let envelope = DiskEnvelope(value: value, fetchedAt: fetchedAt)
        let url = fileURL(for: key)
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(envelope) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// 使某 key 失效(内存 + 磁盘)。
    func invalidate(_ key: String) {
        memory.removeObject(forKey: key as NSString)
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    /// 清空全部(内存;磁盘文件按需清理)。
    func clearAll() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory,
                                                  withIntermediateDirectories: true)
    }

    func isFresh(_ cached: Cached, freshWindow: TimeInterval) -> Bool {
        cached.age <= freshWindow
    }

    private func fileURL(for key: String) -> URL {
        let hash = SHA256Hex(key)
        return directory.appendingPathComponent("\(hash).json")
    }
}

/// SHA-256 十六进制字符串(归一化缓存 key)。
func SHA256Hex(_ s: String) -> String {
    let data = Data(s.utf8)
    let digest = Array(SHA256.hash(data: data))
    return digest.map { String(format: "%02x", $0) }.joined()
}