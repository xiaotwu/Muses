import AppKit
import SwiftUI

enum CollectionPageMode: Equatable, Sendable {
    case stage
    case list
}

enum CollectionDeckScrubberMetrics {
    static let maximumWidth: CGFloat = 460
    static let minimumWidth: CGFloat = 160
    static let horizontalClearance: CGFloat = 220
    static let stageClearance: CGFloat = 24
    static let trackHeight: CGFloat = 4
    static let thumbWidth: CGFloat = 46
    static let thumbHeight: CGFloat = 24
    static let controlHeight: CGFloat = 28
    static let valueHeight: CGFloat = 16
    static let valueSpacing: CGFloat = 4
    static let totalHeight: CGFloat = controlHeight + valueSpacing + valueHeight
    static let playerClearance: CGFloat = OverlayChromeMetrics.scrollBottomInset + 24

    static func width(availableWidth: CGFloat) -> CGFloat {
        min(maximumWidth, max(minimumWidth, availableWidth - horizontalClearance))
    }

    static func thumbCenterX(position: CGFloat, itemCount: Int, width: CGFloat) -> CGFloat {
        let halfThumb = thumbWidth / 2
        let availableTravel = max(0, width - thumbWidth)
        guard itemCount > 1 else { return halfThumb }
        let ratio = min(1, max(0, position / CGFloat(itemCount - 1)))
        return halfThumb + ratio * availableTravel
    }

    static func position(locationX: CGFloat, itemCount: Int, width: CGFloat) -> CGFloat {
        guard itemCount > 1 else { return 0 }
        let availableTravel = max(1, width - thumbWidth)
        let ratio = min(1, max(0, (locationX - thumbWidth / 2) / availableTravel))
        return ratio * CGFloat(itemCount - 1)
    }
}

struct CollectionDeckGeometry: Equatable, Sendable {
    let cardWidth: CGFloat
    let footerHeight: CGFloat
    let spread: CGFloat
    let radius: Int

    var cardHeight: CGFloat { cardWidth + footerHeight }
    /// The roomy fan's fourth card has the largest rotation and vertical drop.
    /// Reserve its complete transformed bounds so the scrubber remains a
    /// separate control below the stage instead of painting underneath it.
    var lowerFanClearance: CGFloat {
        switch radius {
        case 4...: 118
        case 3: 92
        default: 66
        }
    }
    var viewportHeight: CGFloat { cardHeight + lowerFanClearance }

    static func resolve(containerWidth: CGFloat, containerHeight: CGFloat) -> Self {
        let compactHeight = containerHeight < AppleMusicTokens.collectionDeckCompactHeight
        if containerWidth < AppleMusicTokens.collectionDeckCompactBreakpoint || compactHeight {
            return Self(
                cardWidth: AppleMusicTokens.collectionDeckCompactCardWidth,
                footerHeight: AppleMusicTokens.collectionDeckCompactFooterHeight,
                spread: AppleMusicTokens.collectionDeckCompactSpread,
                radius: 2
            )
        }
        if containerWidth < AppleMusicTokens.collectionDeckWideBreakpoint {
            return Self(
                cardWidth: min(146, max(136, containerWidth * 0.19)),
                footerHeight: AppleMusicTokens.collectionDeckRoomyFooterHeight,
                spread: AppleMusicTokens.collectionDeckMediumSpread,
                radius: 3
            )
        }
        return Self(
            cardWidth: AppleMusicTokens.collectionDeckRoomyCardWidth,
            footerHeight: AppleMusicTokens.collectionDeckRoomyFooterHeight,
            spread: AppleMusicTokens.collectionDeckRoomySpread,
            radius: 4
        )
    }
}

enum CollectionDeckProjection {
    static func visibleIndices(count: Int, position: CGFloat, radius: Int) -> [Int] {
        guard count > 0 else { return [] }
        let center = min(count - 1, max(0, Int(position.rounded())))
        let lower = max(0, center - radius)
        let upper = min(count - 1, center + radius)
        return Array(lower...upper)
    }

