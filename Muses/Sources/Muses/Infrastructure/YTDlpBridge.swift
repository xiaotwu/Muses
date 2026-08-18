import Foundation

/// `yt-dlp` 二进制封装。
///
/// 通过 `Process` 调用本机 `yt-dlp` 可执行文件,完成两件事:
///  1. 解析单个视频的直接音频流 URL(`-g`/`--get-url`);
///  2. 以 NDJSON 形式抓取 flat-playlist 的条目(`--flat-playlist --dump-json`)。
///
/// 该桥接器是 `@MainActor`,与 `StreamURLCache` / `MetadataEnricherService` 保持
/// 一致;耗时的子进程运行在 `Task.detached` 中,主 actor 仅等待结果。
@MainActor
final class YTDlpBridge {

    enum YTDlpError: LocalizedError, Equatable, Sendable {
        /// yt-dlp 二进制在磁盘上未找到。
        case notFound
        /// 子进程非零退出;关联退出码与(裁剪过的)stderr。
        case exitCode(Int, String)
        /// 子进程超过超时时间仍在运行,已被终止。
        case timeout
        /// stdout 无法解析为预期结构。
        case parseFailed(String)

        var errorDescription: String? {
            switch self {
            case .notFound:
                "yt-dlp 二进制未找到"
            case .exitCode(let code, let stderr):
                "yt-dlp 退出码 \(code):\(stderr)"
            case .timeout:
                "yt-dlp 调用超时"
            case .parseFailed(let m):
                "yt-dlp 输出解析失败:\(m)"
            }
        }

        static func == (lhs: YTDlpError, rhs: YTDlpError) -> Bool {
            String(describing: lhs) == String(describing: rhs)
        }
    }

    /// flat-playlist `--dump-json` 单条目结构。
    /// `id` 与 `title` 必填,`uploader` / `duration` 可缺省。
    struct YTDlpPlaylistEntry: Codable, Sendable, Equatable {
        let id: String
        let title: String
        let uploader: String?
        let duration: Double?

        init(id: String,
             title: String,
             uploader: String? = nil,
             duration: Double? = nil) {
            self.id = id
            self.title = title
            self.uploader = uploader
            self.duration = duration
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(String.self, forKey: .id)
            self.title = try c.decode(String.self, forKey: .title)
            self.uploader = try c.decodeIfPresent(String.self, forKey: .uploader)
            self.duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(title, forKey: .title)
            try c.encodeIfPresent(uploader, forKey: .uploader)
            try c.encodeIfPresent(duration, forKey: .duration)
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, uploader, duration
        }
    }

    private let log = AppLog.for("YTDlpBridge")

    /// 显式指定的二进制路径(可由测试注入)。
    private let binaryPath: String?

    /// 解析后的二进制路径缓存(只解析一次)。
    private var resolvedBinary: String?

    /// `ytsearch` 结果缓存(spec §21):新鲜命中直接复用,避免重复 spawn yt-dlp。
    /// 注入 nil 可禁用缓存(测试用);默认 `.default`。
    private let searchCache: YTDlpSearchCache?

    /// 后台子进程执行器(脱离主线程 + 并发限流)。注入便于测试。
    private let runner: YTDlpRunner

    /// 质量名 -> yt-dlp `-f` 格式选择器。
    private static let qualityMap: [String: String] = [
        "bestaudio": "bestaudio[ext*=m4a]/bestaudio/best",
        "256k": "ba[abr<=256]/bestaudio[abr<=256]",
        "128k": "ba[abr<=128]",
        "64k": "ba[abr<=64]"
    ]

    init(binaryPath: String? = nil,
         searchCache: YTDlpSearchCache? = .default,
         runner: YTDlpRunner = YTDlpRunner()) {
        self.binaryPath = binaryPath
        self.searchCache = searchCache
        self.runner = runner
    }

    // MARK: - Cookie / 登录

