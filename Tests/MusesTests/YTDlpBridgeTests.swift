import Testing
import Foundation
@testable import Muses

@Suite("YTDlpBridge")
@MainActor
struct YTDlpBridgeTests {

    /// Writes a fake "yt-dlp" shell script to a temporary directory and marks it executable.
    /// - Parameter script: the script body (the caller supplies the `#!/bin/sh` shebang).
    /// - Returns: the absolute path of the fake binary.
    private func makeFakeBinary(script: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ytdlp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let binPath = dir.appendingPathComponent("yt-dlp").path
        try script.write(toFile: binPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: binPath)
        return binPath
    }

    // MARK: - resolveStreamURL

    @Test("resolveStreamURL 解析第一行 stdout 作为 URL")
    func resolveStreamURLParsesFirstStdoutLine() async throws {
        let bin = try makeFakeBinary(script: """
            #!/bin/sh
            echo "https://example.com/audio.m4a"
            """)
        let bridge = YTDlpBridge(binaryPath: bin)
        let url = try await bridge.resolveStreamURL(
            videoId: "vid1", quality: "bestaudio")
        #expect(url.absoluteString == "https://example.com/audio.m4a")
    }

    // MARK: - fetchPlaylist

    @Test("fetchPlaylist 解析 NDJSON 条目")
    func fetchPlaylistParsesNDJSON() async throws {
        let bin = try makeFakeBinary(script: """
            #!/bin/sh
            echo '{"id":"v1","title":"Song A","uploader":"Chan","duration":201.5}'
            echo '{"id":"v2","title":"Song B"}'
            """)
        let bridge = YTDlpBridge(binaryPath: bin)
        let entries = try await bridge.fetchPlaylist(url: "https://example.com/pl")
        #expect(entries.count == 2)
        #expect(entries[0].id == "v1")
        #expect(entries[0].title == "Song A")
        #expect(entries[0].uploader == "Chan")
        #expect(entries[0].duration == 201.5)
        #expect(entries[1].id == "v2")
        #expect(entries[1].title == "Song B")
        #expect(entries[1].uploader == nil)
        #expect(entries[1].duration == nil)
    }

    // MARK: - exitCode

    @Test("非零退出抛出 exitCode")
    func nonZeroExitThrowsExitCode() async throws {
        let bin = try makeFakeBinary(script: """
            #!/bin/sh
            echo "err" >&2
            exit 2
            """)
        let bridge = YTDlpBridge(binaryPath: bin)
        do {
            _ = try await bridge.resolveStreamURL(videoId: "x", quality: "bestaudio")
            Issue.record("应抛出 YTDlpError.exitCode")
        } catch let e as YTDlpBridge.YTDlpError {
            #expect(String(describing: e).hasPrefix("exitCode"))
        } catch {
            Issue.record("抛出了非 YTDlpError 类型:\(error)")
        }
    }

    // MARK: - timeout

    @Test("超时抛出 timeout")
    func timeoutThrowsTimeout() async throws {
        let bin = try makeFakeBinary(script: """
            #!/bin/sh
            sleep 5
            echo done
            """)
        let bridge = YTDlpBridge(binaryPath: bin)
        do {
            _ = try await bridge.resolveStreamURL(
                videoId: "x", quality: "bestaudio", timeout: 0.5)
            Issue.record("应抛出 YTDlpError.timeout")
        } catch let e as YTDlpBridge.YTDlpError {
            #expect(String(describing: e) == "timeout")
        } catch {
            Issue.record("抛出了非 YTDlpError 类型:\(error)")
        }
    }
}