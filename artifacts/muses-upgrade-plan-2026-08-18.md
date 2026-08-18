# Muses 升级方案 2026-08-18

经多轮确认后的最终方案。分 5 阶段实施,每阶段 commit + 构建/测试验证后继续。

## 背景:用户反馈的 8 个问题

1. 导入的 YouTube 歌单不显示歌曲;Songs 有内容但 Albums/Artists 为空。
2. 全局缺少右键菜单。
3. 设置界面缺少退出按钮。
4. 侧栏 "Your YouTube Profile" 改为 "You";"YouTube Sign-in" 应为真实 YouTube 第三方登录,注重隐私与权限。
5. 深色主题蓝色 UI 文字换成发光白;浅色换成发光黑。
6. Search 中的添加库按钮只保留 +;全局其他地方不显示该功能避免重复。
7. 找冗余/重复功能,确认后移除。
8. 整体加载慢、部分卡死;YouTube 在线功能太慢,必要时商讨换技术栈。

## 已确认决策

### 第 1 点 — 元数据富集投影层(非持久化)
- 不改 SwiftData schema,不新增 migration。
- 新建 `MetadataEnrichmentService` + 非持久化 `BrowsableAlbum` / `BrowsableArtist`(含 `CanonicalIDs`: MusicBrainz/Wikidata/AppleMusic/YouTubeChannel)。
- 数据源优先级: Source0 已有 local/yt-dlp 元数据(seed) → Source1 MusicBrainz(主 canonical,需 rate-limit/队列/磁盘缓存/负缓存/SWR) → Source2 Cover Art Archive(artwork) → Source3 Wikidata(可选,仅在高可信 external ID 后) → Source4 Apple Music Catalog(可选,无凭证自动不可用)。
- 置信度评分: ≥0.90 自动解析 / 0.70–0.89 暂定浏览元数据但不持久化 canonical / <0.70 不解析。评分因素: title/artist/duration/album/release year/track count/provider agreement。
- Album 语义: 仅当 YouTube 元数据明确提供 album/release,或 provider 高置信匹配 Release/Release Group,或多 track 可靠归属同一 release 时生成 `BrowsableAlbum`。YouTube playlist / mix / compilation 仍归 Playlists,不伪装成 Album。
- Artist 语义: 仅当 track 有明确 artist field 或 provider 高置信确认 identity 时生成 `BrowsableArtist`。普通 uploader/channel/label 不自动当 Artist,只作 Creator/Uploader metadata。
- 缓存 `MetadataEnrichmentCache`: cache-first → background SWR 增量更新 → 不因 provider 慢而长 spinner。
- 失败降级不阻断播放/歌单/浏览/导入/本地库。宁愿元数据不完整也不造假实体。
- AlbumsView/ArtistsView 统一显示 local + YouTube-derived(带 YT source badge),统一排序/点击体验;点击 local→现有 detail,YouTube-derived→derived detail(由现有 YouTube tracks 支撑)。
- 歌单不显示歌曲的运行时嫌疑(跨 ModelContext save → @Query 不刷新)在 P1 或 P3 顺带验证修复。

### 第 4+8 点 — 真实 Google OAuth + yt-dlp 保留 + 性能重构
- 新建 `YouTubeAccountService`(OAuthSession / YouTubeDataAPIClient / YouTubeAccountSnapshot),OAuth 凭证存 macOS Keychain(非 UserDefaults/SwiftData/明文)。
- 最小只读 scope 优先(`youtube.readonly`);仅在用户面功能明确需要时才提权。
- OAuth 信号(频道身份/owned playlists/items/subscriptions/liked)喂入现有推荐系统,与本地历史/Context/Sessions/Focus/Inbox/本地库/已导入 YouTube 歌单混合。
- 禁止用 OAuth token 抓取/私有调用 YouTube Music 内部 API;不替换 yt-dlp 的播放/导入/流解析;不假设 Data API 提供 YouTube Music 个性化 Home feed。
- 概念分离: "Connect YouTube Account"→OAuth/Data API→个性化; "Browser Cookie Source"→yt-dlp→播放/导入/搜索解析。UI 不再把 cookie 提取叫 "YouTube Sign-in";"Connected to YouTube" 专指 OAuth。
- 离线/token 过期/配额耗尽/Data API 不可用时回退本地信号,不阻断播放。OAuth 集成可选,绝不阻塞播放。
- **性能重构(P1,三项全做):**
  - yt-dlp `Process` 移出 `@MainActor`(后台 actor + continuation 回主线程,移除 poll-wait 挂起)。
  - `LibraryService` 的 `allAlbums/allTracks/allArtists/recentlyPlayedTracks` 移出主线程(后台 ModelContext + snapshot 返回)。
  - 冷启动并发节流: Home discovery 同时最多 2 个 yt-dlp 进程(actor semaphore)。

