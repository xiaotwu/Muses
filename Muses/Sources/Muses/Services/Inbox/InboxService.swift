import Foundation
import Observation
import SwiftData

/// 收件箱服务(Final Spec §10.6 Feature 6 — Music Inbox)。
///
/// 持有 `InboxItem` 表的读写入口,订阅 `PlaybackEventBus`:
/// - `.trackStarted` 命中某收件箱条目(trackId 匹配)→ 置 `.listening`。
/// 其余状态转移由用户在 `InboxView` 触发:
/// - `add(snapshot:source:)` → 新建 `.unheard` 条目(去重:同 trackId 且非终态则不重复加)。
/// - `accept(id:)` → `.accepted` + 回写 `Track.liked = true`(经 `LibraryService`,不改动 YouTube)。
/// - `reject(id:)` → `.rejected`。
/// - `snooze(id:until:)` → `.snoozed` + `snoozeUntil`;`restoreDueSnoozes(now:)` 把到期项置回 `.unheard`。
/// - `remove(id:)` → 删除条目。
/// - `addNote(id:note:)` → 追加备注。
///
/// 功能开关 `PrefKey.ffInbox`(默认关):关闭时 `add` 不落库(入口仍可调用,静默 no-op),
/// 与 `HistoryService`/`SessionService` 的「关 = no-op」约定一致;订阅始终注册,避免漏接事件。
@Observable
@MainActor
final class InboxService {
    private let modelContainer: ModelContainer
    private let eventBus: PlaybackEventBus
    private let enabledProvider: () -> Bool
    private var subscription: UUID?
    /// 落库计数器:每次写入自增,供 `InboxView` 触发重算(@Observable 追踪)。
    private(set) var revision: Int = 0
    /// 收件箱是否启用(实时读开关源,使 Settings 切换即时生效)。
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

    /// 只读容器访问:供 `InboxView`/测试按需做 fresh-context 查询。
    var container: ModelContainer { modelContainer }

    private func subscribe() {
        subscription = eventBus.subscribe { [weak self] event in
            self?.handle(event)
        }
    }

    // MARK: - 事件处理

    private func handle(_ event: PlaybackEvent) {
        guard case .trackStarted(let snap) = event else { return }
        markListening(trackId: snap.id)
    }

    /// 曲目开始播放时,若其 trackId 命中一条 `.unheard`/`.snoozed` 收件箱条目,置 `.listening`。
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

    /// 新增收件箱条目。功能关闭时静默 no-op(保持入口可调用)。同 trackId 已存在且未终态时跳过。
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

    /// 删除条目(用户「Remove」)。
    func remove(id: UUID) {
        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<InboxItem>()
        guard let items = try? ctx.fetch(descriptor),
              let item = items.first(where: { $0.id == id }) else { return }
        ctx.delete(item)
        try? ctx.save()
        revision &+= 1
    }

    /// 接受:置 `.accepted`,并把对应 `Track.liked` 置 true(若尚未收藏)。
    /// 不改动 YouTube 状态(Final Spec §10.6)。`like` 委托 `LibraryService`,不在此处持久化 liked。
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

    /// 拒绝:置 `.rejected`(保留行供审计;`InboxView` 默认隐藏已决项)。
    func reject(id: UUID) {
        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<InboxItem>()
        guard let items = try? ctx.fetch(descriptor),
              let item = items.first(where: { $0.id == id }) else { return }
        item.stateRaw = InboxState.rejected.rawValue
        try? ctx.save()
        revision &+= 1
    }

    /// 延后:置 `.snoozed` + `snoozeUntil`。
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

    /// 追加/替换备注。
    func addNote(id: UUID, note: String) {
        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<InboxItem>()
        guard let items = try? ctx.fetch(descriptor),
              let item = items.first(where: { $0.id == id }) else { return }
        item.notes = note.isEmpty ? nil : note
        try? ctx.save()
        revision &+= 1
    }

    /// 把所有 `.snoozed` 且 `snoozeUntil <= now` 的条目置回 `.unheard`。
    /// 由 `MusesApp` 启动时调用;`InboxView` 也可在 onAppear 调用。
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
