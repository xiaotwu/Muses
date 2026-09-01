---
layout: default
title: Introduction
---

# Muses

**A native macOS music app that treats YouTube as its catalog — and listens to it the Apple Music way.**

Muses turns YouTube — including YouTube Music — into a complete, elegant music application: import playlists, sign in to your account, personalize your Home, and enjoy a floating glass player with an immersive Now Playing and lyrics view, all built natively with SwiftUI + AVFoundation. It is not a web wrapper and not a downloader; it makes YouTube feel like a true native macOS music experience.

## Key features

### YouTube-native library
Imported playlists become real catalog objects — albums and artists are built from stable YouTube IDs, never merged by display name. Likes, subscriptions, and owned playlists connect through a read-only OAuth sign-in; tokens are stored in the macOS Keychain and sync history stays on your Mac.

### Isolated personalized Home (optional · off by default)
With your explicit consent, a separate one-shot helper reads your local YouTube Music browser session and produces a normalized local snapshot:

- It never participates in playback or playlist writes.
- It never stores cookies, auth hashes, raw responses, or pagination tokens.
- Snapshots are reused directly within a 15-minute freshness window; content up to 7 days old is shown explicitly as "saved" with recovery guidance.
- The web channel identity must exactly match the connected OAuth channel — otherwise it fails closed.

### Floating player and immersive Now Playing
A persistent glass capsule carries artwork, transport, volume, lyrics, and the queue across every browsing surface. Full-screen Now Playing offers cover and vinyl modes with synced lyrics. YouTube videos open as an on-demand overlay — audio pauses, and can resume when the overlay closes.

### Song detail card deck
A centered, draggable deck shares a single canonical focus across drag, trackpad, chevrons, keyboard, and a first-to-last scrubber. One tap expands it into the complete sortable track table inside the content pane; playlists keep their curated playlist order.

### Deep macOS integration
System media keys and Now Playing, notification policy, window restoration, instant English/简体中文 switching, VoiceOver labels, and complete keyboard access are first-class product requirements — not polish items.

## Why Muses

| Typical workflow | Muses |
| --- | --- |
| Listening in a browser tab, disconnected from the system | A native window, floating player, and system media keys |
| Web wrappers and downloaders | A real SwiftUI + AVFoundation application |
| A library that is just a list of links | Album/artist catalogs and collections built on stable IDs |
| Login sessions left wherever the browser leaves them | An isolated helper with a temporary cookie jar, wiped on exit |

## Get started

- [Installation](installation.md)
- [Privacy](privacy.md)
- [Build from source](development.md)