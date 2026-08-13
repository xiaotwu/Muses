import Foundation
import Observation
import SwiftData

/// 本地推荐算法:基于播放历史 + 收藏曲目,无需联网。
///
/// 三类推荐:
/// 1. **因为你听过**(Because You Listened):取播放次数最多的艺术家 → 推荐该艺术家的其他专辑。
/// 2. **未探索**(Unplayed Gems):资料库中尚未播放过任何曲目的专辑。
/// 3. **基于收藏**(From Liked):收藏曲目所属艺术家的其他专辑。
///
/// 性能:计算在 `Task.detached` 上完成,只携带值类型快照,避免在主线程上
/// 对每个专辑调用 `library.tracks(in:)`(O(albums × fetch))。所有数据在
/// 主线程一次性快照后,纯值类型计算可安全离线完成。
@Observable
@MainActor
final class RecommendationService {
    private let library: LibraryService

    init(library: LibraryService) {
        self.library = library
    }

    // MARK: - Public

    /// 推荐结果分组。
    struct Recommendations {
        var becauseYouListened: [Album] = []
        var unplayedGems: [Album] = []
        var fromLiked: [Album] = []
        var hasContent: Bool {
            !becauseYouListened.isEmpty || !unplayedGems.isEmpty || !fromLiked.isEmpty
        }
    }

    /// 计算当前推荐结果(基于播放历史 + 收藏)。异步,重计算在后台进行。
    func compute() async -> Recommendations {
        // 1. 主线程一次性快照所有需要的数据为值类型。
        let snap = snapshot()
        guard !snap.albums.isEmpty else { return Recommendations() }

        // 2. 离线纯值类型计算(不触碰 SwiftData @Model 对象)。
        let plan: RecommendationPlan = await Task.detached(priority: .userInitiated) {
            Self.plan(from: snap)
        }.value

        // 3. 主线程把 id 映射回 Album 对象(@Model 非 Sendable,须在主线程)。
        let albumByID = Dictionary(uniqueKeysWithValues: library.allAlbums().map { ($0.id, $0) })
        return Recommendations(
            becauseYouListened: plan.becauseYouListened.compactMap { albumByID[$0] },
            unplayedGems: plan.unplayedGems.compactMap { albumByID[$0] },
            fromLiked: plan.fromLiked.compactMap { albumByID[$0] })
    }

    // MARK: - Snapshots & offline plan

    /// 主线程快照:把 SwiftData 对象投影为可跨线程的值类型(Sendable)。
    private struct DataSnapshot: Sendable {
        struct AlbumSnap: Sendable { let id: UUID; let albumArtist: String? }
        struct TrackSnap: Sendable {
            let id: UUID; let artist: String; let playCount: Int; let albumID: UUID?
        }
        let albums: [AlbumSnap]
        /// 按 albumID 聚合的曲目快照,避免逐专辑 fetch。
        let tracksByAlbum: [UUID: [TrackSnap]]
        let allTracks: [TrackSnap]
        let likedArtists: Set<String>
        let topArtistName: String?
    }

    /// 离线计算结果(仅含 id,Sendable)。
    private struct RecommendationPlan: Sendable {
        let becauseYouListened: [UUID]
        let unplayedGems: [UUID]
        let fromLiked: [UUID]
    }

    private func snapshot() -> DataSnapshot {
        let albums = library.allAlbums().map {
            DataSnapshot.AlbumSnap(id: $0.id, albumArtist: $0.albumArtist)
        }
        let allTracks = library.allTracks().map {
            DataSnapshot.TrackSnap(
                id: $0.id, artist: $0.artist,
                playCount: $0.playCount, albumID: $0.album?.id)
        }
        var byAlbum: [UUID: [DataSnapshot.TrackSnap]] = [:]
        for t in allTracks {
            if let aid = t.albumID { byAlbum[aid, default: []].append(t) }
        }
        let likedArtists = Set(library.likedTracks().map(\.artist))
        let playedCounts: [String: Int] = allTracks.reduce(into: [:]) { acc, t in
            guard t.playCount > 0 else { return }
            acc[t.artist, default: 0] += t.playCount
        }
        let topArtistName = playedCounts.max(by: { $0.value < $1.value })?.key
        return DataSnapshot(
            albums: albums,
            tracksByAlbum: byAlbum,
            allTracks: allTracks,
            likedArtists: likedArtists,
            topArtistName: topArtistName)
    }

    /// 纯函数:根据快照计算推荐 id 列表。可在任意线程运行。
    private nonisolated static func plan(from snap: DataSnapshot) -> RecommendationPlan {
        // 1. 因为你听过:播放次数最多的艺术家 → 该艺术家尚未被完整听完的专辑。
        let because: [UUID] = {
            guard let artist = snap.topArtistName else { return [] }
            return snap.albums.filter { $0.albumArtist == artist }
                .filter { album in
                    let tracks = snap.tracksByAlbum[album.id] ?? []
                    let fullyPlayed = tracks.allSatisfy { $0.playCount > 0 }
                    return !fullyPlayed
                }
                .prefix(10).map(\.id)
        }()

        let becauseSet = Set(because)

        // 2. 未探索:没有任何曲目被播放过的专辑。
        let unplayed: [UUID] = snap.albums.filter { album in
            let tracks = snap.tracksByAlbum[album.id] ?? []
            return !tracks.isEmpty && tracks.allSatisfy { $0.playCount == 0 }
        }.prefix(10).map(\.id)

        // 3. 基于收藏:收藏曲目的艺术家 → 其他专辑(排除已在 because 中的)。
        let fromLiked: [UUID] = snap.albums.filter { album in
            snap.likedArtists.contains(album.albumArtist ?? "")
                && !becauseSet.contains(album.id)
        }.prefix(10).map(\.id)

        return RecommendationPlan(
            becauseYouListened: Array(because),
            unplayedGems: Array(unplayed),
            fromLiked: Array(fromLiked))
    }
}