    /// 根据 UserDefaults 中 `PrefKey.ytCookieSource` 构造 yt-dlp cookie 参数。
    /// - `none` → `[]`
    /// - `safari/chrome/firefox` → `["--cookies-from-browser", browser]`
    /// - `file` → `["--cookies", path]`(path 为空则返回 `[]`)
    ///
    /// 测试可见(internal),便于单元测试验证分支逻辑。
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

    /// 解析并缓存 yt-dlp 可执行文件路径。
    /// 顺序:显式 `binaryPath` -> Bundle 资源 -> `which yt-dlp`。
    private func resolveBinary() async throws -> String {
        if let cached = resolvedBinary {
            return cached
        }

        let fm = FileManager.default

        // 1) 显式注入路径。
        if let explicit = binaryPath {
            if fm.isExecutableFile(atPath: explicit) {
                resolvedBinary = explicit
                return explicit
            }
            // 文件存在但不可执行,尝试 chmod +x。
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

        // 2) Bundle 资源。优先 .app 内的 main bundle,其次 SPM 模块资源 bundle
        //    (Muses_Muses.bundle,由 .copy("Resources") 生成),再回退到工作目录下的
        //    Resources/yt-dlp(swift run 从仓库根执行时),最后 MUSES_YTDLP_PATH 环境变量。
        let envPath = ProcessInfo.processInfo.environment["MUSES_YTDLP_PATH"]
        var candidateURLs: [URL] = []
        candidateURLs.appendIfPresent(
            Bundle.main.url(forResource: "yt-dlp", withExtension: nil))
        candidateURLs.appendIfPresent(
            Bundle.module.url(forResource: "yt-dlp", withExtension: nil))
        candidateURLs.append(URL(fileURLWithPath:
            FileManager.default.currentDirectoryPath
            + "/Muses/Sources/Muses/Resources/yt-dlp"))
        if let path = envPath {
            candidateURLs.append(URL(fileURLWithPath: path))
        }

        for url in candidateURLs {
            let path = url.path
            if !fm.isExecutableFile(atPath: path), fm.fileExists(atPath: path) {
                // 解压/拷贝后可能丢失 +x 权限,补一次。
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            }
            if fm.isExecutableFile(atPath: path) {
                resolvedBinary = path
                return path
            }
        }

        // 3) `which yt-dlp`(短超时 5s)。
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
            // which 失败则继续抛出 notFound。
        }

        throw YTDlpError.notFound
    }

    // MARK: - Public API

