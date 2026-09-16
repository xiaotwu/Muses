import SwiftUI

/// Window-local presentation only. No model objects, playback or persisted
/// playlist order are retained here; translated titles are never identities.
@MainActor
final class CollectionPresentationMemory {
    @MainActor
    final class Entry {
        var mode = CollectionPageMode.stage
        var focusedID: UUID?
        var selection = Set<UUID>()
        var sortOrder: [KeyPathComparator<CollectionTrackRow>]?
        var columns = TableColumnCustomization<CollectionTrackRow>()
    }

    private var entries: [(route: BrowseRoute, value: Entry)] = []
    private let capacity: Int

    init(capacity: Int = 100) { self.capacity = max(1, capacity) }

    func entry(for route: BrowseRoute) -> Entry {
        if let index = entries.firstIndex(where: { $0.route == route }) {
            let existing = entries.remove(at: index)
            entries.append(existing)
            return existing.value
        }
        let value = Entry()
        entries.append((route, value))
        if entries.count > capacity { entries.removeFirst() }
        return value
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
