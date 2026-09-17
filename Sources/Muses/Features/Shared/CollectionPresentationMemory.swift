import Foundation
import SwiftUI

/// Live state remains window-local. A small identity-only snapshot seeds a new
/// process so the last deck/list mode and anchor survive an app restart. No
/// model objects, translated titles, playback state, or playlist order are
/// retained here.
@MainActor
final class CollectionPresentationMemory {
    @MainActor
    final class Entry {
        var mode = CollectionPageMode.stage { didSet { persist() } }
        var focusedID: UUID? { didSet { persist() } }
        var selection = Set<UUID>() { didSet { persist() } }
        var sortOrder: [KeyPathComparator<CollectionTrackRow>]?
        var columns = TableColumnCustomization<CollectionTrackRow>()

        private let onChange: (CollectionPresentationSnapshot) -> Void

        init(
            snapshot: CollectionPresentationSnapshot? = nil,
            onChange: @escaping (CollectionPresentationSnapshot) -> Void = { _ in }
        ) {
            mode = snapshot?.mode ?? .stage
            focusedID = snapshot?.focusedID
            selection = snapshot?.selection ?? []
            self.onChange = onChange
        }

        private func persist() {
            onChange(CollectionPresentationSnapshot(
                mode: mode,
                focusedID: focusedID,
                selection: selection
            ))
        }
    }

    private var entries: [(route: BrowseRoute, value: Entry)] = []
    private let capacity: Int
    private let defaults: UserDefaults

    init(capacity: Int = 100, defaults: UserDefaults = .standard) {
        self.capacity = max(1, capacity)
        self.defaults = defaults
    }

    func entry(for route: BrowseRoute) -> Entry {
        if let index = entries.firstIndex(where: { $0.route == route }) {
            let existing = entries.remove(at: index)
            entries.append(existing)
            return existing.value
        }
        let storageKey = Self.storageKey(for: route)
        let snapshot = storageKey.flatMap { CollectionPresentationSnapshot.read(key: $0, defaults: defaults) }
        let value = Entry(snapshot: snapshot) { [defaults] snapshot in
            guard let storageKey else { return }
            snapshot.save(key: storageKey, defaults: defaults)
        }
        entries.append((route, value))
        if entries.count > capacity { entries.removeFirst() }
        return value
    }

    private static func storageKey(for route: BrowseRoute) -> String? {
        let identity: String
        switch route {
        case .section(.songs): identity = "section:songs"
        case .section(.liked): identity = "section:liked"
        case .section(.musicVideos): identity = "section:musicVideos"
        case .playlist(let id): identity = "playlist:\(id.uuidString)"
        case .youTubeImport(let id): identity = "import:\(id.uuidString)"
        case .release(let id): identity = "release:\(id)"
        default: return nil
        }
        let encoded = Data(identity.utf8).base64EncodedString()
        return "collection.presentation.v1.\(encoded)"
    }
}

struct CollectionPresentationSnapshot: Codable, Equatable {
    let modeRawValue: String
    let focusedID: UUID?
    let selection: Set<UUID>

    init(mode: CollectionPageMode, focusedID: UUID?, selection: Set<UUID>) {
        modeRawValue = mode == .list ? "list" : "stage"
        self.focusedID = focusedID
        self.selection = Set(selection.prefix(500))
    }

    var mode: CollectionPageMode { modeRawValue == "list" ? .list : .stage }

    static func read(key: String, defaults: UserDefaults) -> Self? {
        guard let data = defaults.data(forKey: key), data.count <= 64 * 1024 else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save(key: String, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self), data.count <= 64 * 1024 else { return }
        defaults.set(data, forKey: key)
    }
}

private struct CollectionPresentationKey: EnvironmentKey {
    static let defaultValue: CollectionPresentationMemory.Entry? = nil
}

extension EnvironmentValues {
    var collectionPresentation: CollectionPresentationMemory.Entry? {
        get { self[CollectionPresentationKey.self] }
        set { self[CollectionPresentationKey.self] = newValue }
    }
}
