# Muses 0.5.9

- Search now opens in the main content pane with persistent playback controls, shared navigation history and preserved queries.
- Settings actions use native Liquid Glass capsules. About follows Help & Privacy.
- Volume pointer input and keyboard adjustment work across the scale; outside dismissal consumes the click without activating underlying content.
- YouTube playback shares in-flight yt-dlp resolution, bounds retries and queue waiting, warms settled selections and nearby tracks, and reuses verified media byte ranges.
- Optional idle pre-download is off by default, with favorites/history scopes and 1/2/5/10 GB budgets. Existing cached media is preserved.
- App-owned HTTP, yt-dlp, media, helper and updater files stay under ~/.muses. Existing library data, queue state and credentials are preserved.

Requires macOS 14 or later. New streaming APIs or playback platforms are not added.
Real-network checks covered cold loading, prewarmed distant selection and seeking; cold resolution latency still depends on YouTube/network conditions.
Concurrent brand-font and installer redesign work is excluded from this release.

Release verification: 757 tests in 104 suites passed from the isolated release snapshot.
