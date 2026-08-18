import Foundation
import SwiftData

/// 歌词来源。
enum LyricsSource: String, Sendable {
    case local       // 本地 .lrc 文件
    case lrclib      // LRCLIB API
    case musixmatch  // Musixmatch 公共 Web API
    case cached      // Track.lyrics 持久化缓存
}

/// 单行歌词(可带时间标签)。Phase 22 扩展:可选逐词时间 + 翻译。
struct LyricLine: Sendable, Identifiable {
    let id: UUID
    let time: Double?   // 秒; nil 表示无时间标签(纯文本行)
    let text: String
    /// 逐词时间(增强 LRC 的 `<mm:ss.xx>` 内联标签解析得到)。无则 nil,回退到行级高亮。
    let words: [LyricWord]?
    /// 该行翻译(若有)。数据平台受限:多数来源不提供,保持 nil,绝不伪造。
    let translation: String?

    init(id: UUID = UUID(), time: Double?, text: String,
         words: [LyricWord]? = nil, translation: String? = nil) {
        self.id = id; self.time = time; self.text = text
        self.words = words; self.translation = translation
    }
}

/// 逐词时间标签(增强 LRC)。时间单位为秒,与 `LyricLine.time` 一致。
struct LyricWord: Sendable, Identifiable {
    let id: UUID
    let text: String
    let start: Double   // 秒
    let end: Double?    // 秒;末词无下一词时为 nil
}

/// 译文集合(结构就绪;数据平台受限,LRCLIB/Musixmatch 公共 API 无免费译文 → 多为 nil)。
struct LyricsTranslation: Sendable {
    let language: String?   // 语言码,如 "zh"
    let lines: [String]      // 逐行译文,与原文行对齐(无时间标签)
}

/// 罗马音歌词。与 `LyricsResult` 平行但非递归(Swift 值类型不可自包含),
/// 数据平台受限 → 多为 nil,绝不伪造。
struct LyricsRomanization: Sendable {
    let plainLyrics: String?
    let syncedLyrics: String?
    let source: LyricsSource
}

/// 歌词查询结果。Phase 22 扩展:译文 / 罗马音 / LRC `[offset:]` 偏移。
struct LyricsResult: Sendable {
    let plainLyrics: String?
    let syncedLyrics: String?   // LRC 格式(带 [mm:ss.xx] 标签)
    let source: LyricsSource
    /// 译文集合(平台受限,多为 nil)。
    let translations: [LyricsTranslation]?
    /// 罗马音歌词(平台受限,多为 nil)。
    let romanization: LyricsRomanization?
    /// LRC `[offset:±ms]` 标签解析出的自动偏移(毫秒);正值→歌词显示更晚。
    let offsetMs: Int?

    init(plainLyrics: String?, syncedLyrics: String?, source: LyricsSource,
         translations: [LyricsTranslation]? = nil,
         romanization: LyricsRomanization? = nil,
         offsetMs: Int? = nil) {
        self.plainLyrics = plainLyrics; self.syncedLyrics = syncedLyrics
        self.source = source; self.translations = translations
        self.romanization = romanization; self.offsetMs = offsetMs
    }
}

/// 歌词服务:优先读取本地 `.lrc` 文件或查询 LRCLIB,返回带时间标签的同步歌词。
///
/// 遵循 `MetadataEnricherService` 的模式:`@MainActor`、吞掉所有传输错误、
/// 失败返回 `nil` 而不抛出。
@Observable
@MainActor
final class LyricsService {
    private let session: URLSession
    private let modelContainer: ModelContainer?
    private let log = AppLog.for("LyricsService")

    /// 当前曲目的手动歌词偏移(毫秒,Phase 22 §10.8)。@Observable:歌词视图实时读取,
    /// 偏移微调器写入并同步持久化到 `Track.lyricsOffsetMs`。单曲播放期单值。
    var manualOffsetMs: Int = 0

    init(session: URLSession = .shared, modelContainer: ModelContainer? = nil) {
        self.session = session
        self.modelContainer = modelContainer
    }

    // MARK: - Public

