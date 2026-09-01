### Task 4: UserPreferences + NowPlayingMode + 持久化

**Files:**
- Create: `Muses/Sources/Muses/Domain/UserPreferences.swift`

**Verified API facts:**
- `@AppStorage` in SwiftUI supports `RawRepresentable` types where `RawValue == String` via a custom extension (the built-in `@AppStorage` only supports primitive types + `RawRepresentable` with `RawValue` of `Int`/`String`/`Bool`/`URL`/`Double` via implicit conformance — but for custom enums with `RawValue == String`, SwiftUI's `AppStorage` does NOT have built-in support). **Verified:** The standard approach is to use `@AppStorage` with `String` and convert, OR provide a `RawRepresentable` conformance + an `AppStorage` extension. The simplest reliable approach for macOS 14: use `@AppStorage(PrefKey.nowPlayingMode) private var modeRaw: String = NowPlayingMode.cover.rawValue` and compute `var mode: NowPlayingMode { NowPlayingMode(rawValue: modeRaw) ?? .cover }` in the View. This avoids custom extensions.
- No existing `@AppStorage` usage in the codebase (checked — clean slate).

**Downstream contracts:**
- `NowPlayingMode` (.cover/.vinyl): consumed by NowPlayingView (Task 5) to switch between cover and vinyl layouts; ThemeSettingsView (Task 6) toggles it.
- `AppTheme` (.dark/.light/.system): consumed by SettingsView (Task 11); Phase 2 only renders dark, light is reserved.
- `PrefKey` string constants: used by `@AppStorage(PrefKey.xxx)` across all preference-bearing views.

**Implementation:**

`Muses/Sources/Muses/Domain/UserPreferences.swift`:
```swift
import Foundation

/// Now Playing 页面的两种展示模式。
enum NowPlayingMode: String, CaseIterable, Codable {
    case cover   // 巨大封面
    case vinyl   // 唱片旋转
}

/// 应用主题(阶段 2 仅渲染 dark; light/system 留作阶段 4)。
enum AppTheme: String, CaseIterable, Codable {
    case dark, light, system
}

/// @AppStorage 键常量集中管理。
enum PrefKey {
    static let nowPlayingMode = "muses.nowPlayingMode"
    static let theme = "muses.theme"
    static let eqActivePresetId = "muses.eq.activePresetId"
    static let lyricsSource = "muses.lyrics.source"
    static let audioQuality = "muses.audio.quality"
}
```

- [ ] **Step 1: 构建验证**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift build`
Expected: 编译通过(纯枚举+常量,无依赖)。

- [ ] **Step 2: 回归**

Run: `cd /Users/xiaotwu/Code/xyz/Muses && swift test 2>&1 | tail -3`
Expected: 31 通过(无新测试,纯类型定义不改变行为)。

- [ ] **Step 3: Commit**

```bash
cd /Users/xiaotwu/Code/xyz
git add -A
git commit -m "feat: UserPreferences (NowPlayingMode/AppTheme/PrefKey @AppStorage)"
```

---