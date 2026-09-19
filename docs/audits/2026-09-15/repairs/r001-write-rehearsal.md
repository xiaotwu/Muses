# R001 远端写入演练门槛

日期：2026-09-18。本记录同时保留写入前门槛和当日一次性真实演练结果。用户随后明确将 `PLVRppllwHcDw` 指定为新建、Private、可丢弃的测试歌单，并仅授权该歌单的一次 Insert、Move、Delete 和服务端复读；这一当前决定取代下方准备步骤中“不使用该 506 首歌单”的旧假设。

## 真实演练结果

- 目标账号频道：`UCIfafZrJVaMDXLIADDY1CGg`；目标歌单：`PLVRppllwHcDw`。执行前重新确认 OAuth playlist-management scope、账号频道、所有权、可写状态和 506 项完整 Remote Shadow。
- 在独立 SQLite 一致性副本上运行生产 `YouTubePlaylistSyncService`；真实用户库未写入。测试视频 `dQw4w9WgXcQ` 在初始远端和本地基线中均不存在。
- **Insert：远端成功。** 服务端返回新的 playlistItem ID；完整复读确认总数 507，测试 occurrence 位于位置 506。
- **Move：远端写入生效，但同步批次失败。** 计划只有一个 `move`（506 → 0），服务端随后可见测试 occurrence 位于位置 0；生产服务在最终 `verifiedLocal.isStructurallyEquivalent(to: verifiedRemote)` 门槛报 `Verified remote state does not match Local after Push`，因此批次停在 `started`，没有误标为完成。
- **Delete／恢复：成功。** 失败清理删除测试 occurrence；再次完整服务端复读确认共 506 项，所有 playlistItem ID、视频 ID 和顺序逐项等于写入前基线。
- 首次尝试使用了一个已失效的旧 OAuth 测试构建配置，并在账号身份门槛前收到 `invalid_client`；没有发出任何歌单写请求。随后只使用通过频道、所有权和 scope 预检的有效配置执行上述演练。
- 本轮没有重试 Move，也没有执行歌单创建／删除、订阅或其他账号写入。

结论：精确目标门控、Insert、失败停止和恢复 Delete 获得了真实证据；Move 的服务端结果与本地最终对账仍有缺陷，R001 不通过，普通 Release Push 继续保持关闭。

## 下一步门槛

1. 在假 Data API 中加入 507 项的真实顺序形状，复现“最后一项移动到首位后远端已生效、最终结构校验失败”；记录首个结构差异的 occurrence、位置与 availability，不记录账号原始响应。
2. 修复 Move 后 Remote Shadow 与 Local 的身份／顺序对账，并覆盖重复视频、跨页边界、响应丢失后恢复及服务端短暂旧读。
3. 先在假服务完成 Insert → 幂等零操作 → Move → Remove → 最终精确基线的故障注入回归，再请求新的单次真实写入授权；不得沿用本次授权重试。
4. Move 真实复验通过后，才评估现有 item Push 的受控生产策略。远端创建／删除歌单继续作为独立编排任务。

## 已实现的保护

- 默认应用策略仍为 `disabled`，即使 OAuth 已授予 manage scope 也不会写入。
- 演练模式必须同时提供 `MUSES_YOUTUBE_PUSH_REHEARSAL_PLAYLIST_ID` 和 `MUSES_YOUTUBE_PUSH_REHEARSAL_ACCOUNT_CHANNEL_ID`；缺少任一值即回到全局关闭。
- 执行前重新校验当前 OAuth 频道、歌单所有权、完整 Remote Shadow、预览后的远端指纹和本地目标序列。
- Push 预览明确显示歌单标题、歌单 ID、账号频道 ID 和逐项操作；用户勾选“已核对”前按钮不可用。
- 演练策略只允许环境变量中的精确歌单／频道组合。错歌单、错频道、未确认、只读 scope、非所有者、预览后变化和不完整分页均在首个写请求前失败。
- 每个远端步骤进入 durable journal；重试先复读完整远端状态，再决定继续、认领已完成写入或要求人工确认。最终只有服务端复读与本地目标结构一致时才标记完成。

## 真实演练准备

1. 在目标账号中手工建立一个新的 **Private**、可随时丢弃的测试歌单；不要使用已有 506 首的 `PLVRppllwHcDw`。
2. 只放入两首明确可用的公开视频，记录初始顺序、歌单 ID 和账号频道 ID。
3. 用隔离构建导入该歌单，完成两次 Check Remote／Pull Preview，要求第二次为零差异。
4. 启动隔离构建时仅注入该歌单和频道：

   ```bash
   MUSES_YOUTUBE_PUSH_REHEARSAL_PLAYLIST_ID=<disposable-playlist-id> \
   MUSES_YOUTUBE_PUSH_REHEARSAL_ACCOUNT_CHANNEL_ID=<oauth-channel-id> \
   ./Scripts/build_and_run.sh --isolated
   ```

5. 在执行任何写入前，再由用户明确确认本轮允许修改的测试歌单、预期插入视频和恢复目标。仅设置环境变量不构成执行授权。

## 获得执行授权后的顺序

1. **拒绝路径**：对非目标歌单生成预览，确认在首个 HTTP 写请求前被拒绝。
2. **Insert**：在中间位置加入一首一次性测试视频；Push 后立即完整复读，核对 playlistItem ID、位置和总数。
3. **幂等复核**：不改本地状态再次 Check／Preview，必须为零操作；不得重复插入。
4. **Move**：移动该测试 occurrence，Push 后复读确切顺序。
5. **Remove／恢复**：删除测试 occurrence，复读后应回到最初两首和原顺序。
6. **恢复路径**：只在可控的假服务故障注入中覆盖“远端已提交但响应丢失”等边界；不通过故意破坏真实网络来制造不可预测的生产部分失败。
7. 保存操作 journal、每次完整 Remote Shadow 指纹和最终零差异 Preview；日志不得包含 OAuth token 或原始账号响应。

## 尚未开放

- 普通 Release 不读取演练目标时仍全局关闭 Push。
- 远端创建／删除歌单目前只有低层 Data API 能力，尚未接入同等级的目标校验、显式确认、复读和失败恢复编排；不能在本次 item 演练中顺便执行。
- 对现有用户歌单的生产 Push、订阅写入及其他账号互动仍需单独批准。