    static func projectedIndex(
        startPosition: CGFloat,
        translation: CGFloat,
        predictedTranslation: CGFloat,
        spread: CGFloat,
        count: Int
    ) -> Int {
        guard count > 0, spread > 0 else { return 0 }
        let actual = startPosition - translation / spread
        let projected = startPosition - predictedTranslation / spread
        let maximumFlight: CGFloat = 6
        let boundedProjection = min(
            actual + maximumFlight,
            max(actual - maximumFlight, projected)
        )
        return min(count - 1, max(0, Int(boundedProjection.rounded())))
    }

    static func acceptsVerticalGesture(
        translation: CGSize,
        direction: CollectionExpansionDirection,
        threshold: CGFloat = AppleMusicTokens.collectionDeckExpansionThreshold
    ) -> Bool {
        let directedY = translation.height * direction.multiplier
        return directedY >= threshold
            && abs(translation.height) > abs(translation.width) * 1.25
    }
}

enum CollectionExpansionDirection: Equatable, Sendable {
    case up
    case down

    var multiplier: CGFloat { self == .up ? -1 : 1 }
    var systemName: String { self == .up ? "chevron.up" : "chevron.down" }
}

enum CollectionDeckActivationSource: CaseIterable, Equatable, Sendable {
    case pointer
    case keyboard
    case accessibility
    case contextMenu
}

enum CollectionDeckActivationPolicy {
    static func isPrimaryActivation(_ source: CollectionDeckActivationSource) -> Bool {
        source != .contextMenu
    }
}

enum CollectionDeckInputPolicy {
    /// AppKit event monitors live outside SwiftUI hit testing, so both the
    /// stage and its inherited enabled state must opt into consuming events.
    static func acceptsEvents(stageEnabled: Bool, environmentEnabled: Bool) -> Bool {
        stageEnabled && environmentEnabled
    }
}

struct CollectionDeckStage<Controls: View>: View {
    let title: String
    let subtitle: String
    let youTubeURL: URL?
    let rows: [CollectionTrackRow]
    let currentTrack: TrackSnapshot?
    let playlists: [Playlist]
    let isInteractionEnabled: Bool
    let onPlay: (CollectionTrackRow) -> Void
    let onRemove: ((CollectionTrackRow) -> Void)?
    let onExpand: () -> Void
    let controls: Controls

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var environmentIsEnabled
    @State private var position: CGFloat = 0
    @State private var focusedID: UUID?
    @State private var hoveredID: UUID?
    @State private var fanHovered = false
    @State private var dragOrigin: CGFloat?
    @State private var horizontalDragActive = false
    @State private var wheelAccumulator: CGFloat = 0
    @State private var wheelResetTask: Task<Void, Never>?
    @FocusState private var deckFocused: Bool

    private var focusedIndex: Int {
        guard !rows.isEmpty else { return 0 }
        return min(rows.count - 1, max(0, Int(position.rounded())))
    }

