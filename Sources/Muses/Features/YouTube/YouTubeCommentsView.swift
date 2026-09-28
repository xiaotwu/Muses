import SwiftUI

/// Volatile, read-only comment browsing on the official video surface.
struct YouTubeCommentsView: View {
    let videoID: String
    let onClose: () -> Void
    @Environment(YouTubeAccountService.self) private var account
    @State private var threads: [YouTubeCommentThread] = []
    @State private var nextToken: String?
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var selectedThread: YouTubeCommentThread?
    @State private var replies: [YouTubeComment] = []
    @State private var nextReplyToken: String?
    @State private var task: Task<Void, Never>?
    @State private var requestID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(tr("Comments", "评论", zhHant: "留言"))
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.fullAreaPlain)
                .accessibilityLabel(tr("Close comments", "关闭评论", zhHant: "關閉留言"))
                .help(tr("Close comments", "关闭评论", zhHant: "關閉留言"))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !account.isConnected {
                        ContentUnavailableView(
                            tr("Connect YouTube", "连接 YouTube", zhHant: "連接 YouTube"),
                            systemImage: "person.crop.circle",
                            description: Text(tr("Connect your account to read comments here.",
                                                 "连接账号后即可在这里阅读评论。",
                                                 zhHant: "連接帳號後即可在這裡閱讀留言。")))
                    } else {
                        if let errorMessage {
                            HStack {
                                Text(errorMessage).font(.callout)
                                Button(tr("Retry", "重试", zhHant: "重試")) {
                                    if selectedThread == nil { loadThreads(reset: threads.isEmpty) }
                                    else { loadReplies(reset: replies.isEmpty) }
                                }
                            }
                        }
                        if let selectedThread {
                            Button(tr("Close replies", "收起回复", zhHant: "收起回覆")) {
                                task?.cancel()
                                requestID = UUID()
                                loading = false
                                self.selectedThread = nil
                                replies = []
                                nextReplyToken = nil
                                errorMessage = nil
                            }
                            Text(selectedThread.topLevelComment.text).font(.body)
                            Divider()
                            ForEach(replies) { reply in commentRow(reply) }
                            if nextReplyToken != nil {
                                Button(tr("Load more replies", "加载更多回复", zhHant: "載入更多回覆")) {
                                    loadReplies(reset: false)
                                }.disabled(loading)
                            }
                        } else {
                            ForEach(threads) { thread in
                                VStack(alignment: .leading, spacing: 5) {
                                    commentRow(thread.topLevelComment)
                                    if thread.totalReplyCount > 0 {
                                        Button(tr("View replies", "查看回复", zhHant: "查看回覆")
                                               + " (\(thread.totalReplyCount))") {
                                            self.selectedThread = thread
                                            replies = []
                                            nextReplyToken = nil
                                            loadReplies(reset: true)
                                        }.font(.caption)
                                    }
                                }
                                Divider()
                            }
                            if nextToken != nil {
                                Button(tr("Load more comments", "加载更多评论", zhHant: "載入更多留言")) {
                                    loadThreads(reset: false)
                                }.disabled(loading)
                            }
                            if threads.isEmpty && !loading && errorMessage == nil {
                                Text(tr("No comments available.", "暂无可用评论。", zhHant: "暫無可用留言。"))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if loading { ProgressView().controlSize(.small) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .task(id: videoID + "|" + (account.activeChannelID ?? "")) {
            task?.cancel()
            requestID = UUID()
            loading = false
            threads = []
            nextToken = nil
            selectedThread = nil
            replies = []
            if account.isConnected { loadThreads(reset: true) }
        }
        .onDisappear { task?.cancel(); requestID = UUID() }
    }

    private func commentRow(_ comment: YouTubeComment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(comment.author).font(.subheadline.weight(.semibold))
            Text(comment.text).font(.body).textSelection(.enabled)
            if let publishedAt = comment.publishedAt {
                Text(publishedAt, format: .dateTime.year().month().day())
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadThreads(reset: Bool) {
        guard let client = account.dataAPIClient(), !loading else { return }
        task?.cancel()
        requestID = UUID()
        let expected = requestID
        let token = reset ? nil : nextToken
        loading = true
        errorMessage = nil
        task = Task {
            do {
                let page = try await client.commentThreads(videoID: videoID, pageToken: token)
                guard !Task.isCancelled, requestID == expected else { return }
                if reset { threads = page.items }
                else {
                    var seen = Set(threads.map(\.id))
                    threads += page.items.filter { seen.insert($0.id).inserted }
                }
                nextToken = page.nextPageToken
            } catch {
                guard !Task.isCancelled, requestID == expected else { return }
                errorMessage = error.localizedDescription
            }
            if requestID == expected { loading = false }
        }
    }

    private func loadReplies(reset: Bool) {
        guard let client = account.dataAPIClient(), let selectedThread, !loading else { return }
        task?.cancel()
        requestID = UUID()
        let expected = requestID
        let token = reset ? nil : nextReplyToken
        loading = true
        errorMessage = nil
        task = Task {
            do {
                let page = try await client.commentReplies(parentID: selectedThread.topLevelComment.id,
                                                           pageToken: token)
                guard !Task.isCancelled, requestID == expected else { return }
                if reset { replies = page.items }
                else {
                    var seen = Set(replies.map(\.id))
                    replies += page.items.filter { seen.insert($0.id).inserted }
                }
                nextReplyToken = page.nextPageToken
            } catch {
                guard !Task.isCancelled, requestID == expected else { return }
                errorMessage = error.localizedDescription
            }
            if requestID == expected { loading = false }
        }
    }
}
