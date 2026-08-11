# Muses — 音乐播放器设计

- **日期**: 2026-08-11
- **状态**: 已确认,待写实施计划
- **平台**: macOS 14+ (Sonoma),Apple Silicon 原生 (arm64),不构建 x86_64,不考虑移植或多平台
- **分发**: 个人分发(GitHub Releases + Developer ID 签名 + 公证 + Sparkle 自动更新),**非 App Store**

## 1. 目标与范围

仿照 TIDAL 的应用界面与播放器界面,做一个支持本地与在线的音乐播放器。

- **本地**:用户可选择目录或特定歌曲导入到 Library,实现本地音乐播放。
- **在线**:用户可导入 YouTube / YouTube Music 歌单链接,解析其中的歌曲,实现在线播放。
- **视觉**:复刻 TIDAL 的主布局骨架、专辑详情页(封面主色渐变)、全屏 Now Playing(频谱/波形/歌词)、队列与 Up Next。
- **主题**:与提供的 logo/icon 风格一致,支持深色(默认)/浅色/跟随系统切换。

## 2. 关键决策汇总

| 决策项 | 选择 |
|---|---|
| 产品名 | Muses |
| 技术栈 | Swift + SwiftUI 原生 |
| 架构方案 | 方案 A — 统一 `PlaybackService`,本地 `AVAudioEngine` + YouTube 可注入 `AVAudioEngine`(降级 `AVPlayer`) |
| YouTube 音频流 | yt-dlp 拉流 → 流 URL → 优先 `AVAudioEngine` 渲染;降级 `AVPlayer` |
| 本地音频引擎 | `AVAudioEngine` + `AVAudioPlayerNode` + `AVAudioUnitEQ`(支持 EQ/频谱/波形) |
| 音质 | 本地 native format 渲染(FLAC/ALAC 24/192 原样);YouTube `bestaudio` 最高码率;可选独占模式 |
| 格式 | MP3/M4A/AAC/ALAC/FLAC/OPUS/OGG/WAV/AIFF;OPUS 必要时 `AudioToolbox` 兜底 |
| 元数据 | 内嵌读取 + 联网补全(Apple Music API 为主,MusicBrainz 兜底) |
| 歌词 | 本地 .lrc + 联网补全(LRCLIB / NetEase) |
| YouTube 歌单管理 | 独立 `YouTubeImport` 管理;远端可写时同步,本地附加不回写 YT |
| 队列 | 与 TIDAL 一致:主队列 = 当前播放上下文;Up Next = 手动插队;History;Shuffle / Repeat(off/all/one) |
| 自动更新 | Sparkle |
| 分发 | 个人分发(非 App Store),Developer ID 签名 + 公证 |

### 2.1 合规边界

- yt-dlp 拉流**仅用于个人使用**,遵守当地版权法,不分发音频文件。
- 首次启动 + 关于页明确此声明。
- 不入 App Store,避免 yt-dlp 导致下架。

## 3. 整体架构与分层

```
┌─────────────────────────────────────────────────────────┐
│  SwiftUI App (MusesApp)                                 │
│  └─ AppDelegate: 权限/签名/公证启动检查                   │
├─────────────────────────────────────────────────────────┤
│  Presentation Layer (SwiftUI)                            │
│   ├ Sidebar (Home/Search/Library/Settings)              │
│   ├ ContentRouter (NavigationSplitView)                 │
│   ├ AlbumDetailView (封面主色渐变)                       │
│   ├ NowPlayingView (全屏, 波形/频谱/歌词)                 │
│   └─ PlayerBar (底部固定) + QueueDrawer                  │
│      全部通过 @Observable PlayerViewModel 单向绑定        │
├─────────────────────────────────────────────────────────┤
│  Application Services (Swift)                            │
│   ├ PlaybackService (协议 PlayerEngine)                  │
│   │   ├ LocalAudioEngine (AVAudioEngine + EQ + tap)      │
│   │   └ YouTubeStreamEngine (yt-dlp→AVPlayer, 可选 AudioEngine)│
│   ├ LibraryService (扫描/导入/索引/搜索)                  │
│   ├ MetadataService (内嵌读取+联网补全)                   │
│   ├ LyricsService (.lrc+LRCLIB/NetEase)                   │
│   └ QueueService (本地/YT 混合队列, Up Next)             │
├─────────────────────────────────────────────────────────┤
│  Infrastructure                                          │
│   ├ Persistence (SwiftData, 文件元数据缓存)               │
│   ├ yt-dlp 桥 (进程调用, 缓存流URL, 失败重试)             │
│   ├ Network (Apple Music API/MusicBrainz/LRCLIB 客户端)  │
│   └ MediaIntegrations (MPNowPlayingInfo/MPRemoteCommand) │
└─────────────────────────────────────────────────────────┘
```

要点:
- **依赖方向单向**:UI → Application Services → Infrastructure,绝不反向。跨层通信通过协议与 `@Observable` 视图模型。
- **`PlaybackService` 是唯一播放真相源**:UI 永远只看 `PlayerState`,不直接碰引擎。队列、播放历史、Up Next 都挂在它下面。
- **`PlayerEngine` 协议**:`LocalAudioEngine` 与 `YouTubeStreamEngine` 各自实现,`PlaybackService` 按队列条目的来源分发,对上层透明。
- **小而专注的单元**:每个 Service 一个文件、一个职责,便于单独理解与测试。`MetadataService` 只负责"读+补全",`LibraryService` 只负责"扫描+索引",`LyricsService` 只负责"歌词获取+同步"。

