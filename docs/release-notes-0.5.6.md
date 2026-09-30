# Muses 0.5.6

This update refreshes artwork-led browsing and Now Playing with the T3C indigo theme and F3 typography.

- Songs and playlist details offer a flat, overlapping focus strip and a cover wall. Focus, navigation, and collection playback context stay consistent across the two views.
- Compact page headers, more space below the card scrubber, and a shared floating-player position improve desktop layouts. Larger windows reveal a small preview of complete song-list rows in the available space.
- Indigo headings and navigation accents pair with graphite playback controls and mist-gray surfaces in light and dark appearances.
- Georgia headings and lyrics, Avenir Next song information, and Chinese/Japanese font fallbacks give the interface clearer typographic hierarchy. Native controls retain system typography.
- Hero cards show song title, verified artist, and available album metadata instead of playlist-owner information.
- Now Playing uses responsive artwork and lyrics columns, with glass controls that reveal artwork-derived colors.
- Lyrics matching searches more title and artist variants, including normalized Unicode and title-only fallback queries. Existing sources and strict automatic matching remain in place; no lyrics or timestamps are generated.

Requires macOS 14 or later. ZIP and DMG downloads are signed with Developer ID, notarized, and stapled.

Validation: the final full run passed 707 tests in 99 suites. An initial run hit an intermittent existing Home cache invalidation test failure; its focused rerun and the complete rerun both passed. Native UI checks covered collection layouts, list view, Settings, and Now Playing in light and dark appearances. Timed lyrics typography was checked through font and glyph tests; a live timed-lyrics rendering was unavailable during validation.

Existing libraries and Google connections are preserved. No library database, account tokens, or private validation screenshots are included in the downloads.