    /// 解析视频的直接音频流 URL。
    ///
    /// - Parameters:
    ///   - videoId: YouTube 视频 id。
    ///   - quality: 质量名(`bestaudio` / `128k`)或原始 yt-dlp 格式选择器。
    ///   - timeout: 子进程超时(秒),默认 30。
    /// - Returns: yt-dlp 输出的第一行非空 URL。
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
            throw YTDlpError.parseFailed("无法从 stdout 解析 URL:\(stdout)")
        }
        return url
    }

    /// 抓取 flat-playlist 的条目列表。
    ///
    /// - Parameters:
    ///   - url: 播放列表 URL。
    ///   - timeout: 子进程超时(秒),默认 60。
    /// - Returns: 按 yt-dlp 输出顺序排列的条目数组。
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
                throw YTDlpError.parseFailed("第 \(idx) 行非 UTF-8")
            }
            do {
                entries.append(try decoder.decode(YTDlpPlaylistEntry.self, from: data))
            } catch {
                throw YTDlpError.parseFailed("第 \(idx) 行 JSON 解析失败:\(error)")
            }
        }
        return entries
    }

    /// 通过 yt-dlp `ytsearch{N}:{query}` 搜索 YouTube 视频。
    ///
    /// - Parameters:
    ///   - query: 搜索关键词(如 "artist title")。
    ///   - limit: 最多返回条目数,默认 10。
    ///   - timeout: 子进程超时(秒),默认 30。
    /// - Returns: 按相关性排序的条目数组(复用 `YTDlpPlaylistEntry` 结构)。
    func searchYouTube(query: String,
                       limit: Int = 10,
                       timeout: TimeInterval = 30) async throws -> [YTDlpPlaylistEntry] {
        // 新鲜命中:直接复用,跳过 yt-dlp spawn(spec §21)。
        if let cache = searchCache, cache.isFresh(query: query, limit: limit),
           let cached = cache.get(query: query, limit: limit) {
            log.info("searchYouTube 缓存命中(新鲜):\(query)")
            return cached.value
        }
        let bin = try await resolveBinary()
        var args = cookieArgs()
        // ytsearch 语法:yt-dlp "ytsearch10:query" --flat-playlist --dump-json
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
                throw YTDlpError.parseFailed("搜索结果第 \(idx) 行非 UTF-8")
            }
            do {
                entries.append(try decoder.decode(YTDlpPlaylistEntry.self, from: data))
            } catch {
                throw YTDlpError.parseFailed("搜索结果第 \(idx) 行 JSON 解析失败:\(error)")
            }
        }
        // 写入缓存(成功 spawn 后)。
        searchCache?.set(query: query, limit: limit, entries: entries)
        return entries
    }

    /// 返回已定位的 yt-dlp 可执行文件路径(供设置页只读展示);未找到返回 nil。
    func locateBinary() async -> String? {
        try? await resolveBinary()
    }

    /// 返回 yt-dlp 版本字符串;任何错误下返回 nil(永不抛出)。
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

    /// 运行子进程并返回 stdout / stderr(均裁剪首尾空白)。
    ///
    /// **Internal**(非 private)以便测试注入超时;非测试代码应使用上层的
    /// `resolveStreamURL` / `fetchPlaylist` / `version`。
    ///
    /// 在 `Task.detached(priority: .utility)` 中并发读取 stdout/stderr 两个管道,
    /// 避免大输出(长播放列表)撑满管道缓冲区导致死锁。子进程的运行/等待与
    /// 超时赛跑,超时则 `terminate()` 并抛出 `.timeout`。
    ///
    /// - Parameters:
    ///   - args: 传给 yt-dlp 二进制的参数。
    ///   - timeout: 超时秒数。
    /// - Returns: (裁剪过的 stdout, 裁剪过的 stderr)。
    @discardableResult
    internal func runProcess(args: [String],
                             timeout: TimeInterval) async throws -> (stdout: String, stderr: String) {
        let bin = try await resolveBinary()
        return try await runInternal(
            executablePath: bin,
            args: args,
            timeout: timeout)
    }

    /// 真正执行子进程的内部实现。`executablePath` 直接使用,不再经过 `resolveBinary`
    /// (避免 `resolveBinary` 中的 `which` 子进程再次进入本函数造成递归)。
    ///
    /// 子进程的全部阻塞操作由 `YTDlpRunner` 在后台 `Task.detached` 中完成,主线程
    /// 仅在 `await` 处挂起并释放,不再 20ms 轮询 `process.isRunning`。并发数量由
    /// runner 内的信号量限流(默认 2)。
    private func runInternal(executablePath: String,
                             args: [String],
                             timeout: TimeInterval) async throws
        -> (stdout: String, stderr: String) {
        do {
            return try await runner.run(
                executablePath: executablePath, args: args, timeout: timeout)
        } catch let e as YTDlpError {
            switch e {
            case .timeout: log.error("yt-dlp 超时(\(timeout)s),已终止")
            case .exitCode(let code, let stderr): log.error("yt-dlp 退出码 \(code):\(stderr)")
            case .notFound: log.error("yt-dlp 启动失败:\(executablePath)")
            case .parseFailed: break
            }
            throw e
        } catch {
            log.error("yt-dlp 运行未知错误:\(error)")
            throw error
        }
    }
}

private extension Array where Element == URL {
    /// 当可选元素非 nil 时追加。
    mutating func appendIfPresent(_ url: URL?) {
        if let url { append(url) }
    }
}