## 4. 数据模型与 Library 结构

核心领域模型(SwiftData `@Model`,持久化到 SQLite):

```
Track                      单首可播放曲目,本地与 YT 共用同一张表
├ id: UUID
├ source: TrackSource  (.local | .youtube)
├ title, artist, album, albumArtist: String
├ durationMs: Int
├ trackNo, discNo, year: Int?
├ genre: String?
├ filePath: String?        仅 .local,相对 Library 根
├ youTubeId: String?       仅 .youtube,video id
├ artworkUrl: String?     远程封面(Apple Music/MusicBrainz)
├ localArtworkHash: String?  内嵌封面文件缓存哈希
├ lyrics: String?          内嵌或下载的 .lrc(同步歌词)
├ replayGain: Float?       后续 EQ/音量归一
├ addedAt: Date
├ lastPlayedAt: Date?
├ playCount: Int
├ liked: Bool
└ album: Album?            反向关系

Album                     由扫描自动聚合
├ id, title, albumArtist, year, artworkUrl
├ tracks: [Track]
└ isVarious: Bool          合辑

Playlist                  用户自建(本地歌单)
├ id, title, description, createdAt
├ coverArtworkUrl
└ items: [PlaylistItem]   有序

PlaylistItem              本地歌单的有序条目
├ id, playlist, track, order, addedAt

ScanRoot                  用户导入的目录根,供重新扫描
├ id, path, lastScannedAt, watch: Bool

YouTubeImport             一次 YouTube 歌单链接导入(独立管理实体)
├ id, playlistId(YT), url, title, channel, artworkUrl
├ importedAt, lastSyncedAt
├ items: [YouTubeImportItem]   YT 侧曲目(只读镜像)
└ localAdditions: [Track]      本地附加到该歌单的曲目(仅本地显示,不同步回 YT)

YouTubeImportItem          YT 侧的只读条目
├ id, import, youTubeId, title, artist, durationMs, order
└ track: Track              指向懒创建的 .youtube Track
```

要点:
- **统一 `Track` 表**:本地与 YouTube 共用,通过 `source` 区分。队列、搜索、封面墙的渲染逻辑只有一套,TIDAL 式混合浏览自然成立。
- **YouTube 导入即建 `YouTubeImport` + `YouTubeImportItem` + 懒建 `.youtube` Track**:播放时才由 `YouTubeStreamEngine` 调 yt-dlp 解析实际流 URL 并缓存(流 URL 有时效,缓存 ~6 小时)。
- **YouTube 歌单管理**:Sidebar 下 "My Collection" 里有独立的 **YouTube Imports** 区。远端可写时,添加在线歌曲同步更新 YT;添加本地歌曲只写 `YouTubeImport.localAdditions`,**绝不**调 YT 写 API,本地附加项用本地徽标区分。提供"重新同步"按钮按 `playlistId` 拉取最新 YT 侧条目,合并(保留本地附加项)。
- **Album 自动聚合**:扫描时按 `(albumTitle, albumArtist)` 聚合;YouTube 来源且无专辑信息的歌曲归入"Various/单曲"虚拟专辑,避免空封面墙。
- **封面缓存策略**:内嵌封面提取后存到 `~/Library/Caches/Muses/artwork/<hash>.jpg`,DB 只存哈希;远程封面 URL 按需下载到同目录。封面加载零解码、离线可见。
- **SwiftData 选择理由**:原生、声明式、与 SwiftUI 深度集成、无需第三方 ORM,Apple Silicon 上零额外开销。查询用 `@Query` 直接喂视图。
- **不做云端同步**:MVP 单机,Library 存本地。未来若要同步另起 SyncService,不污染现有模型。

## 5. Library 扫描与导入流程

```
用户操作                LibraryService              MetadataService           持久化
────────────────────────────────────────────────────────────────────────────────────
1. 添加目录 ─→ 注册 ScanRoot(path, watch) ───────────────────────────→ Save ScanRoot
              └─ 启动 DirectoryScanner(NSMetadataQuery 或 FileEnumerator)
                 ├ 枚举 .mp3/.m4a/.flac/.opus/.wav/.ogg
                 ├ 逐文件 AVAsset(url) 异步读取
                 └ 限流:8 并发(TaskGroup)

2. 每个文件 ─→ resolveMetadata(asset)
              ├ 读内嵌: title/artist/album/art/duration(同步, 快)
              ├ 内嵌封面 → 存 Caches/artwork/<hash>.jpg, 记 hash
              └ 缺失字段入"待补全"队列 ──────────→ async enrich(track):
                 ├ Apple Music API search (title+artist) → artworkUrl/专辑/年份
                 ├ 兜底 MusicBrainz (release-group) → 补齐
                 └ 命中 → 回填 DB; 未命中 → 标记 metadataStatus=.missing
              ──────────────────────────────────────────────────────────→ Upsert Track/Album
              (UI 通过 @Query 自动看到增量出现)

3. 文件监视 ─→ watch=true 的 ScanRoot 用 DispatchSource / FSEvents
              ├ 新增文件 → 走步骤2
              ├ 修改文件 → 重新读元数据, 保留 playCount/liked
              └ 删除文件 → Track 标记 .unavailable(不立即删, 保留用户数据)

4. 导入单文件/多选 ─→ 同步骤2, 但 ScanRoot 为"散集", 记录原路径

5. 导入 YouTube 歌单 ─→ YouTubeImportService
   ├ 解析 URL (regex playlist?list=...)
   ├ yt-dlp --flat-playlist --dump-json 拿条目列表(不拉流)
   ├ 建 YouTubeImport + YouTubeImportItem + 懒建 .youtube Track
   └ 异步 enrich YT 条目的封面/专辑(MusicBrainz 按 title+artist)

6. 重新扫描 ─→ 增量: 按 filePath 存在性比对, 仅处理新增/变更
```

