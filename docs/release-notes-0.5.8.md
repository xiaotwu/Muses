# Muses 0.5.8

This update improves lyrics matching, native input, collection browsing and
YouTube playback responsiveness.

- Lyrics matching keeps editable title and artist queries stable during search,
  and preserves the dialog's heading and input layout.
- Global media keys control Muses playback after Accessibility permission is
  granted. Settings reports readiness and reconnects after authorization.
- Shortcuts & Gestures brings global hotkeys and player gestures into one
  settings category. A downward trackpad swipe returns to the browsing position
  without changing the current song; leftover swipe and momentum events no
  longer move the collection underneath the player.
- Now Playing has a trailing collapse button. Closing keeps the artwork and
  lyrics layout intact until its fade completes.
- Precise hero-card browsing follows trackpad motion, combines input at the
  window's display cadence, and aligns to one card when scrolling stops.
- Foreground stream resolution bypasses occupied background slots, cancels
  obsolete requests, and warms the settled hero-card selection's stream URL.
- Song credits use video metadata rather than imported-playlist ownership,
  preserving manually edited artist information.
- Collection destinations gain consistent controls and content states.
  Cold launch starts at Home, and opening Settings starts at General.
- Appearance offers Small, Standard and Large interface text plus a list of
  installed system font families.
- Volume controls use one floating capsule, and the playlist-add button uses
  borderless sidebar chrome.

Requires macOS 14 or later. Existing libraries, Google connections and queue
state are preserved. Media keys require Accessibility permission, called
Device Control and Data Access on newer macOS versions.

Physical-device checks confirmed Play/Pause interception without launching
Apple Music, real-network selection across a 1,001-position collection, and
improved rapid trackpad browsing with correct final alignment. Test and
verification details are recorded in `input-playback-validation-2026-10-01.md`.

Release verification: 746 tests in 102 suites passed from the isolated release
snapshot. The source snapshot excludes concurrent brand-font and installer
redesign work.
