# Muses 0.4.0 — Human Acceptance & Distribution Checklists

Scope is frozen. No features added, no systems refactored. These checklists gate
the public release. Current state:

- **RC_STATUS = READY** (engineering complete; ad-hoc RC build verified)
- **HUMAN_ACCEPTANCE = PENDING** (needs a human at the keyboard)
- **DISTRIBUTION_BUILD = PENDING** (needs Developer ID + notary credentials)
- **PUBLIC_RELEASE_STATUS = NOT READY**

`PUBLIC_RELEASE_STATUS = READY` requires **all** items in both checklists to PASS.

Known non-blocking engineering issue (do not block release unless reproduced as
a real playback defect): the `LocalAudioEngine` "crossfade ramps volume from old
to new player" unit test is flaky under parallel test load but passes in
isolation. No user-facing playback defect has been observed.

---

## A. Human Acceptance Checklist

Run against `build/Muses.app` (ad-hoc RC build is sufficient for this checklist).
All Phase 16–27 features are **off by default**; enable the relevant flag in
Settings (or `defaults write com.muses.app <flag> -bool true`) before each
section, then disable it after. Record PASS/FAIL per item; any FAIL is a release
blocker (stop and report).

### A1. Fresh install & first run
- [ ] Launch `build/Muses.app` on a clean user account (no existing
      `~/Library/Application Support/Muses/`). App opens to the library view.
- [ ] No crash dialog, no DiagnosticReports for `Muses`.
- [ ] A fresh `muses.sqlite` is created at the above path (verify with
      `sqlite3 .../muses.sqlite ".tables"` — 18 `Z*` model tables present).

### A2. Library import & local playback
- [ ] Add a real music folder (drag-drop or Add Folder). Incremental scan imports
      tracks; album/artist/song surfaces populate.
- [ ] Click a track → Play → audio heard. Pause/resume work.
- [ ] Seek by dragging the progress bar; position follows.
- [ ] Next/Prev advance within the album context; queue reflects the collection.
- [ ] Repeat / shuffle toggle and behave.

### A3. YouTube source (`ffYouTube`-related, on by default for the engine)
- [ ] Search a YouTube track → import a playlist → `.youtube` tracks appear.
- [ ] Click Play on a YouTube track → streaming decode, audio heard.
- [ ] Cross from a local track to a YouTube track via Next (and back) — no
      engine deadlock, audio resumes.
- [ ] Playback speed control on a YouTube track changes speed.

### A4. Queue & crash recovery (`ffSessions` ON, `ffAdvancedQueue` ON)
- [ ] Build a queue (play from album, add Up Next). Reorder an item.
- [ ] With `ffAdvancedQueue` ON: lock a track; create a queue group; insert via
      "play after current group" and "add to queue with priority".
- [ ] While a track is playing, force-quit the app (`Cmd-Q` mid-playback or
      `kill -9`). Relaunch → the restore dialog offers to continue.
- [ ] Click **Continue** → resumes the same track at ~the checkpointed position.
      Click **Restart** (on a second try) → starts the track from 0.
- [ ] After a 2h+ idle gap, the stale session auto-ends (no dialog on relaunch).

### A5. Desktop integration (each flag ON one at a time, then OFF)
- [ ] `ffGlobalHotkeys` ON → registered hotkeys work from any app; OFF → hotkeys
      stop (Carbon unregister).
- [ ] `ffTray` ON → status-item tray icon appears with the Muses menu; OFF →
      icon removed (released).
- [ ] `ffMiniPlayer` ON → mini-player window opens and shares the single
      playback engine (no second engine); close → window released.
- [ ] `ffDesktopLyrics` ON → borderless floating lyrics overlay shows the
      current line; OFF → overlay hidden and panel released.
- [ ] Throughout: no crash, no resource leak (app stays responsive; quit and
      relaunch clean).

