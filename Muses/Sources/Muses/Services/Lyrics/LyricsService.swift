import Foundation

/// 歌词来源。
enum LyricsSource: String, Sendable {
    case local   // 本地 .lrc 文件
    case lrclib  // LRCLIB API
}

/// 单行歌词(可带时间标签)。
struct LyricLine: Sendable, Identifiable {
    let id: UUID
    let time: Double?   // 秒; nil 表示无时间标签(纯文本行)
    let text: String
}

/// 歌词查询结果。
struct LyricsResult: Sendable {
    let plainLyrics: String?
    let syncedLyrics: String?   // LRC 格式(带 [mm:ss.xx] 标签)
    let source: LyricsSource
}

/// 歌词服务:优先读取本地 `.lrc` 文件或查询 LRCLIB,返回带时间标签的同步歌词。
///
/// 遵循 `MetadataEnricherService` 的模式:`@MainActor`、吞掉所有传输错误、
/// 失败返回 `nil` 而不抛出。
@MainActor
final class LyricsService {
    private let session: URLSession
    private let log = AppLog.for("LyricsService")

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public

    /// 根据用户偏好(`PrefKey.lyricsSource`)按优先级获取歌词。
    /// - source == "local":先本地 .lrc,失败回退 LRCLIB
    /// - source == "lrclib":先 LRCLIB,失败回退本地 .lrc
    /// - 默认:LRCLIB 再本地
    /// 任一来源成功即返回;两者均失败返回 nil。
    func fetch(track: TrackSnapshot) async -> LyricsResult? {
        let pref = UserDefaults.standard.string(forKey: PrefKey.lyricsSource) ?? "lrclib"

        switch pref {
        case "local":
            if let local = fetchLocal(track: track) { return local }
            return await fetchLrclib(track: track)
        case "lrclib":
            if let remote = await fetchLrclib(track: track) { return remote }
            return fetchLocal(track: track)
        default:
            if let remote = await fetchLrclib(track: track) { return remote }
            return fetchLocal(track: track)
        }
    }

    // MARK: - Local .lrc

    /// 读取音轨同目录下的同名 `.lrc` 文件。YouTube 音轨无本地文件,直接返回 nil。
    private func fetchLocal(track: TrackSnapshot) -> LyricsResult? {
        guard let filePath = track.filePath, !filePath.isEmpty else {
            return nil
        }

        let audioURL = URL(fileURLWithPath: filePath)
        let lrcURL = audioURL
            .deletingPathExtension()
            .appendingPathExtension("lrc")

        guard FileManager.default.fileExists(atPath: lrcURL.path) else {
            log.info("fetchLocal: no .lrc at \(lrcURL.path)")
            return nil
        }

        do {
            let content = try String(contentsOf: lrcURL, encoding: .utf8)
            return LyricsResult(plainLyrics: nil, syncedLyrics: content, source: .local)
        } catch {
            log.error("fetchLocal: read error for \(lrcURL.path): \(error)")
            return nil
        }
    }

    // MARK: - LRCLIB

    /// 查询 LRCLIB `/api/get`;404 或无匹配时回退到 `/api/search` 取首条结果。
    private func fetchLrclib(track: TrackSnapshot) async -> LyricsResult? {
        let getURL = LyricsEndpoint.lrclib(
            track: track.title,
            artist: track.artist,
            album: track.albumTitle
        )

        if let data = await get(getURL) {
            if let result = parseLrclibGet(data: data) {
                return result
            }
        }

        // 回退到搜索接口,取第一个非空条目。
        let searchURL = LyricsEndpoint.lrclibSearch(track: track.title, artist: track.artist)
        guard let data = await get(searchURL) else { return nil }
        return parseLrclibSearch(data: data)
    }

