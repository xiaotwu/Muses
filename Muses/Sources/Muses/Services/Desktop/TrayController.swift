import AppKit
import Foundation

/// 菜单栏/托盘控制器(Final Spec §10.1 Feature 1 — NSStatusItem tray)。
///
/// 持有一个 `NSStatusItem`,菜单内容随 `PlaybackEventBus.trackStarted` 刷新当前曲目。
/// 功能开关 `PrefKey.ffTray`(默认关):关 → 隐藏并释放 status item。所有动作通过注入的
/// 闭包派发(生产接 CommandRegistry/PlaybackService;测试可注入录音器),便于无 AppKit 依赖的单元测试。
@MainActor
final class TrayController {
    private let trackProvider: () -> TrackSnapshot?
    private let isPlayingProvider: () -> Bool
    private let onPlayPause: () -> Void
    private let onNext: () -> Void
    private let onPrevious: () -> Void
    private let onLike: () -> Void
    private let onAddToInbox: () -> Void
    private let onOpenMini: () -> Void
    private let onOpenMain: () -> Void
    private let onQuit: () -> Void
    private var statusItem: NSStatusItem?
    private(set) var revision: Int = 0

    init(trackProvider: @escaping () -> TrackSnapshot?,
         isPlayingProvider: @escaping () -> Bool,
         onPlayPause: @escaping () -> Void,
         onNext: @escaping () -> Void,
         onPrevious: @escaping () -> Void,
         onLike: @escaping () -> Void,
         onAddToInbox: @escaping () -> Void,
         onOpenMini: @escaping () -> Void,
         onOpenMain: @escaping () -> Void,
         onQuit: @escaping () -> Void) {
        self.trackProvider = trackProvider
        self.isPlayingProvider = isPlayingProvider
        self.onPlayPause = onPlayPause
        self.onNext = onNext
        self.onPrevious = onPrevious
        self.onLike = onLike
        self.onAddToInbox = onAddToInbox
        self.onOpenMini = onOpenMini
        self.onOpenMain = onOpenMain
        self.onQuit = onQuit
    }

    /// 开关同步:启用 → 创建并构建菜单;禁用 → 释放。幂等。
    func setEnabled(_ enabled: Bool) {
        if enabled {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                statusItem = item
            }
            rebuild()
        } else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
        }
        revision &+= 1
    }

    /// 刷新菜单(在 trackStarted 事件后调用)。
    func refresh() {
        guard statusItem != nil else { return }
        rebuild()
        revision &+= 1
    }

    private func rebuild() {
        guard let item = statusItem else { return }
        let track = trackProvider()
        let playing = isPlayingProvider()
        item.button?.title = ""
        item.button?.image = TrayIcon.templateImage()
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.toolTip = track.map { "\($0.title) — \($0.artist)" } ?? tr("Muses", "Muses")
        let menu = NSMenu()
        menu.autoenablesItems = false
        for spec in TrayMenuModel.items(track: track, isPlaying: playing) {
            if spec.kind == .separator {
                menu.addItem(.separator()); continue
            }
            let mi = NSMenuItem(title: spec.title, action: #selector(menuAction(_:)),
                                 keyEquivalent: "")
            mi.target = self
            mi.tag = TrayMenuModel.tag(for: spec.kind)
            mi.isEnabled = spec.enabled
            mi.target = self
            menu.addItem(mi)
        }
        item.menu = menu
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let kind = TrayMenuModel.kind(for: sender.tag) else { return }
        switch kind {
        case .playPause:    onPlayPause()
        case .next:         onNext()
        case .previous:     onPrevious()
        case .like:         onLike()
        case .addToInbox:   onAddToInbox()
        case .openMini:     onOpenMini()
        case .openMain:     onOpenMain()
        case .quit:         onQuit()
        case .header, .separator: break
        }
    }
}

/// Menu-bar template mark: the bundled logo, white knocked out so macOS can
/// invert it for light and dark menu bars.
enum TrayIcon {
    static let symbolName = "music.note"
    static let symbolPointSize: CGFloat = 15

    static func loadLogo() -> NSImage? {
        let url = Bundle.main.url(forResource: "logo", withExtension: "png")
            ?? Bundle.module.url(forResource: "logo", withExtension: "png")
        return url.flatMap { NSImage(contentsOf: $0) }
    }