要点:
- **`NSMetadataQuery` 优先**:对用户选择的目录,用 Spotlight 索引快速枚举音频文件(比 FileEnumerator 快得多),无法访问时降级到 `FileManager.enumerator`。
- **并发限流**:用 `TaskGroup` + 信号量限到 8,避免大批导入时元数据读取把磁盘/CPU 打满。Apple Silicon 上 8 并发是吞吐与响应的平衡点。
- **enrichment 异步、非阻塞 UI**:扫描先把内嵌元数据写入,曲目立刻出现在封面墙;联网补全在后台跑,命中后封面墙对应位置平滑刷新(`@Query` 自动驱动)。`metadataStatus` 字段让 UI 知道哪些还在补全 / 已缺。
- **删除软处理**:文件消失不立即删 `Track`,因为可能只是外置盘拔了。标 `.unavailable`,UI 灰显;用户在管理界面手动"清理不可用"才真删。
- **YouTube 导入用 flat-playlist**:只拿元数据不拉流,导入几千首歌的歌单也只需几秒;实际流 URL 在播放那一刻才解析(见 §6)。
- **增量扫描**:记 `filePath` + `fileModificationDate`,重新扫描时跳过未变文件。
- **进度可观测**:`LibraryService.scanProgress` 是 `@Observable` 的 `(scanned, total, currentPath)`,UI 显示进度条。
- **全格式 + 高音质**:AVFoundation 原生支持 FLAC/ALAC/OPUS(macOS 14+);OPUS 必要时 `AudioToolbox` 扩展兜底。`AVAudioFile` 以 native format 渲染,不做有损重采样。Hi-Res(24/192)整链路保留高位深,仅在 OutputNode 按设备做高质量 SRC。

## 6. 播放引擎与队列

### 6.1 引擎抽象

```
protocol PlayerEngine: AnyObject {
    var state: PlayerState { get }            // @Observable, UI 绑定
    func load(_ track: Track) async throws
    func play(); func pause(); func toggle()
    func seek(to time: TimeInterval)
    func setVolume(_ v: Float)                // 0...1, 软音量
    func setEQ(_ bands: [EQBand])             // 频段增益
    func installSpectrumTap(_ h: @escaping (SpectrumFrame) -> Void)
}

PlayerState (@Observable)
├ track: Track?               当前曲目
├ isPlaying: Bool
├ position, duration: Double   秒
├ buffering: Bool / bufferRatio
├ source: TrackSource
├ quality: AudioQualityInfo?  (sampleRate, bitDepth, codec, lossless: Bool)
└ error: PlayerError?
```

### 6.2 LocalAudioEngine (AVAudioEngine, 主引擎)

```
AVAudioEngine
  AVAudioPlayerNode ─→ AVAudioUnitEQ (最多 32 段) ─→ AVAudioMixerNode ─→ OutputNode
                        │
                        └─ installTap → 拉原始 PCM
                           ├ FFT (vDSP) → SpectrumFrame (64 频段)
                           └ 缓存波形峰值(整曲预扫描一次)

播放本地文件:
  AVAudioFile(url) 读取 → playerNode.scheduleSegment / scheduleBuffer
  以 file.processingFormat 渲染(保留 native 采样率/位深)
  高音质: 若 sampleRate ≠ 设备, 在 OutputNode 处用高质量 SRC
  独占模式(可选): AVAudioEngine 直连设备 native rate, 绕过系统重采样
```

要点:
- **EQ 自由度最大化**:`AVAudioUnitEQ` 最多 32 段,用户可任意增删频段、调中心频率/带宽/Q;提供预设(Flat/HiFi/Bass Boost/Vocal 等),用户可保存自定义预设;每段增益 ±24dB,`setEQ` 实时生效。Settings 里给图形化 EQ 编辑器。
- **频谱**:用 `installTap` 在 EQ 后抓 PCM,`vDSP.DFT` 算 64 频段幅度,~30fps 推给 `SpectrumFrame`。Now Playing 的频谱条直接绑定。
- **整曲波形预扫描**:首次加载时后台算一次峰值缓存(存 Caches/waveforms/<trackId>),进度条上的缩略波形复用,避免每次重算。
- **seek**:`playerNode.scheduleSegment(atOffset:)` 精确跳转;FLAC/ALAC 大文件用 `framePosition` 精确跳转,不重解码整段。
- **后台播放**:macOS 用 `NSApplication` 代理 + `MPNowPlayingInfoCenter`,后台不暂停。

### 6.3 YouTubeStreamEngine (yt-dlp → AVPlayer, 可选注入 AVAudioEngine)

```
播放 .youtube Track:
  1. 查流URL缓存(videoId → url, expiresAt), 命中且未过期(<6h) → 直接用
  2. 未命中 → 调 yt-dlp:
     yt-dlp -f "bestaudio[ext*=m4a]/bestaudio/best"
            --no-playlist -g <videoUrl>
     拿到 直链 audioURL(带签名, 有时效)
     缓存 (videoId → audioURL, expiresAt)
  3. 优先注入 AVAudioEngine(高音质 + 统一频谱/EQ):
     AVAudioFile(从 audioURL 流式下载到临时 buffer) → playerNode
     ├ 适合短曲/缓冲完整; 长曲需分段缓冲(边下边播, 缓冲水位低于阈值显示 buffering)
  4. 降级: 注入失败/流不稳 → AVPlayer(http url)
     └ AVAudioMix 接系统; EQ/频谱 在该曲不可用, UI 提示"原生模式"
     └ 后台/seek/NowPlaying 全开箱
```

