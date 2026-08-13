import Foundation
import Observation
import SwiftData

/// 本地推荐算法:基于播放历史 + 收藏曲目,无需联网。
///
/// 三类推荐:
/// 1. **因为你听过**(Because You Listened):取播放次数最多的艺术家 → 推荐该艺术家的其他专辑。
/// 2. **未探索**(Unplayed Gems):资料库中尚未播放过任何曲目的专辑。
/// 3. **基于收藏**(From Liked):收藏曲目所属艺术家的其他专辑。
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

    /// 计算当前推荐结果(基于播放历史 + 收藏)。
    func compute() -> Recommendations {
        let albums = library.allAlbums()
        let allTracks = library.allTracks()
        guard !albums.isEmpty else { return Recommendations() }

        let played = allTracks.filter { $0.playCount > 0 }
        let liked = library.likedTracks()

        // 1. 因为你听过:播放次数最多的艺术家 → 其他专辑
        let topArtist = topPlayedArtist(tracks: played)
        let becauseListened: [Album] = {
            guard let artist = topArtist else { return [] }
            // 该艺术家的专辑中,排除"全部曲目都已高播放"的
            return albums.filter { $0.albumArtist == artist.name }
                .filter { album in
                    let albumTracks = library.tracks(in: album)
                    let fullyPlayed = albumTracks.allSatisfy { $0.playCount > 0 }
                    return !fullyPlayed
                }
                .prefix(10).map { $0 }
        }()

        // 2. 未探索:没有任何曲目被播放过的专辑
        let unplayed: [Album] = albums.filter { album in
            let albumTracks = library.tracks(in: album)
            return !albumTracks.isEmpty && albumTracks.allSatisfy { $0.playCount == 0 }
        }.prefix(10).map { $0 }

        // 3. 基于收藏:收藏曲目的艺术家 → 其他专辑(排除已在 becauseListened 中的)
        let likedArtists = Set(liked.map { $0.artist })
        let fromLikedAlbums: [Album] = albums.filter { album in
            likedArtists.contains(album.albumArtist)
                && !becauseListened.contains(where: { $0.id == album.id })
        }.prefix(10).map { $0 }

        return Recommendations(
            becauseYouListened: Array(becauseListened),
            unplayedGems: Array(unplayed),
            fromLiked: Array(fromLikedAlbums)
        )
    }

    // MARK: - Private

    /// 取播放次数最高的艺术家(按所有曲目的 playCount 汇总)。
    private func topPlayedArtist(tracks: [Track]) -> Artist? {
        // 汇总每个艺术家的总播放次数
        var counts: [String: Int] = [:]
        for t in tracks {
            counts[t.artist, default: 0] += t.playCount
        }
        guard let topName = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        return library.allArtists().first { $0.name == topName }
    }
}