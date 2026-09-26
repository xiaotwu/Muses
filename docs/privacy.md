---
layout: default
title: Privacy
---

# Privacy & data boundaries

Muses is a personal, local-first application. This page documents exactly what leaves your machine and what never does.

## What stays on this Mac

| Data | Location |
| --- | --- |
| OAuth tokens (read-only YouTube account) | macOS Keychain |
| Library: tracks, playlists, likes, pins, history, notes | `~/.muses/data` |
| Downloaded media streams | `~/.muses/cache/streams` |
| Home feed snapshots (separate Muses and YouTube Music partitions) | `~/.muses/cache/home-feed/` |
| Session/configuration | `UserDefaults` on this Mac |

## Home and recommendations

Home has two user-selectable sources. Changing the source does not merge their recommendation data or caches.

### Muses

Muses is the default. Recommendations are computed on-device from the local library, likes and listening history. The profile is deterministic, remains on this Mac and is never sent to YouTube or Google as recommendation input.

### YouTube Music

YouTube Music mode requests recommendation shelves directly from YouTube Music. Anonymous requests contain the protocol metadata needed by YouTube Music, but no Muses library, likes, listening history, cookies or authorization headers. If the request fails, Muses can show a previously saved normalized snapshot from the same mode and scope; it does not silently switch recommendation sources.

Signed-in YouTube Music recommendations are an additional, explicit choice. When authorized:

1. A **separate one-shot helper executable** performs every web request. It is launched, does one job, and exits. The main app never embeds web content and does not use WKWebView.
2. The helper starts by exporting your browser's YouTube cookies into a **permission-restricted temporary jar** (`0700` directory, `0600` file). That jar is deleted the moment the helper exits.
3. Authentication uses a per-request **SAPISIDHASH generated in memory**. Continuation (pagination) tokens exist only in the app's volatile memory and are never encoded into saved caches.
4. Every saved Home snapshot is **whitelist-parsed and normalized**. Raw responses are not kept; unknown response shapes fail closed instead of being stored or rendered.
5. The web channel identity is verified to **exactly match** the connected OAuth channel. Any mismatch or shape change fails closed.
6. Cookie values, auth hashes, raw payloads, and continuation tokens are **never logged** — the app and helper contain no logging sinks for them.

## What YouTube Music Home may not do

The YouTube Music Home layer is read-only display data. By design it cannot:

- start or control playback,
- send push notifications,
- write or modify playlists,
- act as the app's source of truth for your data.

## Google account

- The app requests the minimum read-only scope first; playlist management is granted only through a separate, explicit in-app action.
- You can revoke access at any time at [myaccount.google.com/permissions](https://myaccount.google.com/permissions), and disconnect from within the app.

## Network traffic

The app talks to YouTube/Google endpoints to resolve streams, fetch metadata and, when selected, render YouTube Music Home. There is no analytics SDK, no third-party telemetry and no server operated for Muses. Update checks call the GitHub Releases API.