要点:
- **流 URL 缓存**:YouTube 直链 6h 内有效,缓存避免重复调 yt-dlp(慢且易触发限流)。过期或 403 自动重解析。
- **音质选择**:yt-dlp `-f` 选最高音轨(通常 256k AAC 或 Opus 160k)。Settings 可选"高音质"vs"省流"。
- **yt-dlp 依赖**:随应用打包(`Resources/yt-dlp`),通过 `Process` 调用;启动时检查版本提示更新。
- **错误隔离**:yt-dlp 失败(网络/年龄限制/下架)→ `PlayerError.sourceUnavailable`,队列自动跳到下一首,不阻塞。
- **降级是兜底,不是常态**:常态优先注入 `AVAudioEngine`,长流/异常流才降级 `AVPlayer`。

### 6.4 QueueService (本地 + YT 混合队列,与 TIDAL 一致)

```
QueueModel (@Observable)
├ items: [QueueItem]           有序, 每 item 引用一个 Track(当前播放上下文)
├ currentIndex: Int
├ upNext: [QueueItem]          手动加入的"下一首"
├ history: [QueueItem]        播放过的(LRU, 限 200)
└ repeatMode(off/all/one), shuffle: Bool

QueueItem
├ id, track: Track, source: TrackSource
├ queuedAt, fromContext: QueueSource  (.album, .playlist, .import, .search)

行为(与 TIDAL 一致):
- play(track, from collection) → 以该 track 所在集合为"队列上下文", 建 items, 定位到选中曲
- playNext(track) → 插入 upNext 头
- addToQueue(track) → 追加到 upNext 尾
- 播完一首 → 自动从 upNext 优先, 空了再回 items 顺序; 写入 history
- shuffle 打乱 items 顺序(保留原序以恢复)
- repeat all: 到末尾回到头; repeat one: 当前曲循环
- 混合: 一个队列里可同时有 .local 与 .youtube, PlaybackService 按 item.source 选引擎
- 拖拽排序: items / upNext 支持原生 .onMove
- 持久化: 当前队列 + upNext 存 SwiftData, 重启恢复
```

要点:
- **队列上下文**:从专辑点"播放"时,把整张专辑灌进 `items`,定位到选中曲;从 YT 导入点"播放"同理。这让"上一首/下一首"在来源集合内跳转,符合直觉。
- **Up Next 与主队列分离**:`upNext` 是临时插队的,播完即从 `upNext` 取,空了再回 `items` 顺序。TIDAL/Spotify 标准模型。
- **混合队列对引擎透明**:`PlaybackService.advance()` 看下一个 `QueueItem.source`,调对应 `PlayerEngine.load`,切换时优雅淡入淡出(`setVolume` 0→1 over 200ms 或 `scheduleSegment` fade)。
- **跨引擎切换**:不能同时输出,切换时先 `stop` 当前 engine 再 `load` 下一个,~50ms gap 基本无感,可加短暂 crossfade 选项(后续)。

## 7. UI 设计与品牌

### 7.1 品牌系统

从图标提取的调色板:

```
Magenta 主强调  #F090F0  (240,144,240)   主按钮/播放/选中/品牌色
Cyan 副强调    #18A8F0  (24,168,240)    链接/进度条辅/均衡器
Green 强调     #18A818  (24,168,24)     在线/已同步/HiFi 徽标
深底           #0E0E12  近黑微紫        主背景(深色)
次底           #181820                   卡片/侧边栏
浮层            #202028 + .blur          Now Playing 半透明
文字主         #F0F0F0  (240,240,240)
文字次         #888892                   元数据/时间
分隔线          rgba(255,255,255,0.08)

浅色主题:
底 #F7F7FA, 次底 #FFFFFF, 文字主 #1A1A20, 文字次 #6A6A72
强调色 Magenta/Cyan/Green 在两套主题下都适用
```

设计语言:
- **深色主导**(默认),强调色用于点缀而非铺面;大封面主导视觉。
- **渐变取色**(TIDAL 专辑页标志):专辑详情页与 Now Playing 的背景渐变由封面主色动态生成(运行时提取 2-3 主色,生成 `LinearGradient` 从顶到底,叠加深色透明罩保证文字可读)。浅色主题对调(浅色渐变 + 深文字)。
- **高斯模糊 + 深色透明**:Now Playing、队列抽屉、右键菜单用 `.ultraThinMaterial` / 自定义模糊。
- **字体**:系统 SF Pro;标题 `.largeTitle` 粗体,正文 `.body`;数字(时长/位深)用等宽 SF Mono。
- **圆角**:封面 8pt,卡片 12pt,按钮 18pt 胶囊。
- **动效**:封面切换 0.4s 交叉淡入;频谱条 30fps;进度条 `TimelineView` + `trim`;遵守 `Reduce Motion`。

### 7.2 主布局骨架(参考 TIDAL)

