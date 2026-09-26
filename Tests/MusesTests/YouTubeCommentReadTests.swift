import Foundation
import Testing
@testable import Muses

private actor CommentRequestRecorder {
    var urls: [URL] = []
    var methods: [String] = []
    var bodies: [Data?] = []
    func append(_ request: URLRequest) {
        if let url = request.url { urls.append(url) }
        methods.append(request.httpMethod ?? "")
        bodies.append(request.httpBody)
    }
}

@Suite("YouTube comment reads")
struct YouTubeCommentReadTests {
    @Test("subscription target resolves only an exact stable channel ID")
    func channelLookup() async throws {
        let recorder = CommentRequestRecorder()
        let client = YouTubeDataAPIClient(accessTokenProvider: { "test-token" },
            http: { request in
                let url = try #require(request.url)
                await recorder.append(request)
                let body = """
                    {"items":[{"id":"UCabcdefghij123456789012",
                    "snippet":{"title":"Verified Channel"}}]}
                    """
                return (Data(body.utf8), HTTPURLResponse(url: url,
                    statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        let channel = try await client.channel(id: "UCabcdefghij123456789012")
        #expect(channel?.title == "Verified Channel")
        let urls = await recorder.urls
        #expect(urls.count == 1)
        #expect(URLComponents(url: urls[0], resolvingAgainstBaseURL: false)?
            .queryItems?.contains(.init(name: "id", value: "UCabcdefghij123456789012")) == true)
        await #expect(throws: YouTubeDataAPIClient.DataAPIError.self) {
            _ = try await client.channel(id: "Channel Name")
        }
        #expect(await recorder.urls.count == 1)
    }

    @Test("video metadata uses source timestamp and ISO duration without inferring missing availability")
    func videoMetadata() async throws {
        let client = YouTubeDataAPIClient(accessTokenProvider: { "test-token" },
            http: { request in
                let url = try #require(request.url)
                let body = """
                    {"items":[{"id":"abcdefghijk","snippet":{"publishedAt":"2025-11-14T08:30:00Z"},
                    "contentDetails":{"duration":"PT1H2M3S"},"status":{"uploadStatus":"processed"}}]}
                    """
                return (Data(body.utf8), HTTPURLResponse(url: url,
                    statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        let values = try await client.videoMetadata(ids: ["abcdefghijk"])
        let item = try #require(values.first)
        #expect(item.durationMs == 3_723_000)
        #expect(item.publishedAt != nil)
        #expect(item.availability == .available)
    }

    @Test("thread and reply pages use plain text and separate continuation tokens")
    func pages() async throws {
        let recorder = CommentRequestRecorder()
        let client = YouTubeDataAPIClient(accessTokenProvider: { "test-token" },
            http: { request in
                let url = try #require(request.url)
                await recorder.append(request)
                let isReply = url.path.hasSuffix("/comments")
                let body = isReply ? """
                    {"nextPageToken":"more-replies","items":[{"id":"reply-1","snippet":{
                    "authorDisplayName":"Reader","authorChannelId":{"value":"UCreader"},
                    "textDisplay":"Hello & world","publishedAt":"2026-01-01T00:00:00Z"}}]}
                    """ : """
                    {"nextPageToken":"more-threads","items":[{"id":"thread-1","snippet":{
                    "totalReplyCount":2,"topLevelComment":{"id":"top-1","snippet":{
                    "authorDisplayName":"Author","textDisplay":"Top comment"}}}}]}
                    """
                return (Data(body.utf8), HTTPURLResponse(url: url,
                    statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })

        let threads = try await client.commentThreads(videoID: "abcdefghijk")
        #expect(threads.items.first?.topLevelComment.text == "Top comment")
        #expect(threads.items.first?.totalReplyCount == 2)
        #expect(threads.nextPageToken == "more-threads")
        let replies = try await client.commentReplies(parentID: "top-1", pageToken: "page + 2")
        #expect(replies.items.first?.authorChannelID == "UCreader")
        #expect(replies.items.first?.text == "Hello & world")
        #expect(replies.nextPageToken == "more-replies")
        let urls = await recorder.urls
        #expect(urls.count == 2)
        #expect(await recorder.methods == ["GET", "GET"])
        #expect(URLComponents(url: urls[0], resolvingAgainstBaseURL: false)?
            .queryItems?.contains(.init(name: "textFormat", value: "plainText")) == true)
        #expect(URLComponents(url: urls[1], resolvingAgainstBaseURL: false)?
            .queryItems?.contains(.init(name: "pageToken", value: "page + 2")) == true)
    }
}
