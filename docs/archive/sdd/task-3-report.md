# Task 3 Report: Search overlay, Escape, shortcut copy, rail Retry

## Status

**DONE_WITH_CONCERNS**

## Summary

Search is overlay-only: sidebar Search posts `.musesFocusSearch` and no longer tags `.search`. RootView `.search` maps to `HomeView` (dead fallback; never `EmptyView`). Escape dismisses Search and Queue. Empty-state copy says ⌘F. Failed Home discovery rails show Retry via `homeDiscovery.reload()` + view-local `retryingIDs`; loaded-empty hides the whole section including header. Top Picks Retry calls `loadTrending()`. Task 2 play-context in HomeView (`context: recentlyPlayed`) is untouched.

## Changes

### Sidebar (`SidebarView.swift`)

Replaced the tagged Search `Label` with a plain `Button` that posts `.musesFocusSearch`. No `.tag(SidebarSection.search)`. Does not set `selection = .search`.

### RootView (`.search` fallback)

```swift
case .search:
    HomeView(selection: $section, selectedAlbum: $selectedAlbum)
```

`SidebarSection.search` remains on the enum. `onReceive(.musesFocusSearch)` still only toggles `showSearch`.

### Search Escape (`GlobalSearchView.swift`)

- Root `ZStack`: `.onExitCommand { close() }`
- Search `TextField`: `.onExitCommand { close() }` and `.onKeyPress(.escape) { close(); return .handled }`
- Escape still calls existing `close()` (`search.reset(); isPresented = false`). Does not clear the query. No global key monitor.

### Queue Escape (`QueueDrawerView.swift`)

Root `HStack` (not the rename `alert`): `.onExitCommand { isPresented = false }`.

### Empty-state copy (`LibraryView.swift`)

- Albums empty: `Open Search (⌘F) and tap + to import a music folder, or drag files into the window`
- Songs empty: `Open Search (⌘F) and tap + to import a music folder`

`rg -n '⌘K' Muses/Sources/Muses/Features/LibraryView.swift` → no hits.

### Home rail Retry + empty collapse (`HomeView.swift`)

- `@State private var retryingIDs: Set<String> = []`
- `.failed`: keep `SectionHeader`; message + `Button(tr("Retry", "重试")) { retryingIDs.insert(section.id); homeDiscovery.reload() }`
- While `homeDiscovery.isRefreshing && retryingIDs.contains(section.id)`: existing skeleton `ResponsiveCarousel` instead of the error caption
- `.onChange(of: homeDiscovery.isRefreshing)`: when `false`, `retryingIDs.removeAll()`
- `.loaded` / `.idle` with empty items: entire `discoverySection` returns `EmptyView()` (no header)
- `topPicksSection` error: keep header, `Button(tr("Retry", "重试")) { loadTrending() }`
- No `retrySection(id:)` on `HomeDiscoveryService`

## Verification

| Check | Result |
|-------|--------|
| `swift build --target Muses` | PASS (7.04s) |
| `make app` | PASS — `build/Muses.app` signed ad-hoc |
| `rg -n 'EmptyView\(\)' Muses/Sources/Muses/App/RootView.swift` | no hits |
| `rg -n 'SidebarSection.search' Muses/Sources/Muses/Features/SidebarView.swift` | no hits |
| `rg -n '⌘K' Muses/Sources/Muses/Features/LibraryView.swift` | no hits |
| `rg -n 'retrySection' Muses/Sources/Muses` | no hits |
| `rg -n 'section = \.search' Muses/Sources/Muses` | no hits |
| Task 2 `context: recentlyPlayed` | still at `HomeView.swift:229` |
| ArtworkSource / engines / hover | untouched |

### Rendered click-test (blocked)

`open build/Muses.app` launched (pid 70006). CGWindowList saw a 1152×721 window titled `Muses`.

Could not complete the brief’s five click checks:

1. Sidebar Search → overlay; Home stays under scrim; sidebar highlight does not move
2. ⌘F still opens Search
3. Escape on focused field (typed query and empty) dismisses overlay
4. Queue ⌘K Escape; rename-group alert Escape closes alert not drawer
5. Failed discovery Retry → skeleton then items or error

Why blocked:

- Full-screen `screencapture` produced a black 3600×2338 PNG (no Screen Recording permission for this agent).
- `screencapture -l 4262` failed: `could not create image from window`.
- System Events listed 0 Muses windows.
- AX tree of pid 70006 exposed only the application + menu bar; no sidebar row, search field, or Retry button to click.

Worktree instance was killed after the probe. User’s pre-existing Muses (`/Users/xiaotwu/Code/xyz/build/Muses.app`, pid 63419) was left running.

Leave Escape / overlay / Retry visual checks for Task 10 QA rather than claiming them from source.

## Commit

- `1799340` — fix: Search overlay, Escape, rail Retry, and ⌘F empty-state copy

## Self-review

- **Completeness:** Steps 1–7 and 9 done. Step 8 attempted (`make app` + launch); click-through not possible in this environment.
- **Quality:** Verbatim copy and handlers from the brief. Search stays overlay-only. Empty rails collapse including header.
- **Discipline:** Six files only. No `retrySection`. No play-context revert. No ArtworkSource / hover / engine edits.
- **Testing:** Debug target build + release `make app` + grep done-bar. No new unit tests (brief does not add any).

## Concerns

Rendered Escape / overlay / Retry behavior is unimplemented-as-clicked. Code matches the brief; Task 10 should click-test the five cases above. Sidebar Search is a `Button` inside `List(selection:)` without a tag — expected not to move highlight, but that was not visually confirmed.