```
┌──────────────────────────────────────────────────────────────┐
│ Traffic Lights                                                 │ macOS
├────────────┬──────────────────────────────────────────────────┤
│ Sidebar    │  Content (NavigationSplitView detail)              │
│            │                                                    │
│ Muses ▶    │  ┌──────────────────────────────────────────────┐ │
│            │  │ 顶部栏:  ← →  搜索框          排序/视图切换   │ │
│ ▸ Home     │  ├──────────────────────────────────────────────┤ │
│ ▸ Search   │  │                                                  │ │
│ ▾ My Coll. │  │  内容区(滚动): 封面墙 / 专辑列表 / 歌单网格   │ │
│   ├ Albums │  │                                                  │ │
│   ├ Songs  │  │                                                  │ │
│   ├ Playl. │  │                                                  │ │
│   ├ YT Im. │  │  ← YouTube Imports 管理入口                      │ │
│   └ Liked  │  │                                                  │ │
│ ▸ Settings │  └──────────────────────────────────────────────┘ │
│            │                                                    │
│ ─────────  │ ═══════════════════ PlayerBar (底部固定) ═════════ │
│ [封面 缩略]│  封面 标题/艺术家  ◁  ▶/⏸  ▷  ━━━━●━━━  时长  音量 队列│
│ mini now  │                                                    │
├────────────┴──────────────────────────────────────────────────┤
└──────────────────────────────────────────────────────────────┘
```

- **`NavigationSplitView`**:三栏(侧边栏 / 内容 / 可选详情)。侧边栏 ~220pt,可折叠。PlayerBar ~76pt。内容区占满中间。
- **封面墙网格**:响应式(窄 3 列、中 4-5、宽 6-7),卡片宽高比 1:1 + 下方标题 2 行。
- **侧边栏底部 mini now**:始终显示当前封面缩略 + 标题,点击展开 Now Playing。
- **PlayerBar**:底部 76pt 固定,跨所有页面。左侧封面+元数据,中部进度+控制,右侧音量+队列按钮+全屏按钮。进度条可拖拽 seek,悬停显示时间气泡。
- **队列抽屉**:点 PlayerBar 队列图标,从右侧滑入 320pt 抽屉,叠在内容区上方,显示 Up Next / 主队列 / History 三段,拖拽排序。

### 7.3 专辑详情页(封面主色渐变)

```
┌─────────────────────────────────────────────────┐
│  ↑ 返回                                          │
│                                                  │
│   ┌──────┐                                       │
│   │       │   ALBUM TITLE                        │ ← 渐变背景:
│   │ 大封面 │   Album Artist · 2024 · 12 首        │   顶部 = 封面主色1
│   │       │   [▶ 播放]  [+ 添加]  ⋯              │   底部 = 深底
│   └──────┘   Hi-Res Lossless  24/96 FLAC         │   叠加 .45 黑
│                                                  │
│  ─────────────────────────────────────────────   │
│  #  标题              艺术家      时长   ⋯       │
│  1  ...                                          │ ← 滚动后表头吸顶
│  ...                                             │
└─────────────────────────────────────────────────┘
```

- **背景渐变**:`AlbumArtworkExtractor.dominantColors(art, n=3)` 在加载封面时异步算,生成垂直 `LinearGradient`,叠透明罩保证曲目表可读。
- **大封面**:左上 220×220,阴影;Hi-Res 徽标用 Green 强调色。
- **曲目表**:`List` + 行高 44pt,行内封面缩略 32×32(对合辑)、音质徽标、时长;右键菜单(播放/播放下一首/加入队列/添加到歌单/显示文件/信息)。表头滚动后吸顶。
- **来源标识**:YT 导入的专辑/歌单在标题下加"YouTube Music"徽标。

### 7.4 全屏 Now Playing(频谱/波形/歌词)

Now Playing 视觉模式(主题设置里选):
- **"巨大封面"** — 静止大圆角封面 + 微光。
- **"唱片旋转"** — 圆形封面 + 中心唱片孔 + 播放时旋转(`Angle` 由 `TimelineView` 推进,暂停时停),`matchedGeometryEffect` 从 PlayerBar 封面过渡。

```
┌─────────────────────────────────────────────────┐
│  ✕(收起)          NOW PLAYING              ⏸ ▷  │
│                                                  │
│         ┌──────────────────────┐                  │
│         │      巨大封面/唱片     │  ← 中心          │
│         │     (480×480)         │                  │
│         └──────────────────────┘                  │
│                                                  │
│    ▁▂▃▅▆▇█▇▆▅▃▂▁  频谱(64段, 镜像条形) ▁▂▃       │
│                                                  │
│         Song Title                                │
│         Artist · Album                            │
│         24/96 Hi-Res Lossless                     │
│                                                  │
│    ━━━━━━━━━━●━━━━━━━━━━━━━━━   1:23 / 3:45      │
│                                                  │
│         [歌词区: 当前行高亮, 上下行淡出]          │
└─────────────────────────────────────────────────┘
```

- **进入**:点 PlayerBar 封面或全屏按钮,封面从小到大放大转场(`matchedGeometryEffect`),背景渐变接管整个窗口。
- **频谱样式**:对称镜像条形频谱 — 64 段从中线向上下两侧延伸,上半 Magenta→Cyan、下半镜像半透明,峰值带 200ms 衰减残留;`Reduce Motion` 降为静态波形。
- **波形**:进度条上方叠加整曲波形缩略(预扫描缓存),已播放部分填 Magenta,未播放部分灰。
- **歌词**:三行可见,当前行 `.title2` 加粗高亮 + Magenta,上下行 `.subheadline` 半透明,随 `position` 滚动;无歌词时显示"无可用歌词,点此搜索"(调 LyricsService 联网补)。
- **手势**:左右拖拽 seek;上滑展开队列抽屉;空格播放/暂停。
- **降级模式**:YouTube 走 AVPlayer 时,频谱条改用"假动画"(随音量/节拍估算),提示"原生模式 — 频谱不可用"。

