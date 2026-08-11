import Foundation

final class DirectoryScanner {
    static let extensions: Set<String> = ["mp3", "m4a", "aac", "alac", "flac",
                                         "opus", "ogg", "wav", "aiff"]

    func enumerateAudio(at root: URL) -> AsyncStream<URL> {
        AsyncStream { continuation in
            Task.detached(priority: .utility) {
                let fm = FileManager.default
                guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [
                    .isRegularFileKey, .localizedNameKey
                ]) else {
                    continuation.finish(); return
                }
                // 用 allObjects 避免在异步上下文中调用非 Sendable 的 makeIterator()。
                for case let url as URL in enumerator.allObjects {
                    if Task.isCancelled { continuation.finish(); return }
                    if Self.extensions.contains(url.pathExtension.lowercased()) {
                        continuation.yield(url)
                    }
                }
                continuation.finish()
            }
        }
    }
}