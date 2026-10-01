import Foundation
import SwiftData

/// Opt-in idle downloads. It never changes the queue, history, or playback state,
/// and never evicts previously played files to make room for predictions.
@Observable
@MainActor
final class StreamPrecacheService {
    enum Scope: String, CaseIterable { case favorites, recent, both }
    private let defaults: UserDefaults
    private let resolution: StreamResolutionCoordinator
    private let session: URLSession
    private let directory: URL
    private let candidates: (Scope) -> [TrackSnapshot]
    private let isBusy: () -> Bool
    private var work: Task<Void, Never>?
    private var resource: SharedStreamResource?
    private var generation = UUID()
    var completedCount = 0
    var status = tr("Off", "已关闭")

    init(resolution: StreamResolutionCoordinator, defaults: UserDefaults = .standard,
         candidates: @escaping (Scope) -> [TrackSnapshot], isBusy: @escaping () -> Bool,
         session: URLSession = .shared, directory: URL = MediaFileCache.directory) {
        self.resolution = resolution
        self.session = session
        self.directory = directory
        self.defaults = defaults
        self.candidates = candidates
        self.isBusy = isBusy
    }

    func pauseForPlayback() {
        generation = UUID()
        work?.cancel()
        work = nil
        if let resource { Task { await resource.cancel() } }
        resource = nil
        if defaults.bool(forKey: PrefKey.streamPrecacheEnabled) { status = tr("Waiting for idle playback", "等待播放空闲") }
    }

    func configure() {
        pauseForPlayback()
        completedCount = 0
        guard defaults.bool(forKey: PrefKey.streamPrecacheEnabled) else { status = tr("Off", "已关闭"); return }
        let generation = generation
        let scope = Scope(rawValue: defaults.string(forKey: PrefKey.streamPrecacheScope) ?? "favorites") ?? .favorites
        let quality = defaults.string(forKey: PrefKey.ytAudioQuality) ?? "bestaudio"
        let budget = Self.budgetBytes(defaults.integer(forKey: PrefKey.streamPrecacheLimitGB))
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            // Downloads remain enabled across launches, but wait while playback
            // is active. No high-frequency playback clock is observed.
            while isBusy() {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard !Task.isCancelled, self.generation == generation else { return }
            }
            let rows = candidates(scope)
            var seen = Set<String>()
            for track in rows where seen.insert(track.youTubeId).inserted {
                guard !Task.isCancelled, self.generation == generation, !isBusy() else { return }
                guard !track.youTubeId.isEmpty, MediaFileCache.existing(videoId: track.youTubeId, quality: quality, in: directory) == nil else { continue }
                let directory = directory
                let used = await Task.detached(priority: .utility) { MediaFileCache.totalBytes(in: directory) }.value
                guard !Task.isCancelled, self.generation == generation, !isBusy() else { return }
                guard used < budget else { status = tr("Cache budget reached", "已达到缓存容量限制"); return }
                status = tr("Preparing \(track.title)", "正在准备 \(track.title)")
                var ownedResource: SharedStreamResource?
                do {
                    let url = try await YTDlpRequestPriority.$interactive.withValue(false) {
                        try await resolution.resolve(videoID: track.youTubeId, quality: quality)
                    }
                    try Task.checkCancellation()
                    guard !isBusy(), self.generation == generation, url.scheme == "https" else { return }
                    let destination = MediaFileCache.file(videoId: track.youTubeId, quality: quality, ext: "m4a", in: directory)
                    let resource = SharedStreamResource(source: url, destination: destination, session: session)
                    ownedResource = resource
                    self.resource = resource
                    let info = try await resource.information()
                    try Task.checkCancellation()
                    guard self.generation == generation, !isBusy() else {
                        await resource.cancel()
                        return
                    }
                    guard Self.fits(size: info.size, used: used, budget: budget) else {
                        await resource.cancel(); self.resource = nil
                        continue
                    }
                    _ = try await resource.finish()
                    await resource.cancel()
                    guard !Task.isCancelled, self.generation == generation else { return }
                    self.resource = nil
                    completedCount += 1
                } catch {
                    await ownedResource?.cancel()
                    if Task.isCancelled || self.generation != generation { return }
                    self.resource = nil
                }
            }
            if self.generation == generation { status = tr("Preparation finished: \(completedCount) downloaded", "预下载已结束：新增 \(completedCount) 首") }
        }
    }

    func awaitWorkForTests() async { await work?.value }

    static func budgetBytes(_ gigabytes: Int) -> Int64 { Int64([1, 2, 5, 10].contains(gigabytes) ? gigabytes : 2) * 1_073_741_824 }
    static func fits(size: Int64, used: Int64, budget: Int64) -> Bool {
        size > 0 && used >= 0 && used <= budget && size <= budget - used
    }

    static func snapshots(container: ModelContainer, scope: Scope) -> [TrackSnapshot] {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Track>(sortBy: [SortDescriptor(\.playCount, order: .reverse)])
        switch scope {
        case .favorites: descriptor.predicate = #Predicate { $0.liked == true }
        case .recent: descriptor.predicate = #Predicate { $0.lastPlayedAt != nil }
        case .both: descriptor.predicate = #Predicate { $0.liked == true || $0.lastPlayedAt != nil }
        }
        descriptor.fetchLimit = 200
        return ((try? context.fetch(descriptor)) ?? []).map { TrackSnapshot(from: $0) }
    }
}
