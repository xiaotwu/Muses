import Foundation

/// Wrapper around the `yt-dlp` binary.
///
/// Invokes the local `yt-dlp` executable via `Process` for two jobs:
///  1. resolving a single video's direct audio stream URL (`-g` / `--get-url`);
///  2. fetching flat-playlist entries as NDJSON (`--flat-playlist --dump-json`).
///
/// This bridge is `@MainActor`, consistent with `StreamURLCache` /
/// `MetadataEnricherService`; the slow subprocess work runs in a
/// `Task.detached` while the main actor simply awaits the result.
@MainActor
final class YTDlpBridge {

    enum YTDlpError: LocalizedError, Equatable, Sendable {
        /// The yt-dlp binary was not found on disk.
        case notFound
        /// The subprocess exited with a non-zero status; carries the exit code and (trimmed) stderr.
        case exitCode(Int, String)
        /// The subprocess exceeded the timeout and was terminated.
        case timeout
        /// stdout could not be parsed into the expected structure.
        case parseFailed(String)

        var errorDescription: String? {
            switch self {
            case .notFound:
                tr("yt-dlp binary not found", "yt-dlp 二进制未找到")
            case .exitCode(let code, let stderr):
                tr("yt-dlp exit code \(code):\(stderr)", "yt-dlp 退出码 \(code):\(stderr)")
            case .timeout:
                tr("yt-dlp timed out", "yt-dlp 调用超时")
            case .parseFailed(let m):
                tr("yt-dlp output parse failed: \(m)", "yt-dlp 输出解析失败:\(m)")
            }
        }

        static func == (lhs: YTDlpError, rhs: YTDlpError) -> Bool {
            String(describing: lhs) == String(describing: rhs)
        }
    }

    /// A single entry from a flat-playlist `--dump-json` stream.
    /// `id` and `title` are required; `uploader` / `duration` may be absent.
    struct YTDlpPlaylistEntry: Codable, Sendable, Equatable {
        let id: String
        let title: String
        let uploader: String?
        let duration: Double?
        /// Parent playlist title from yt-dlp (`playlist_title` / `playlist`).
        let playlistTitle: String?
        /// Stable uploader/channel identity when yt-dlp exposes it.
        let channelID: String?
        /// YouTube Music metadata. These fields distinguish an official audio
        /// song from a generic video without changing video identity.
        let track: String?
        let album: String?
        let releaseYear: Int?

        init(id: String,
             title: String,
             uploader: String? = nil,
             duration: Double? = nil,
             playlistTitle: String? = nil,
             channelID: String? = nil,
             track: String? = nil,
             album: String? = nil,
             releaseYear: Int? = nil) {
            self.id = id
            self.title = title
            self.uploader = uploader
            self.duration = duration
            self.playlistTitle = playlistTitle
            self.channelID = channelID
            self.track = track
            self.album = album
            self.releaseYear = releaseYear
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(String.self, forKey: .id)
            self.title = try c.decode(String.self, forKey: .title)
            self.uploader = try c.decodeIfPresent(String.self, forKey: .uploader)
            self.duration = try c.decodeIfPresent(Double.self, forKey: .duration)
            let named = try c.decodeIfPresent(String.self, forKey: .playlistTitle)
            let playlist = try c.decodeIfPresent(String.self, forKey: .playlist)
            self.playlistTitle = Self.nonEmpty(named) ?? Self.nonEmpty(playlist)
            let channelID = try c.decodeIfPresent(String.self, forKey: .channelID)
            let uploaderID = try c.decodeIfPresent(String.self, forKey: .uploaderID)
            self.channelID = Self.nonEmpty(channelID) ?? Self.nonEmpty(uploaderID)
            self.track = Self.nonEmpty(try c.decodeIfPresent(String.self, forKey: .track))
            self.album = Self.nonEmpty(try c.decodeIfPresent(String.self, forKey: .album))
            self.releaseYear = try c.decodeIfPresent(Int.self, forKey: .releaseYear)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(title, forKey: .title)
            try c.encodeIfPresent(uploader, forKey: .uploader)
            try c.encodeIfPresent(duration, forKey: .duration)
            try c.encodeIfPresent(playlistTitle, forKey: .playlistTitle)
            try c.encodeIfPresent(channelID, forKey: .channelID)
            try c.encodeIfPresent(track, forKey: .track)
            try c.encodeIfPresent(album, forKey: .album)
            try c.encodeIfPresent(releaseYear, forKey: .releaseYear)
        }

        private static func nonEmpty(_ value: String?) -> String? {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return value
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, uploader, duration
            case playlistTitle = "playlist_title"
            case playlist
            case channelID = "channel_id"
            case uploaderID = "uploader_id"
            case track, album
            case releaseYear = "release_year"
        }