### A6. Focus / Inbox / History / Notes / Lyrics (each flag ON)
- [ ] `ffFocusMode` ON → start a focus session (optional Pomodoro); Home/New
      recommendations suppress while active; stop → state clears.
- [ ] `ffInbox` ON → send a track to Inbox; accept → track becomes liked;
      reject; snooze → returns due later.
- [ ] `ffSmartHistory` ON → play a few tracks; History view shows events, recap
      aggregates, and replay works.
- [ ] `ffNotes` ON → add a track note, a track bookmark (tap → seeks), an album
      note; BookmarksView lists bookmarks; GlobalSearch finds a note.
- [ ] `ffAdvancedQueue` (lyrics) → open lyrics mode; click a line → seeks;
      fullscreen lyrics; manual offset ±50ms; LRC word-timing highlights.
- [ ] `ffAudioNerd` ON → Audio Info panel shows real bit-rate/channels/device
      (no "Unknown" fabrication when metadata is present); output-device
      switch lists real devices.

### A7. Contextual Listening privacy (`ffContext` ON, then OFF)
- [ ] `ffContext` ON + `contextTrackActiveApp` ON → a ListeningEvent's
      `contextSummaryJSON` records hour/day/weekend, the frontmost **bundle id
      only**, and the output device name. Verify (sqlite3) that **no** window
      title, URL, document, keystroke, clipboard, or file content is present.
- [ ] `ffContext` OFF → `capture()` returns nil; no context is stored on new
      events.
- [ ] `ffContext` ON + `contextTrackActiveApp` OFF → no bundle id recorded.

### A8. Automation (`ffAutomation` ON)
- [ ] Create a rule with a trigger + a condition + a cooldown + an action → it
      fires once and respects cooldown.
- [ ] Confirm a rule with **no cooldown** does NOT self-loop catastrophically
      (known issue #2: nil-condition + nil-cooldown can loop — set a cooldown as
      mitigation; report if it loops).

### A9. Cross-cutting
- [ ] Light / Dark / High-contrast appearances remain legible; Reduce Motion and
      Reduce Transparency honored.
- [ ] Keyboard shortcuts, menus, context menus, drag/drop, sharing all work.
- [ ] System media controls (play/pause/next/prev, like) drive playback.
- [ ] Bilingual EN/ZH switching is immediate.
- [ ] No console errors / crashes across the whole session.

**A. Result → HUMAN_ACCEPTANCE = PASS only if every box above is checked PASS.**

---

## B. Distribution Checklist

Prerequisites (operator-provided, not in the build environment):
- "Developer ID Application: <name>" signing identity in Keychain
  (`security find-identity -v -p codesigning` must list it).
- Notary credentials: either a keychain notarytool profile (`MUSES_NOTARY_PROFILE`)
  or `MUSES_APPLE_ID` + `MUSES_TEAM_ID` + `MUSES_APP_PASSWORD` (app-specific
  password). Store a profile once:
  `xcrun notarytool store-credentials muses --apple-id you@example.com \
  --team-id XXXXXXXX --password <app-specific-password>`.
- `gh` CLI authenticated for `xiaotwu/noname123` (for the GitHub Release update
  feed).

All commands run from the repo root. `VER=0.4.0`.

### B1. Clean release build
- [ ] `git status` clean (no uncommitted source changes); on `main` at the RC
      commits (`725e0dc`, `f932956`).
- [ ] `swift package clean && swift build -c release` → exit 0.
- [ ] `swift test` → 316/316 except the known crossfade flake (must pass in
      `swift test --filter LocalAudioEngine`).

### B2. Developer ID signed build
- [ ] `MUSES_VERSION=$VER MUSES_BUILD=<n> \
      MUSES_SIGN_IDENTITY="Developer ID Application: <name>" \
      ./Scripts/build-app.sh`
- [ ] `codesign --verify --deep --strict build/Muses.app` → "valid on disk".
- [ ] `codesign -dvvv build/Muses.app 2>&1 | grep -E 'Authority|TeamIdentifier'`
      → shows "Developer ID Authority: ..." and a TeamIdentifier.
