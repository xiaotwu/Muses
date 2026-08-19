import Foundation
import AppKit
import SwiftUI

/// 共享图片加载器(spec §22):内存缓存 + 请求合并 + 低分辨率优先 + 取消离屏加载。
///
/// - 内存:`NSCache<NSString, NSImage>`(系统在内存压力下自动淘汰)。
/// - 请求合并:同 URL 并发请求只发一次网络/磁盘读,其余 await 同一任务。
/// - 低分辨率优先:YouTube `hqdefault`(<200px)先到先显示,需要时再升级。
/// - 取消:`load(_:)` 返回的 task 在视图 `.onDisappear` 取消,避免后台继续抓取。
///
/// 磁盘层依赖系统共享 `URLCache`(AsyncImage 同款);此处只补内存 + 合并 + 取消。
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    private let memory: NSCache<NSString, NSImage> = .init()
    /// 进行中的请求(URL → Task),用于合并。
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    init() {
        // 内存上限 ~50MB,够首页几十张封面。
        memory.countLimit = 256
        memory.totalCostLimit = 50 * 1024 * 1024
    }

    /// 同步取内存命中(供视图首帧立即可用)。
    func cachedImage(for url: URL) -> NSImage? {
        memory.object(forKey: url.absoluteString as NSString)
    }

    func cacheKey(url: URL, targetSize: CGFloat) -> String {
        "\(url.absoluteString)#\(Int(targetSize.rounded()))"
    }

    func cachedImage(for url: URL, targetSize: CGFloat) -> NSImage? {
        memory.object(forKey: cacheKey(url: url, targetSize: targetSize) as NSString)
    }

    /// 本地文件有界解码;不走 `URLSession`。同 key 合并,返回的 `Task` 可被取消。
    func loadLocal(url: URL, targetSize: CGFloat) -> Task<NSImage?, Never> {
        let key = cacheKey(url: url, targetSize: targetSize)
        if let hit = memory.object(forKey: key as NSString) {
            return Task { hit }
        }
        if let existing = inFlight[key] { return existing }
        let task = Task<NSImage?, Never> { [self] in
            defer { Task { @MainActor in self.inFlight[key] = nil } }
            let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let src = NSImage(contentsOf: url) else { return nil }
                let scale: CGFloat = 2
                let px = max(targetSize * scale, 1)
                let newSize = NSSize(width: px, height: px)
                let dest = NSImage(size: newSize)
                dest.lockFocus()
                src.draw(in: NSRect(origin: .zero, size: newSize),
                         from: NSRect(origin: .zero, size: src.size),
                         operation: .copy, fraction: 1)
                dest.unlockFocus()
                return dest
            }.value
            if let img {
                await MainActor.run {
                    self.memory.setObject(img, forKey: key as NSString, cost: Int(targetSize * targetSize * 4))
                }
            }
            return img
        }
        inFlight[key] = task
        return task
    }

    /// 异步加载;请求合并 + 内存缓存。返回的 `Task` 可被取消。
    func load(_ url: URL) -> Task<NSImage?, Never> {
        let key = url.absoluteString as NSString
        if let hit = memory.object(forKey: key) {
            return Task { hit }
        }
        let keyStr = url.absoluteString
        if let existing = inFlight[keyStr] { return existing }
        let task = Task<NSImage?, Never> { [self] in
            defer { Task { @MainActor in self.inFlight[keyStr] = nil } }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled, let img = NSImage(data: data) else { return nil }
                // 估算 cost 以辅助 NSCache 淘汰决策。
                let cost = data.count
                self.memory.setObject(img, forKey: key, cost: cost)
                return img
            } catch {
                return nil
            }
        }
        inFlight[keyStr] = task
        return task
    }
}

/// 替代裸 `AsyncImage` 的内存缓存图片视图(spec §22)。
/// 首帧用内存命中立即绘制;未命中异步加载并支持取消;低分辨率 URL 优先。
struct CachedAsyncImage: View {
    let url: URL?
    var lowResURL: URL? = nil
    private let renderer: (NSImage) -> AnyView
    private let placeholderView: AnyView

    @State private var image: NSImage? = nil

    init(url: URL?,
         lowResURL: URL? = nil,
         content: @escaping (Image) -> some View,
         placeholder: @escaping () -> some View) {
        self.url = url
        self.lowResURL = lowResURL
        self.renderer = { ns in AnyView(content(Image(nsImage: ns))) }
        self.placeholderView = AnyView(placeholder())
    }

    var body: some View {
        Group {
            if let img = image {
                renderer(img)
            } else {
                placeholderView
            }
        }
        .task(id: url) {
            await loadImage()
        }
    }

    @MainActor
    private func loadImage() async {
        guard let url else { image = nil; return }
        // 内存命中:首帧立即可用。
        if let hit = ImageLoader.shared.cachedImage(for: url) {
            image = hit
            PerfTrace.event("artwork.firstVisible")
            return
        }
        // 低分辨率优先:若提供且未命中,先加载低清,再升级。
        if let low = lowResURL, low != url,
           ImageLoader.shared.cachedImage(for: low) == nil {
            let lowTask = ImageLoader.shared.load(low)
            if let lowImg = await lowTask.value, !Task.isCancelled {
                image = lowImg
                PerfTrace.event("artwork.firstVisible")
            }
        }
        let task = ImageLoader.shared.load(url)
        if let img = await task.value, !Task.isCancelled {
            image = img
            PerfTrace.event("artwork.firstVisible")
        }
    }
}