    static func templateImage(from source: NSImage? = nil, pointSize: CGFloat = 18) -> NSImage {
        if source == nil,
           let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Muses") {
            let configuration = NSImage.SymbolConfiguration(
                pointSize: min(symbolPointSize, pointSize),
                weight: .semibold
            )
            let image = symbol.withSymbolConfiguration(configuration) ?? symbol
            image.isTemplate = true
            return image
        }

        let src = source ?? loadLogo() ?? NSImage(size: NSSize(width: pointSize, height: pointSize))
        let scale: CGFloat = 2
        let px = max(Int((pointSize * scale).rounded()), 1)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: px,
            pixelsHigh: px,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            src.size = NSSize(width: pointSize, height: pointSize)
            src.isTemplate = true
            return src
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        src.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
                 from: .zero,
                 operation: .copy,
                 fraction: 1,
                 respectFlipped: true,
                 hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()

        if let data = rep.bitmapData {
            let row = rep.bytesPerRow
            let spp = 4
            for y in 0..<px {
                for x in 0..<px {
                    let i = y * row + x * spp
                    let r = CGFloat(data[i]) / 255
                    let g = CGFloat(data[i + 1]) / 255
                    let b = CGFloat(data[i + 2]) / 255
                    let a = CGFloat(data[i + 3]) / 255
                    let lum = 0.299 * r + 0.587 * g + 0.114 * b
                    if a < 0.08 || lum > 0.88 {
                        data[i] = 0
                        data[i + 1] = 0
                        data[i + 2] = 0
                        data[i + 3] = 0
                    } else {
                        let ink = UInt8(min(255, max(0, Int((1 - lum) * a * 255))))
                        data[i] = 0
                        data[i + 1] = 0
                        data[i + 2] = 0
                        data[i + 3] = ink
                    }
                }
            }
        }
        // Mark this bitmap as a 2x backing representation instead of a 36pt
        // image that AppKit has to resample back down in the menu bar.
        rep.size = NSSize(width: pointSize, height: pointSize)

        let img = NSImage(size: NSSize(width: pointSize, height: pointSize))
        img.addRepresentation(rep)
        img.isTemplate = true
        return img
    }
}

/// 菜单栏菜单规格(纯值,便于无 AppKit 依赖的单元测试)。
enum TrayMenuModel {
    struct Item: Equatable, Sendable {
        enum Kind: Int, Sendable, Equatable {
            case header = 0, playPause = 1, next = 2, previous = 3, like = 4,
                 addToInbox = 5, openMini = 6, openMain = 7, quit = 8, separator = 99
        }
        let kind: Kind
        let title: String
        let enabled: Bool
    }

    static func tag(for kind: Item.Kind) -> Int { kind.rawValue }
    static func kind(for tag: Int) -> Item.Kind? { Item.Kind(rawValue: tag) }

    static func items(track: TrackSnapshot?, isPlaying: Bool) -> [Item] {
        var out: [Item] = []
        let headerTitle: String
        if let track {
            headerTitle = "\(track.title) — \(track.artist)"
        } else {
            headerTitle = tr("Muses", "Muses")
        }
        out.append(Item(kind: .header, title: headerTitle, enabled: false))
        out.append(Item(kind: .separator, title: "", enabled: false))
        out.append(Item(kind: .playPause,
                       title: isPlaying ? tr("Pause", "暂停") : tr("Play", "播放"),
                       enabled: track != nil))
        out.append(Item(kind: .previous, title: tr("Previous", "上一首"), enabled: track != nil))
        out.append(Item(kind: .next, title: tr("Next", "下一首"), enabled: track != nil))
        out.append(Item(kind: .separator, title: "", enabled: false))
        out.append(Item(kind: .like, title: tr("Like", "收藏"), enabled: track != nil))
        out.append(Item(kind: .addToInbox, title: tr("Add to Inbox", "加入收件箱"), enabled: track != nil))
        out.append(Item(kind: .separator, title: "", enabled: false))
        out.append(Item(kind: .openMini, title: tr("Open Mini Player", "打开迷你播放器"), enabled: true))
        out.append(Item(kind: .openMain, title: tr("Open Muses", "打开 Muses"), enabled: true))
        out.append(Item(kind: .separator, title: "", enabled: false))
        out.append(Item(kind: .quit, title: tr("Quit Muses", "退出 Muses"), enabled: true))
        return out
    }
}