    /// 解析 `/api/get` 的单对象响应。
    private func parseLrclibGet(data: Data) -> LyricsResult? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.warning("lrclib get: JSON parse failed")
            return nil
        }
        let plain = json["plainLyrics"] as? String
        let synced = json["syncedLyrics"] as? String
        // 两者皆空视为未命中。
        guard (plain?.isEmpty == false) || (synced?.isEmpty == false) else { return nil }
        return LyricsResult(plainLyrics: plain, syncedLyrics: synced, source: .lrclib)
    }

    /// 解析 `/api/search` 的数组响应,取第一个含歌词的条目。
    private func parseLrclibSearch(data: Data) -> LyricsResult? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            log.warning("lrclib search: JSON parse failed")
            return nil
        }
        for entry in array {
            let plain = entry["plainLyrics"] as? String
            let synced = entry["syncedLyrics"] as? String
            if (plain?.isEmpty == false) || (synced?.isEmpty == false) {
                return LyricsResult(plainLyrics: plain, syncedLyrics: synced, source: .lrclib)
            }
        }
        return nil
    }

    // MARK: - LRC parsing

    /// 解析 LRC 文本为 `LyricLine` 数组。
    ///
    /// 支持:
    /// - `[mm:ss.xx]` 与 `[mm:ss.xxx]` 时间标签(分数:秒.小数)
    /// - 同一行多个时间标签:`[01:23.45][02:45.67] lyric` → 两条 LyricLine
    /// - 无时间标签的纯文本行 → time=nil
    /// - 跳过 LRC 元数据标签:`[ti:...]`、`[ar:...]`、`[al:...]`、`[by:...]`、
    ///   `[offset:...]`、`[length:...]`、`[re:...]`
    ///
    /// 结果按时间升序排列,无时间标签的行保持原顺序置于末尾。
    static func parseLRC(_ lrc: String) -> [LyricLine] {
        // 时间标签正则:捕获 分、秒、可选小数(1-3 位,`.` 或 `:` 分隔)。
        let timestampPattern = #"\[(\d+):(\d{2})(?:[.:](\d{1,3}))?\]"#
        let timestampRegex = try? NSRegularExpression(pattern: timestampPattern)
        // 元数据标签(键后跟 `:`):整行跳过。
        let metadataKeys: Set<String> = ["ti", "ar", "al", "by", "offset", "length", "re"]

        var timed: [(time: Double, text: String, order: Int)] = []
        var untimed: [(text: String, order: Int)] = []
        var order = 0

        let lines = lrc.components(separatedBy: .newlines)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // 空行或纯空白跳过。
            if line.isEmpty { continue }

            // 检测是否为元数据标签行(以 `[xx:` 形式开头,xx 为已知键)。
            if isMetadataLine(line, keys: metadataKeys) {
                continue
            }

            // 提取行首所有连续时间标签。
            var times: [Double] = []
            var scanIndex = line.startIndex
            while let regex = timestampRegex {
                // 下一个时间标签必须紧跟在 scanIndex 处(连续无空白)。
                let scanRange = scanIndex..<line.endIndex
                let nsRange = NSRange(scanRange, in: line)
                guard let match = regex.firstMatch(
                    in: line,
                    range: nsRange
                ), match.range.location == nsRange.location else { break }

                guard let matchRange = Range(match.range, in: line) else { break }
                let minuteStr = String(line[Range(match.range(at: 1), in: line)!])
                let secondStr = String(line[Range(match.range(at: 2), in: line)!])
                let fracRange = match.range(at: 3)
                let fracStr: String
                if fracRange.location != NSNotFound,
                   let r = Range(fracRange, in: line) {
                    fracStr = String(line[r])
                } else {
                    fracStr = ""
                }

                guard let minutes = Double(minuteStr),
                      let seconds = Double(secondStr) else { break }
                var time = minutes * 60.0 + seconds
                if !fracStr.isEmpty, let frac = Double(fracStr) {
                    // 小数位数决定缩放:2 位 → 0.01,3 位 → 0.001。
                    let scale = pow(10.0, Double(fracStr.count))
                    time += frac / scale
                }
                times.append(time)

                scanIndex = matchRange.upperBound
            }

            // 时间标签之后的剩余文本即歌词(已 trim)。
            let text = String(line[scanIndex..<line.endIndex])
                .trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }

            if times.isEmpty {
                untimed.append((text: text, order: order))
                order += 1
            } else {
                for t in times {
                    timed.append((time: t, text: text, order: order))
                    order += 1
                }
            }
        }

        // 定时行按时间升序;同时间保持原顺序(稳定排序)。
        timed.sort { lhs, rhs in
            lhs.time != rhs.time ? lhs.time < rhs.time : lhs.order < rhs.order
        }

        var result: [LyricLine] = timed.map {
            LyricLine(id: UUID(), time: $0.time, text: $0.text)
        }
        result.append(contentsOf: untimed.map {
            LyricLine(id: UUID(), time: nil, text: $0.text)
        })
        return result
    }

    /// 判断一行是否为 LRC 元数据标签(如 `[ti:Title]`)。键后必须紧跟 `:`。
    private static func isMetadataLine(_ line: String, keys: Set<String>) -> Bool {
        guard line.hasPrefix("[") else { return false }
        // 提取 `[` 之后、第一个 `:` 之前的 token(去除可能的空白)。
        let afterBracket = line.dropFirst()
        guard let colon = afterBracket.firstIndex(of: ":") else { return false }
        let key = String(afterBracket[..<colon]).trimmingCharacters(in: .whitespaces)
        return keys.contains(key)
    }

    // MARK: - Helpers

    /// GET 一个 URL 并返回 body data;非 2xx 或传输错误返回 nil(吞掉错误)。
    private func get(_ url: URL) async -> Data? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                log.warning("GET \(url) non-2xx")
                return nil
            }
            return data
        } catch {
            log.error("GET \(url) transport error: \(error)")
            return nil
        }
    }
}