### 7.5 YouTube Imports 管理视图

```
My Collection ▸ YouTube Imports
┌─────────────────────────────────────────────────┐
│  [+ 导入 YouTube 歌单链接]                        │
│                                                  │
│  ┌──────┐  Playlist Title                         │
│  │ 封面 │  Channel · 87 首 · 上次同步 2天前       │
│  └──────┘  [重新同步] [在 YT 中打开] [删除] [▶]   │
│  ─────────────────────────────────────────────   │
│  ▾ 展开条目                                      │
│    1  Song A   Artist   3:21   [▶][加入队列][⋯]   │ ← YT 条目
│    2  ...                                        │
│  ── 本地附加 ──(仅本地显示, 不同步回 YT)──        │
│    + Song X  Local   4:02   [移除]                │ ← 本地附加(本地徽标)
│    [+ 添加本地歌曲到此歌单]                       │
└─────────────────────────────────────────────────┘
```

- **导入**:顶部按钮弹出输入框,粘贴 URL,调 `YouTubeImportService`。
- **同步**:按钮调 YT Data API v3(若已登录且可写);只读则只刷新本地镜像并提示。
- **本地附加区**:独立分组,视觉用 Green 徽标"本地"区分,永不调 YT 写 API。
- **删除**:删 `YouTubeImport` 及其镜像条目,保留已生成的 `.youtube` Track(用户可能已在队列/歌单中引用),提示是否一并清理。

### 7.6 设置

- **Library**:ScanRoots 列表(增删、开启监视)、重新扫描、清理不可用项。
- **音质**:本地 native / 独占模式开关;YouTube bestaudio / 省流。
- **EQ**:图形化 32 段编辑器(频率/增益/Q),预设管理(内置 + 自定义保存)。
- **歌词**:默认源(LRCLIB/NetEase/本地优先)、自动补全开关。
- **YouTube**:yt-dlp 路径(默认随应用)、版本检查、登录态(YT 同步用,可选)。
- **主题**:深色 / 浅色 / 跟随系统;Now Playing 模式(巨大封面 / 唱片旋转)。
- **关于**:Muses 版本、logo、合规声明(个人使用、非 App Store)。

## 8. 系统集成、错误处理与测试

### 8.1 系统集成

```
MPNowPlayingInfoCenter / MPRemoteCommandCenter (MediaPlayer)
├ 每次曲目/状态/进度变化 → 更新 nowPlayingInfo
│   (title/artist/album/artwork/duration/elapsedTime/playbackRate)
├ 暴露命令: play/pause/next/prev/seek/seekForward/seekBackward
│   └ 全部转发给 PlaybackService
└ 媒体键(F8/F9/F10/F11/F12) → 自动通过 MPRemoteCommand 触发

NSUserActivity / Spotlight
├ 索引: Track/Album 进 Spotlight, 可搜"播放 XXX"
├ 继续播放: app 启动恢复队列(NSUserActivity 持久化 currentIndex)

文件打开
├ 注册 .mp3/.flac/.opus 等为 Muses 可打开类型
└ 拖拽文件到窗口 → 导入到 Library(走 §5 步骤4)

URL Scheme (可选, v2)
└ muses://import?url=<yt playlist url> → 触发 YT 导入
```

### 8.2 错误处理

统一 `PlayerError` / `LibraryError` / `ImportError` 枚举,UI 通过 `@Observable` 的 `lastError` 单点消费。

```
PlayerError
├ .sourceUnavailable        (yt-dlp 失败/下架/年龄限制)
├ .networkError(Error)      (流解析/缓冲失败)
├ .fileMissing(String)      (本地文件已删/移动)
├ .decodingFailed(String)    (格式损坏/OPUS 兜底仍失败)
├ .engineStartFailed        (AVAudioEngine 启动失败)
└ .rateLimited               (YT 拉流被限流)

行为策略:
├ 播放失败 → 自动跳下一首(最多连续 3 次后停止, 防全军覆没)
├ 文件缺失 → Track 标 .unavailable, 队列灰显, 不自动跳(用户可能想修)
├ 解码失败 → 先尝试 AudioToolbox 兜底; 仍失败标 .unavailable
├ engineStartFailed → 提示"音频设备占用/重启", 提供重试
├ rateLimited → 退避 30s, 提示"稍后重试", 队列暂停
└ 所有错误写入 Diagnostic 日志(~/Library/Logs/Muses/)

yt-dlp 失败细分:
├ 解析失败(返回空)→ .sourceUnavailable
├ HTTP 403/429 → .rateLimited
└ 超时(>15s)→ .networkError
```

- **错误非阻塞**:不打断队列主流程,失败项标记后跳过,用户在播放历史能看到"未播放"。
- **可恢复优先**:`AVAudioEngine` 偶发崩溃(设备热插拔)→ `reset` + `prepare` + 重 `load` 当前曲目,无缝恢复。

### 8.3 日志与诊断

- **`Logger`**:`os.Logger`(`subsystem: "com.muses.app"`),分级 `debug/info/notice/warning/error`;Release 构建 `info+` 进统一日志,`debug` 仅本地。
- **诊断包**:设置里"导出诊断"按钮 → 打包最近日志 + Library 元数据摘要(不含曲目内容)到 zip,供问题反馈。
- **崩溃**:集成 `MetricKit` + 自定义 `uncaughtExceptionHandler`,崩溃记录到诊断目录。