### 第 5 点 — 原生 Liquid Glass(macOS 26)
- macOS 26 `glassEffect` / `GlassEffectContainer` / `glassEffectID` / interactive glass;macOS 14/15 用 material 回退(不升 deployment target)。
- 系统优先: NavigationSplitView sidebar/toolbar/sheet/popover/标准控件用系统 Liquid Glass;删除/避免遮挡系统 glass 的自定义不透明背景/scrim/blur;不自己模拟 ultraThinMaterial+shadow 冒充。
- 自定义浮层(PlayerBar/mini-player/overlay/selected contextual/floating action groups)用真正 SwiftUI Liquid Glass API;相邻 glass 控件放同一 `GlassEffectContainer`;展开/收起 morph 用 `glassEffectID`。
- 不全局发光: Liquid Glass 自身负责透明/折射/高光/pointer response;不给所有文字/icon/sidebar item 加 glow。`BrandColors.magenta` 仅用于 semantic emphasis(当前播放/主操作/选中/来源/状态指示),其余保持 system glass neutral。
- Sidebar/Toolbar 用系统 glass;Home/New 内容层(album artwork/playlist cards/song lists)不玻璃化;artwork 能"透过/影响"附近 glass 而非被覆盖。
- PlayerBar 是最明显的 Liquid Glass 区域,目标类似 Apple Music/macOS 26 浮层控制面(真实 translucency/refraction/highlight/interactive response,非 heavy bloom)。
- Accessibility: Reduce Transparency/Increase Contrast/Reduce Motion 回退为高可读 system surface。
- 不重构信息架构: 保留 Home/New 的 Apple Music-style 层级;Liquid Glass 是 chrome/material upgrade。
- 蓝色问题根因: 代码无显式蓝;`BrandColors.magenta/cyan/green` 已解析为深色白/浅色黑,但根视图无全局 `.tint`,未显式 tint 的控件(Toggle/Slider/ProgressView/分段 Picker)回退系统蓝。P4 顺带在根视图加全局 `.tint` 兜底。

### 第 6 点 — 工具栏 + 收敛
- 只把工具栏 `AddMusicMenu` 的 `+` 移到 Search 界面显示,其他界面隐藏该按钮。
- 保留: 拖拽导入、Home/全局搜索 YouTube 结果点击即播放并隐式入库、YouTubeImportsView 导入歌单按钮(语义不同)。
- 不移除隐式入库播放体验。

### 第 7 点 — feature flag 全部默认开启
- 把用户列出的所有默认 OFF 的 ff flag 翻为默认 ON(不删代码,让功能可见):
  - ffDiscovery / ffSituationalNew
  - ffSmartHistory / ffSessions / ffAdvancedQueue / ffInbox / ffNotes / ffAutomation
  - ffGlobalHotkeys / ffTray / ffMiniPlayer / ffDesktopLyrics
  - ffFocusMode / ffAudioNerd / ffLocalHardening
- 注: ffContext(隐私敏感,捕获当前 App)与 ffAdvancedLyrics 未在用户列举范围,保持原默认,必要时单独确认。
- 同时清理不可达死代码(YouTubeMusicView / YouTubeSearchView / 独立 YouTubeImportsView 的导入按钮)——P5。

### 第 2 点 — 右键菜单统一补齐
- 给主要列表/网格/卡片统一右键菜单: Play / Play Next / Add to Queue / Add to Inbox / Add to Playlist / Like-Unlike / Show in Album / Show in Artist。
- 覆盖: ArtistCard / PlaylistSidebarRow / 侧栏导航项 / PlaylistTrackRow / YouTube 导入行 / HistoryView / ArtistDetailView / HomeView 卡片 / SongCompactRow / NowPlayingView / MiniPlayerView / PlayerBar / 全局搜索结果行。
- 队列右键基础项从 `ffAdvancedQueue` 解绑(默认可用)。

### 第 3 点 — 设置退出按钮
- Settings 底部加 "Quit Muses" 按钮(`NSApp.terminate(nil)`)。

## 实施阶段

- **P1 性能重构(基础):** yt-dlp 移出主线程 + Library fetch 移出主线程 + 并发节流。high-risk(YTDlpBridge/YouTubeStreamEngine/LibraryService),窄改 + 测试。
- **P2 OAuth + Keychain + Data API:** YouTubeAccountService + Keychain 凭证 + DataAPIClient + 信号接入推荐。需用户提供 Google Cloud OAuth Client ID/Secret。
- **P3 元数据富集投影层:** MetadataEnrichmentService + BrowsableAlbum/Artist + 多源 + 置信度 + 缓存 + AlbumsView/ArtistsView 统一呈现。需网络依赖确认(MusicBrainz 公开,Apple Music 需 MusicKit)。
- **P4 Liquid Glass:** 根视图全局 tint 兜底 + sidebar/toolbar 系统 glass + PlayerBar/mini-player 浮层 glass + 回退 + accessibility。
- **P5 一致性清理:** 右键菜单补齐 + 设置退出按钮 + 工具栏 + 收敛到 Search + ff flag 全开 + 死代码清理。

## 需用户提供的外部凭证
- Google Cloud OAuth Client ID/Secret(YouTube Data API,只读 scope)——P2 必需。
- (可选)Apple Music Catalog: MusicKit entitlement——P3 可选 provider。
- MusicBrainz / Cover Art Archive / Wikidata: 免费公开,无需 key。