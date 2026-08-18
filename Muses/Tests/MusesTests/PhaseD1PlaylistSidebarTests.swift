import Testing
import Foundation
@testable import Muses

/// Phase D1 — 歌单侧边栏合并适配器与 YouTube 链接识别的纯逻辑测试。
/// 不触 SwiftData 持久化容器:仅构造未插入的 @Model 实例读取属性。
@Suite("Phase D1 — Playlist sidebar adapter & link detection")
struct PhaseD1PlaylistSidebarTests {

    // MARK: - PlaylistSidebarAdapter.merged

    @Test("merged: 本地与 YouTube 合并,钉选置顶,其余按时间倒序")
    func mergedSortsPinnedFirstThenDateDesc() {
        let now = Date()
        let localOld = Playlist(name: "Old", createdAt: now.addingTimeInterval(-3600), pinned: false)
        let localNew = Playlist(name: "New", createdAt: now, pinned: false)
        let localPinned = Playlist(name: "Pinned", createdAt: now.addingTimeInterval(-7200), pinned: true)
        let yt = YouTubeImport(playlistId: "PL1", url: "u", title: "YT", channel: "c",
                               importedAt: now.addingTimeInterval(-1800))

        let merged = PlaylistSidebarAdapter.merged(local: [localOld, localNew, localPinned], youTube: [yt])

        // 钉选置顶,其余按 sortDate 倒序:New(0) > YT(-1800) > Old(-3600)
        #expect(merged.count == 4)
        #expect(merged[0].name == "Pinned")
        #expect(merged[1].name == "New")
        #expect(merged[2].name == "YT")
        #expect(merged[3].name == "Old")
    }

    @Test("merged: YouTube 项标记 origin=.youtube 且 isYouTube")
    func mergedYouTubeOriginFlag() {
        let yt = YouTubeImport(playlistId: "PL1", url: "u", title: "YT", channel: "c", importedAt: Date())
        let merged = PlaylistSidebarAdapter.merged(local: [], youTube: [yt])
        #expect(merged.count == 1)
        #expect(merged[0].isYouTube)
        #expect(merged[0].origin == .youtube)
        #expect(merged[0].youTubeImportId == yt.id)
        #expect(merged[0].playlistId == nil)
    }

    @Test("merged: 本地项标记 origin=.local 且携带 playlistId")
    func mergedLocalOriginFlag() {
        let p = Playlist(name: "Local", createdAt: Date())
        let merged = PlaylistSidebarAdapter.merged(local: [p], youTube: [])
        #expect(merged.count == 1)
        #expect(merged[0].origin == .local)
        #expect(merged[0].playlistId == p.id)
        #expect(merged[0].youTubeImportId == nil)
        #expect(!merged[0].isYouTube)
    }

    @Test("merged: id 跨类型唯一(前缀区分,无碰撞)")
    func mergedIdsUniqueAcrossOrigins() {
        let p = Playlist(name: "Local", createdAt: Date())
        let yt = YouTubeImport(playlistId: "PL1", url: "u", title: "YT", channel: "c", importedAt: Date())
        let merged = PlaylistSidebarAdapter.merged(local: [p], youTube: [yt])
        let ids = Set(merged.map { $0.id })
        #expect(ids.count == 2)
        #expect(merged.contains { $0.id.hasPrefix("pl-") })
        #expect(merged.contains { $0.id.hasPrefix("yt-") })
    }

    // MARK: - YouTubeLinkKind.detect

    @Test("detect: playlist 链接(list= 参数)")
    func detectPlaylist() {
        #expect(YouTubeLinkKind.detect("https://www.youtube.com/playlist?list=PLxxx") == .playlist)
        #expect(YouTubeLinkKind.detect("https://www.youtube.com/watch?v=abc&list=PLyyy") == .playlist)
        #expect(YouTubeLinkKind.detect("https://youtu.be/abc?list=PLzzz") == .playlist)
    }

    @Test("detect: 单曲链接")
    func detectVideo() {
        #expect(YouTubeLinkKind.detect("https://www.youtube.com/watch?v=abc123") == .video)
        #expect(YouTubeLinkKind.detect("https://youtu.be/abc123") == .video)
        #expect(YouTubeLinkKind.detect("https://www.youtube.com/shorts/abc123") == .video)
        #expect(YouTubeLinkKind.detect("https://www.youtube.com/embed/abc123") == .video)
    }

    @Test("detect: 非法/空/非 YouTube 链接 → unknown")
    func detectUnknown() {
        #expect(YouTubeLinkKind.detect("") == .unknown)
        #expect(YouTubeLinkKind.detect("not a url") == .unknown)
        #expect(YouTubeLinkKind.detect("https://example.com/watch?v=abc") == .unknown)
        // /playlist 但无 list= 参数,无法确定歌单 id
        #expect(YouTubeLinkKind.detect("https://www.youtube.com/playlist") == .unknown)
    }
}