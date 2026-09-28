import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Muses

struct ArtworkImageDecoderTests {
    private func imageData(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func cropsOnlyLetterboxedYouTubeThumbnails() async throws {
        let data = try imageData(width: 480, height: 360)
        let youtube = try #require(URL(string: "https://i.ytimg.com/vi/example/hqdefault.jpg"))
        let cover = try #require(await ArtworkImageDecoder.shared.decode(data, url: youtube))
        #expect(cover.width == 480)
        #expect(cover.height == 270)
        let other = try #require(URL(string: "https://example.com/cover.png"))
        let untouched = try #require(await ArtworkImageDecoder.shared.decode(data, url: other))
        #expect(untouched.width == 480)
        #expect(untouched.height == 360)
    }

    @Test func capsLargeImagesWithoutUpscalingThumbnails() async throws {
        let url = try #require(URL(string: "https://example.com/cover.png"))
        let large = try imageData(width: 2400, height: 1200)
        let decoded = try #require(await ArtworkImageDecoder.shared.decode(large, url: url))
        #expect(decoded.width == 2048)
        #expect(decoded.height == 1024)
        let small = try imageData(width: 120, height: 120)
        let thumbnail = try #require(await ArtworkImageDecoder.shared.decode(small, url: url))
        #expect(thumbnail.width == 120)
        #expect(thumbnail.height == 120)
    }

    @Test func corruptDataFailsWithoutAnImage() async throws {
        let url = try #require(URL(string: "https://example.com/cover.png"))
        #expect(await ArtworkImageDecoder.shared.decode(Data([1, 2, 3]), url: url) == nil)
        #expect(await ArtworkImageDecoder.shared.decode(Data(), url: url, maximumPixelSize: 0) == nil)
    }
}
