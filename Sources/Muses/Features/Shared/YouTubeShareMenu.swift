import AppKit
import SwiftUI

/// Platform actions open a compose surface; Muses never posts on the user's behalf.
struct YouTubeShareMenu: View {
    let target: YouTubeShareTarget

    var body: some View {
        Menu {
            YouTubeShareMenuItems(target: target)
        } label: {
            Label(tr("Share", "分享"), systemImage: "square.and.arrow.up")
        }
        .help(tr("Share official YouTube links", "分享 YouTube 官方链接"))
    }
}

struct YouTubeShareMenuItems: View {
    let target: YouTubeShareTarget

    var body: some View {
        ForEach(YouTubeShareTarget.Service.allCases, id: \.self) { service in
            if let url = target.url(on: service) {
                Button(service == .music
                       ? tr("Copy YouTube Music Link", "复制 YouTube Music 链接")
                       : tr("Copy YouTube Link", "复制 YouTube 链接")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                Menu(service == .music ? "YouTube Music" : "YouTube") {
                    ForEach(YouTubeShareTarget.Platform.allCases, id: \.self) { platform in
                        if let destination = target.platformURL(platform, service: service) {
                            Link(platform == .email ? tr("Email", "邮件") : platform.rawValue,
                                 destination: destination)
                        }
                    }
                    Divider()
                    Link(tr("Open on YouTube for more sharing options", "在 YouTube 打开以使用更多分享选项"), destination: url)
                }
            }
        }
    }
}
