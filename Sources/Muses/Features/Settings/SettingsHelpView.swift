import SwiftUI

/// Explanations have a stable destination instead of crowding preference rows.
struct SettingsHelpView: View {
    var body: some View {
        Group {
            Section {
                Text(tr("Google sign-in connects your YouTube account. Playlist changes require playlist management access. Browser access for Personalized Home is a separate, optional permission; it does not change playback settings.",
                        "Google 登录用于连接 YouTube 账号。修改账号歌单需要歌单管理权限。个性化首页的浏览器访问是独立且可选的授权，不会改变播放设置。"))
                Text(tr("Account tokens stay in Keychain. Personalized Home uses an isolated helper and a temporary browser session that is removed after each request. Disconnecting your account clears its Home session.",
                        "账号令牌保存在钥匙串。个性化首页通过隔离的辅助进程使用临时浏览器会话，并在每次请求结束后清除。断开账号会清除对应的首页会话。"))
            } header: { Text(tr("Account and browser access", "账号与浏览器访问")).font(.headline.weight(.semibold)) }
            Section {
                Text(tr("Your Muses listening history and likes belong to this Mac. Reading account data does not automatically write local changes back to YouTube. Share links identify the original YouTube content; a playlist without a YouTube identity has no public share link.",
                        "Muses 的收听历史与收藏保存在本机。读取账号数据不会自动将本机更改写回 YouTube。分享链接指向原始 YouTube 内容；没有 YouTube 身份的歌单没有公开分享链接。"))
            } header: { Text(tr("Library and sharing", "资料库与分享")).font(.headline.weight(.semibold)) }
            Section {
                Text(tr("Quality depends on the source YouTube makes available. Changing quality reloads the current track. Clearing the media cache also reloads playback. Audio output follows the macOS default output device.",
                        "可用音质取决于 YouTube 提供的源。更改音质会重新加载当前曲目，清除媒体缓存也会重新加载播放。音频输出跟随 macOS 的默认输出设备。"))
            } header: { Text(tr("Playback", "播放")).font(.headline.weight(.semibold)) }
            Section {
                Text(tr("Muses is an independent client for personal use and is not affiliated with YouTube or Google. YouTube content remains subject to YouTube's terms.",
                        "Muses 是供个人使用的独立客户端，与 YouTube 或 Google 无隶属关系。YouTube 内容仍受 YouTube 服务条款约束。"))
                Link(tr("YouTube Help", "YouTube 帮助"), destination: URL(string: "https://support.google.com/youtube/")!)
                Link(tr("Apple Intelligence availability", "Apple Intelligence 可用性"), destination: URL(string: "https://support.apple.com/121115")!)
            } header: { Text(tr("Personal use", "个人使用")).font(.headline.weight(.semibold)) }
        }

        .textSelection(.enabled)
    }
}
