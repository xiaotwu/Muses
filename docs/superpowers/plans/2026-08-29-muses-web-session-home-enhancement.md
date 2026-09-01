# Muses 隔离式 Web Session Home 增强实施计划

- **状态：** 已批准并实施中；方案 A 自动化、打包签名及默认浏览器运行态门禁已通过，真实 Cookie / VoiceOver / 服务条款验收待完成。
- **日期：** 2026-08-29
- **对应评审项：** P0-1 / UI-1
- **批准方向：** A+B——官方账号、公共发现和本地信号是稳定基线；登录态 YouTube Music Web Session 仅为可关闭、可失效、可回退的增强。
- **实施方式：** 本计划确认后，在独立 Codex 对话中实施。

## 1. 目标与完成定义

目标是在不削弱当前稳定 Home 的前提下，加入真实的登录态 YouTube Music Home 区段：快速精选、Mix、继续收听、新发行、编辑推荐以及来源提供的后续 shelves。

只有同时满足以下条件，UI 才能显示“源自 YouTube Music 个性化”：

1. 用户明确启用 Web Home 增强。
2. Google OAuth 已连接，存在稳定的活动 `channelID`。
3. Web 会话可用，并从会话自身解析出频道身份。
4. Web 频道与活动 OAuth `channelID` 完全一致。
5. payload 形状、协议版本、媒体身份和区段完整性校验通过。

任意条件不满足时，Home 仍正常使用官方账号 + 公共发现基线；不得出现空白页，也不得把基线内容描述成真实 YouTube Music 个性化首页。

## 2. 明确不做的事情

- 不使用 WKWebView 或 YouTube IFrame 作为 Home 数据、登录或播放引擎。
- 不把 Web 会话用于播放授权、YouTube Push、资料库真相或后台写操作。
- 不以 OAuth access token 冒充 YouTube Music Web 会话。
- 不把 Cookie、`SAPISIDHASH`、原始 Web payload 或 continuation token 写进日志、诊断文件、普通缓存或 SwiftData。
- 不在未获得独立同意时复用当前“仅供 yt-dlp 播放”的 Cookie 设置。
- 不引入新的持久数据库或长期迁移链。
- 不在第一版恢复多账号同时在线；仍只允许一个活动账号。

## 3. 当前源码基线与缺口

已经具备：