### 8.4 测试策略

```
单元测试 (XCTest)
├ MetadataService
│   ├ 内嵌读取(用 fixture 文件: mp3/flac/opus 各一个)
│   └ enrich 命中/未命中/mock 网络
├ LibraryService
│   ├ 扫描增量(新增/变更/删除)
│   └ 并发限流(TaskGroup 行为)
├ QueueService
│   ├ play/playNext/addToQueue/shuffle/repeat 状态机
│   ├ 上下文构建(专辑/歌单/YT导入)
│   └ 持久化恢复
├ YouTubeImportService
│   ├ URL 解析/flat-playlist 解析(mock yt-dlp 输出)
│   └ 同步(只读/可写 mock)/本地附加不触发写
└ LyricsService
    ├ .lrc 解析(时间戳对齐)
    └ 联网补全 mock

集成测试
├ LocalAudioEngine: 加载 fixture → play → 验证 position 推进/seek/EQ 生效
├ SpectrumTap: 验证 SpectrumFrame 帧率与非零幅度
├ yt-dlp 桥: 用 --version 与一个公开视频 mock, 验证流URL缓存/过期
└ MPNowPlaying: 状态变化触发 info 更新(mock)

UI 测试 (XCTestUI)
├ 主布局渲染(侧边栏/内容/PlayerBar 存在)
├ 点封面进 NowPlaying → 退回
├ 队列抽屉拖拽
└ 设置主题切换(深/浅)渲染差异(快照测试)

性能
├ 大 Library(10k 曲)扫描耗时目标 < 60s
├ 封面墙滚动 60fps(Instruments)
└ Now Playing 频谱 CPU < 8% (M1)
```

- **fixture 工程**:`Tests/Fixtures/` 放 3 个小音频 + 1 个 .lrc + 1 个 mock yt-dlp JSON 输出。
- **快照测试**:用 XCTest 原生对比图像哈希(避免新依赖)。UI 主题/深浅切换覆盖。
- **不测的部分**:`yt-dlp` 实际网络(慢且不稳),全用 mock;`AVAudioEngine` 输出音频不测声音,只测状态与频谱数据。

## 9. 项目结构、依赖与构建

### 9.1 目录结构

```
Muses/
├ App/
│   ├ MusesApp.swift                入口、AppDelegate、Sparkle 初始化
│   ├ RootView.swift                NavigationSplitView 主布局
│   └ Info.plist                    文件类型/URL scheme(后续)/隐私
├ Features/
│   ├ Library/
│   │   ├ LibraryView.swift         专辑/歌曲/歌单网格
│   │   ├ AlbumDetailView.swift     封面主色渐变 + 曲目表
│   │   ├ AlbumArtworkExtractor.swift 封面主色提取(运行时)
│   │   └ SidebarView.swift         导航 + mini now
│   ├ YouTube/
│   │   ├ YouTubeImportsView.swift  管理视图
│   │   ├ ImportSheet.swift         粘贴 URL 导入
│   │   └ YouTubePlaylistDetailView.swift
│   ├ Playback/
│   │   ├ PlayerBar.swift           底部固定
│   │   ├ NowPlayingView.swift      全屏(封面/唱片模式)
│   │   ├ SpectrumView.swift        镜像条形频谱
│   │   ├ WaveformView.swift        整曲波形
│   │   └ QueueDrawer.swift        Up Next/队列/历史
│   ├ Lyrics/
│   │   └ LyricsView.swift          滚动对齐
│   ├ Settings/
│   │   ├ SettingsView.swift
│   │   ├ LibrarySettingsView.swift
│   │   ├── AudioQualitySettingsView.swift
│   │   ├── EQSettingsView.swift    32段图形化
│   │   ├── LyricsSettingsView.swift
│   │   ├── YouTubeSettingsView.swift
│   │   └── ThemeSettingsView.swift 深浅/Now Playing 模式
│   └ Search/
│       └ SearchView.swift
├ Domain/                          纯模型, 无框架依赖
│   ├ Track.swift  Album.swift  Playlist.swift
│   ├ YouTubeImport.swift  YouTubeImportItem.swift
│   ├ QueueItem.swift  PlayerState.swift  SpectrumFrame.swift
│   └ Enums.swift                   TrackSource/AudioQuality/RepeatMode/...
├ Services/
│   ├ Playback/
│   │   ├ PlayerEngine.swift        protocol
│   │   ├ LocalAudioEngine.swift    AVAudioEngine + EQ + tap
│   │   ├ YouTubeStreamEngine.swift yt-dlp→AVPlayer/AVAudioEngine
│   │   ├ PlaybackService.swift     统一调度 + 跨引擎切换
│   │   └ SpectrumTap.swift         vDSP 频谱
│   ├ Library/
│   │   ├ LibraryService.swift      扫描/导入/索引
│   │   ├ DirectoryScanner.swift    NSMetadataQuery/FileEnumerator
│   │   └ MetadataService.swift     内嵌读+联网补全
│   ├ YouTube/
│   │   ├ YouTubeImportService.swift flat-playlist 解析+管理
│   │   ├ YtdlpBridge.swift         Process 调用 + 流URL缓存
│   │   └ YouTubeSyncService.swift  YT Data API v3(可选写)
│   ├ Lyrics/
│   │   └ LyricsService.swift       .lrc + LRCLIB/NetEase
│   ├ Queue/
│   │   └ QueueService.swift        混合队列 + Up Next
│   ├ Metadata/
│   │   ├ AppleMusicClient.swift   artwork/专辑补全
│   │   └ MusicBrainzClient.swift  兜底
│   └ Integrations/
│       ├ NowPlayingManager.swift   MPNowPlayingInfo/RemoteCommand
│       └ SpotlightIndexer.swift
├ Persistence/
│   ├ MusesModelContainer.swift     SwiftData container
│   └ SchemaV1.swift               版本化 schema
├ Infrastructure/
│   ├ Networking/  HTTPClient, 限流, 缓存
│   ├ ArtworkCache/                 ~/Library/Caches/Muses/artwork
│   ├ WaveformCache/                ~/Library/Caches/Muses/waveforms
│   ├ StreamURLCache/               YT 流URL(<6h)
│   └ Logging/  Logger, DiagnosticExporter
├ Resources/
│   ├ yt-dlp                        随应用打包二进制 + LICENSE
│   ├ Assets.xcassets               AppIcon, AccentColor, 品牌色
│   └ logo-and-icon/                原始 logo/icon
├ Tests/
│   ├ MusesTests/                   单元/集成
│   └ MusesUITests/                 UI + 快照
├ Scripts/
│   └ copy-ytdlp.sh                 构建脚本: 下载 arm64 yt-dlp 到 Resources
├ Muses.xcodeproj
└ docs/
    └ superpowers/specs/2026-08-11-muses-music-player-design.md
```