        var inferredMediaKind: TrackMediaKind {
            if track != nil || album != nil { return .song }
            let normalized = title.lowercased()
            let videoMarkers = [
                "official music video", "official video", "music video", "m/v", " mv",
                "官方mv", "音乐录像", "音樂錄影帶"
            ]
            return videoMarkers.contains(where: normalized.contains) ? .musicVideo : .song
        }
    }

    private let log = AppLog.for("YTDlpBridge")

    /// Explicitly specified binary path (injectable for tests).
    private let binaryPath: String?

    /// Cache of the resolved binary path (resolved only once).
    private var resolvedBinary: String?

    /// `ytsearch` result cache: fresh hits are reused directly, avoiding repeated yt-dlp spawns.
    /// Inject nil to disable the cache (for tests); defaults to `.default`.
    private let searchCache: YTDlpSearchCache?

    /// Background subprocess executor (off the main thread + concurrency throttled).
    /// Injectable for tests.
    private let runner: YTDlpRunner

    /// Quality name -> yt-dlp `-f` format selector.
    private static let qualityMap: [String: String] = [
        "bestaudio": "bestaudio[ext*=m4a]/bestaudio/best",
        "256k": "ba[abr<=256]/bestaudio[abr<=256]",
        "128k": "ba[abr<=128]",
        "64k": "ba[abr<=64]",
        "best": "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best",
        "1080p": "best[height<=1080][ext=mp4]/best[height<=1080]",
        "720p": "best[height<=720][ext=mp4]/best[height<=720]"
    ]

    init(binaryPath: String? = nil,
         searchCache: YTDlpSearchCache? = .default,
         runner: YTDlpRunner = YTDlpRunner()) {
        self.binaryPath = binaryPath
        self.searchCache = searchCache
        self.runner = runner
    }

    // MARK: - Cookie / sign-in

    /// Builds the yt-dlp cookie arguments from `PrefKey.ytCookieSource` in UserDefaults.
    /// - `none` → `[]`
    /// - `safari/chrome/firefox` → `["--cookies-from-browser", browser]`
    /// - `file` → `["--cookies", path]` (returns `[]` if path is empty)
    ///
    /// Internal (visible to tests) so unit tests can verify the branch logic.
    internal func cookieArgs() -> [String] {
        let raw = UserDefaults.standard.string(forKey: PrefKey.ytCookieSource) ?? YTCookieSource.none.rawValue
        let source = YTCookieSource(rawValue: raw) ?? .none
        switch source {
        case .none:
            return []
        case .safari, .chrome, .firefox:
            return ["--cookies-from-browser", source.rawValue]
        case .file:
            let path = UserDefaults.standard.string(forKey: PrefKey.ytCookiePath) ?? ""
            guard !path.isEmpty else { return [] }
            return ["--cookies", path]
        }
    }

    // MARK: - Binary resolution

    /// Resolves and caches the yt-dlp executable path.
    /// Order: explicit `binaryPath` -> bundle resources -> `which yt-dlp`.
    private func resolveBinary() async throws -> String {
        if let cached = resolvedBinary {
            return cached
        }

        let fm = FileManager.default

        // 1) Explicitly injected path.
        if let explicit = binaryPath {
            if fm.isExecutableFile(atPath: explicit) {
                resolvedBinary = explicit
                return explicit
            }
            // File exists but is not executable; try chmod +x.
            if fm.fileExists(atPath: explicit) {
                try? fm.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: explicit)
                if fm.isExecutableFile(atPath: explicit) {
                    resolvedBinary = explicit
                    return explicit
                }
            }
            throw YTDlpError.notFound
        }

        // 2) Bundle resources. Prefer the main bundle inside the .app, then the SPM
        //    module resource bundle (Muses_Muses.bundle, produced by
        //    .copy("Resources")), then Resources/yt-dlp relative to the working
        //    directory (for swift run from the repo root), and finally the
        //    MUSES_YTDLP_PATH environment variable.
        let envPath = ProcessInfo.processInfo.environment["MUSES_YTDLP_PATH"]
        var candidateURLs: [URL] = []
        candidateURLs.appendIfPresent(
            Bundle.main.url(forResource: "yt-dlp", withExtension: nil))
        candidateURLs.appendIfPresent(
            Bundle.module.url(forResource: "yt-dlp", withExtension: nil))
        candidateURLs.append(URL(fileURLWithPath:
            FileManager.default.currentDirectoryPath
            + "/Sources/Muses/Resources/yt-dlp"))
        if let path = envPath {
            candidateURLs.append(URL(fileURLWithPath: path))
        }