    var body: some View {
        GeometryReader { proxy in
            let horizontalPadding: CGFloat = proxy.size.width < 760 ? 24 : AppleMusicTokens.contentPaddingX
            let availableWidth = max(0, proxy.size.width - horizontalPadding * 2)
            let geometry = CollectionDeckGeometry.resolve(
                containerWidth: availableWidth,
                containerHeight: proxy.size.height
            )

            VStack(spacing: 0) {
                CollectionPageHeader(title: title, youTubeURL: youTubeURL) {
                    controls
                }
                    .padding(.horizontal, AppleMusicTokens.contentPaddingX)
                    .padding(.top, AppleMusicSpacing.browseTitleTop)
                    .padding(.bottom, AppleMusicSpacing.headerToPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(2)

                Spacer(minLength: 0)

                deck(geometry: geometry)
                    .frame(width: availableWidth, height: geometry.viewportHeight)

                CollectionDeckScrubber(
                    position: position,
                    rows: rows,
                    isEnabled: isInteractionEnabled,
                    onPositionChanged: { value, animated in
                        setPosition(value, animated: animated)
                    }
                )
                .frame(width: CollectionDeckScrubberMetrics.width(availableWidth: availableWidth))
                .padding(.top, CollectionDeckScrubberMetrics.stageClearance)

                CollectionExpansionHandle(
                    direction: .up,
                    accessibilityLabel: tr("Show complete song list", "展开完整歌曲列表"),
                    help: tr("Show complete song list", "展开完整歌曲列表"),
                    action: onExpand
                )
                .disabled(!isInteractionEnabled)

                Color.clear
                    .frame(height: CollectionDeckScrubberMetrics.playerClearance)
            }
            .frame(
                width: proxy.size.width,
                height: proxy.size.height,
                alignment: .top
            )
        }
        .onAppear(perform: establishInitialFocus)
        .onChange(of: rows.map(\.id)) { _, _ in reconcileFocus() }
        .onDisappear {
            wheelResetTask?.cancel()
            wheelResetTask = nil
        }
    }

    private func deck(geometry: CollectionDeckGeometry) -> some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(CollectionDeckProjection.visibleIndices(
                    count: rows.count,
                    position: position,
                    radius: geometry.radius
                ), id: \.self) { index in
                    card(at: index, geometry: geometry, containerWidth: proxy.size.width)
                }

                deckChevron(systemName: "chevron.left", help: tr("Previous song", "上一首")) {
                    moveFocus(by: -1)
                }
                .disabled(focusedIndex <= 0 || !isInteractionEnabled)
                .frame(maxWidth: .infinity, alignment: .leading)

                deckChevron(systemName: "chevron.right", help: tr("Next song", "下一首")) {
                    moveFocus(by: 1)
                }
                .disabled(focusedIndex >= rows.count - 1 || !isInteractionEnabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                fanHovered = inside
                if !inside { hoveredID = nil }
            }
            .simultaneousGesture(deckDrag(geometry: geometry))
            .background {
                DeckScrollEventBridge(isEnabled: CollectionDeckInputPolicy.acceptsEvents(
                    stageEnabled: isInteractionEnabled,
                    environmentEnabled: environmentIsEnabled
                )) { delta in
                    handleScroll(delta)
                }
                .allowsHitTesting(false)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($deckFocused)
            .onKeyPress(.leftArrow) {
                moveFocus(by: -1)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                moveFocus(by: 1)
                return .handled
            }
            .onKeyPress(.home) {
                moveFocus(to: 0)
                return .handled
            }
            .onKeyPress(.end) {
                moveFocus(to: rows.count - 1)
                return .handled
            }
            .onKeyPress(.return) {
                activateFocusedCard()
                return .handled
            }
            .onKeyPress(.space) {
                activateFocusedCard()
                return .handled
            }
            .animation(MusesMotion.hoverAnimation(reduceMotion: reduceMotion), value: fanHovered)
            .animation(MusesMotion.hoverAnimation(reduceMotion: reduceMotion), value: hoveredID)
            .accessibilityRepresentation {
                VStack {
                    Button(tr("Previous song", "上一首")) {
                        moveFocus(by: -1)
                    }
                    .disabled(focusedIndex <= 0 || !isInteractionEnabled)

                    ForEach(CollectionDeckProjection.visibleIndices(
                        count: rows.count,
                        position: position,
                        radius: geometry.radius
                    ), id: \.self) { index in
                        let row = rows[index]
                        Button(cardAccessibilityLabel(
                            row: row,
                            index: index,
                            playing: row.matches(currentTrack)
                        )) {
                            guard isInteractionEnabled else { return }
                            setPosition(CGFloat(index), animated: true)
                            activate(row, source: .accessibility)
                        }
                        .accessibilityValue(
                            index == focusedIndex ? tr("Focused", "当前焦点") : ""
                        )
                    }

                    Button(tr("Next song", "下一首")) {
                        moveFocus(by: 1)
                    }
                    .disabled(focusedIndex >= rows.count - 1 || !isInteractionEnabled)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(tr(
                    "Song card deck. Use Left and Right arrows, drag, trackpad, or the scrubber to browse.",
                    "歌曲卡片牌组。使用左右方向键、拖动、触控板或拖动条浏览。"
                ))
            }
        }
    }

    private func card(
        at index: Int,
        geometry: CollectionDeckGeometry,
        containerWidth: CGFloat
    ) -> some View {
        let row = rows[index]
        let relative = CGFloat(index) - position
        let distance = abs(relative)
        let hovered = hoveredID == row.id
        let playing = row.matches(currentTrack)
        let fanScale: CGFloat = fanHovered ? 1.06 : 1
        let spread = geometry.spread * fanScale
        var x = relative * spread
        var y = 1.7 * relative * relative + 5.5 * distance
        var scale = 1 - min(distance * 0.018, 0.08)
        var yield: CGFloat = 0

        if let hoveredIndex = rows.firstIndex(where: { $0.id == hoveredID }), !hovered {
            yield = index < hoveredIndex ? -4 : 4
        }
        if hovered {
            x += relative == 0 ? 3 : (relative < 0 ? -3 : 3)
            y -= AppleMusicTokens.collectionDeckHoverLift
            scale *= 1.035
        }
        let playingLift: CGFloat = playing && !reduceMotion ? 14 : 0
        let playingScale: CGFloat = playing && !reduceMotion ? 1.05 : 1

        return Button {
            guard isInteractionEnabled, !horizontalDragActive else { return }
            setPosition(CGFloat(index), animated: true)
            focusedID = row.id
            activate(row, source: .pointer)
        } label: {
            CollectionDeckCardSurface(
                row: row,
                cardWidth: geometry.cardWidth,
                footerHeight: geometry.footerHeight,
                isFocused: index == focusedIndex,
                isPlaying: playing,
                isHovered: hovered,
                showsKeyboardFocus: deckFocused && index == focusedIndex
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .position(
            x: containerWidth / 2 + x + yield,
            y: geometry.cardHeight / 2 + 18 + y - playingLift
        )
        .rotationEffect(.degrees(Double(relative * 3.15)))
        .scaleEffect(scale * playingScale)
        .zIndex(playing ? 600 : (hovered ? 500 : 200 - distance * 10))
        .animation(MusesMotion.collectionCardAnimation(reduceMotion: reduceMotion), value: playing)
        .onHover { inside in hoveredID = inside ? row.id : (hoveredID == row.id ? nil : hoveredID) }
        .trackContextMenu(
            snapshot: row.snapshot,
            playlists: playlists,
            onPlay: {
                guard isInteractionEnabled else { return }
                setPosition(CGFloat(index), animated: false)
                onPlay(row)
            },
            onRemoveFromContainer: onRemove.map { handler in { handler(row) } }
        )
        .help(tr("Play \(row.title)", "播放 \(row.title)"))
        .accessibilityLabel(cardAccessibilityLabel(row: row, index: index, playing: playing))
        .accessibilityValue(index == focusedIndex ? tr("Focused", "当前焦点") : "")
    }

    private func deckChevron(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(BrandColors.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func deckDrag(geometry: CollectionDeckGeometry) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard isInteractionEnabled else { return }
                if dragOrigin == nil { dragOrigin = position }
                guard abs(value.translation.width) > abs(value.translation.height) * 1.15,
                      abs(value.translation.width) > 7,
                      let origin = dragOrigin else { return }
                horizontalDragActive = true
                setPosition(origin - value.translation.width / geometry.spread, animated: false)
            }
            .onEnded { value in
                let origin = dragOrigin ?? position
                let wasHorizontal = horizontalDragActive
                dragOrigin = nil
                guard wasHorizontal else {
                    horizontalDragActive = false
                    return
                }
                let target = CollectionDeckProjection.projectedIndex(
                    startPosition: origin,
                    translation: value.translation.width,
                    predictedTranslation: value.predictedEndTranslation.width,
                    spread: geometry.spread,
                    count: rows.count
                )
                moveFocus(to: target)
                Task { @MainActor in
                    await Task.yield()
                    horizontalDragActive = false
                }
            }
    }

    /// Keyboard activation is the same immediate primary card activation
    /// exposed to pointer and VoiceOver.
    private func activateFocusedCard() {
        guard rows.indices.contains(focusedIndex), isInteractionEnabled else { return }
        let row = rows[focusedIndex]
        focusedID = row.id
        activate(row, source: .keyboard)
    }

    private func activate(
        _ row: CollectionTrackRow,
        source: CollectionDeckActivationSource
    ) {
        guard CollectionDeckActivationPolicy.isPrimaryActivation(source) else { return }
        onPlay(row)
    }

    private func moveFocus(by delta: Int) {
        moveFocus(to: focusedIndex + delta)
    }

    private func moveFocus(to index: Int) {
        guard !rows.isEmpty else { return }
        setPosition(CGFloat(min(rows.count - 1, max(0, index))), animated: true)
    }

    private func setPosition(_ value: CGFloat, animated: Bool) {
        guard !rows.isEmpty else {
            position = 0
            focusedID = nil
            return
        }
        let clamped = min(CGFloat(rows.count - 1), max(0, value))
        let update = {
            position = clamped
            focusedID = rows[min(rows.count - 1, max(0, Int(clamped.rounded())))].id
        }
        if animated, let animation = MusesMotion.collectionDeckAnimation(reduceMotion: reduceMotion) {
            withAnimation(animation, update)
        } else {
            update()
        }
    }

    private func handleScroll(_ delta: CGFloat) {
        guard isInteractionEnabled else { return }
        wheelAccumulator += delta
        wheelResetTask?.cancel()
        if abs(wheelAccumulator) >= 34 {
            moveFocus(by: wheelAccumulator > 0 ? 1 : -1)
            wheelAccumulator = 0
        }
        wheelResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            wheelAccumulator = 0
        }
    }

    private func establishInitialFocus() {
        if let index = rows.firstIndex(where: { $0.matches(currentTrack) }) {
            position = CGFloat(index)
            focusedID = rows[index].id
        } else {
            reconcileFocus()
        }
    }

    private func reconcileFocus() {
        guard !rows.isEmpty else {
            position = 0
            focusedID = nil
            return
        }
        if let focusedID, let index = rows.firstIndex(where: { $0.id == focusedID }) {
            position = CGFloat(index)
        } else {
            let index = min(rows.count - 1, max(0, focusedIndex))
            position = CGFloat(index)
            focusedID = rows[index].id
        }
    }

    private func cardAccessibilityLabel(
        row: CollectionTrackRow,
        index: Int,
        playing: Bool
    ) -> String {
        let positionText = tr("\(index + 1) of \(rows.count)", "第 \(index + 1) 首，共 \(rows.count) 首")
        let playbackText = playing ? tr("Playing", "正在播放") : tr("Play", "播放")
        return "\(positionText), \(row.title) — \(row.artist), \(playbackText)"
    }
}

struct CollectionDeckCardSurface: View {
    let row: CollectionTrackRow
    let cardWidth: CGFloat
    let footerHeight: CGFloat
    let isFocused: Bool
    let isPlaying: Bool
    let isHovered: Bool
    var showsKeyboardFocus = false

    @State private var glowColor = Color.white
    @State private var glowIdentity = ""

    private var artworkSource: ArtworkSource {
        ArtworkSource.resolve(for: row.snapshot)
    }

    private var resolvedGlow: Color {
        glowIdentity == artworkSource.identity ? glowColor : Color.white
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AppleMusicTokens.cardCorner, style: .continuous)
        VStack(spacing: 0) {
            ArtworkView(
                source: artworkSource,
                cornerRadius: 0,
                glyphSize: max(24, cardWidth * 0.2),
                targetSize: cardWidth,
                presentation: .fitOnAmbient
            )
            .overlay {
                if isHovered {
                    Circle()
                        .fill(BrandColors.magenta)
                        .frame(width: 31, height: 31)
                        .overlay {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: 1)
                        }
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                        .transition(.opacity)
                }
            }

            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: footerHeight <= 48 ? 1 : 3) {
                    Text(row.title)
                        .font(.system(size: footerHeight <= 48 ? 11.5 : 12.5, weight: .semibold))
                        .foregroundStyle(BrandColors.textPrimary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Text(row.artist)
                        .font(.system(size: footerHeight <= 48 ? 10 : 11.5))
                        .foregroundStyle(BrandColors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isPlaying {
                    Image(systemName: "waveform")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(BrandColors.magenta)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, footerHeight <= 48 ? 3 : 7)
            .frame(height: footerHeight, alignment: .top)
            .background(BrandColors.surface)
        }
        .frame(width: cardWidth, height: cardWidth + footerHeight)
        .background(BrandColors.surface)
        .clipShape(shape)
        .overlay {
            shape.stroke(
                isPlaying
                    ? Color.white.opacity(0.68)
                    : (showsKeyboardFocus
                        ? BrandColors.textPrimary.opacity(0.78)
                        : (isFocused ? BrandColors.textSecondary.opacity(0.58) : BrandColors.hairline)),
                lineWidth: isPlaying ? 1.5 : (showsKeyboardFocus ? 2 : (isFocused ? 1.25 : 1))
            )
        }
        .shadow(
            color: .black.opacity(isHovered ? 0.44 : (isFocused ? 0.32 : 0.22)),
            radius: isHovered ? 21 : (isFocused ? 15 : 9),
            y: isHovered ? 12 : 8
        )
        .shadow(
            color: isPlaying ? resolvedGlow.opacity(0.52) : Color.clear,
            radius: 22
        )
        .shadow(
            color: isPlaying ? resolvedGlow.opacity(0.28) : Color.clear,
            radius: 44
        )
        .task(id: artworkSource.identity) {
            let expectedIdentity = artworkSource.identity
            let color = await CollectionArtworkGlowCache.shared.color(for: artworkSource)
            guard !Task.isCancelled, expectedIdentity == artworkSource.identity else { return }
            glowColor = color.map { Color(nsColor: $0) } ?? .white
            glowIdentity = expectedIdentity
        }
    }
}

@MainActor
private final class CollectionArtworkGlowCache {
    static let shared = CollectionArtworkGlowCache()

    private let colors = NSCache<NSString, NSColor>()
    private var inFlight: [String: Task<NSColor?, Never>] = [:]

    private init() {
        colors.countLimit = 192
    }

    func color(for source: ArtworkSource) async -> NSColor? {
        let key = source.identity
        if let cached = colors.object(forKey: key as NSString) {
            return cached
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task<NSColor?, Never> { @MainActor in
            let image: NSImage?
            switch source {
            case .remote(let url):
                image = await ImageLoader.shared.load(url).value
            case .placeholder:
                image = nil
            }
            guard let image, !Task.isCancelled else { return nil }
            return await Task.detached(priority: .utility) {
                guard let base = AlbumArtworkExtractor.dominantColors(image, count: 3).first,
                      let rgb = base.usingColorSpace(.sRGB) else { return nil }
                var hue: CGFloat = 0
                var saturation: CGFloat = 0
                var brightness: CGFloat = 0
                var alpha: CGFloat = 0
                rgb.getHue(
                    &hue,
                    saturation: &saturation,
                    brightness: &brightness,
                    alpha: &alpha
                )
                return NSColor(
                    calibratedHue: hue,
                    saturation: min(0.88, max(0.28, saturation)),
                    brightness: min(0.92, max(0.58, brightness)),
                    alpha: 1
                )
            }.value
        }
        inFlight[key] = task
        let color = await task.value
        inFlight[key] = nil
        if let color {
            colors.setObject(color, forKey: key as NSString)
        }
        return color
    }
}

struct CollectionExpansionHandle: View {
    let direction: CollectionExpansionDirection
    let accessibilityLabel: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: direction.systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BrandColors.textSecondary)
                .frame(width: 48, height: AppleMusicTokens.collectionDeckHandleHeight)
                .background {
                    if direction == .down {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(BrandColors.surface.opacity(0.72))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onEnded { value in
                    if CollectionDeckProjection.acceptsVerticalGesture(
                        translation: value.translation,
                        direction: direction
                    ) {
                        action()
                    }
                }
        )
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct CollectionDeckScrubber: View {
    let position: CGFloat
    let rows: [CollectionTrackRow]
    let isEnabled: Bool
    let onPositionChanged: (CGFloat, Bool) -> Void

    @State private var dragging = false
    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var usesOpaqueThumb: Bool {
        reduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    private var index: Int {
        guard !rows.isEmpty else { return 0 }
        return min(rows.count - 1, max(0, Int(position.rounded())))
    }

    private var valueText: String {
        guard rows.indices.contains(index) else { return tr("No songs", "没有歌曲") }
        return "\(index + 1) / \(rows.count) · \(rows[index].title)"
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let thumbX = CollectionDeckScrubberMetrics.thumbCenterX(
                position: position,
                itemCount: rows.count,
                width: width
            )
            let showsValue = dragging || hovering || focused

            VStack(spacing: CollectionDeckScrubberMetrics.valueSpacing) {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(BrandColors.textPrimary.opacity(focused ? 0.26 : 0.18))
                        .frame(height: CollectionDeckScrubberMetrics.trackHeight)
                        .overlay {
                            Capsule()
                                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                        }

                    Capsule()
                        .fill(
                            usesOpaqueThumb
                                ? BrandColors.surface
                                : Color.white.opacity(0.05)
                        )
                        .frame(
                            width: CollectionDeckScrubberMetrics.thumbWidth,
                            height: CollectionDeckScrubberMetrics.thumbHeight
                        )
                        .musesGlass(
                            in: Capsule(),
                            tint: Color.white.opacity(0.12),
                            role: .compactControl
                        )
                        .overlay {
                            Capsule()
                                .stroke(
                                    focused
                                        ? Color.white.opacity(0.96)
                                        : Color.white.opacity(usesOpaqueThumb ? 0.86 : 0.64),
                                    lineWidth: focused ? 2 : 1
                                )
                        }
                        .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
                        .shadow(
                            color: focused ? Color.white.opacity(0.28) : Color.clear,
                            radius: 7
                        )
                        .position(
                            x: thumbX,
                            y: CollectionDeckScrubberMetrics.controlHeight / 2
                        )
                }
                .frame(height: CollectionDeckScrubberMetrics.controlHeight)

                Text(valueText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(BrandColors.textSecondary)
                    .lineLimit(1)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: CollectionDeckScrubberMetrics.valueHeight,
                        maxHeight: CollectionDeckScrubberMetrics.valueHeight
                    )
                    .opacity(showsValue ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled, !rows.isEmpty else { return }
                        dragging = true
                        onPositionChanged(
                            CollectionDeckScrubberMetrics.position(
                                locationX: value.location.x,
                                itemCount: rows.count,
                                width: width
                            ),
                            false
                        )
                    }
                    .onEnded { value in
                        dragging = false
                        guard isEnabled, !rows.isEmpty else { return }
                        let projectedPosition = CollectionDeckScrubberMetrics.position(
                            locationX: value.location.x,
                            itemCount: rows.count,
                            width: width
                        )
                        onPositionChanged(projectedPosition.rounded(), true)
                    }
            )
            .onHover { hovering = $0 }
            .opacity(isEnabled ? 1 : 0.46)
        }
        .frame(height: CollectionDeckScrubberMetrics.totalHeight)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) {
            guard isEnabled else { return .ignored }
            onPositionChanged(CGFloat(max(0, index - 1)), true)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard isEnabled else { return .ignored }
            onPositionChanged(CGFloat(min(max(0, rows.count - 1), index + 1)), true)
            return .handled
        }
        .onKeyPress(.home) {
            guard isEnabled else { return .ignored }
            onPositionChanged(0, true)
            return .handled
        }
        .onKeyPress(.end) {
            guard isEnabled else { return .ignored }
            onPositionChanged(CGFloat(max(0, rows.count - 1)), true)
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Browse collection", "快速浏览收藏"))
        .accessibilityValue(valueText)
        .accessibilityHint(tr(
            "Drag or use Left, Right, Home, and End to browse every song.",
            "拖动或使用左、右、Home 和 End 键浏览全部歌曲。"
        ))
        .help(tr(
            "Drag or use Left and Right arrows to browse songs",
            "拖动或使用左右方向键浏览歌曲"
        ))
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment:
                onPositionChanged(CGFloat(min(max(0, rows.count - 1), index + 1)), true)
            case .decrement:
                onPositionChanged(CGFloat(max(0, index - 1)), true)
            @unknown default:
                break
            }
        }
    }
}

private struct DeckScrollEventBridge: NSViewRepresentable {
    let isEnabled: Bool
    let onScroll: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll)
    }

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.coordinator = context.coordinator
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        context.coordinator.onScroll = onScroll
        context.coordinator.isEnabled = isEnabled
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
        nsView.coordinator = nil
    }

    final class MonitorView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.viewWindowDidChange()
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var view: MonitorView?
        var isEnabled = true
        var onScroll: (CGFloat) -> Void
        private var monitor: Any?

        init(onScroll: @escaping (CGFloat) -> Void) {
            self.onScroll = onScroll
        }

        func attach(to view: MonitorView) {
            self.view = view
            startMonitoringIfNeeded()
        }

        func viewWindowDidChange() {
            startMonitoringIfNeeded()
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func startMonitoringIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      self.isEnabled,
                      let view = self.view,
                      let window = view.window,
                      event.window === window else { return event }
                let location = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(location) else { return event }
                let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                    ? event.scrollingDeltaX
                    : event.scrollingDeltaY
                guard abs(delta) > 0.01 else { return event }
                self.onScroll(delta)
                return nil
            }
        }
    }
}
