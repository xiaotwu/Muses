import Foundation

extension HomeSection {
    /// Provider-owned copy may have been cached before the user changed language.
    /// Re-localize only Muses' known section labels; preserve remote editorial copy.
    var localizedTitle: String {
        guard source != .signedInWeb, cachedOrigin != .signedInWeb else { return title }
        switch id {
        case "new-releases": return tr("New releases", "新发行")
        case "quick-picks": return tr("Quick picks", "快速精选")
        case "listen-again": return tr("Listen again", "再听一次")
        case "trending": return tr("Charts", "排行榜")
        case "yt-liked": return tr("Liked on YouTube", "YouTube 喜欢")
        case "top-artist":
            if let name = suffix(after: ["Mixed for you · ", "为你精选 · ", "為你精選 · "]) {
                return tr("Mixed for you · \(name)", "为你精选 · \(name)", zhHant: "為你精選 · \(name)")
            }
        case "from-liked":
            if let name = suffix(after: ["Because you like ", "因为你喜欢 ", "因為你喜歡 "]) {
                return tr("Because you like \(name)", "因为你喜欢 \(name)", zhHant: "因為你喜歡 \(name)")
            }
        case "yt-subs":
            if let name = suffix(after: ["From ", "来自 ", "來自 "]) {
                return tr("From \(name)", "来自 \(name)", zhHant: "來自 \(name)")
            }
        case "seasonal": return Self.localizedKnownCopy(title)
        default:
            if id.hasPrefix("more-") { return tr("More for you", "更多推荐") }
            if id.hasPrefix("yt-mix-") {
                let name = String(id.dropFirst("yt-mix-".count))
                return tr("Because you liked \(name)", "因为你喜欢 \(name)", zhHant: "因為你喜歡 \(name)")
            }
        }
        return title
    }

    var localizedSubtitle: String? {
        guard source != .signedInWeb, cachedOrigin != .signedInWeb else { return subtitle }
        return subtitle.map(Self.localizedKnownCopy)
    }

    private func suffix(after prefixes: [String]) -> String? {
        prefixes.first(where: { title.hasPrefix($0) }).map { String(title.dropFirst($0.count)) }
    }

    private static func localizedKnownCopy(_ value: String) -> String {
        let copy = [
            ("From YouTube Music", "来自 YouTube Music"),
            ("From your account", "来自你的账号"),
            ("From your subscriptions", "来自你的订阅"),
            ("From your YouTube likes", "来自你的 YouTube 点赞"),
            ("Mix from YouTube Music", "YouTube Music 电台"),
            ("Play all", "全部播放"),
            ("Soundtrack the season", "本季原声"),
            ("That summer feeling", "夏日氛围"),
            ("Autumn atmosphere", "秋日氛围"),
            ("Winter listening", "冬日聆听"),
            ("Spring refresh", "春日焕新")
        ]
        for (en, zh) in copy where value == en || value == zh || value == L10n.traditionalStrings[zh] {
            return tr(en, zh)
        }
        return value
    }
}
