# Muses playback/window-loss reproduction

Date: 2026-08-17  
Bundle: `build/Muses.app` (`com.muses.app`, 0.4.0)  
Environment: dark appearance, 1280×800 main window

## Verdict

**Literal zero-visible-window symptom: not reproduced.**  
**Playback-triggered runtime failure: reproduced.**

Starting the available YouTube track caused a severe `NowPlayingManager` observation/task runaway. Muses remained the active, unhidden application and WindowServer continued to show its named 1280×800 window onscreen, but Accessibility stopped responding and reported `kAXErrorCannotComplete`. That failure is sufficient to explain the capture timeouts and misleading zero-window automation results.

## Exact reproduction

1. Quit the prior Muses process.
2. Launch `/Users/xiaotwu/Code/xyz/build/Muses.app` with `/usr/bin/open -n`.
3. Confirm PID 63159, one main non-minimized 1280×800 window at `(0,39)`, dark appearance, and stopped PlayerBar.
4. Open **YouTube Imports** through the sidebar.
5. Click the imported playlist's ordinary **Play** button at 08:41:59 local time.
6. Poll process, activation, AX window, and WindowServer state independently; capture the WindowServer window without asking Muses for an accessibility snapshot.
7. Attempt normal Command-Q after the runaway begins. It did not complete within five seconds, so the exact validated process was terminated with SIGTERM to stop memory growth.
8. Relaunch normally. PID 63601 returned to one responsive 1280×800 window at low CPU and approximately 140 MB RSS. A normal `/usr/bin/open build/Muses.app` activation reused that process and window.

## Local playback

Not testable. A read-only query of the active SwiftData store found five `youtube` track rows, zero local file paths, and only one distinct YouTube ID. No local track was available to start without mutating the library.

## YouTube playback

- Playback state did start: CoreAudio enabled its output stream, AVPlayer/MediaRemote activity began, and the captured PlayerBar showed a pause control and `0:18 / 3:54` progress.
- The main window remained visually present and onscreen. See [YouTube playback capture](/Users/xiaotwu/Code/xyz/artifacts/playback-window-repro-2026-08-17/02-youtube-start-windowserver.png).
- AX degraded within seconds and then returned error `-25204` (`kAXErrorCannotComplete`). AX's apparent count became zero while CGWindowList still reported one onscreen Muses window, number 9578, at 1280×800.
- At 08:43:20, Muses was still active/unhidden but used 363% CPU and about 4.75 GB RSS. A process sample showed a rapidly growing physical footprint and the main thread dominated by `NowPlayingManager.startObserving()`.
- Normal Command-Q no longer completed, consistent with main-actor starvation.

Audible output was not independently listened to, so the claim is limited to AVPlayer/CoreAudio activity and advancing application playback state.

## Lifecycle facts during the failure

| Fact | Observation |
|---|---|
| App process alive | Yes, PID 63159 |
| Playback state active | Yes; timeline advanced and CoreAudio started |
| MediaRemote active | Yes; repeated `setNowPlayingInfo` traffic |
| Application active | Yes |
| Application hidden | No |
| AX window enumeration | Failed with `kAXErrorCannotComplete`; zero was not a trustworthy count |
| WindowServer window | Present, named `Muses`, 1280×800 |
| Window onscreen | Yes |
| Window visibly rendered | Yes, independently captured |
| SwiftUI scene instantiated | Strongly indicated by the updated PlayerBar, but not directly introspected after AX failure |
| Window closed/minimized/offscreen | No evidence in this reproduction |

## Likely subsystem

High-confidence suspect: [`NowPlayingManager.startObserving()`](/Users/xiaotwu/Code/xyz/Muses/Sources/Muses/Services/System/NowPlayingManager.swift:30). Each tracked state change starts another permanent observation loop without cancelling the previous loop; every surviving loop publishes to MediaRemote every 250 ms. YouTube's periodic observer writes position and duration every 250 ms in [`YouTubeStreamEngine.swift`](/Users/xiaotwu/Code/xyz/Muses/Sources/Muses/Services/Playback/YouTubeStreamEngine.swift:537), making it a strong amplifier.

There is no playback path to `close`, `hide`, `orderOut`, `dismissWindow`, or terminate the app. The root is one [`WindowGroup`](/Users/xiaotwu/Code/xyz/Muses/Sources/Muses/App/MusesApp.swift:71), and app-lifetime playback/MediaRemote services survive independently of a window.

Persisted logs from one earlier automated session do show a real AppKit `finishing close` immediately after a mouse-up action. That supports an automation click as the explanation for at least one genuinely closed-window state; it does not identify playback as the close source.

## Confidence and impact

- Real observation/task runaway: **high confidence**.
- No window destruction in this reproduction: **high confidence**.
- Prior zero-window readings caused by AX/capture failure: **high confidence** for the readings; **medium confidence** for every historical occurrence because one prior run also contains a mouse-triggered real close.
- YouTube-specific versus any active playback: **inconclusive**, because no local track exists. Source suggests any 4 Hz playback mutation can trigger the defect, with YouTube likely amplifying it.
- AppKit/WindowGroup lifecycle defect: **low confidence**; runtime and source do not support it.

This should block playback-dependent visual implementation and acceptance—especially PlayerBar and Now Playing runtime work—until separately fixed. It does not block static design planning or restrained browsing-surface work. No fix was made in this phase.
