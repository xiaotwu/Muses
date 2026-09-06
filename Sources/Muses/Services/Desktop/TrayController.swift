import AppKit
import Foundation
import SwiftUI

/// Menu-bar/tray controller (Final Spec §10.1 Feature 1 — NSStatusItem tray).
///
/// Owns an `NSStatusItem`; menu content refreshes the current track on
/// `PlaybackEventBus.trackStarted`. Feature flag `PrefKey.ffTray` (off by default):
/// off → hides and releases the status item. Left-click opens the modern Figure 2 Liquid Glass
/// player card popover (`MenuBarPlayerView`), while right-click opens the fast standard menu.
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
    private weak var playbackService: PlaybackService?
    private weak var audioDevices: AudioDeviceService?

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
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
         onQuit: @escaping () -> Void,
         playback: PlaybackService? = nil,
         audioDevices: AudioDeviceService? = nil) {
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
        self.playbackService = playback
        self.audioDevices = audioDevices
    }

    /// Toggles the tray: enabled → create and build the menu; disabled → release it. Idempotent.
    func setEnabled(_ enabled: Bool) {
        if enabled {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                statusItem = item
            }
            rebuild()
        } else {
            popover?.performClose(nil)
            popover = nil
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
        }
        revision &+= 1
    }

    /// Refreshes the menu (called after trackStarted events).
    func refresh() {
        guard statusItem != nil else { return }
        rebuild()
        revision &+= 1
    }

    private func rebuild() {
        guard let item = statusItem else { return }
        let track = trackProvider()
        item.button?.title = ""
        item.button?.image = TrayIcon.templateImage()
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.toolTip = track.map { "\($0.title) — \($0.artist)" } ?? tr("Muses", "Muses")
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.menu = nil
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showContextMenu(sender)
        } else {
            togglePopover(sender)
        }
    }

    private func showContextMenu(_ sender: NSStatusBarButton) {
        let track = trackProvider()
        let playing = isPlayingProvider()
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
            menu.addItem(mi)
        }
        statusItem?.popUpMenu(menu)
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }

        guard let playback = playbackService else {
            showContextMenu(sender)
            return
        }

        let p = NSPopover()
        p.behavior = .transient
        p.animates = true

        let cardView = MenuBarPlayerView(
            onOpenMain: { [weak self] in
                self?.popover?.performClose(nil)
                self?.onOpenMain()
            },
            onQuit: { [weak self] in
                self?.popover?.performClose(nil)
                self?.onQuit()
            }
        )
        .environment(playback)
        .environment(audioDevices)

        let hosting = NSHostingController(rootView: cardView)
        p.contentViewController = hosting
        p.contentSize = NSSize(width: 310, height: 185)

        self.popover = p
        p.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        p.contentViewController?.view.window?.makeKey()
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

/// Menu-bar menu specification (pure values, enabling AppKit-free unit testing).
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
