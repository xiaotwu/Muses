<p align="center">
  <img src="logo-and-icon/icon.png" width="96" alt="Muses icon" />
</p>

<h1 align="center">Muses</h1>

<p align="center">
  A native macOS music player — a real desktop app for the music you love online.
</p>

<p align="center">
  <a href="https://github.com/xiaotwu/Muses/releases"><img src="https://img.shields.io/badge/platform-macOS%2014%2B-black?style=flat-square&logo=apple" alt="macOS 14+"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT License"></a>
  <a href="https://github.com/xiaotwu/Muses/actions"><img src="https://img.shields.io/badge/tests-455%2B%20passing-success?style=flat-square" alt="455+ Tests Passing"></a>
</p>

---

## What is Muses?

Muses is a native macOS music application. It takes the music you listen to on the web — imported playlists, your account, your recommendations — and gives it what it has always deserved: a real library with albums and artists, a floating glass capsule player, an immersive Now Playing experience with lyrics, and deep macOS integration.

Built entirely natively with **Swift 6 + SwiftUI + SwiftData + AVFoundation**. Not an Electron wrapper, not a web view wrap, not a downloader — a true desktop music application.

---

## Highlights

- **Albums & Artists Catalog** — Imported tracks and playlists automatically aggregate into clean catalog objects. Explore albums, EPs, and singles resolved by stable YouTube identifiers. Browse artist discographies directly from YouTube Music and compare your library with official tracklists.
- **Apple Music Web Chrome & Liquid Glass** — Left navigation pane with standard window button clearance, Search, Home, New, and Library. Expressive `#FA586A` Apple Music pink accent, neutral surfaces, and restrained semantic glass.
- **Floating Player (Persistent PlayerBar)** — A floating glass capsule carrying artwork, transport, scrubber, volume, lyrics, queue, and video overlay across every browsing surface.
- **Immersive Now Playing** — Large square cover and vinyl modes with smooth clock-synced lyrics on a distraction-free canvas. YouTube videos open as an on-demand overlay that pauses and resumes playback.
- **Song Detail Card Deck** — Centered fan-shaped card deck with focused navigation, scrubber, and one-tap expansion into the complete sortable tracklist. Playlists preserve their curated order.
- **Menu Bar & Desktop Integration** — Global media hotkeys, menu bar tray with compact playback controls, independent mini player floating window, and pinned desktop lyrics.
- **Sound Check & Gapless Playback** — ReplayGain automatic loudness normalization and smooth crossfade between consecutive tracks.
- **Personalized Home (Optional, Off by Default)** — With explicit consent, an isolated one-shot helper executable safely reads your browser session into a normalized, whitelisted local snapshot. It never touches playback, never writes playlists, and never stores cookies, auth hashes, or continuation tokens.
- **Deep macOS Integration** — Native media keys, system notifications, window state restoration, instant English / 简体中文 switching, complete VoiceOver accessibility, and full keyboard navigation.

---

## Privacy Principles

- **Local-First**: Account tokens stay securely in the macOS Keychain; your library, history, and notes live in a private local SwiftData store.
- **Isolated Web Session**: Browser cookies for personalized Home exist only in a permission-restricted temporary jar (0700/0600) deleted the moment the helper exits. Raw payloads and pagination tokens are never written to disk or logs.
- **Read-Only Web Display**: The web layer is purely display data. It has no authority over playback, cannot write to playlists, and cannot modify persisted user data.
- **No Telemetry**: No analytics SDK, no third-party trackers, and no tracking servers.

---

## Installation

1. Download the latest `Muses-x.y.z.dmg` from [Releases](https://github.com/xiaotwu/Muses/releases).
2. Mount the DMG and drag **Muses** into **Applications**.
3. On first launch, if macOS Gatekeeper asks for verification, **Right-click → Open**, or approve it in **System Settings → Privacy & Security**.
4. *(Recommended)* Grant Muses **Full Disk Access** via the shortcut in Settings to enable browser session detection for personalized Home.

---

## Building from Source

```bash
# Clone repository
git clone https://github.com/xiaotwu/Muses.git && cd Muses

# Fetch bundled yt-dlp binary into private resources
./Scripts/copy-ytdlp.sh

# Debug build
swift build

# Run the full test suite (455+ tests)
make test

# Assemble macOS Application bundle
make app

# (Optional) Build with your signing identity
make app MUSES_SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)"

# Generate drag-to-install DMG
MUSES_VERSION=0.4.0 make dmg
```

---

## Project Structure

```
Muses/
├── Package.swift                  # Single SwiftPM package
├── Sources/
│   ├── Muses/                     # Application core
│   │   ├── App/                   # App entry, tokens, window lifecycle
│   │   ├── Domain/                # Snapshots, catalog projections, models
│   │   ├── Features/              # Home, New, Catalog, NowPlaying, Settings, PlayerBar
│   │   ├── Infrastructure/        # yt-dlp bridge, media cache, process execution
│   │   ├── Persistence/           # SwiftData schema, store snapshots
│   │   └── Services/              # Playback, queue, history, search, catalog, desktop
│   ├── MusesWebHomeHelper/        # Isolated one-shot Web Home helper executable
│   ├── MusesWebHomeCore/          # Cookie jar, session client, whitelisted parser
│   └── MusesWebHomeProtocol/      # Versioned stdin/stdout IPC protocol
├── Tests/MusesTests/              # 455+ unit & integration tests (+ Fixtures/)
├── Scripts/                       # Packaging, DMG generation, signing, notarization
└── docs/                          # GitHub Pages documentation
```

---

## References & Credits

Muses builds upon excellent open-source work:

- **[yt-dlp](https://github.com/yt-dlp/yt-dlp)** — Stream resolution and metadata extraction engine, bundled as a private resource ([Unlicense](https://github.com/yt-dlp/yt-dlp/blob/master/LICENSE)).
- **[Swift](https://www.swift.org) / [SwiftUI](https://developer.apple.com/xcode/swiftui/) / [SwiftData](https://developer.apple.com/xcode/swiftdata/) / [AVFoundation](https://developer.apple.com/av-foundation/) / [Metal](https://developer.apple.com/metal/) / [Swift Testing](https://developer.apple.com/xcode/swift-testing/)** — Apple's programming languages, frameworks, and testing tools.
- **[Google OAuth 2.0](https://developers.google.com/identity/protocols/oauth2)** — Authorization protocol for optional read-only account sign-in.
- **[LRCLIB](https://lrclib.net/)** — Synced lyrics provider.

---

## License

Muses is released under the [MIT License](LICENSE).
Third-party components remain under their respective licenses. Respect the terms of service of any media and content sources you access.