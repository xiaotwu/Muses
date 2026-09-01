---
layout: default
title: Introduction
---

# Muses

**A native macOS music player — a real desktop app for the music you love online.**

Muses takes the music you already listen to on the web — imported playlists, your account, your recommendations — and gives it what it has always deserved: a genuine library with albums and artists, a floating glass player, an immersive Now Playing with lyrics, and deep macOS integration. Built entirely natively with SwiftUI + AVFoundation. Not a web wrapper, not a downloader — a true desktop music application.

## Key features

### A real library
Imported playlists become genuine catalog objects — albums and artists are built from stable identifiers, never merged by display name. Likes, subscriptions, and owned playlists connect through a read-only account sign-in; tokens are stored in the macOS Keychain and sync history stays on your Mac.

### Isolated personalized Home (optional · off by default)
With your explicit consent, a separate one-shot helper reads your local browser session and produces a normalized local snapshot:

- It never participates in playback or playlist writes.
- It never stores cookies, auth hashes, raw responses, or pagination tokens.
- Snapshots are reused directly within a 15-minute freshness window; content up to 7 days old is shown explicitly as "saved" with recovery guidance.
- The remote channel identity must exactly match the connected account — otherwise it fails closed.

### Floating player and immersive Now Playing
A persistent glass capsule carries artwork, transport, volume, lyrics, and the queue across every browsing surface. Full-screen Now Playing offers cover and vinyl modes with synced lyrics. Videos open as an on-demand overlay — audio pauses, and can resume when the overlay closes.

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

## References & license

See [References and License on GitHub](https://github.com/xiaotwu/Muses#references) — Muses is MIT-licensed; the bundled yt-dlp binary is public-domain software ([Unlicense](https://github.com/yt-dlp/yt-dlp/blob/master/LICENSE)).