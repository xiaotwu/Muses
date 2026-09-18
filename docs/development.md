---
layout: default
title: Development
---

# Development guide

Muses is a Swift 6 package with a standard SwiftPM layout, built with SwiftUI, SwiftData, AVFoundation, and Swift Testing. Target platform is macOS 14+.

Home is a mode-switched product boundary. The default Muses provider ranks local library snapshots on-device. The YouTube Music provider uses anonymous Innertube as its baseline and may layer an explicitly authorized, account-matched Web response from the isolated helper. Neither network path receives Muses listening signals.

## Project layout

```
Muses/
├── Package.swift                  # Single package: Muses (app), MusesWebHomeHelper (one-shot helper),
│                                  # MusesWebHomeProtocol / MusesWebHomeCore, MusesTests
├── Sources/
│   ├── Muses/                     # App, Domain, Features, Infrastructure, Persistence,
│   │                              # Services (Discovery, Recommendation, YouTube), Resources
│   ├── MusesWebHomeHelper/        # Isolated one-shot helper executable
│   ├── MusesWebHomeCore/          # Cookie jar, session client, whitelisted payload parser
│   └── MusesWebHomeProtocol/      # Versioned stdin/stdout IPC contract
├── Tests/MusesTests/              # Swift Testing suites (+ Fixtures/)
├── Scripts/                       # Packaging, DMG, icon, yt-dlp bootstrap
└── docs/                          # User docs (also powers GitHub Pages)
```

## Build & test

```bash
./Scripts/copy-ytdlp.sh          # fetch yt-dlp into Sources/Muses/Resources (git-ignored)
swift build                      # debug build
make test                        # full suite: swift test --no-parallel
swift test --filter InnertubeHome # focused parser/request/privacy suite
swift test --filter WebHome       # focused signed-in helper suite
make app                         # assemble build/Muses.app
make app MUSES_SIGN_IDENTITY="Apple Development: you (TEAMID)"
MUSES_VERSION=0.5.0 make dmg
```

Google OAuth configuration is injected at packaging time through build environment variables:

```bash
MUSES_GOOGLE_OAUTH_CLIENT_ID=...      MUSES_GOOGLE_OAUTH_CLIENT_SECRET=... \
    ./Scripts/build-app.sh --identity "Apple Development: you (TEAMID)"
```

They are never committed, never logged, and are not present unless you inject them. Sign out of the app revokes tokens stored in the Keychain.

## Conventions

- Source code, identifiers, and comments are English; user-visible strings go through `tr(_ en:, _ zhHans:)`.
- Comments explain intent and invariants; no phase-number prefixes, no store-generation "V" labels in naming.
- Engineering, UX, privacy, and verification rules live in [AGENTS.md](../AGENTS.md) — read it before changing playback, queue, persistence, packaging, or the signed-in Home boundary.
- Keep Home providers behind `HomeDiscoveryProvider`. Muses and YouTube Music caches are mode-partitioned; guest and account scopes remain physically separate inside each mode.
- The anonymous Innertube request must never contain cookies, authorization headers or locally derived recommendation signals. Continuation tokens stay in memory and are not encoded into saved snapshots.

## Release runbook

### Prerequisites

1. Apple Developer Program membership and a **Developer ID Application** certificate for public distribution (import into Keychain; note the identity name).
2. Sparkle EdDSA key pair for update signing (`SUPublicEDKey` is injected into Info.plist by `Scripts/sign-update.sh`; export the private key outside the repository).

### Build a distributable DMG

```bash
MUSES_GOOGLE_OAUTH_CLIENT_ID=... MUSES_GOOGLE_OAUTH_CLIENT_SECRET=... MUSES_WEB_HOME_ENABLED=YES \
    ./Scripts/build-app.sh --identity "$MUSES_SIGN_IDENTITY"
MUSES_VERSION=0.5.0 ./Scripts/make-dmg.sh
# Notarization, when credentials exist:
./Scripts/notarize.sh
```

### Publish a release

```bash
git tag -a v0.5.0 -m "Muses 0.5.0" && git push origin v0.5.0
gh release create v0.5.0 build/Muses-0.5.0.dmg --title "Muses 0.5.0" --notes "…"
```

### Pre-release checklist

- [ ] `make test` green
- [ ] `codesign --verify --deep --strict` on the app and the bundled helper
- [ ] Helper present at `Contents/Helpers/MusesWebHomeHelper`, mode 0700, same-signature chain
- [ ] Fresh install defaults to Muses mode; helper never launches without signed-in Home consent
- [ ] Sensitive-material audit: no cookies/SAPISIDHASH/continuation tokens in logs, SwiftData, or caches
- [ ] Notarization performed (if distributing beyond test users)

### Troubleshooting

- **"could not find chrome cookies database"** — macOS privacy (TCC) denies the app's access to other applications' data, so the cookie file appears absent. Grant Full Disk Access to the exact `.app` you are running; ad-hoc rebuilds invalidate that grant, so sign with a stable certificate identity during development.
- **Helper "signature rejected"** — the helper must be signed before the app bundle (`Scripts/build-app.sh` handles this ordering).
- **Keychain prompts repeat** — re-signing with a *different* certificate invalidates keychain ACLs; keep the identity stable and click "Always Allow" once.

## GitHub Pages

`docs/` doubles as the site source (Jekyll). Set the repository Pages source to *Deploy from branch → `main` → `/docs`* to publish it.
## 0.5.0 preview build

`make clean` removes the complete SwiftPM build directory and app packaging outputs.
The GitHub `macOS build` workflow runs serial tests and uploads an ad-hoc signed
Apple Silicon preview bundle. Publishing a notarized distribution requires a
Developer ID identity and notary credentials; the public 0.5.0 preview is not notarized.
OAuth configuration is injected only at packaging time and must not be committed.

Settings uses first-level categories with expanded sections. Shared glass actions
live in `Features/Shared/GlassControls.swift`; controls use capsule shapes while
artwork and large reading surfaces preserve their aspect ratios. Native glass is
availability-gated and retains older-system and accessibility fallbacks.
