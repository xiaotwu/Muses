### Task 7: 队列抽屉 + 持久化恢复

**Files:**
- Create: `Muses/Sources/Muses/Domain/QueueState.swift`(@Model 持久化)
- Modify: `Muses/Sources/Muses/Services/Queue/QueueService.swift`(持久化/恢复 + move API + Codable on QueueItem/TrackSnapshot)
- Modify: `Muses/Sources/Muses/Domain/QueueItem.swift`(add Codable to QueueItem + TrackSnapshot)
- Modify: `Muses/Sources/Muses/Persistence/MusesModelContainer.swift`(add QueueState to schema v1)
- Create: `Muses/Sources/Muses/Features/Queue/QueueDrawerView.swift`
- Modify: `Muses/Sources/Muses/App/RootView.swift`(抽屉覆盖)
- Modify: `Muses/Sources/Muses/Features/PlayerBar.swift`(队列按钮触发)
- Create: `Muses/Tests/MusesTests/QueueServicePersistenceTests.swift`

**Verified API facts:**
- `QueueService` is `@Observable @MainActor final class` with: items:[QueueItem], currentIndex:Int, upNext:[QueueItem], history:[QueueItem], repeatMode:RepeatMode, shuffle:Bool, originalOrder (private). Methods: play/playNext/addToQueue/current/next/previous/setRepeat/toggleShuffle. File: `Muses/Sources/Muses/Services/Queue/QueueService.swift`.
- `QueueItem` is `struct QueueItem: Identifiable, Equatable, Sendable` with id:UUID, track:TrackSnapshot, source:TrackSource, queuedAt:Date, fromContext:QueueSource. Needs `Codable` added. File: `Muses/Sources/Muses/Domain/QueueItem.swift`.
- `TrackSnapshot` is `struct TrackSnapshot: Identifiable, Equatable, Sendable` with all-let fields. Needs `Codable` added (all fields are already Codable: UUID, String, String?, Double, String?, String?, String?, String?, String?, Int?, Int?, String?, Bool).
- `TrackSource`, `RepeatMode`, `QueueSource` are all `String, Codable, Sendable` enums.
- `MusesModelContainer.swift`: `MusesSchema.v1 = Schema([Track.self, Album.self, ScanRoot.self])`. Need to add `QueueState.self`.
- `MusesApp.swift`: `makeModelContainer()` creates the container; `PlaybackService` receives `queue: QueueService()` — no ModelContext injected. For persistence, QueueService needs a ModelContext reference. The cleanest approach: add `var modelContext: ModelContext?` to QueueService, set after container creation in MusesApp init.
- `PlayerBar` has a `Button { } label: { Image(systemName: "list.bullet") }` — wire this to showQueue.
- `RootView` presents overlays; add `@State showQueue` + `.overlay(alignment: .trailing)` for the drawer.
- SwiftData `@Model` syntax: `@Model final class QueueState { ... }`.
- JSON encoding: `JSONEncoder().encode(items)` → String(data:encoding:.utf8). Decode: `JSONDecoder().decode([QueueItem].self, from: Data(json.utf8))`.

**Downstream contracts:**
- `QueueService.persist()` — saves current state to ModelContext (upsert single QueueState row with fixed id).
- `QueueService.restore()` — loads from ModelContext if available.
- `QueueService.move(from: Int, to: Int)` — reorder items (for .onMove in List).
- `QueueService.moveUpNext(from: Int, to: Int)` — reorder upNext.
- `QueueDrawerView(isPresented:)` — trailing drawer with 3 sections.

**Implementation steps:**

1. Add `Codable` to `QueueItem` and `TrackSnapshot` (just add `Codable` to the protocol list — all fields are already Codable).

2. Create `QueueState.swift`:
```swift
import Foundation
import SwiftData

@Model final class QueueState {
    @Attribute(.unique) var id: UUID
    var itemsJSON: String
    var currentIndex: Int
    var upNextJSON: String
    var historyJSON: String
    var repeatModeRaw: String
    var shuffle: Bool
    var savedAt: Date

    init(id: UUID = UUID(), itemsJSON: String, currentIndex: Int, upNextJSON: String,
         historyJSON: String, repeatModeRaw: String, shuffle: Bool, savedAt: Date = .init()) {
        self.id = id; self.itemsJSON = itemsJSON; self.currentIndex = currentIndex
        self.upNextJSON = upNextJSON; self.historyJSON = historyJSON
        self.repeatModeRaw = repeatModeRaw; self.shuffle = shuffle; self.savedAt = savedAt
    }
}
```
Use a FIXED id (e.g. `UUID(uuidString: "00000000-0000-0000-0000-000000000001")!`) for the single-row upsert so restore always finds the same row.

3. Add `QueueState.self` to `MusesSchema.v1`.

4. Modify `QueueService`: add `var modelContext: ModelContext?`. Add methods:
- `persist()` — encode items/upNext/history to JSON strings, upsert QueueState with fixed id into modelContext.
- `restore()` — fetch QueueState with fixed id, decode JSON back to items/upNext/history/currentIndex/repeatMode/shuffle.
- `move(from: Int, to: Int)` — reorder items array; if currentIndex is affected, adjust.
- `moveUpNext(from: Int, to: Int)` — reorder upNext array.
Call `persist()` at the end of `play`, `next`, `previous`, `playNext`, `addToQueue`, `setRepeat`, `toggleShuffle`, `move`, `moveUpNext` (guard modelContext != nil).

5. In `MusesApp.init()`, after creating container, set `queue.modelContext = container.mainContext`.

6. Create `QueueDrawerView.swift`:
- Width 360, slides in from trailing edge.
- List with 3 sections: "当前队列" (items with .onMove calling queue.move), "Up Next" (upNext with .onMove calling queue.moveUpNext), "History" (history, read-only).
- Each row: track title, artist, duration.
- Close button or tap-outside-to-dismiss.

7. Modify `PlayerBar`: add `var onQueueTap: () -> Void = {}`, wire the list.bullet button.

8. Modify `RootView`: add `@State showQueue`, `.overlay(alignment: .trailing) { if showQueue { QueueDrawerView(isPresented: $showQueue) } }`, pass `onQueueTap: { showQueue = true }` to PlayerBar.

9. Write `QueueServicePersistenceTests.swift`:
- Test 1: play → persist → new QueueService with same ModelContext → restore → assert items.count, currentIndex, upNext.count match.
- Test 2: move(from: 0, to: 2) → items order changed → persist → restore on new instance → assert order preserved.
Use `makeModelContainer(inMemory: true)` for test ModelContext.

**Build gate:** `swift build` — must pass.
**Test gate:** `swift test` — 31 existing + new persistence tests must pass.
**Do NOT commit.** Report back with final file contents, build result, test count.

---