- [ ] Confirm `build/Muses.app/Contents/Resources/yt-dlp` is signed (the script
      pre-signs it; `--deep` covers it).

### B3. Notarization + Stapler
- [ ] `MUSES_VERSION=$VER MUSES_NOTARY_PROFILE=muses ./Scripts/notarize.sh`
      (or the `MUSES_APPLE_ID`/`MUSES_TEAM_ID`/`MUSES_APP_PASSWORD` variant).
      Script submits the zip, waits, staples, validates, and re-zips.
- [ ] `notarytool` status = `Accepted` (script aborts on Invalid/Rejected).
- [ ] `xcrun stapler staple build/Muses.app` → succeeds (script does this).
- [ ] `xcrun stapler validate build/Muses.app` → "The validate action passed!".
- [ ] Re-zipped `build/Muses-$VER.zip` is the stapled artifact.

### B4. Gatekeeper verification
- [ ] `spctl --assess --type execute --verbose=4 \
      --context context:primary-signat build/Muses.app` → "source=notarized
      Developer ID".
- [ ] `xcrun stapler validate build/Muses.app` → pass.
- [ ] On a **different** machine (or a clean admin account with no prior Muses),
      double-click `build/Muses.app` → opens without the "unidentified
      developer" / damaged-build warning.

### B5. Clean-environment smoke test
On a clean macOS user account (no existing `~/Library/Application Support/Muses/`,
no `com.muses.app` defaults):
- [ ] Launch the **notarized, stapled** `Muses.app`. No Gatekeeper warning, no
      crash.
- [ ] Import a small real music folder → Play → audio heard.
- [ ] Import a YouTube playlist → Play a YouTube track → audio heard.
- [ ] Toggle a feature flag (e.g., `ffFocusMode`) ON then OFF → no crash.
- [ ] Quit and relaunch → state persists.
- [ ] Upgrade test: replace the fresh DB with a 0.3.x-era store (unversioned,
      stamped `1.0.0`) and relaunch → library intact, no migration prompt, no
      data loss.

### B6. Distribution artifacts
- [ ] `MUSES_VERSION=$VER ./Scripts/make-dmg.sh` (sign with Developer ID) →
      `build/Muses-$VER.dmg`.
- [ ] Verify the DMG opens and the app drags to /Applications.
- [ ] `MUSES_VERSION=$VER ./Scripts/sign-update.sh` → `build/Muses-$VER.zip`
      (stapled, for the update feed).
- [ ] `gh release create v$VER build/Muses-$VER.dmg build/Muses-$VER.zip \
      --title "Muses $VER" --notes-file artifacts/release-notes-0.4.0-rc.md`
      (publishes the GitHub Release that `UpdateService` polls).
- [ ] Sanity: in the app, trigger an update check → it finds v$VER as the latest.

**B. Result → DISTRIBUTION_BUILD = PASS only if B1–B6 all PASS.**

---

## C. Release gate

| Gate | Required for | Current |
|---|---|---|
| RC_STATUS = READY | entering human QA & distribution | ✓ READY |
| HUMAN_ACCEPTANCE = PASS | PUBLIC_RELEASE | PENDING (human) |
| DISTRIBUTION_BUILD = PASS | PUBLIC_RELEASE | PENDING (credentials) |
| PUBLIC_RELEASE_STATUS = READY | publish | NOT READY (gated on both above) |

**Do not set `PUBLIC_RELEASE_STATUS = READY` until HUMAN_ACCEPTANCE = PASS AND
DISTRIBUTION_BUILD = PASS.** Until then, `RC_STATUS` stays `READY`.

If human QA (Section A) reproduces an **actual playback defect** from the
crossfade path, fix only that defect with the smallest possible diff and rerun
the relevant regression suite; otherwise leave the crossfade test flake as a
known non-blocking engineering issue.