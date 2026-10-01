# Automatic updates implementation plan

Status: Implementation complete; isolated installation acceptance passed on 2026-09-30. Production release gates are listed below. Authorized on 2026-09-30.

## Contract

Muses checks a signed stable appcast, downloads and verifies an update, saves user state, terminates normally, installs into the existing bundle location, relaunches, and removes updater-owned downloads and transient records. Playback, queue, library, media caches, browser downloads, Keychain, and preferences survive. Automatic installation is a separate opt-in preference. Active playback, video, imports, and synchronization defer automatic relaunch; manual installation still waits for critical writes. A cancellable countdown precedes automatic relaunch.

Sparkle 2 owns the download and external installation processes. Muses owns installation scheduling, the persistence gate, transaction acknowledgment, and its settings UI. A failed persistence gate cancels termination. A replacement bundle is not considered successfully launched until the persistent store and main window are ready. No blanket cache deletion or promise of database rollback is allowed.

## Steps

- [x] Pin Sparkle's stable dependency and add an injectable update adapter and state machine.
- [x] Add automatic settings, progress, delayed installation, cancellation, and application menu commands.
- [x] Wire state saving and successful-launch acknowledgment at the composition root.
- [x] Embed and sign Sparkle's framework, helpers, and XPC services; inject feed/public key only for configured builds.
- [x] Implement signed/notarized archive and signed-appcast generation; implement publication with assets preceding the feed. Production publication remains separate.
- [x] Add focused tests for scheduling, persistence failure, transaction cleanup, malformed configuration, and packaging.
- [x] Build, run relevant tests, package an isolated preview, and inspect rendered settings.
- [x] Validate signed old-to-new installation, postponement, relaunch, and actual installer cleanup in an isolated acceptance environment. System authorization remains a production release gate.

## Release configuration

Use GitHub Releases for immutable versioned assets and a dedicated `updates` release for the stable appcast URL. A feed is published only after its referenced package exists. Developer ID and notary credentials remain in the release environment; EdDSA private keys remain in Keychain. The pinned framework supports signed feeds and validation before extraction. Preview/acceptance builds do not consume the production feed.

The first upgrade from a version without Sparkle is manual. Missing production feed, key, or signing credentials must be reported as an explicit release blocker, never replaced by invented secrets or an unsigned production update.

## Verification record

- Swift Testing: 730 tests in 100 suites passed (`swift test --no-parallel`, 20.654 seconds).
- Release configuration: all 8 Python tests passed. Modified shell scripts passed syntax checks; `git diff --check` passed.
- Developer ID acceptance bundle built successfully, including inside-out Sparkle/XPC/helper signatures and bundled yt-dlp checks. A resource bundle naming mismatch exposed by the real launch was corrected.
- Signed appcast/archive verification passed; tampering with either the feed or archive was rejected by public-key verification.
- Final isolated runtime: `com.muses.acceptance.updates.verified`, signed loopback feed on port 18767, version 0.5.6/build 20260930.1 to version 0.5.7/build 20261001.1. Native Settings and countdown were inspected.
- At 22:30:48 local time, Later generated response 1000 and a deferral log. PID 34503 remained active beyond the original countdown, with no pending installation transaction. Turning automatic installation off/on deliberately resumed scheduling.
- At 22:31:37, the countdown requested automatic installation. The application relaunched as PID 34731 with the new build. PersistentDownloads and Installation were empty; the pending transaction was absent; preferences and Settings restoration survived.
- Focused tests cover failed persistence, active imports/sync, playback blocking, repeated presentation after Later, explicit relaunch intent, cleanup retry, and symlink boundaries. Playback data preservation is covered by session checkpoint tests; the isolated runtime used an empty library.

## Production release gates

- The local production EdDSA key is provisioned in Keychain; no private key was exported or committed.
- Run the existing notary workflow with the configured release credentials, validate the final notarized/stapled DMG, and exercise macOS authorization when the install location requires elevation. The isolated test installed a Developer ID signed ZIP in a writable directory and did not exercise these cases.
- Publish the first updater-enabled version and the dedicated signed feed through the documented explicit release command. No GitHub release, tag, or feed was published during implementation.
- Existing installed versions need one manual upgrade to acquire the updater. Subsequent updates use the automated flow.
