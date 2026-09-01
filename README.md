<p align="center">
  <img src="logo-and-icon/icon.png" width="96" alt="Muses icon" />
</p>

<h1 align="center">Muses</h1>

<p align="center">
  A native macOS music player — a real desktop app for the music you love online.
</p>

---

## What is Muses?

Muses is a native macOS music application. It takes the music you already listen to on the web — imported playlists, your account, your recommendations — and gives it what it has always deserved: a real library with albums and artists, a floating glass player, an immersive Now Playing with lyrics, and deep macOS integration. Built entirely natively with SwiftUI + AVFoundation. Not a web wrapper, not a downloader — a true desktop music application.

### Highlights

- **A real library** — Imported playlists become genuine catalog objects: albums and artists built from stable identifiers, never merged by display name. Likes, subscriptions, and owned playlists connect through a read-only account sign-in; tokens stay in the macOS Keychain.
- **Personalized Home (optional, off by default)** — With your explicit consent, a separate one-shot helper reads your local browser session and turns it into a normalized local snapshot. It never participates in playback or playlist writes, and never stores cookies, auth hashes, raw responses, or pagination tokens. Snapshots are reused directly within a 15-minute freshness window; older content is clearly shown as "saved" with recovery guidance.
- **Floating player (persistent PlayerBar)** — A glass capsule carrying artwork, transport, volume, lyrics, queue, and the video overlay across every browsing surface.
- **Immersive Now Playing** — Cover and vinyl modes, synced lyrics on a distraction-free canvas; videos open as an on-demand overlay (audio pauses, and can resume).
- **Song detail card deck** — A centered, draggable deck with one-tap expansion into the complete sortable track table; playlists keep their curated order.
- **Deep macOS integration** — System media controls, notifications policy, window restoration, instant English/简体中文 switching, VoiceOver labels, and full keyboard access.
- **ReplayGain & gapless playback** — Consistent loudness from saved metadata; 0-second crossfade prioritizes seamless playback.

### Privacy principles

- Account tokens live in the macOS Keychain; sync history stays on this Mac.
- Browser cookies for personalized Home exist only in a permission-restricted temporary jar deleted when the helper exits; raw responses and pagination tokens are never written to disk or logs.
- The web layer is read-only display data: it has no authority over playback, push notifications, playlist writes, or the app's source of truth for your data.

## Installation

1. Download `Muses-x.y.z.dmg` from [Releases](https://github.com/xiaotwu/Muses/releases), mount it, and drag **Muses** into **Applications**.
2. If macOS reports the app can't be verified, **right-click → Open**, or approve it under System Settings → Privacy & Security.
3. Recommended: grant Muses **Full Disk Access** (the app's settings surface offers a direct shortcut). Reading your browser session and some video sources requires it.

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

## References

Muses stands on the shoulders of excellent open work:

- **[yt-dlp](https://github.com/yt-dlp/yt-dlp)** — stream resolution and metadata extraction engine, bundled as a private resource. Licensed under the [Unlicense](https://github.com/yt-dlp/yt-dlp/blob/master/LICENSE) (public domain).
- **[Swift](https://www.swift.org) / [SwiftUI](https://developer.apple.com/xcode/swiftui/) / [SwiftData](https://developer.apple.com/xcode/swiftdata/) / [AVFoundation](https://developer.apple.com/av-foundation/) / [Metal](https://developer.apple.com/metal/) / [Swift Testing](https://developer.apple.com/xcode/swift-testing/)** — Apple's open languages, frameworks, and tooling.
- **[Google OAuth 2.0](https://developers.google.com/identity/protocols/oauth2)** — the authorization protocol used for optional account sign-in.
- **[SwiftLint-style conventions](AGENTS.md)** — engineering, UX, and privacy rules maintained in [AGENTS.md](AGENTS.md).

## License

Muses is released under the [MIT License](LICENSE).

Third-party components remain under their own licenses:
the bundled yt-dlp binary is public-domain software ([Unlicense](https://github.com/yt-dlp/yt-dlp/blob/master/LICENSE)),
and platform frameworks are provided by Apple under their respective terms.
Respect the terms of service of the content sources you use with Muses.

## Development

- Stack: Swift 6 / SwiftUI / SwiftData / AVFoundation / Swift Testing; macOS 14+.
- Layout: `Sources/Muses` (app), `Sources/MusesWebHome*` (isolated helper/parser/protocol), `Tests/MusesTests`, `Scripts/`, `docs/`.
- User-facing documentation and the GitHub Pages source live in [docs/](docs/); the introduction mirrors this page on [the project site](docs/index.md).