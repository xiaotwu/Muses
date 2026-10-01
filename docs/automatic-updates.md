# Automatic updates

Muses uses Sparkle 2.10.0 for signed updates outside the Mac App Store. The
app-lifetime UpdateService owns preferences and scheduling. Sparkle owns the
feed parser, downloader, external installer, authorization, and relaunch.
Settings → About and the application menu share the same updater.

## User behavior

Automatic checks default to enabled and run on Sparkle's 24-hour schedule.
Automatic downloading and installation is a separate opt-in preference. Enabling
it enables checks; disabling checks disables automatic installation.

Background and manual downloads use one custom user driver. Availability,
progress, preparation, ready state, and errors appear in Settings. Release notes
remain available on GitHub. Informational releases never download code.

Automatic installation waits for audio/video playback, buffering, imports,
synchronization, and existing modal UI. It presents a native 15-second countdown
with Later and Update Now. Resuming a blocking operation resets the countdown.
Later defers automatic restart for that build during this session, including a
repeated update presentation. Re-enabling automatic installation resumes scheduling.
A relaunch requires an explicit installation intent from the scheduling/persistence
gate. Sparkle can still install a
staged update on normal quit.

Before installation and again at termination, Muses pauses through
PlaybackService, saves the main context, checkpoints queue/position in a fresh
context, checkpoints podcast progress, and retries pending podcast writes.
Failed saves or active import/sync reject termination. Existing recovery restores
queue/track/position paused. A fallback in-memory store cannot start an update.

## Successful launch and cleanup

A UserDefaults transaction contains a UUID and target build. It is acknowledged
only after the real persistent store and main window are ready and the running
build is at least the target build. Cleanup failure retains the transaction for
retry and postpones new updates.

Sparkle removes its Installation directory during installer completion. Muses
also clears leftover PersistentDownloads before starting another updater.
The pinned framework's source defines this path as
`~/Library/Caches/<bundle-id>/org.sparkle-project.Sparkle/PersistentDownloads`.
For `com.muses.app`, the cache identifier is `com.muses.app.sparkle`, because it
ends in `.app`. Symbolic-link ancestors are rejected. Muses never removes a live
installer directory, music downloads, artwork, library data, browser history,
or user-owned Downloads files. Acknowledgment clears the transaction and retired
checker cache keys. Preferences and Sparkle's scheduler timestamp remain.

Sparkle's cleanup is coupled to installation/relaunch, rather than a database
health handshake. Muses adds application readiness acknowledgment; this design
does not promise arbitrary binary or database rollback.

## Release setup

Run `swift package resolve` to obtain the pinned framework and release tools.
Provision the production key once on the release machine:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account muses-polyhymnia
```

Keep the private key in Keychain and back it up securely. Release builds read
its public key automatically. `MUSES_UPDATE_PUBLIC_KEY` can override the lookup.
Optional configuration:
`MUSES_UPDATE_FEED_URL`, `MUSES_UPDATE_KEY_ACCOUNT` (default `muses-polyhymnia`),
or a protected `MUSES_UPDATE_PRIVATE_KEY_FILE` instead of Keychain. Private keys
are never embedded in the application.

The default stable feed is
`https://github.com/xiaotwu/Muses-Polyhymnia/releases/download/updates/appcast.xml`.

Configure Developer ID, the existing notarization profile, and the OAuth build
environment, then run:

```sh
export MUSES_NOTARY_PROFILE=muses
make release MUSES_SIGN_IDENTITY='Developer ID Application: ...' \
  MUSES_VERSION=0.6.0 MUSES_BUILD=20261001.1
```

`make release` signs framework/helpers inside-out, notarizes/staples the app,
makes/notarizes/staples the DMG, and then signs the final archive and appcast.
Feed metadata must match the final archive. CryptoKit verifies both signatures
against the application's embedded public key before publication. Unconfigured
previews disable updating; release builds reject missing keys or ad-hoc signing.

Publication is separate and must be explicitly requested:

```sh
MUSES_VERSION=0.6.0 ./Scripts/publish-update.sh
```

The script creates/resumes a draft release, uploads the DMG, publishes the version,
and finally replaces appcast.xml on the dedicated prerelease named `updates`.
Published version archives cannot be overwritten by this script. If feed upload
fails after publication, the new version is available manually; verify the
published DMG before retrying only the feed upload.

The generated appcast contains one stable full update and no deltas. Preserve
compatible older entries before future OS/architecture changes. Keep
CFBundleVersion increasing; never mutate an archive after signing.

Existing versions without Sparkle need one manual upgrade. A project signing
key was provisioned in the local Keychain during implementation; it was not
exported. Implementation does not publish a release.

## Isolated acceptance

Only `com.muses.acceptance.*` bundles can explicitly enable
`MUSES_UPDATE_ACCEPTANCE_LOOPBACK=YES` and consume a signed HTTP feed on
`127.0.0.1:<port>`. Production requires HTTPS. This narrow exception permits
installation tests without changing certificate trust or publishing test builds.
Acceptance bundles clear OAuth/deep links, disable Web Home, use separate
data/cache namespaces, and cannot use the default production feed.

Run `swift test --no-parallel` and
`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/ReleaseTests`.
Runtime acceptance must inspect Settings, old/new PID and build changes, and
download/transaction cleanup. System authorization and notarized production
installation need separate release evidence.
