import Foundation
import SwiftData

/// Lyrics source.
enum LyricsSource: String, Sendable {
    case lrclib      // LRCLIB API
    case musixmatch  // Musixmatch public Web API
    case cached      // Track.lyrics persistent cache
}

/// One lyric line (optionally time-tagged). Also carries optional per-word
/// timings and a translation.
struct LyricLine: Sendable, Identifiable {
    let id: UUID
    let time: Double?   // seconds; nil means no time tag (plain-text line)
    let text: String
    /// Per-word timings (parsed from enhanced-LRC `<mm:ss.xx>` inline tags).
    /// nil falls back to line-level highlighting.
    let words: [LyricWord]?
    /// This line's translation, if any. Data-platform limitation: most sources
    /// do not provide one, so it stays nil — never fabricated.
    let translation: String?

    init(id: UUID = UUID(), time: Double?, text: String,
         words: [LyricWord]? = nil, translation: String? = nil) {
        self.id = id; self.time = time; self.text = text
        self.words = words; self.translation = translation
    }
}

/// Per-word timing tag (enhanced LRC). Time unit is seconds, matching `LyricLine.time`.
struct LyricWord: Sendable, Identifiable {
    let id: UUID
    let text: String
    let start: Double   // seconds
    let end: Double?    // seconds; nil for the last word, which has no successor
}

/// A set of translations (structure ready; data-platform limitation — the free
/// LRCLIB/Musixmatch public APIs have no translations → usually nil).
struct LyricsTranslation: Sendable {
    let language: String?   // language code, e.g. "zh"
    let lines: [String]      // line-by-line translation aligned with the original lines (no time tags)
}

/// Romanized lyrics. Parallel to `LyricsResult` but non-recursive (a Swift value
/// type cannot contain itself); data-platform limitation → usually nil, never fabricated.
struct LyricsRomanization: Sendable {
    let plainLyrics: String?
    let syncedLyrics: String?
    let source: LyricsSource
}

/// Lyrics lookup result. Carries translations / romanization / the LRC `[offset:]` shift.
struct LyricsResult: Sendable {
    let plainLyrics: String?
    let syncedLyrics: String?   // LRC format (with [mm:ss.xx] tags)
    let source: LyricsSource
    /// Translation set (platform-limited, usually nil).
    let translations: [LyricsTranslation]?
    /// Romanized lyrics (platform-limited, usually nil).
    let romanization: LyricsRomanization?
    /// Automatic offset (milliseconds) parsed from the LRC `[offset:±ms]` tag;
    /// positive → lyrics display later.
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

/// Lyrics service: queries LRCLIB / Musixmatch and returns synced or plain-text lyrics.
///
/// Follows the `MetadataEnricherService` pattern: `@MainActor`, swallows all transport
/// errors, and returns `nil` on failure instead of throwing.
@Observable
@MainActor
final class LyricsService {
    private let session: URLSession
    private let modelContainer: ModelContainer?
    private let log = AppLog.for("LyricsService")

    /// Manual lyric offset for the current track, in milliseconds (§10.8).
    /// @Observable: the lyrics view reads it live; the offset fine-tuner writes it and
    /// mirrors it into `Track.lyricsOffsetMs`. A single value while a track plays.
    var manualOffsetMs: Int = 0

    init(session: URLSession = .shared, modelContainer: ModelContainer? = nil) {
        self.session = session
        self.modelContainer = modelContainer
    }

    // MARK: - Public

    /// Checks the persistent cache (Track.lyrics). A hit returns LyricsResult(source: .cached).
    func fetchCached(track: TrackSnapshot) -> LyricsResult? {
        if let lyrics = track.lyrics, !lyrics.isEmpty {
            // Detect whether it is LRC (with time tags) or plain text
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

    /// Writes lyrics back to the Track.lyrics persistent cache.
    private func persistLyrics(_ result: LyricsResult, for trackId: UUID) {
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)
        let descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.id == trackId })
        guard let track = try? ctx.fetch(descriptor).first else { return }
        // Prefer caching synced lyrics (LRC), then plain text
        track.lyrics = result.syncedLyrics ?? result.plainLyrics
        try? ctx.save()
    }