        for url in candidateURLs {
            let path = url.path
            if !fm.isExecutableFile(atPath: path), fm.fileExists(atPath: path) {
                // The +x bit may be lost after unpacking/copying; restore it.
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            }
            if fm.isExecutableFile(atPath: path) {
                resolvedBinary = path
                return path
            }
        }

        // 3) `which yt-dlp` (short 5s timeout).
        let envBin = "/usr/bin/env"
        let whichArgs = ["which", "yt-dlp"]
        do {
            let (stdout, _) = try await runInternal(
                executablePath: envBin,
                args: whichArgs,
                timeout: 5)
            let firstLine = stdout
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            if let line = firstLine, !line.isEmpty,
               fm.isExecutableFile(atPath: line) {
                resolvedBinary = line
                return line
            }
        } catch {
            // If `which` fails, fall through and throw notFound.
        }

        throw YTDlpError.notFound
    }

    // MARK: - Public API

    /// Resolves a video's direct audio stream URL.
    ///
    /// - Parameters:
    ///   - videoId: the YouTube video id.
    ///   - quality: a quality name (`bestaudio` / `128k`) or a raw yt-dlp format selector.
    ///   - timeout: subprocess timeout in seconds, defaults to 30.
    /// - Returns: the first non-empty URL line from yt-dlp output.
    func resolveStreamURL(videoId: String,
                          quality: String,
                          timeout: TimeInterval = 30) async throws -> URL {
        let bin = try await resolveBinary()
        let format = Self.qualityMap[quality] ?? quality
        var args = cookieArgs()
        args += ["-f", format, "--no-playlist", "-g",
                 "https://youtu.be/\(videoId)"]
        let (stdout, _) = try await runInternal(
            executablePath: bin,
            args: args,
            timeout: timeout)
        let firstLine = stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let line = firstLine, !line.isEmpty,
              let url = URL(string: line) else {
            throw YTDlpError.parseFailed("Unable to parse URL from stdout: \(stdout)")
        }
        return url
    }

    /// Fetches the entries of a flat-playlist.
    ///
    /// - Parameters:
    ///   - url: the playlist URL.
    ///   - timeout: subprocess timeout in seconds, defaults to 60.
    /// - Returns: entries in yt-dlp output order.
    func fetchPlaylist(url: String,
                       timeout: TimeInterval = 60) async throws -> [YTDlpPlaylistEntry] {
        let bin = try await resolveBinary()
        var args = cookieArgs()
        args += ["--flat-playlist", "--dump-json", url]
        let (stdout, _) = try await runInternal(
            executablePath: bin,
            args: args,
            timeout: timeout)
        let decoder = JSONDecoder()
        var entries: [YTDlpPlaylistEntry] = []
        for (idx, raw) in stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map({ String($0) })
            .enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8) else {
                throw YTDlpError.parseFailed("Line \(idx) is not valid UTF-8")
            }
            do {
                entries.append(try decoder.decode(YTDlpPlaylistEntry.self, from: data))
            } catch {
                throw YTDlpError.parseFailed("Line \(idx) JSON parse failed: \(error)")
            }
        }
        return entries
    }

    /// Searches YouTube videos via yt-dlp `ytsearch{N}:{query}`.
    ///
    /// - Parameters:
    ///   - query: the search keywords (e.g. "artist title").
    ///   - limit: maximum number of entries to return, defaults to 10.
    ///   - timeout: subprocess timeout in seconds, defaults to 30.
    /// - Returns: entries ordered by relevance (reusing the `YTDlpPlaylistEntry` struct).
    func searchYouTube(query: String,
                       limit: Int = 10,
                       timeout: TimeInterval = 30) async throws -> [YTDlpPlaylistEntry] {
        // Fresh hit: reuse it directly and skip the yt-dlp spawn.
        if let cache = searchCache, cache.isFresh(query: query, limit: limit),
           let cached = cache.get(query: query, limit: limit) {
            log.info("searchYouTube cache hit (fresh): \(query)")
            return cached.value
        }
        let bin = try await resolveBinary()
        var args = cookieArgs()
        // ytsearch syntax: yt-dlp "ytsearch10:query" --flat-playlist --dump-json
        args += ["--flat-playlist", "--dump-json", "ytsearch\(limit):\(query)"]
        let (stdout, _) = try await runInternal(
            executablePath: bin,
            args: args,
            timeout: timeout)
        let decoder = JSONDecoder()
        var entries: [YTDlpPlaylistEntry] = []
        for (idx, raw) in stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map({ String($0) })
            .enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8) else {
                throw YTDlpError.parseFailed("Search result line \(idx) is not valid UTF-8")
            }
            do {
                entries.append(try decoder.decode(YTDlpPlaylistEntry.self, from: data))
            } catch {
                throw YTDlpError.parseFailed("Search result line \(idx) JSON parse failed: \(error)")
            }
        }
        // Store in the cache (after a successful spawn).
        searchCache?.set(query: query, limit: limit, entries: entries)
        return entries
    }

    /// Returns the located yt-dlp executable path (for read-only display in
    /// Settings); nil if not found.
    func locateBinary() async -> String? {
        try? await resolveBinary()
    }

    /// Returns the yt-dlp version string; nil on any error (never throws).
    func version() async -> String? {
        guard let bin = try? await resolveBinary() else { return nil }
        do {
            let (stdout, _) = try await runInternal(
                executablePath: bin,
                args: ["--version"],
                timeout: 10)
            return stdout
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        } catch {
            return nil
        }
    }

    // MARK: - Process runner

    /// Runs a subprocess and returns stdout / stderr (both trimmed).
    ///
    /// **Internal** (not private) so tests can inject timeouts; non-test code
    /// should use the higher-level `resolveStreamURL` / `fetchPlaylist` / `version`.
    ///
    /// stdout and stderr are read concurrently in `Task.detached(priority: .utility)`
    /// so large outputs (long playlists) cannot fill the pipe buffers and deadlock.
    /// The subprocess races against the timeout; on expiry it is `terminate()`d and
    /// `.timeout` is thrown.
    ///
    /// - Parameters:
    ///   - args: arguments passed to the yt-dlp binary.
    ///   - timeout: timeout in seconds.
    /// - Returns: (trimmed stdout, trimmed stderr).
    @discardableResult
    internal func runProcess(args: [String],
                             timeout: TimeInterval) async throws -> (stdout: String, stderr: String) {
        let bin = try await resolveBinary()
        return try await runInternal(
            executablePath: bin,
            args: args,
            timeout: timeout)
    }

    /// The internal implementation that actually spawns the subprocess.
    /// `executablePath` is used directly, without going through `resolveBinary`
    /// (which would recurse when its own `which` subprocess re-enters this function).
    ///
    /// All blocking subprocess work is performed by `YTDlpRunner` on a background
    /// `Task.detached`; the main thread simply suspends at the `await` instead of
    /// polling `process.isRunning` every 20ms. Concurrency is throttled by a
    /// semaphore inside the runner (default 2).
    private func runInternal(executablePath: String,
                             args: [String],
                             timeout: TimeInterval) async throws
        -> (stdout: String, stderr: String) {
        do {
            return try await runner.run(
                executablePath: executablePath, args: args, timeout: timeout)
        } catch let e as YTDlpError {
            switch e {
            case .timeout:
                log.error("yt-dlp timed out (\(timeout)s), terminated")
            case .exitCode(let code, let stderr):
                log.error("yt-dlp exit code \(code): \(stderr)")
                let isCookieOrConfigError = stderr.localizedCaseInsensitiveContains("cookie")
                    || stderr.localizedCaseInsensitiveContains("permission")
                    || stderr.localizedCaseInsensitiveContains("operation not permitted")
                    || stderr.localizedCaseInsensitiveContains("could not copy")
                let hasCookieArgs = args.contains("--cookies") || args.contains("--cookies-from-browser")
                let hasIgnoreConfig = args.contains("--ignore-config")
                if isCookieOrConfigError && (hasCookieArgs || !hasIgnoreConfig) {
                    log.warning("yt-dlp encountered cookie or permission error, automatically falling back: retrying without cookies and with --ignore-config")
                    var fallbackArgs = args
                    var i = 0
                    while i < fallbackArgs.count {
                        if fallbackArgs[i] == "--cookies" || fallbackArgs[i] == "--cookies-from-browser" {
                            fallbackArgs.remove(at: i)
                            if i < fallbackArgs.count {
                                fallbackArgs.remove(at: i)
                            }
                        } else {
                            i += 1
                        }
                    }
                    if !fallbackArgs.contains("--ignore-config") {
                        fallbackArgs.insert("--ignore-config", at: 0)
                    }
                    do {
                        return try await runner.run(
                            executablePath: executablePath, args: fallbackArgs, timeout: timeout)
                    } catch {
                        throw e
                    }
                }
            case .notFound:
                log.error("yt-dlp launch failed: \(executablePath)")
            case .parseFailed:
                break
            }
            throw e
        } catch {
            log.error("yt-dlp runtime error: \(error)")
            throw error
        }
    }
}

private extension Array where Element == URL {
    /// Appends the element when the optional is non-nil.
    mutating func appendIfPresent(_ url: URL?) {
        if let url { append(url) }
    }
}