要点:
- **`Domain/` 纯模型**:无 SwiftUI/Foundation 之外的引用,易测。
- **`Features/` 按业务域分**:每个子目录内文件专注单一视图。
- **`Services/` 同域内分文件**:`Playback/` 拆 5 个文件而非一个巨类,每个可独立理解测试。
- **`Infrastructure/` 收所有 I/O 副作用**:缓存、网络、日志,Services 依赖协议而非具体实现,便于注入 mock。

### 9.2 外部依赖

```
Sparkle                 自动更新        SPM, com.sparkle.project
swift-collections      高效队列/OrderedCollections   SPM
(其余全用 Apple 原生框架)
```

- **刻意最小化依赖**:AVFoundation/AudioToolbox/SwiftData/MediaPlayer/SwiftUI/vDSP/`os.Logger`/MetricKit 全原生。Sparkle 是唯一非原生必需依赖。
- **yt-dlp 不是 Swift 依赖**:随应用打包的可执行二进制,通过 `Process` 调用,版本独立管理。
- **不引入第三方音频库**(如 AudioKit):原生 `AVAudioEngine` 足够。
- **网络客户端自写**:基于 `URLSession`,无需 Alamofire。

### 9.3 构建与分发

```
工具链: Xcode 16+, Swift 5.10+, macOS 14 SDK
部署: macOS 14+ (Sonoma), Apple Silicon 原生(arm64);不构建 x86_64
签名: Developer ID Application 证书
公证: xcrun notarytool submit + staple
打包: .app + yt-dlp 二进制嵌入 Resources(需 chmod +x, 签名并入)
Sparkle: appcast.xml 发布频道, EdDSA 签名, delta 更新
发布渠道: GitHub Releases(arm64 .dmg/.zip)
CI: GitHub Actions(macos-14), 单元+UI+签名+公证
```

- **最低部署 macOS 14**:用上 SwiftData 最新特性、`AVAudioEngine` 改进、`@Observable`。Apple Silicon 原生。
- **yt-dlp 二进制处理**:`Scripts/copy-ytdlp.sh` 下载 arm64 yt-dlp 到 Resources,`chmod +x`,纳入代码签名(`codesign --force -s`)。CI 自动拉取最新版。
- **Sparkle 集成**:`SUEnableInstallerLauncherService` + EdDSA 签名的 appcast;更新包用 Developer ID 签名公证。
- **诊断/日志路径**:`~/Library/Logs/Muses/`、`~/Library/Caches/Muses/`,遵循 macOS 约定。

## 10. 实施阶段

```
阶段 1 — 本地播放骨架(最高优先)
  ├ 项目骨架 + Domain + SwiftData schema
  ├ LibraryService 扫描 + MetadataService 内嵌读取
  ├ LocalAudioEngine + PlaybackService + 队列
  ├ 主布局 + PlayerBar + AlbumDetailView
  └ 单元/集成测试

阶段 2 — TIDAL 体验层
  ├ Now Playing(封面/唱片模式) + 频谱 + 波形
  ├ 队列抽屉 + Up Next + 持久化恢复
  ├ NowPlayingManager + 媒体键 + Spotlight
  ├ EQ 32段 + 设置
  └ 联网元数据补全(Apple Music/MusicBrainz)

阶段 3 — 在线与同步
  ├ yt-dlp 桥 + YouTubeStreamEngine(注入 AVAudioEngine, 降级 AVPlayer)
  ├ YouTubeImportsView + 导入 + 管理 + 本地附加
  ├ YT Data API v3 同步(可选写)
  ├ LyricsService(.lrc + LRCLIB/NetEase) + 歌词视图
  └ Sparkle 自动更新 + 签名公证 + GitHub Release

阶段 4 — 打磨
  ├ 主题(深/浅/跟随系统)
  ├ 性能调优(大 Library/封面墙/频谱)
  ├ 快照测试 + 诊断导出
  └ 合规审查 + 文档
```

要点:
- **阶段 1 即可独立可用**:本地播放器完整闭环,不阻塞等待 YouTube。
- **阶段 3 引入合规敏感功能**:此时再做签名公证分发。
- **每阶段可演示**:阶段结束产出可运行的 .app。