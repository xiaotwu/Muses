# Input and playback validation — 2026-10-01

## Scope

Validation used `build/MusesValidation.app` (`com.muses.validation`), an isolated
SQLite fixture in `/tmp/muses-input-acceptance`, and the acceptance cache partition.
The running production application and its library were preserved. Only the
validation application received the user-approved Device Control and Data Access
permission (the current system label for Accessibility).

## Confirmed results

- Physical Play/Pause: the user pressed the hardware key twice. The event tap
  recorded exactly two presses; the player returned to paused at 1:00. The user
  reported that Apple Music did not appear, and the running-app inventory confirmed
  that Music remained stopped.
- Cold distant selection: in a 1,001-position collection, real YouTube playback
  moved from position 1 (`aqz-KE-bpKQ`) to position 1,001 (`kJQP7kiw5Fk`). At
  11.876 seconds after activation, polling observed 0:01 / 4:42 and subsequent
  continued progress. This passed playback correctness but exposed resolution delay.
- Focus URL warmup: after dwelling on position 501 (`9bZkp7q19f0`), activation
  from position 1,001 showed 0:00 / 4:12 at 1.768 seconds and 0:01 / 4:12 at
  2.863 seconds. Playback continued for over two minutes. Polling includes UI
  inspection overhead; these are observed bounds, not exact audio-start times.
  Different songs and cache conditions mean these samples are not a controlled
  speedup comparison or a latency guarantee.
- Automated verification: 744 tests in 103 suites passed, including warmup reuse,
  cancellation despite a dependency ignoring cancellation, stale-load rejection,
  media-key decoding, gesture thresholds and natural-scroll direction mapping.
- Release build completed, and `build/MusesRepairs.app` passed strict deep
  signature verification.

The fixture contains only three materialized real YouTube tracks. Synthetic lazy
positions supply collection distance; they were not intentionally played. No
local audio was used for the live playback checks. Network playback ran at muted
application volume, with transport progress observed.

## Implementation

The media-key event tap is retried when the application becomes active after
permission changes. Settings exposes readiness and the received-press count.
The settled collection focus warms one stream URL after the existing 350 ms
debounce. Changing focus cancels it; activating playback cancels unfinished
speculation and uses the independent foreground resolver. Warmup neither downloads
an entire collection nor changes the queue, playback state, or gapless next slot.

## Pending physical checks

Return semantics were subsequently verified in the rendered application: with
position 501 paused at 0:14 and browsing focused on position 1,001, both toolbar
Back and the downward-chevron button returned to position 1,001. The current
track and its position stayed unchanged. The downward gesture now invokes that
same return callback. Repeated collection appearance preserves its live focus
before considering saved focus or the currently playing item. The scoped
collection/presentation regression run passed 31 tests in three suites; the
release application was rebuilt and its signature reverified.

The two-finger downward gesture is awaiting the user's hardware action and
feedback. Optional horizontal track switching and upward lyrics gestures have
policy tests but do not yet have physical-device acceptance evidence. Hardware
Next/Previous keys were not part of the two-press Play/Pause test.

Production permission is separate from the isolated validation permission.

## Follow-up: swipe return moved focus from 1000 to 0974

The user reported this physical-device failure after the button-return checks.
Runtime inspection confirmed the player was still on `1000 · Despacito` while
the browsing focus had moved to `0974`. The earlier button checks did not cover
the complete swipe event sequence. Source inspection found the underlying
collection's local scroll monitor remained enabled during Now Playing and also
accepted remaining events after overlay dismissal.

Browsing input is now disabled while Now Playing is open. A window-scoped
transient tail guard consumes the returning swipe and its momentum after the
overlay disappears. A new finger gesture releases the guard immediately; 300 ms
without events expires it. The collection monitor also checks the guard before
its delta accumulator, regardless of local-monitor ordering. A regression test
covers continuing deltas, inertia, a fresh gesture, and idle expiry. All 32 scoped
tests passed. The updated validation bundle is prepared with both current track
and browsing focus at `1000`; physical swipe acceptance is awaiting feedback.

## Follow-up: flash during downward return

The user subsequently reported flashing during the closing transition. Runtime
inspection after that physical swipe showed browsing still at `1000` with the
same paused track and position, confirming the scroll-tail correction for this
sample. Inspection found that dismissal removed the external artwork host and
reset the lyrics column at the start of a 300 ms fade, changing both artwork
ownership and layout while they were still visible.

The artwork host and lyrics layout now remain mounted throughout the fade.
Cleanup waits for SwiftUI's animation-removal completion instead of a fixed
sleep, and uses an animation-free transaction. Reopening cancels pending cleanup;
Reduce Motion retains immediate dismissal. All 89 scoped chrome, collection and
repair tests passed. The updated validation bundle is open on the same track;
physical smoothness acceptance is awaiting user feedback. No frame-pacing or
universal smoothness claim is made from unit tests or static screenshots.

## Follow-up: fast hero-card browsing

Code review found precise trackpad movement was quantized into steps, with every
step retargeting the 220 ms discrete snap animation. Precise input now advances
fractional collection position without animation, following finger and momentum
deltas. One coordinator-owned idle watcher aligns the final position after input
stops; it does not create/cancel a task for every event. Keyboard and non-precise
wheel navigation retain discrete snapping. The per-event movement bound remains
three positions, and current playback/queue state is unchanged by browsing.

The stage no longer constructs `rows.map(\.id)` during every position update;
it observes the existing immutable rows value for collection changes. Visible
card virtualization and existing 350 ms metadata/warmup debounce remain intact.
All 94 scoped tests passed, including continuous sub-threshold movement,
direction, bounds, accumulated distance and the preceding return regressions.
Rendered inspection confirmed artwork, card overlap, scrubber and PlayerBar
layout. Physical fast-swipe acceptance is awaiting user feedback. These changes
remove concrete work from the input path; no measured frame-rate improvement is
claimed without a comparable runtime trace.

The user reported that the first continuous-input version still stuttered.
The follow-up now coalesces precise deltas in a non-observable accumulator and
publishes once per `NSView` window display-link tick. This follows the current
display cadence instead of updating SwiftUI for every input event. Accumulated
movement and direction reversals are conserved. The display link runs only
while input/inertia is active, stops after idle alignment, and is invalidated
when the surface is disabled, moved between windows, or dismantled. No per-event
tasks are scheduled. All 95 scoped tests passed, including coalescing distance,
reversals and clearing consumed input. The first two process samples mostly
captured idle and accessibility inspection; they are insufficient to attribute
the residual stutter or quantify an improvement. Second-round physical
acceptance passed: the user reported "明显改善，停止后对齐正常" after
rapidly swiping the updated display-paced version. This is qualitative
physical-device acceptance, not a measured FPS improvement. The release bundle
was updated and strict deep signature verification passed.
