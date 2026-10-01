import AppKit
import SwiftUI

struct SearchCategoryButton: View {
    let title: String
    let systemName: String
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemName)
                    .font(MusesTypography.system(size: 18, weight: .semibold))
                    .foregroundStyle(BrandColors.accent)
                    .frame(width: 28, height: 28)
                Text(title)
                    .font(MusesTypography.system(size: 15, weight: .semibold))
                    .foregroundStyle(BrandColors.textPrimary)
                Spacer()
                Image(systemName: "chevron.forward")
                    .font(MusesTypography.system(size: 11, weight: .semibold))
                    .foregroundStyle(BrandColors.textSecondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 58)
            .background(BrandColors.surface.opacity(hovering ? 0.96 : 0.72),
                        in: RoundedRectangle(cornerRadius: AppleMusicTokens.cardCorner,
                                             style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: AppleMusicTokens.cardCorner,
                                           style: .continuous))
        }
        .buttonStyle(.fullAreaPlain)
        .onHover { hovering = $0 }
        .animation(MusesMotion.hoverAnimation(reduceMotion: reduceMotion), value: hovering)
        .accessibilityLabel(title)
    }
}

struct GlobalSearchTrackRow: View {
    let snapshot: TrackSnapshot
    let isCurrent: Bool
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 11) {
                ArtworkView(source: ArtworkSource.resolve(for: snapshot),
                            cornerRadius: 5, glyphSize: 16, targetSize: 42)
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.title)
                        .font(MusesTypography.system(size: 14, weight: .medium))
                        .foregroundStyle(isCurrent ? BrandColors.accent : BrandColors.textPrimary)
                        .lineLimit(1)
                    Text([snapshot.artist, snapshot.albumTitle]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — "))
                        .font(MusesTypography.caption)
                        .foregroundStyle(BrandColors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Text(formatDuration(snapshot.durationSeconds))
                    .font(MusesTypography.caption.monospacedDigit())
                    .foregroundStyle(BrandColors.textSecondary)
                YouTubeMark(size: 13)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: SearchPagePolicy.resultRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.fullAreaPlain)
        .overlay(alignment: .bottom) {
            Rectangle().fill(BrandColors.hairline).frame(height: 1)
        }
        .accessibilityLabel("\(snapshot.title), \(snapshot.artist)")
        .accessibilityValue(formatDuration(snapshot.durationSeconds))
    }
}

struct GlobalSearchYouTubeRow: View {
    let entry: YTDlpBridge.YTDlpPlaylistEntry
    let isSaved: Bool
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Button(action: onPlay) {
                HStack(spacing: 11) {
                    CachedAsyncImage(
                        url: YouTubeThumbnail.url(videoId: entry.id),
                        content: { $0.resizable().scaledToFill() },
                        placeholder: { Rectangle().fill(BrandColors.surface) }
                    )
                    .frame(width: 72, height: 41)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .clipped()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .font(MusesTypography.system(size: 14, weight: .medium))
                            .foregroundStyle(BrandColors.textPrimary)
                            .lineLimit(1)
                        Text(entry.uploader ?? "YouTube Music")
                            .font(MusesTypography.caption)
                            .foregroundStyle(BrandColors.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.fullAreaPlain)
            if isSaved {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(BrandColors.accent)
                    .help(tr("In Library", "已在资料库中"))
                    .accessibilityLabel(tr("In Library", "已在资料库中"))
            }
            YouTubeMark(size: 14)
                .accessibilityHidden(true)
            Button {
                guard let url = URL(string: "https://music.youtube.com/watch?v=\(entry.id)") else { return }
                NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "arrow.up.right")
                    .font(MusesTypography.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.fullAreaPlain)
            .help(tr("Open in Browser", "在浏览器中打开"))
            .accessibilityLabel(tr("Open in Browser", "在浏览器中打开"))
        }
        .frame(minHeight: SearchPagePolicy.resultRowHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(BrandColors.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

struct SearchStatusView: View {
    let systemName: String
    let title: String
    var subtitle: String? = nil
    var showsProgress = false

    var body: some View {
        VStack(spacing: 10) {
            if showsProgress {
                ProgressView().controlSize(.regular)
            } else {
                Image(systemName: systemName)
                    .font(MusesTypography.system(size: 28, weight: .semibold))
                    .foregroundStyle(BrandColors.textSecondary)
            }
            Text(title)
                .font(MusesTypography.headline)
                .foregroundStyle(BrandColors.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(MusesTypography.subheadline)
                    .foregroundStyle(BrandColors.textSecondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }
}

struct GlobalSearchNoteRow: View {
    let hit: NotesService.NoteSearchHit
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "note.text")
                    .font(MusesTypography.system(size: 15, weight: .semibold))
                    .foregroundStyle(BrandColors.accent)
                    .frame(width: 42, height: 42)
                    .background(BrandColors.surface,
                                in: Capsule())
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.ownerTitle)
                        .font(MusesTypography.system(size: 14, weight: .medium))
                        .foregroundStyle(BrandColors.textPrimary)
                        .lineLimit(1)
                    Text(hit.snippet)
                        .font(MusesTypography.caption)
                        .foregroundStyle(BrandColors.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            .frame(minHeight: SearchPagePolicy.resultRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.fullAreaPlain)
        .overlay(alignment: .bottom) {
            Rectangle().fill(BrandColors.hairline).frame(height: 1)
        }
    }
}

private func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "—" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