- `HomeSource.signedInWeb`、账号 scope、来源/新鲜度元数据和 `HomeSnapshot` manifest。
- `LayeredHomeProvider` 对空结果、失败、schema 不合法和账号不匹配的整体拒绝。
- guest / account 物理缓存隔离、账号切换取消和晚到结果拒绝。
- Home 顶部来源状态、已保存状态、重试动作和稳定基线。
- 当前打包的 yt-dlp 版本为 `2026.08.19`。[yt-dlp 官方 FAQ](https://github.com/yt-dlp/yt-dlp/wiki/FAQ)确认 `--cookies-from-browser <browser> --cookies <file>` 可以把浏览器 Cookie 导出为 Netscape Cookie 文件。

实施前必须补齐：

1. `MusesApp` 当前仍注入 `webEnhancement: nil`，没有真实适配器。
2. `HomeDiscoveryProvider` 通过可变属性暴露 capability，并只返回 `[HomeSection]`；一次调用的内容、失败和缓存策略不是原子结果。
3. Web 失败目前可能返回纯基线，并被当作成功写回组合缓存，覆盖同账号最后成功的 Web 快照。
4. `HomeFeedCache` 按账号隔离，但未按 `baseline` / `web` 来源物理分区。
5. `HomeSection` / `YouTubeDiscoveryCard` 尚未完整表达 browse/play endpoint、可用性和稳定 Web 区段身份。
6. 当前 Cookie 设置在产品文案和代码契约上只允许服务 yt-dlp 播放，不能静默扩权。
7. 当前 app bundle 只包含主可执行文件和 yt-dlp；构建、签名与验证脚本尚未支持独立 helper。

## 4. 架构选择

### 方案 1：独立的一次性 Helper 进程（推荐）

主应用通过版本化 JSON stdin/stdout 协议启动 `MusesWebHomeHelper`。Helper 读取会话、完成请求、解析原始 payload，只返回不可变、已归一化的值快照，然后立即退出。

优点：

- Cookie、鉴权 header 和原始私有 payload 不进入 SwiftUI 或主应用服务图。
- 私有格式解析崩溃、超时、内存异常和协议漂移不会拖垮主应用。
- 可以设置严格的进程超时、输出大小、协议版本和签名门禁。
- 未来可以单独替换或关闭适配器，不影响官方基线。

成本：

- Swift Package、app bundle、签名、调试脚本和测试结构都需要增加 helper 支持。
- IPC、取消和错误映射比进程内 URLSession 多一层。

### 方案 2：主应用内的隔离 URLSession

使用独立 actor、ephemeral `URLSessionConfiguration` 和私有 Cookie store，但仍运行在 Muses 主进程内。

优点是实现和打包较少；缺点是凭证与 payload 仍进入主进程，解析异常和内存峰值也没有真正隔离。它满足“严格容器”但不满足更强的故障边界。

**建议选择方案 1。** P0 功能的私有接口波动和凭证敏感度足以证明独立进程的成本合理。

## 5. 目标模块划分

新增三个窄 target，避免主应用依赖解析实现：

1. `MusesWebHomeProtocol`
   - 仅包含 `Codable + Sendable` IPC 请求、响应、错误码和版本号。
   - 不包含 Cookie、网络或 SwiftUI 代码。
2. `MusesWebHomeCore`
   - Helper 内使用的 Cookie jar、Web client、账号身份解析、payload parser 和归一化逻辑。
   - 主应用 target 不依赖它。
3. `MusesWebHomeHelper`
   - 一次性可执行入口；从 stdin 解码一个请求，输出一个响应后退出。

主应用新增：

- `WebHomeHelperClient`：启动、超时、取消、输出限额、错误映射、签名/路径检查。
- `WebHomeEnhancementProvider`：把 helper 响应转换为 `.signedInWeb` source snapshot。
- 调整后的 `LayeredHomeProvider` / `HomeDiscoveryService`：组合 baseline 与 Web layer，但分别缓存。

## 6. IPC 与安全边界

### 请求

请求至少包含：

- `protocolVersion`
- action：`probeSession`、`fetchHome` 或 `fetchContinuation`
- 预期 OAuth `channelID`
- Cookie source descriptor（用户确认时绑定的 Safari / Chrome / Firefox 类型）
- locale、region、超时预算
- 仅在同一活跃进程内使用的 continuation handle

Cookie source descriptor 通过 stdin 传递，不放入进程参数；Cookie 内容永不跨 IPC。

### 响应

响应只包含：

- helper/protocol/parser schema 版本
- Web 会话实际解析到的 `channelID`
- 获取时间、建议过期时间和能力状态
- 已归一化的区段、稳定媒体身份、标题、副标题、布局类型、browse/play endpoint、 artwork 与 availability
- 结构化且不含敏感内容的错误码

### 进程约束

- 一次请求一个 helper；默认 12 秒超时，可取消并终止。
- stdout 最大 10 MiB；超限、非 JSON、协议版本不符或多余输出全部拒绝。
- stderr 只允许已脱敏诊断；生产日志不记录请求体、响应体、Cookie 名值或 URL 查询参数。
- Helper 路径固定在签名后的 app bundle 内；不从 `PATH` 加载同名程序。
- 临时 Cookie 目录权限 `0700`、文件 `0600`，使用后立即删除；异常退出时由下次启动的限定目录清理器回收。
- Cookie 文件不经 shell、环境变量或命令行参数传递给主应用。

## 7. 会话获取与账号核验

### 用户授权

在 YouTube 设置中新增独立开关：

`使用已登录的 YouTube Music Web 会话增强首页`

- 默认关闭。
- 开关旁明确说明读取范围、仅本机处理、可能失效、不会用于播放或写入。
- 启用时自动识别 macOS 默认浏览器；仅 Safari、Chrome、Firefox 可作为首版来源，并在读取前显示一次独立确认。
- 确认绑定当时显示的浏览器类型；之后更改系统默认浏览器不会静默切换来源，必须先关闭 Web Home 再重新连接。
- 播放/导入使用的 yt-dlp Cookie 来源保持独立；Web Home 不读取、不复用也不改写该选择。
- 提供“检查会话”“打开 YouTube Music”“关闭并清除临时会话”动作。

### Cookie 获取

- 浏览器来源：Helper 调用 bundle 内固定版本的 yt-dlp，将 Cookie 导出到权限受限的临时 Netscape jar，再由 Helper 读取并删除。
- 默认浏览器探测只读取 macOS 的 HTTPS handler 与应用 bundle identity；不会启动浏览器或读取 profile。
- 不把任意 Chromium 衍生浏览器静默映射为 Chrome；暂不支持时给出可恢复提示。
- 不复制 Cookie 到 UserDefaults、Home cache、SwiftData 或 Keychain。

### 账号一致性

- Web client 先请求账号菜单/身份 endpoint，得到活动 Web channel ID。
- 只有 `webChannelID == oauthChannelID` 才允许继续获取 Home。
- 无法稳定解析身份按 `identityUnavailable` 处理；不能通过显示名、头像或邮箱猜测。
- 不一致时 UI 显示“Web 会话属于另一个频道”，并提供在浏览器切换账号后重试；不展示该 Web payload，也不删除另一账号的休眠缓存。

## 8. Web 请求与解析策略

Helper 负责以下步骤：

1. 获取 `music.youtube.com` bootstrap HTML。
2. 提取当前 Web client version、API key、visitor data 和必要 context。
3. 从 Cookie 生成请求所需的短期鉴权 header；只保留在 Helper 内存。
4. 核验 Web channel ID。
5. 请求 Home browse endpoint。
6. 通过白名单 parser 处理已支持 renderer，跳过未知 renderer。
7. 将结果归一化为协议值；原始 payload 在响应前释放。

解析规则：

- 首版支持经过 fixture 覆盖的 carousel、music shelf、grid/quick-pick 和 continuation shelf。
- 以 browse/video/playlist/channel ID 作为身份；显示名绝不作为合并主键。
- 未知 renderer 可以跳过；核心容器、身份或超过阈值的结构缺失会使整个 Web 快照 `shapeChanged`，绝不返回半可信内容。
- 区段 ID 使用来源 endpoint + renderer identity 的稳定哈希，不与基线硬编码标题绑定。
- continuation token 只保存在 helper-client 的短期内存句柄中，不写磁盘；从已保存快照启动时先刷新，成功后才恢复“加载更多”。

## 9. Provider 与缓存重构

### 原子调用结果

把“区段数组 + 事后读取可变 capability”改为一次调用返回的值：

```text
HomeFetchResult
├── baselineSnapshot
├── webSnapshot?
├── webCapability
├── failures[]
└── cacheDirectives
```

这样一次刷新中的内容、状态和缓存策略不会互相错位，也避免并发请求覆盖 capability。

### 来源分区

缓存目录调整为：

```text
home-feed/
├── guest/baseline/
└── account-<channel-id>/
    ├── baseline/
    └── web-v1/
```

- 旧组合 Home cache 是可重建数据，版本升级时直接失效，不迁移。
- baseline 默认新鲜 30 分钟。
- Web 默认新鲜 15 分钟；最后成功快照最多作为 stale 显示 7 天。
- Web 失败只更新 capability/失败原因，不覆盖或删除最后成功的同账号 Web 快照。
- 注销后清除 helper 与内存 continuation；磁盘快照休眠。相同 channel 再登录才可恢复。
- 账号切换立即取消两个 layer 的任务；所有写入前再次比较捕获 scope。

### 精确降级顺序

1. 同账号、新鲜的实时 Web snapshot + 最新 baseline。
2. 同账号、未超过 stale 上限的最后成功 Web snapshot，标记“已保存”并展示失败原因 + 重试。
3. 官方账号 + 公共发现 + 本地信号 baseline。
4. baseline 自身失败时使用其已有 SWR 缓存和每区段重试；仍不产生空白页。

## 10. UI 与交互

### 设置

- 独立 Web Home section，不与 OAuth 权限或播放 Cookie 混写。
- 自动显示检测到的默认浏览器；支持的来源在单独确认后固定到断开 Web Home 为止。
- 状态：关闭、待检查、可用、刷新中、会话过期、账号不匹配、格式变化、暂不可用。
- 明确数据用途和撤销路径；关闭开关立即停止 helper、清除临时文件和内存 token。
- “清除已保存的个性化首页”只删除当前账号 Web cache，不影响 OAuth、播放 Cookie、资料库或 baseline cache。

### Home

- `.available`：显示“YouTube Music 个性化 · 账号名”。
- `.saved`：显示“已保存的 YouTube Music 个性化”、更新时间、原因和重试。
- `.unavailable` / `.rejected`：显示官方账号 + 公共发现，不夸大来源；提供非阻断恢复动作。
- 每个 section 继续显示实际 source；混合页面不隐藏来源差异。
- 新增状态、按钮和错误文本全部支持即时中英文、键盘、VoiceOver、高对比度与 Reduce Transparency。

## 11. 错误模型与可观测性

结构化错误至少区分：

- `disabled`
- `oauthRequired`
- `cookieSourceUnavailable`
- `sessionExpired`
- `consentOrCaptchaRequired`
- `identityUnavailable`
- `accountMismatch`
- `shapeChanged`
- `rateLimited`
- `offline`
- `timedOut`
- `helperCrashed`
- `protocolMismatch`
- `responseTooLarge`
- `malformedResponse`

只记录本地脱敏事件：尝试、成功、使用 stale、回退、拒绝原因分类、耗时和 parser schema；不记录账号 ID、标题、视频 ID、Cookie 或原始 URL。

## 12. 分阶段实施顺序

### Phase 1 — 契约与来源缓存

- 引入原子 `HomeFetchResult`。
- 拆分 baseline/Web cache。
- 修复 Web 失败覆盖最后成功快照的问题。
- 增加 TTL、stale 上限、账号切换与退出测试。

**门禁：** 不接真实 Web 也能跑完全部现有测试；Home 行为与当前版本一致。

### Phase 2 — Helper 骨架与 IPC

- 新增 protocol/core/helper targets。
- 完成固定路径启动、stdin/stdout、超时、取消、输出限额、错误映射。
- 更新 debug/release bundle、签名、验证和打包脚本。

**门禁：** 假 helper 的成功、超时、崩溃、恶意超大输出和协议错版测试全部通过；bundle 内 helper 签名验证通过。

### Phase 3 — Cookie 与身份探测

- 新增显式设置与同意流程。
- 自动识别受支持的 macOS 默认浏览器，并与播放 yt-dlp Cookie 设置物理分离。
- 实现 yt-dlp 临时 Cookie jar、权限和清理。
- 实现 bootstrap、账号身份解析与 exact channel match。

**门禁：** 不匹配账号、过期 Cookie、缺少浏览器权限和取消都只降级，不污染缓存。

### Phase 4 — Home parser 与归一化

- 用去标识 fixture 实现 renderer 白名单、媒体身份、区段身份和 availability。
- 实现 shape version 和完整性阈值。
- 接入 `WebHomeEnhancementProvider`。

**门禁：** fixture、shape drift、未知 renderer、重复视频、缺失字段和账号污染测试通过。

### Phase 5 — UI、continuation 与恢复

- 完成设置状态、Home 来源、stale banner、重试、清缓存和 continuation。
- 验证关闭、断网、过期、账号 A→B、晚到结果和重新登录同账号。

**门禁：** 当前 baseline 不发生视觉/行为回归；所有 Web 状态都可键盘和 VoiceOver 操作。

### Phase 6 — 发布验收

- 全量单元/集成测试、构建、签名、冷启动、崩溃恢复和日志脱敏检查。
- 使用专门测试账号完成真实 Home、断网、Cookie 过期、账号不匹配、shape fixture 录制和 7 天 stale 时钟模拟。
- 完成服务条款/分发风险复核；保留构建级 kill switch 和用户级关闭开关。

## 13. 测试矩阵

自动化测试至少覆盖：

- IPC 编解码、协议版本、超时、取消、崩溃、输出上限。
- Cookie 临时文件权限、正常删除、异常遗留清理和日志脱敏。
- session identity 成功、缺失、A/B 不匹配和 OAuth 退出。
- parser 支持的每种 renderer、未知 renderer、空 section、重复媒体、缺失 ID、不可用媒体和 continuation。
- live Web → stale Web → baseline 的严格降级顺序。
- Web 失败不覆盖成功 Web cache；baseline/Web 物理隔离。
- guest、账号 A、账号 B、A 请求晚到、注销和同账号重新登录。
- 关闭 Web feature 后不启动 helper、不读 Cookie、不展示 Web 来源。
- 设置与 Home 的中英文、VoiceOver label/value、键盘焦点、高对比度。
- debug/release helper 嵌入、签名、notarization 前检查和无 helper 回退。

真实环境矩阵：

| 状态 | 预期 |
|---|---|
| 未连接 OAuth | 不读取 Web Cookie；显示 guest baseline |
| OAuth 已连接、Web 未启用 | 官方账号 + 公共发现 |
| Web 已启用、同账号有效 | 实时个性化 Web sections + baseline |
| Web 断网/超时 | 同账号 stale Web + baseline；可重试 |
| Cookie 过期/需要验证码 | stale/baseline；明确恢复提示 |
| Cookie 账号与 OAuth 不同 | 拒绝 payload；baseline；不触碰两边缓存 |
| payload shape 变化 | 整体拒绝 Web snapshot；记录 schema 类别；baseline |
| 注销 | 立即停止 helper；隐藏账号内容；缓存休眠 |
| A→B 切换 | A 的晚到结果不能写入 B；只读 B 的命名空间 |

## 14. 回滚与发布保护

- 用户级开关默认关闭。
- 构建级开关可完全不注入 `WebHomeEnhancementProvider`。
- Helper 缺失、签名异常、协议错版或连续失败都回到 baseline，不影响启动。
- Web cache 可独立删除，不触碰用户真相。
- 私有格式变化只更新 helper/parser；主 UI、播放、同步和资料库无需跟随改写。

## 15. 已批准的三项决策

用户于 2026-08-29 批准全部推荐项：

1. **隔离方式：** 使用独立的一次性 Helper 进程，不采用主进程内的 ephemeral URLSession。
2. **授权方式（2026-08-30 更新）：** Web Home 默认关闭；自动识别 Safari、Chrome 或 Firefox 这一系统默认浏览器，并在独立确认后绑定该来源。不得复用或改写播放用 yt-dlp Cookie source，也不得在默认浏览器变化后静默切换。
3. **stale 保留：** 同账号 Web 快照新鲜 15 分钟，最多以“已保存”状态展示 7 天。

实施任务不得跳过 Phase 1 的缓存/结果契约修复，也不得在真实账号验收前宣称 P0-1 完成。
