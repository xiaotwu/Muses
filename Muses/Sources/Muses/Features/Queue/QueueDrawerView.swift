import SwiftUI

/// 队列抽屉:从 trailing 滑入,展示当前队列 / Up Next / History 三段。
/// 当前队列与 Up Next 支持拖拽重排(`.onMove`),History 只读。
struct QueueDrawerView: View {
    @Environment(PlaybackService.self) private var playback
    @Binding var isPresented: Bool

    var body: some View {
        HStack(spacing: 0) {
            // 点击左侧遮罩关闭
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            drawer
                .frame(width: 360)
                .background(.ultraThinMaterial)
                .overlay(Rectangle().frame(width: 1).foregroundStyle(.white.opacity(0.08)),
                         alignment: .leading)
                .transition(.move(edge: .trailing))
        }
        .animation(.easeInOut(duration: 0.25), value: isPresented)
    }

    private var drawer: some View {
        VStack(spacing: 0) {
            header
            Divider().background(.white.opacity(0.08))
            list
        }
    }

    private var header: some View {
        HStack {
            Text("Queue").font(.headline).foregroundStyle(.white)
            Spacer()
            Button { isPresented = false } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(BrandColors.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var list: some View {
        List {
            Section("当前队列") {
                ForEach(playback.queue.items) { item in
                    QueueRow(item: item,
                             isCurrent: playback.queue.currentIndex ==
                                        playback.queue.items.firstIndex(where: { $0.id == item.id }))
                }
                .onMove { indices, destination in
                    guard let from = indices.first else { return }
                    playback.queue.move(from: from,
                                        to: destination > from ? destination - 1 : destination)
                }
            }
            Section("Up Next") {
                ForEach(playback.queue.upNext) { item in
                    QueueRow(item: item, isCurrent: false)
                }
                .onMove { indices, destination in
                    guard let from = indices.first else { return }
                    playback.queue.moveUpNext(from: from,
                                              to: destination > from ? destination - 1 : destination)
                }
            }
            Section("History") {
                ForEach(playback.queue.history) { item in
                    QueueRow(item: item, isCurrent: false)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 44)
    }
}

private struct QueueRow: View {
    let item: QueueItem
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isCurrent ? "play.fill" : "music.note")
                .font(.caption)
                .foregroundStyle(isCurrent ? BrandColors.magenta : BrandColors.textSecondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.track.title).foregroundStyle(.white).lineLimit(1)
                Text(item.track.artist)
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(format(item.track.durationSeconds))
                .font(.caption2)
                .foregroundStyle(BrandColors.textSecondary)
        }
        .padding(.vertical, 4)
    }

    private func format(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}