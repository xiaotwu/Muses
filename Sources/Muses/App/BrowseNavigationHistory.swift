import Foundation

/// Window-local navigation stores identities, never retained SwiftData models.
enum BrowseRoute: Hashable {
    case section(SidebarSection)
    case channel(String)
    case settings(String, [SettingsDestination])
    case playlist(UUID)
    case youTubeImport(UUID)
    case release(String)
    case artist(String)
}

struct BrowseNavigationHistory {
    private(set) var entries: [BrowseRoute] = [.section(.home)]
    private(set) var index = 0
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index + 1 < entries.count }

    init(initial: BrowseRoute = .section(.home)) {
        switch initial {
        case .channel: entries = [.section(.subscriptions), initial]
        case .settings, .section(.settings): entries = [.section(.home), initial]
        case .playlist, .youTubeImport: entries = [.section(.playlists), initial]
        case .release: entries = [.section(.albums), initial]
        case .artist: entries = [.section(.artists), initial]
        default: entries = [initial]
        }
        index = entries.count - 1
    }

    mutating func visit(_ route: BrowseRoute) {
        guard entries[index] != route else { return }
        entries.removeSubrange((index + 1)..<entries.count)
        entries.append(route)
        if entries.count > 100 { entries.removeFirst() }
        index = entries.count - 1
    }

    mutating func back() -> BrowseRoute? {
        guard canGoBack else { return nil }
        index -= 1
        return entries[index]
    }

    mutating func forward() -> BrowseRoute? {
        guard canGoForward else { return nil }
        index += 1
        return entries[index]
    }

    mutating func replaceCurrent(_ route: BrowseRoute) { entries[index] = route }
}

/// Versioned route values only; account scope is a public channel ID, never a token.
struct BrowseRouteSnapshot: Codable, Equatable {
    static let preferenceKey = "browse.lastRoute.v1"
    let version: Int
    let kind: String
    let value: String
    let accountChannelID: String?

    init(route: BrowseRoute, accountChannelID: String?) {
        version = 1
        switch route {
        case .channel(let id): kind = "channel"; value = id
        case .settings(let category, _): kind = "settings"; value = category
        case .section(let section): kind = "section"; value = section.rawValue
        case .playlist(let id): kind = "playlist"; value = id.uuidString
        case .youTubeImport(let id): kind = "import"; value = id.uuidString
        case .release(let id): kind = "release"; value = id
        case .artist(let id): kind = "artist"; value = id
        }
        self.accountChannelID = (kind == "channel" || route == .section(.subscriptions)) ? accountChannelID : nil
    }

    var requiresAccount: Bool { kind == "channel" || (kind == "section" && value == SidebarSection.subscriptions.rawValue) }

    func route(activeChannelID: String?) -> BrowseRoute? {
        guard version == 1, value.utf8.count <= 256 else { return nil }
        if requiresAccount {
            guard let accountChannelID, accountChannelID == activeChannelID else { return nil }
        }
        switch kind {
        case "channel": return value.hasPrefix("UC") ? .channel(value) : nil
        case "settings": return SettingsCategory(rawValue: value).map { .settings($0.destination.rawValue, []) }
        case "section": return SidebarSection(rawValue: value).map(BrowseRoute.section)
        case "playlist": return UUID(uuidString: value).map(BrowseRoute.playlist)
        case "import": return UUID(uuidString: value).map(BrowseRoute.youTubeImport)
        case "release": return YouTubeCatalogIdentity.isResolvedRelease(value) ? .release(value) : nil
        case "artist": return YouTubeCatalogIdentity.isResolvedArtist(value) ? .artist(value) : nil
        default: return nil
        }
    }

    static func read(defaults: UserDefaults = .standard) -> Self? {
        guard let data = defaults.data(forKey: preferenceKey), data.count <= 4096 else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.preferenceKey)
    }
}