    /// Persists the per-track manual lyric offset (§10.8). `offsetMs == 0` is treated as a
    /// reset → stores nil. Also updates the observable `manualOffsetMs` so the lyrics view
    /// reacts immediately.
    func setOffset(trackId: UUID, offsetMs: Int) {
        manualOffsetMs = offsetMs
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)
        let descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.id == trackId })
        guard let track = try? ctx.fetch(descriptor).first else { return }
        track.lyricsOffsetMs = offsetMs == 0 ? nil : offsetMs
        try? ctx.save()
    }

    /// Fetches lyrics by priority according to the user preference (`PrefKey.lyricsSource`).
    /// - source == "musixmatch": Musixmatch first, falling back to LRCLIB on failure
    /// - default: LRCLIB
    /// Returns on the first successful source; nil when all fail.
    func fetch(track: TrackSnapshot) async -> LyricsResult? {
        let pref = UserDefaults.standard.string(forKey: PrefKey.lyricsSource) ?? "lrclib"

        switch pref {
        case "lrclib":
            if let remote = await fetchLrclib(track: track) {
                persistLyrics(remote, for: track.id)
                return remote
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
            return nil
        default:
            if let remote = await fetchLrclib(track: track) {
                persistLyrics(remote, for: track.id)
                return remote
            }
            return nil
        }
    }

    // MARK: - LRCLIB

    /// Strip YouTube/MV decorations so LRCLIB / Musixmatch can match (Better Lyrics style).
    static func sanitizedTitle(_ raw: String) -> String {
        var s = raw
        let patterns = [
            #"\s*[\(\[【]\s*official\s*(music\s*)?(video|audio|lyric(s)?(\s*video)?)\s*[\)\]】]"#,
            #"\s*[\(\[【]\s*lyric(s)?(\s*video)?\s*[\)\]】]"#,
            #"\s*[\(\[【]\s*(official\s*)?audio\s*[\)\]】]"#,
            #"\s*[\(\[【]\s*mv\s*[\)\]】]"#,
            #"\s*[\(\[【]\s*4k\s*[\)\]】]"#,
            #"\s*\|\s*.*$"#
        ]
        for pattern in patterns {
            s = s.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Queries LRCLIB `/api/get`; on 404 or no match, falls back to `/api/search` and takes the first result.
    private func fetchLrclib(track: TrackSnapshot) async -> LyricsResult? {
        let titles = Self.queryTitles(track.title)
        for title in titles {
            let getURL = LyricsEndpoint.lrclib(
                track: title,
                artist: track.artist,
                album: track.albumTitle
            )
            if let data = await get(getURL), let result = parseLrclibGet(data: data) {
                return result
            }
        }
        for title in titles {
            let searchURL = LyricsEndpoint.lrclibSearch(track: title, artist: track.artist)
            if let data = await get(searchURL), let result = parseLrclibSearch(data: data) {
                return result
            }
        }
        return nil
    }

    static func queryTitles(_ raw: String) -> [String] {
        let cleaned = sanitizedTitle(raw)
        if cleaned.isEmpty || cleaned == raw { return [raw] }
        return [raw, cleaned]
    }

    /// Parses the single-object `/api/get` response.
    private func parseLrclibGet(data: Data) -> LyricsResult? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.warning("lrclib get: JSON parse failed")
            return nil
        }
        let plain = json["plainLyrics"] as? String
        let synced = json["syncedLyrics"] as? String
        // Both empty counts as no hit.
        guard (plain?.isEmpty == false) || (synced?.isEmpty == false) else { return nil }
        return LyricsResult(plainLyrics: plain, syncedLyrics: synced, source: .lrclib,
                            offsetMs: synced.flatMap { Self.parseOffsetMs($0) })
    }

    /// Parses the array `/api/search` response, taking the first entry that has lyrics.
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

    /// Queries the Musixmatch public Web API: `track.search` for the first track_id,
    /// then fetches `track.subtitle.get` (synced LRC) and `track.lyrics.get` (plain text).
    /// Any failed step returns nil (`fetch` then falls back to LRCLIB).
    private func fetchMusixmatch(track: TrackSnapshot) async -> LyricsResult? {
        // 1. Search for the track and take the first entry with a track_id.
        let searchTitle = Self.queryTitles(track.title).last ?? track.title
        let searchURL = LyricsEndpoint.musixmatchSearch(
            track: searchTitle, artist: track.artist
        )
        guard let searchData = await get(searchURL),
              let trackId = parseMusixmatchTrackId(data: searchData)
        else {
            log.info("musixmatch: no track_id for \(track.title) / \(track.artist)")
            return nil
        }

        // 2. Fetch synced lyrics (subtitle) first; plain text is only tried if this fails.
        let subtitleURL = LyricsEndpoint.musixmatchSubtitle(trackId: trackId)
        var synced: String?
        if let subData = await get(subtitleURL) {
            synced = parseMusixmatchSubtitle(data: subData)
        }

        // 3. Fetch plain-text lyrics. Only a redundant fallback when subtitle already gave synced.
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

    /// Parses the `track.search` response and returns the first `track_id`.
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

    /// Parses the `track.subtitle.get` response and returns `subtitle_body` (LRC text).
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

    /// Parses the `track.lyrics.get` response and returns `lyrics_body` (plain text).
    /// Truncates Musixmatch's trailing "******* This Lyrics is NOT for Commercial use ******" marker.
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
        // Strip the non-commercial-use warning tail.
        if let cutRange = text.range(of: "\n******* This Lyrics") {
            return String(text[..<cutRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    // MARK: - LRC parsing

    /// Parses LRC text into an array of `LyricLine`.
    ///
    /// Supports:
    /// - `[mm:ss.xx]` and `[mm:ss.xxx]` time tags (minutes:seconds.fraction)
    /// - Multiple time tags on one line: `[01:23.45][02:45.67] lyric` → two LyricLines
    /// - Untagged plain-text lines → time=nil
    /// - Skips LRC metadata tags: `[ti:...]`, `[ar:...]`, `[al:...]`, `[by:...]`,
    ///   `[offset:...]`, `[length:...]`, `[re:...]`
    ///
    /// The result is sorted ascending by time; untagged lines keep their original
    /// order and are placed at the end.
    static func parseLRC(_ lrc: String) -> [LyricLine] {
        // Time-tag regex: captures minutes, seconds, and an optional fraction
        // (1-3 digits, separated by `.` or `:`).
        let timestampPattern = #"\[(\d+):(\d{2})(?:[.:](\d{1,3}))?\]"#
        let timestampRegex = try? NSRegularExpression(pattern: timestampPattern)
        // Metadata tags (a key followed by `:`): the whole line is skipped.
        let metadataKeys: Set<String> = ["ti", "ar", "al", "by", "offset", "length", "re"]

        var timed: [(time: Double, text: String, order: Int)] = []
        var untimed: [(text: String, order: Int)] = []
        var order = 0

        let lines = lrc.components(separatedBy: .newlines)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Skip empty or whitespace-only lines.
            if line.isEmpty { continue }

            // Detect a metadata tag line (starting with `[xx:` where xx is a known key).
            if isMetadataLine(line, keys: metadataKeys) {
                continue
            }

            // Extract all leading consecutive time tags.
            var times: [Double] = []
            var scanIndex = line.startIndex
            while let regex = timestampRegex {
                // The next time tag must start exactly at scanIndex (adjacent, no whitespace).
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
                    // Digit count decides the scale: 2 digits → 0.01, 3 digits → 0.001.
                    let scale = pow(10.0, Double(fracStr.count))
                    time += frac / scale
                }
                times.append(time)

                scanIndex = matchRange.upperBound
            }

            // Whatever follows the time tags is the lyric text (already trimmed).
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

        // Timed lines ascending by time; equal times keep original order (stable sort).
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

    /// Parses enhanced-LRC inline per-word timing tags `<mm:ss.xx>` / `<mm:ss.xxx>`.
    /// The text before the first tag starts at `lineStart`; each `<...>` tag marks the
    /// start of the following word segment. The last word's `end` is nil.
    /// Returns nil when there are no inline tags (falls back to line-level highlighting).
    static func parseWords(text: String, lineStart: Double) -> [LyricWord]? {
        let wordTagPattern = #"<(\d+):(\d{2})(?:[.:](\d{1,3}))?>"#
        guard let regex = try? NSRegularExpression(pattern: wordTagPattern) else { return nil }
        // No inline tags at all → nil (ordinary line-level LRC).
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard regex.firstMatch(in: text, range: fullRange) != nil else { return nil }

        var words: [LyricWord] = []
        var segStart = text.startIndex
        var segTime = lineStart

        // Walk all `<...>` tags, slicing out the text segment before each.
        regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let match, let r = Range(match.range, in: text) else { return }
            // Text segment before the tag
            let segment = String(text[segStart..<r.lowerBound])
            if !segment.isEmpty {
                words.append(LyricWord(id: UUID(), text: segment, start: segTime, end: nil))
            }
            // Parse the tag time as the next segment's start
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
        // Trailing segment (after the last tag)
        let tail = String(text[segStart..<text.endIndex])
        if !tail.isEmpty {
            words.append(LyricWord(id: UUID(), text: tail, start: segTime, end: nil))
        }
        // Fill in end: each word's end is the next word's start
        for i in 0..<words.count {
            if i + 1 < words.count {
                words[i] = LyricWord(id: words[i].id, text: words[i].text,
                                     start: words[i].start, end: words[i+1].start)
            }
        }
        return words.isEmpty ? nil : words
    }

    /// Parses the LRC `[offset:±ms]` metadata tag. A positive value means the lyrics
    /// should display later (standard LRC semantics). Returns nil when the tag is
    /// missing or fails to parse.
    static func parseOffsetMs(_ lrc: String) -> Int? {
        let pattern = #"\[offset:\s*([+-]?\d+)\s*\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(lrc.startIndex..<lrc.endIndex, in: lrc)
        guard let match = regex.firstMatch(in: lrc, range: range),
              let r = Range(match.range(at: 1), in: lrc),
              let v = Int(lrc[r]) else { return nil }
        return v
    }

    /// Whether a line is an LRC metadata tag (e.g. `[ti:Title]`). The key must be
    /// immediately followed by `:`.
    private static func isMetadataLine(_ line: String, keys: Set<String>) -> Bool {
        guard line.hasPrefix("[") else { return false }
        // Extract the token between `[` and the first `:` (trimmed of any whitespace).
        let afterBracket = line.dropFirst()
        guard let colon = afterBracket.firstIndex(of: ":") else { return false }
        let key = String(afterBracket[..<colon]).trimmingCharacters(in: .whitespaces)
        return keys.contains(key)
    }

    // MARK: - Helpers

    /// GETs a URL and returns the body data; nil on non-2xx or transport error (errors are swallowed).
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
