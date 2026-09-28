# Muses 0.5.5

This update improves library browsing, settings, lyrics matching, and macOS integration.

- Songs now follows the union of active playlists. Deleted playlists no longer leave unrelated songs in Songs; local recovery records can be cleared.
- Collection decks respond more efficiently to dragging and trackpad input, with isolated card updates, deferred focus persistence, and artwork decoding off the main thread. A corner action locates the currently playing song.
- Page actions share centered circular Liquid Glass controls. Playlist deletion, track removal, queue/history removal, and cache clearing require confirmation. Cloud playlist writes retain explicit account and target review.
- Settings uses a consistent category layout, compact controls, and Home navigation. Collapsed navigation shows icons only. YouTube affordances are monochrome.
- Connected Google accounts can import their YouTube playlists automatically. Importing reads cloud content; playlist writes remain separately confirmed.
- Lyrics matching offers additional sources and optional on-device Apple Intelligence assistance for search metadata. It does not invent lyrics or timestamps. Lyrics and unavailable states are centered in the right column.
- The application icon uses the white-background artwork across bundled macOS icon resources.

Requires macOS 14 or later. ZIP and DMG downloads are signed with Developer ID, notarized, and stapled. Apple Intelligence features require a supported Mac and an available on-device model; standard lyrics search remains available otherwise.

Validation: 696 tests in 96 suites passed, followed by 136 focused UI-policy, collection, queue, and playlist-sync tests. Installed-app checks covered collection controls, menu edge clicks, and cancellation of local/cloud confirmation dialogs. Frame-rate gains and lower memory consumption are not claimed; performance measurements varied between runs.

The release does not reset existing users' libraries or Google connections. No library database, account tokens, or private test recordings are included in the downloads.
