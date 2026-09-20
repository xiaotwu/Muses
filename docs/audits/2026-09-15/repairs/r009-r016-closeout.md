# R009／R016 目录与 Home 续修记录

日期：2026-09-17，2026-09-19 更新。本文区分代码修复、真实只读网络证据和仍需人工条件的产品验收，不把固定夹具或编译结果写成真实服务验收。

## 本轮完成

- R009 顶层搜索筛选固定为歌曲、视频、专辑、艺人、歌单、播客六类；播客单集只作为节目详情中的 browse 内容，不再显示为第七类顶层搜索源。
- 目录 parser 接受 `musicCardShelfRenderer`，继续按官方 endpoint 的 pageType／musicVideoType 判定类型；未知 renderer、未知类型和缺失稳定 ID 仍 fail closed。
- Home 全局 continuation 和 shelf continuation 都校验当前账号 scope、推荐模式和操作代号；离开 Home、切换账号或切换 Muses／YouTube Music 后，迟到结果不能追加到新来源。
- Home shelf continuation 只接受对应 section 的响应，不把另一 shelf 的合法响应拼入当前 shelf；失败保留原游标并显示区段级重试提示。
- 匿名 Home provider 每次首屏刷新都会重置旧 continuation 链；Innertube bootstrap 形状变化支持一次无旧状态重试。
- 本机推荐只按稳定 `artistCatalogID` 聚合；没有稳定身份的艺人不会因为显示名相同而合并。时间段和当前小时参与本机推荐评分；元数据变化会触发 Muses Home 刷新。
- Home 文案区分本机推荐、匿名 YouTube Music 公共发现、签名 Web 增强和账号管理数据；Data API 账号数据失败不再伪装成推荐来源失败。

## 自动化证据

专项目录、Home scope/cache、Innertube 和浏览器状态测试通过；新增同名艺人隔离和六类顶层筛选测试。最后一次完整串行回归为 587 tests／85 suites 通过，`git diff --check` 通过。

随后显式启用 `MUSES_TEST_PUBLIC_CATALOG=1` 的真实只读公共目录测试通过：Bruno Mars 搜索、歌曲第二页、专辑 browse、Mix 推荐及播客节目／单集 browse 均返回结构化结果。

## 2026-09-19 批次 23 实现收口

- 公共目录的请求、页面、continuation 和磁盘缓存均显式绑定语言与地区；应用语言切换会轮换 provider，旧语言游标不能继续写入新页面。
- 规范化目录缓存升级为 `v2/<language>/<region>` 物理分区。网络成功为 fresh；失败只允许读取七日内的规范化 stale 页；expired 或未来时间记录会删除，原始响应、筛选参数和 continuation 仍不落盘。
- 匿名 Home 的 client、cache 与 continuation 同样绑定语言和地区；Muses／YouTube Music、guest／account、baseline／web 的既有隔离不变。精确清除一个 scope/layer 时会覆盖其未在本进程打开的所有语言分区。
- 艺人 discography 和发行曲目不再调用 yt-dlp 搜索／歌单抓取来建立目录关系，改为稳定 channel／browse ID 的结构化 browse，并有界读取完整 continuation；超过上限时 fail closed，不把不完整结果缓存成完整目录。
- 搜索来源栏显示实际语言和地区；browse-backed 发行保留自身稳定 ID，不再伪装成 playlist ID。

真实只读网络矩阵已通过：英语／美国的歌曲、视频、专辑、艺人、歌单、播客六类搜索，专辑／艺人／歌单／播客详情，搜索 continuation，美国榜单；繁中／台湾的搜索筛选、专辑和榜单；英语／美国及繁中／台湾匿名 `FEmusic_home` 首屏，并实际读取一个可用的 shelf continuation。最后一次完整串行回归为 **609 tests／86 suites**，Release 构建和 `git diff --check` 通过。

## 仍需真实条件验收

以下仍不能由本轮只读网络测试替代：同一候选 Release 的全局 Home continuation（本轮响应没有提供时不得伪造）、真实账号 helper 成功／失败／频道不匹配、保存快照与无网恢复、服务端真实 renderer 变化、订阅上传流、完整 collection-context 播放；还需完成 VoiceOver、键盘、三语言、最小／全屏窗口和大结果集性能实机检查。OAuth 远端写入仍由既有保护边界隔离，本轮未发送账号写请求。
