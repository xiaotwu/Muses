<p align="center">
  <img src="logo-and-icon/icon.png" width="96" alt="Muses icon" />
</p>

<h1 align="center">Muses</h1>

<p align="center">
  A native macOS music app that treats YouTube as its catalog — and listens to it the Apple&nbsp;Music way.
</p>

---

## What is Muses?

Muses turns YouTube — including YouTube Music — into a complete, elegant music application: import playlists, sign in to your account, personalize your Home, and enjoy a floating glass player with an immersive Now Playing and lyrics view. Everything is built natively with SwiftUI + AVFoundation. It is not a web wrapper and not a downloader — Muses makes YouTube feel like a true native macOS music experience.

### Highlights

- **YouTube-native library** — Import public playlists and build album/artist catalogs from stable IDs (never merged by display name); likes, subscriptions, and owned playlists connect through a read-only OAuth sign-in with tokens stored in the macOS Keychain.
- **Isolated personalized Home (optional, off by default)** — With your explicit consent, a separate one-shot helper reads your local YouTube Music browser session and turns it into a normalized local snapshot. It never participates in playback or playlist writes, and never stores cookies, auth hashes, raw responses, or pagination tokens. Snapshots are reused directly within a 15-minute freshness window; content up to 7 days old is clearly shown as "saved" with recovery guidance.
- **Floating now-playing bar (persistent PlayerBar)** — A glass capsule that carries artwork, transport, volume, lyrics, queue, and the YouTube video overlay across every browsing surface.
- **Immersive Now Playing** — Cover and vinyl modes, synced lyrics on a distraction-free canvas; YouTube videos open as an on-demand overlay (audio pauses, and can resume).
- **Song detail card deck** — A centered, draggable deck with one-tap expansion into the complete sortable track table; playlists keep their curated playlist order.
- **Deep macOS integration** — System media controls, notifications policy, window restoration, instant English/简体中文 switching, VoiceOver labels, and full keyboard access.
- **ReplayGain & gapless playback** — Consistent loudness from saved metadata; 0-second crossfade prioritizes seamless playback.

### Privacy principles

- Playback credentials (OAuth tokens) live in the macOS Keychain; playlist sync history stays on this Mac.
- Browser cookies for personalized Home exist only in a permission-restricted temporary jar deleted when the helper exits; raw responses and continuation tokens are never written to disk or logs.
- The web layer is read-only display data: it has no authority over playback, push notifications, playlist writes, or the app's source of truth for your data.

## Installation

1. Download `Muses-x.y.z.dmg` from [Releases](https://github.com/xiaotwu/Muses/releases), mount it, and drag **Muses** into **Applications**.
2. If macOS reports the app can't be verified, **right-click → Open**, or approve it under System Settings → Privacy & Security.
3. Recommended: grant Muses **Full Disk Access** (System Settings → Privacy & Security → Full Disk Access). The app's settings surface offers a direct shortcut. Reading browser sessions and some video sources requires it.

> The DMG is not notarized (Gatekeeper will warn). Proper distribution requires a Developer ID certificate and notarization — see the development guide.

## Building from source

```bash
git clone git@github.com:xiaotwu/Muses.git && cd Muses
./Scripts/copy-ytdlp.sh          # fetch the yt-dlp binary into Resources
swift build                      # debug build
make test                        # full test suite (swift test --no-parallel)
make app                         # assemble build/Muses.app
make app MUSES_SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)"
MUSES_VERSION=0.4.0 make dmg     # drag-to-install DMG
```

Optional: inject Google OAuth configuration via the **build environment** variables `MUSES_GOOGLE_OAUTH_CLIENT_ID` (and `MUSES_GOOGLE_OAUTH_CLIENT_SECRET`) — written into Info.plist at package time, never committed. Without it, guest browsing and playback work normally; only account sign-in is unavailable.

## Development

- Stack: Swift 6 / SwiftUI / SwiftData / AVFoundation / Swift Testing; macOS 14+.
- Layout: `Sources/Muses` (app), `Sources/MusesWebHome*` (isolated helper/parser/protocol), `Tests/MusesTests`, `Scripts/`, `docs/`.
- Engineering and acceptance rules: [AGENTS.md](AGENTS.md).
- User-facing docs and the GitHub Pages source live in [docs/](docs/).

## Documentation (GitHub Pages)

- [Introduction](docs/index.md)
- [Installation](docs/installation.md)
- [Privacy](docs/privacy.md)
- [Development guide & release runbook](docs/development.md)