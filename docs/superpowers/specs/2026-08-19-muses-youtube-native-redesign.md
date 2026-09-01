# Muses — YouTube-Native Redesign

- **Date:** 2026-08-19
- **Status:** Approved for implementation
- **Supersedes:** local-library and dual-AVAudioEngine chapters of `2026-08-11-muses-music-player-design.md`

## 1. Goal

Muses is a YouTube-native macOS music app. Happy-path playback is the official YouTube IFrame Player inside one app-lifetime `WKWebView`. Local file scanning and import are removed. Albums and Artists leave the information architecture.

## 2. Playback (updated 2026-08-19 evening)

IFrame embed as the sound source was rolled back: the parked WKWebView produced a broken Now Playing layout and paused when hidden.

```
PlaybackService
 └ YouTubeStreamEngine    yt-dlp → stream URL → AVPlayer start + disk cache
```

- Cover mode: square artwork. Vinyl: circular artwork.
- yt-dlp downloads are cached by `videoId` + quality. Settings can change quality and re-download.
- No WKWebView playback host.

## 3. Library

- Import: YouTube video or playlist URL only.
- Sidebar: Search, Home, New, Pins, Recently, Songs, History, Inbox, Playlists. No Albums, no Artists.
- SwiftData `Album` / `Artist` / `ScanRoot` tables stay. Stop writing. Drop later.

## 4. UI

- Home rails: square 160pt cards, center-cropped YouTube thumbs.
- Playlist detail: icon-only actions, lazy list of snapshots.
- History: animated recap glyphs + artwork rows (Reduce Motion → static).
- `YouTubeMark` on every YouTube affordance.
- `trackContextMenu` on every track surface.
- Source comments in English. `tr(en, zhHans, zhHant:nil, ja:nil)`.

## 5. Out of scope this pass

- Dropping SwiftData tables.
- Guaranteeing IFrame quality.
- Replacing yt-dlp metadata import with Data API.
