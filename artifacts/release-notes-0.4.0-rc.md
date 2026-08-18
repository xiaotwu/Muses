# Muses 0.4.0 — Release Candidate

## Release Notes

### Highlights

- **Phase 16b — SwiftData migration infrastructure.** The store is now under
  formal version control (`MusesSchemaV1`, version `1.0.0`) with an explicit
  `SchemaMigrationPlan`. Existing user databases open with **no migration stage**
  (their stamped version already matches), so upgrades are zero-risk to library
  data. A historical 10-model baseline (`MusesSchemaV0`, `0.1.0`) is recorded for
  the migration plan and exercised by migration tests. The corrupt-store backup
  + in-memory fallback safety net is preserved — user data is never deleted or
  overwritten.
- **Phase 16–27 feature set (all feature-flagged, default off).** Smart Listening
  History, Listening Sessions + crash recovery, Advanced Queue, Music Inbox,
  Notes & Bookmarks, Advanced Lyrics, Contextual Listening + Automation, native
  desktop integration (global hotkeys, tray, mini-player, desktop-lyrics
  overlay), Focus Mode, Audio Nerd Mode, and optional Local Music hardening.
  Each phase is additive and independently toggleable.
- **Test infrastructure hardening.** Network stubs are now isolated per test
  suite, eliminating the intermittent network-test flakes seen in prior builds.

### Upgrade compatibility

- Upgrading from any prior 0.3.x build (unversioned 18-model store, stamped
  `1.0.0`): opens cleanly, no migration, no data loss. **Verified at runtime.**
- Upgrading from a pre-Phase-16 10-model store (stamped `0.1.0`): the V0→V1
  lightweight stage runs, adding the eight new model tables and preserving all
  existing rows. **Verified at runtime.**
- On any migration/open failure, the database is backed up to
  `muses-corrupt-<timestamp>.sqlite` and the app falls back to an in-memory store
  so playback can continue. The original file is never deleted.

### Known issues

1. **`LocalAudioEngine` crossfade timing test is flaky under parallel test
   load.** The unit test "crossfade ramps volume from old to new player" can
   fail when the full suite runs in parallel; it passes reliably in isolation.
   No user-facing playback defect has been observed; the flake is a
   timing-sensitive assertion, not a playback bug. Not fixed in this RC per
   scope (no playback-engine changes). If manual QA reveals an actual
   crossfade playback defect, it will be addressed with a minimal diff.
2. **Automation rules with nil conditions AND nil cooldown can self-loop.**
   With `ffAutomation` on, a rule whose trigger fires and whose action
   re-triggers itself (e.g., a `.trackStarted` action that starts playback of the
   same track) has no built-in guard against nil-condition + nil-cooldown
   self-looping. Mitigation: set a cooldown on any automation rule. A future UI
   validation will warn when a rule has both nil conditions and nil cooldown.
   No behavior change in this RC.
3. **LocalHardening relink is dormant.** `ffLocalHardening` computes
   `partialContentHash` on insert/update and can classify/match moved files,
   but relink is **not** wired at runtime in this RC (audit guardrail only). No
   moved-file auto-relink occurs.
4. **Distribution signing + notarization require operator credentials.** The
   build produces an ad-hoc-signed `.app` by default. Distribution outside a
   personal ad-hoc install requires a "Developer ID Application" signing
   identity (`MUSES_SIGN_IDENTITY`) and notarytool credentials
   (`MUSES_NOTARY_PROFILE` or Apple ID + Team ID + app password) — these are
   not configured in the build environment.

### Interactive QA deferred to the human tester

The following were verified at the service/logic level and via runtime
launch-smoke (no crash, services initialize), but the final click-through
requires a human at the keyboard:

- Local playback: Add Folder → scan → click Play → hear audio → seek/pause.
- YouTube playback: search/import → click Play → streaming decode.
- Local ↔ YouTube source transitions (next/prev across engines, gapless).
- Queue/Session crash-recovery: click "Continue" on the restore dialog → seeks
  to the checkpointed position → resumes.
- Desktop: press a registered global hotkey; click the tray menu; open/close the
  mini-player; toggle desktop-lyrics overlay on/off.
- Focus/Inbox/History/Notes/Lyrics: open each surface, create/read/delete a
  sample item.

## Verification summary

- Clean Debug build: ✓ (exit 0)
- Release build: ✓ (exit 0)
- `.app` packaging (ad-hoc): ✓ codesign verified
- Full test suite: 316 tests, 62 suites — 315 pass; 1 known flaky crossfade
  timing test (passes in isolation)
- Migration tests: 3/3 ✓ (V0→V1 fixture; unversioned→versioned; backup
  preserves original)
- Network suites: 24/24 ✓, stable across repeated runs
- Fresh-install runtime smoke: ✓ (no crash, fresh DB stamped `1.0.0`, 18 tables)
- Upgrade runtime smoke: ✓ (legacy 18-model and V0 10-model both open/migrate
  cleanly)
- Feature-flag lifecycle: ✓ (all 14 flags ON → services init, no crash; OFF →
  clean launch)
- Privacy (Contextual Listening): ✓ code-level — off by default, bundle-id gated,
  no title/URL/content capture
- Large-library perf smoke (10k tracks, in-memory): insert 1.85s, fetch-all
  162ms, albums 66ms, search predicate 19ms, history aggregate 15ms