    /// 检查持久化缓存(Track.lyrics)。命中返回 LyricsResult(source: .cached)。
    func fetchCached(track: TrackSnapshot) -> LyricsResult? {
        if let lyrics = track.lyrics, !lyrics.isEmpty {
            // 判断是 LRC(含时间标签)还是纯文本
            let isLRC = lyrics.contains("[") && lyrics.range(of: #"\[\d{2}:\d{2}"#, options: .regularExpression) != nil
            if isLRC {
                return LyricsResult(plainLyrics: nil, syncedLyrics: lyrics,
                                     source: .cached, offsetMs: Self.parseOffsetMs(lyrics))
            } else {
                return LyricsResult(plainLyrics: lyrics, syncedLyrics: nil, source: .cached)
            }
        }
        return nil
    }

    /// 将歌词写回 Track.lyrics 持久化缓存。
    private func persistLyrics(_ result: LyricsResult, for trackId: UUID) {
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)
        let descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.id == trackId })
        guard let track = try? ctx.fetch(descriptor).first else { return }
        // 优先缓存同步歌词(LRC),其次纯文本
        track.lyrics = result.syncedLyrics ?? result.plainLyrics
        try? ctx.save()
    }

    /// 持久化逐曲手动歌词偏移(Phase 22 §10.8)。`offsetMs == 0` 视为清除 → 存 nil。
    /// 同时更新可观察 `manualOffsetMs`,使歌词视图实时反应。
    func setOffset(trackId: UUID, offsetMs: Int) {
        manualOffsetMs = offsetMs
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)
        let descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.id == trackId })
        guard let track = try? ctx.fetch(descriptor).first else { return }
        track.lyricsOffsetMs = offsetMs == 0 ? nil : offsetMs
        try? ctx.save()
    }

    /// 根据用户偏好(`PrefKey.lyricsSource`)按优先级获取歌词。
    /// - source == "local":先本地 .lrc,失败回退 LRCLIB
    /// - source == "lrclib":先 LRCLIB,失败回退本地 .lrc
    /// - source == "musixmatch":先 Musixmatch,失败回退 LRCLIB 再本地
    /// - 默认:LRCLIB 再本地
    /// 任一来源成功即返回;全部失败返回 nil。
    func fetch(track: TrackSnapshot) async -> LyricsResult? {
        let pref = UserDefaults.standard.string(forKey: PrefKey.lyricsSource) ?? "lrclib"

        switch pref {
        case "local":
            if let local = fetchLocal(track: track) {
                persistLyrics(local, for: track.id)
                return local
            }
            if let remote = await fetchLrclib(track: track) {
                persistLyrics(remote, for: track.id)
                return remote
            }
            return nil
        case "lrclib":
            if let remote = await fetchLrclib(track: track) {
                persistLyrics(remote, for: track.id)
                return remote
            }
            if let local = fetchLocal(track: track) {
                persistLyrics(local, for: track.id)
                return local
            }
            return nil
        case "musixmatch":
            if let mx = await fetchMusixmatch(track: track) {
                persistLyrics(mx, for: track.id)
                return mx
            }
            if let remote = await fetchLrclib(track: track) {
                persistLyrics(remote, for: track.id)
                return remote
            }
            if let local = fetchLocal(track: track) {
                persistLyrics(local, for: track.id)
                return local
            }
            return nil
        default:
            if let remote = await fetchLrclib(track: track) {
                persistLyrics(remote, for: track.id)
                return remote
            }
            if let local = fetchLocal(track: track) {
                persistLyrics(local, for: track.id)
                return local
            }
            return nil
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
        return LyricsResult(plainLyrics: plain, syncedLyrics: synced, source: .lrclib,
                            offsetMs: synced.flatMap { Self.parseOffsetMs($0) })
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
                return LyricsResult(plainLyrics: plain, syncedLyrics: synced, source: .lrclib,
                                    offsetMs: synced.flatMap { Self.parseOffsetMs($0) })
            }
        }
        return nil
    }

    // MARK: - Musixmatch

    /// 查询 Musixmatch 公共 Web API:`track.search` 取首个 track_id,
    /// 再分别拉 `track.subtitle.get`(同步 LRC)与 `track.lyrics.get`(纯文本)。
    /// 任一步失败返回 nil(由 `fetch` 回退到 LRCLIB)。
    private func fetchMusixmatch(track: TrackSnapshot) async -> LyricsResult? {
        // 1. 搜索曲目,取首个带 track_id 的条目。
        let searchURL = LyricsEndpoint.musixmatchSearch(
            track: track.title, artist: track.artist
        )
        guard let searchData = await get(searchURL),
              let trackId = parseMusixmatchTrackId(data: searchData)
        else {
            log.info("musixmatch: no track_id for \(track.title) / \(track.artist)")
            return nil
        }

        // 2. 拉同步歌词(subtitle)。优先,失败再拉纯文本。
        let subtitleURL = LyricsEndpoint.musixmatchSubtitle(trackId: trackId)
        var synced: String?
        if let subData = await get(subtitleURL) {
            synced = parseMusixmatchSubtitle(data: subData)
        }

        // 3. 拉纯文本歌词。subtitle 已有 synced 时 plain 仅作冗余回退。
        var plain: String?
        if synced == nil {
            let lyricsURL = LyricsEndpoint.musixmatchLyrics(trackId: trackId)
            if let lyrData = await get(lyricsURL) {
                plain = parseMusixmatchLyrics(data: lyrData)
            }
        }

        guard (synced?.isEmpty == false) || (plain?.isEmpty == false) else {
            log.info("musixmatch: track_id \(trackId) 无歌词内容")
            return nil
        }
        return LyricsResult(
            plainLyrics: plain, syncedLyrics: synced, source: .musixmatch,
            offsetMs: synced.flatMap { Self.parseOffsetMs($0) }
        )
    }

    /// 解析 `track.search` 响应,返回首个 `track_id`。
    private func parseMusixmatchTrackId(data: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let body = message["body"] as? [String: Any],
              let trackList = body["track_list"] as? [[String: Any]]
        else {
            log.warning("musixmatch search: JSON parse failed")
            return nil
        }
        for entry in trackList {
            if let track = entry["track"] as? [String: Any],
               let id = track["track_id"] as? Int {
                return id
            }
        }
        return nil
    }

    /// 解析 `track.subtitle.get` 响应,返回 `subtitle_body`(LRC 文本)。
    private func parseMusixmatchSubtitle(data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let body = message["body"] as? [String: Any],
              let subtitle = body["subtitle"] as? [String: Any],
              let text = subtitle["subtitle_body"] as? String,
              !text.isEmpty
        else {
            return nil
        }
        return text
    }

    /// 解析 `track.lyrics.get` 响应,返回 `lyrics_body`(纯文本)。
    /// 截断 Musixmatch 末尾的 "******* This Lyrics is NOT for Commercial use ******" 标记。
    private func parseMusixmatchLyrics(data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let body = message["body"] as? [String: Any],
              let lyrics = body["lyrics"] as? [String: Any],
              let text = lyrics["lyrics_body"] as? String,
              !text.isEmpty
        else {
            return nil
        }
        // 去除商业使用警告尾部。
        if let cutRange = text.range(of: "\n******* This Lyrics") {
            return String(text[..<cutRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
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
            LyricLine(id: UUID(), time: $0.time, text: $0.text,
                      words: parseWords(text: $0.text, lineStart: $0.time))
        }
        result.append(contentsOf: untimed.map {
            LyricLine(id: UUID(), time: nil, text: $0.text)
        })
        return result
    }

    /// 解析增强 LRC 的内联逐词时间标签 `<mm:ss.xx>` / `<mm:ss.xxx>`。
    /// 第一个标签前的文本段以 `lineStart` 为起点;每个 `<...>` 标记后续词段的起点。
    /// 末词的 `end` 为 nil。无内联标签时返回 nil(回退到行级高亮)。
    static func parseWords(text: String, lineStart: Double) -> [LyricWord]? {
        let wordTagPattern = #"<(\d+):(\d{2})(?:[.:](\d{1,3}))?>"#
        guard let regex = try? NSRegularExpression(pattern: wordTagPattern) else { return nil }
        // 无任何内联标签 → nil(普通行级 LRC)。
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard regex.firstMatch(in: text, range: fullRange) != nil else { return nil }

        var words: [LyricWord] = []
        var segStart = text.startIndex
        var segTime = lineStart

        // 遍历所有 `<...>` 标签,切出其前的文本段。
        regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let match, let r = Range(match.range, in: text) else { return }
            // 标签前的文本段
            let segment = String(text[segStart..<r.lowerBound])
            if !segment.isEmpty {
                words.append(LyricWord(id: UUID(), text: segment, start: segTime, end: nil))
            }
            // 解析该标签时间,作为下一词段起点
            let m = Double(String(text[Range(match.range(at: 1), in: text)!])) ?? 0
            let s = Double(String(text[Range(match.range(at: 2), in: text)!])) ?? 0
            var t = m * 60.0 + s
            let fracRange = match.range(at: 3)
            if fracRange.location != NSNotFound, let fr = Range(fracRange, in: text) {
                let fracStr = String(text[fr])
                if let frac = Double(fracStr) {
                    t += frac / pow(10.0, Double(fracStr.count))
                }
            }
            segStart = r.upperBound
            segTime = t
        }
        // 末段(最后标签之后)
        let tail = String(text[segStart..<text.endIndex])
        if !tail.isEmpty {
            words.append(LyricWord(id: UUID(), text: tail, start: segTime, end: nil))
        }
        // 填充 end:每词 end = 下一词 start
        for i in 0..<words.count {
            if i + 1 < words.count {
                words[i] = LyricWord(id: words[i].id, text: words[i].text,
                                     start: words[i].start, end: words[i+1].start)
            }
        }
        return words.isEmpty ? nil : words
    }

    /// 解析 LRC `[offset:±ms]` 元数据标签。正值表示歌词应更晚显示(标准 LRC 语义)。
    /// 无标签或解析失败返回 nil。
    static func parseOffsetMs(_ lrc: String) -> Int? {
        let pattern = #"\[offset:\s*([+-]?\d+)\s*\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(lrc.startIndex..<lrc.endIndex, in: lrc)
        guard let match = regex.firstMatch(in: lrc, range: range),
              let r = Range(match.range(at: 1), in: lrc),
              let v = Int(lrc[r]) else { return nil }
        return v
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