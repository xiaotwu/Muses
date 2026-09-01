import AppKit
import SwiftUI

struct SearchWindowConfigurator: NSViewRepresentable {
    let colorScheme: ColorScheme

    func makeNSView(context: Context) -> SearchWindowConfigurationView {
        SearchWindowConfigurationView()
    }

    func updateNSView(_ nsView: SearchWindowConfigurationView, context: Context) {
        guard let window = nsView.window else { return }
        SearchWindowConfigurationView.configure(window, colorScheme: colorScheme)
    }
}

final class SearchWindowConfigurationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        Self.configure(window, colorScheme: effectiveColorScheme)
    }

    @MainActor
    static func configure(_ window: NSWindow, colorScheme: ColorScheme) {
        window.identifier = NSUserInterfaceItemIdentifier("Muses.search-window")
        window.setFrameAutosaveName("MusesSearchWindow")
        window.title = tr("Search Muses", "搜索 Muses")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .normal
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let appearanceName: NSAppearance.Name = switch (colorScheme, highContrast) {
        case (.dark, true): .accessibilityHighContrastDarkAqua
        case (.light, true): .accessibilityHighContrastAqua
        case (.dark, false): .darkAqua
        case (.light, false): .aqua
        @unknown default: .aqua
        }
        window.appearance = NSAppearance(named: appearanceName)
        window.contentMinSize = NSSize(
            width: SearchWindowPolicy.minimumWidth,
            height: SearchWindowPolicy.minimumHeight
        )
        for type in [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton
        ] {
            window.standardWindowButton(type)?.isHidden = false
        }
    }

    private var effectiveColorScheme: ColorScheme {
        window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .dark : .light
    }
}

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
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(BrandColors.magenta)
                    .frame(width: 28, height: 28)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(BrandColors.textPrimary)
                Spacer()
                Image(systemName: "chevron.forward")
                    .font(.system(size: 11, weight: .semibold))
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
        .buttonStyle(.plain)
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
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isCurrent ? BrandColors.magenta : BrandColors.textPrimary)
                        .lineLimit(1)
                    Text([snapshot.artist, snapshot.albumTitle]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — "))
                        .font(.caption)
                        .foregroundStyle(BrandColors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Text(formatDuration(snapshot.durationSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(BrandColors.textSecondary)
                YouTubeMark(size: 13)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: SearchWindowPolicy.resultRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(BrandColors.textPrimary)
                            .lineLimit(1)
                        Text(entry.uploader ?? "YouTube Music")
                            .font(.caption)
                            .foregroundStyle(BrandColors.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isSaved {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(BrandColors.magenta)
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
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(tr("Open in Browser", "在浏览器中打开"))
            .accessibilityLabel(tr("Open in Browser", "在浏览器中打开"))
        }
        .frame(minHeight: SearchWindowPolicy.resultRowHeight)
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
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(BrandColors.textSecondary)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(BrandColors.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
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
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(BrandColors.magenta)
                    .frame(width: 42, height: 42)
                    .background(BrandColors.surface,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.ownerTitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(BrandColors.textPrimary)
                        .lineLimit(1)
                    Text(hit.snippet)
                        .font(.caption)
                        .foregroundStyle(BrandColors.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            .frame(minHeight: SearchWindowPolicy.resultRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
