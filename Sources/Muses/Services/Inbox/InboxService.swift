import Foundation
import Observation
import SwiftData

/// Inbox service (Final Spec §10.6 Feature 6 — Music Inbox).
///
/// Owns read/write access to the `InboxItem` table and subscribes to `PlaybackEventBus`:
/// - `.trackStarted` matching an inbox entry (by trackId) → marks it `.listening`.
/// All other state transitions are user-driven in `InboxView`:
/// - `add(snapshot:source:)` → creates a new `.unheard` entry (deduplicated: an existing
///   non-terminal entry with the same trackId is not added twice).
/// - `accept(id:)` → `.accepted` + writes `Track.liked = true` (via `LibraryService`;
///   YouTube state is untouched).
/// - `reject(id:)` → `.rejected`.
/// - `snooze(id:until:)` → `.snoozed` + `snoozeUntil`; `restoreDueSnoozes(now:)` moves due
///   items back to `.unheard`.
/// - `remove(id:)` → deletes the entry.
/// - `addNote(id:note:)` → attaches a note.
///
/// Feature flag `PrefKey.ffInbox` (off by default): when off, `add` does not persist
/// (the entry point stays callable as a silent no-op), matching the "off = no-op" convention
/// of `HistoryService`/`SessionService`; the subscription is always registered so no event
/// is missed.
@Observable
@MainActor
final class InboxService {
    private let modelContainer: ModelContainer
    private let eventBus: PlaybackEventBus
    private let enabledProvider: () -> Bool
    private var subscription: UUID?
    /// Persistence counter: bumped on every write so `InboxView` recomputes (tracked via @Observable).
    private(set) var revision: Int = 0
    /// Whether the inbox is enabled (reads the live flag source so Settings toggles take effect immediately).
    var isEnabled: Bool { enabledProvider() }

    init(modelContainer: ModelContainer, eventBus: PlaybackEventBus,
         enabledProvider: @escaping () -> Bool = {
        UserDefaults.standard.bool(forKey: PrefKey.ffInbox)
    }) {
        self.modelContainer = modelContainer
        self.eventBus = eventBus
        self.enabledProvider = enabledProvider
        subscribe()
    }

    /// Read-only container access: lets `InboxView`/tests run fresh-context queries as needed.
    var container: ModelContainer { modelContainer }

    private func subscribe() {
        subscription = eventBus.subscribe { [weak self] event in
            self?.handle(event)
        }
    }

    // MARK: - Event handling

    private func handle(_ event: PlaybackEvent) {
        guard case .trackStarted(let snap) = event else { return }
        markListening(trackId: snap.id)
    }

    /// When a track starts playing, marks the matching `.unheard`/`.snoozed` inbox entry (by trackId) as `.listening`.
    func markListening(trackId: UUID) {
        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<InboxItem>()
        guard let items = try? ctx.fetch(descriptor) else { return }
        guard let item = items.first(where: { $0.trackId == trackId && ($0.state == .unheard || $0.state == .snoozed) }) else { return }
        item.stateRaw = InboxState.listening.rawValue
        try? ctx.save()
        revision &+= 1
    }

    // MARK: - CRUD

    /// Adds an inbox entry. A silent no-op when the feature is off (the entry point stays callable).
    /// Skipped if an entry with the same trackId already exists in a non-terminal state.
    @discardableResult
    func add(_ snap: TrackSnapshot, source: InboxSource = .manual) -> UUID? {
        guard isEnabled else { return nil }
        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<InboxItem>()
        if let existing = try? ctx.fetch(descriptor),
           existing.contains(where: { $0.trackId == snap.id && $0.state != .accepted && $0.state != .rejected }) {
            return nil
        }
        let item = InboxItem(trackId: snap.id, trackTitle: snap.title, artist: snap.artist,
                             albumTitle: snap.albumTitle, durationSeconds: snap.durationSeconds,
                             youTubeId: snap.youTubeId, artworkUrl: snap.artworkUrl,
                             source: source)
        ctx.insert(item)
        try? ctx.save()
        revision &+= 1
        return item.id
    }

    /// Deletes an entry (user's "Remove").
    func remove(id: UUID) {
        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<InboxItem>()
        guard let items = try? ctx.fetch(descriptor),
              let item = items.first(where: { $0.id == id }) else { return }
        ctx.delete(item)
        try? ctx.save()
        revision &+= 1
    }

    /// Accept: sets `.accepted` and marks the corresponding `Track.liked = true`
    /// (if not already liked). YouTube state is untouched (Final Spec §10.6).
    /// The like is delegated to `LibraryService`; liked is not persisted here.
    func accept(id: UUID, library: LibraryService?) {
        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<InboxItem>()
        guard let items = try? ctx.fetch(descriptor),
              let item = items.first(where: { $0.id == id }) else { return }
        item.stateRaw = InboxState.accepted.rawValue
        try? ctx.save()
        if let library, !library.isLiked(id: item.trackId) {
            library.toggleLike(id: item.trackId)
        }
        revision &+= 1
    }

    /// Reject: sets `.rejected` (the row is kept for audit; `InboxView` hides decided items by default).
    func reject(id: UUID) {
        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<InboxItem>()
        guard let items = try? ctx.fetch(descriptor),
              let item = items.first(where: { $0.id == id }) else { return }
        item.stateRaw = InboxState.rejected.rawValue
        try? ctx.save()
        revision &+= 1
    }

    /// Snooze: sets `.snoozed` + `snoozeUntil`.
    func snooze(id: UUID, until: Date) {
        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<InboxItem>()
        guard let items = try? ctx.fetch(descriptor),
              let item = items.first(where: { $0.id == id }) else { return }
        item.stateRaw = InboxState.snoozed.rawValue
        item.snoozeUntil = until
        try? ctx.save()
        revision &+= 1
    }

    /// Appends/replaces the note.
    func addNote(id: UUID, note: String) {
        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<InboxItem>()
        guard let items = try? ctx.fetch(descriptor),
              let item = items.first(where: { $0.id == id }) else { return }
        item.notes = note.isEmpty ? nil : note
        try? ctx.save()
        revision &+= 1
    }

    /// Moves every `.snoozed` entry with `snoozeUntil <= now` back to `.unheard`.
    /// Called by `MusesApp` at launch; `InboxView` may also call it onAppear.
    func restoreDueSnoozes(now: Date = .init()) {
        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<InboxItem>()
        guard let items = try? ctx.fetch(descriptor) else { return }
        var changed = false
        for item in items where item.state == .snoozed && (item.snoozeUntil ?? .distantFuture) <= now {
            item.stateRaw = InboxState.unheard.rawValue
            item.snoozeUntil = nil
            changed = true
        }
        if changed { try? ctx.save(); revision &+= 1 }
    }
}
