import Testing
import AppKit
import Foundation
@testable import Muses

@MainActor
struct ChromeLayoutTests {

    @Test("YouTube hqdefault URLs are treated as letterboxed")
    func letterboxURLDetection() {
        let hq = URL(string: "https://i.ytimg.com/vi/abc/hqdefault.jpg")!
        let mq = URL(string: "https://i.ytimg.com/vi/abc/mqdefault.jpg")!
        let max = URL(string: "https://i.ytimg.com/vi/abc/maxresdefault.jpg")!
        #expect(YouTubeThumbnail.isLetterboxed(hq))
        #expect(!YouTubeThumbnail.isLetterboxed(mq))
        #expect(!YouTubeThumbnail.isLetterboxed(max))
        #expect(YouTubeThumbnail.urlString(videoId: "abc") == "https://i.ytimg.com/vi/abc/hqdefault.jpg")
    }

    @Test("4:3 YouTube thumbs drop the 12.5% letterbox bars")
    func cropsFourByThreeLetterbox() {
        let image = makeSolidImage(width: 480, height: 360)
        let cropped = YouTubeThumbnail.cropLetterboxIfNeeded(
            image,
            url: URL(string: "https://i.ytimg.com/vi/abc/hqdefault.jpg")
        )
        guard let cg = cropped.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Issue.record("cropped image has no CGImage")
            return
        }
        #expect(cg.width == 480)
        #expect(cg.height == 270)
    }

    @Test("16:9 thumbs are left unchanged")
    func leavesSixteenByNine() {
        let image = makeSolidImage(width: 320, height: 180)
        let result = YouTubeThumbnail.cropLetterboxIfNeeded(
            image,
            url: URL(string: "https://i.ytimg.com/vi/abc/mqdefault.jpg")
        )
        guard let cg = result.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Issue.record("result has no CGImage")
            return
        }
        #expect(cg.width == 320)
        #expect(cg.height == 180)
    }

    @Test("Apple Music key color is FA586A")
    func appleMusicKeyColor() {
        #expect(AppleMusicTokens.keyColorHex == "FA586A")
        #expect(abs(AppleMusicTokens.keyColorRGB.r - 250.0 / 255.0) < 0.0001)
        #expect(abs(AppleMusicTokens.keyColorRGB.g - 88.0 / 255.0) < 0.0001)
        #expect(abs(AppleMusicTokens.keyColorRGB.b - 106.0 / 255.0) < 0.0001)
    }

    @Test("dark page background is measured AM Web 1F1F1F")
    func darkPageBackground() {
        #expect(abs(AppleMusicTokens.darkPageRGB.r - 31.0 / 255.0) < 0.0001)
        #expect(AppleMusicTokens.pageTitleSize == 34)
        #expect(AppleMusicTokens.sectionTitleSize == 22)
        #expect(AppleMusicTokens.sidebarWidth >= 232 && AppleMusicTokens.sidebarWidth <= 260)
        #expect(AppleMusicTokens.cardCorner == 8)
    }

    @Test("player dock is full-width web chrome, not a floating capsule")
    func playerDockMetrics() {
        #expect(PlayerDockMetrics.height == 72)
        #expect(PlayerDockMetrics.art == 48)
        #expect(PlayerDockMetrics.play > PlayerDockMetrics.icon)
        #expect(AppTopTab.from(.home) == .home)
        #expect(AppTopTab.from(.new) == .new)
        #expect(AppTopTab.from(.songs) == .library)
        #expect(SidebarSection.home.isLibrary == false)
        #expect(SidebarSection.playlists.isLibrary == true)
    }

    @Test("media cache keys include quality")
    func mediaCacheQualityKey() {
        let dir = MediaFileCache.directory
        #expect(dir.path.contains("Muses/streams"))
        let a = MediaFileCache.file(videoId: "abc", quality: "bestaudio", ext: "m4a")
        let b = MediaFileCache.file(videoId: "abc", quality: "128k", ext: "m4a")
        #expect(a.lastPathComponent.contains("bestaudio"))
        #expect(b.lastPathComponent.contains("128k"))
        #expect(a != b)
    }

    @Test("lyrics titles drop Official Video decorations")
    func sanitizesOfficialVideo() {
        #expect(LyricsService.sanitizedTitle("Letter In Orange (Official Video)") == "Letter In Orange")
        #expect(LyricsService.sanitizedTitle("Song [Official Audio]") == "Song")
        #expect(LyricsService.sanitizedTitle("Plain Title") == "Plain Title")
        #expect(LyricsService.queryTitles("Song (Official Video)") == ["Song (Official Video)", "Song"])
    }

    private func makeSolidImage(width: Int, height: Int) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }
}
