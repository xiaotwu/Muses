<p align="center"><img src="docs/assets/icon.png" width="88" alt="Muses"></p>
<h1 align="center">Muses</h1>
<p align="center">A quieter home for the music you find on YouTube.</p>
<p align="center">Native macOS · Personal library · YouTube Music discovery</p>
<p align="center"><a href="https://github.com/xiaotwu/Muses/releases/tag/v0.5.0">Download preview</a> · <a href="https://xiaotwu.github.io/Muses/">Website</a> · <a href="docs/installation.md">Installation</a></p>

![Muses on macOS](docs/assets/hero-home.jpg)

Muses turns the music you find on YouTube into a focused, native Mac listening experience. Import playlists, build a personal library, move through a queue that remembers its context, and give every song room to breathe with artwork, lyrics and a full-screen Now Playing view.

## Made for listening

- **Your YouTube music, organized.** Import YouTube playlists, keep favorites, pins and listening history, and browse albums and artists with stable source identities.
- **Playback with context.** Start from a playlist, search result or recent session and keep meaningful Previous, Next and Up Next behavior. Repeat, shuffle and queue restoration belong to the same continuous experience.
- **A Home that fits your privacy choice.** Muses mode builds recommendations privately from the library and listening activity on this Mac. YouTube Music mode requests its own recommendations directly, without uploading Muses listening history as input.
- **Artwork and lyrics in the foreground.** Move between cover and vinyl presentations, follow source-matched lyrics, and let artwork color the current line without overpowering the music.
- **Made for macOS.** A native sidebar, floating player, compact menu-bar controls, keyboard commands, system media controls, app volume and output selection feel at home on the desktop.
- **One playback path.** Muses resolves YouTube audio for native playback; recommendation pages never become an embedded web player.

## Two ways to come Home

**Muses** is the default. It creates a deterministic Home from your library, likes and listening history entirely on-device. The recommendation profile stays on your Mac and remains useful without an account.

**YouTube Music** is optional. It loads recommendations from YouTube Music anonymously, or—after a separate, explicit browser-session authorization—with the connected account's YouTube Music identity. Browser credentials remain inside a short-lived helper, while saved Home cards contain only normalized display data. Switching modes never mixes their caches.

## Preview status

**0.5.0 is a preview, not a complete feature-matrix sign-off.** Complete catalog relationships, the podcast workflow, production account writes and the full hardware/accessibility matrix remain unfinished. A favorite in Muses does not automatically become a YouTube like. YouTube Music Home is read-only and cannot authorize account writes or control playback.

The downloadable build is **Apple Silicon, ad-hoc signed and not notarized**. It requires macOS 14 or later. Google OAuth credentials are not bundled in this public preview; guest browsing and public playback remain available. Source builds can inject their own appropriately configured OAuth client. Translation and Intelligence depend on OS, hardware, region and model availability. No Premium DRM equivalence is promised.

## Build

```sh
make test                         # Swift Testing, serial execution
make app                          # Release .app in build/
MUSES_VERSION=0.5.0 ./Scripts/sign-update.sh
make dmg
```

Use a current Xcode command-line toolchain supporting the package's Swift version. Build scripts bundle app resources, yt-dlp and the optional signed-in Home helper. `make clean` removes **all** local build outputs. See [development](docs/development.md) and [installation](docs/installation.md).

## Your data stays yours

Your library and the default Muses recommendation profile stay on your Mac. OAuth tokens use Keychain. Signed-in YouTube Music recommendations require separate authorization, and their helper removes temporary browser-session material after every request. Muses contains no analytics SDK. See [privacy](docs/privacy.md).

[MIT license](LICENSE). Independent project, not affiliated with Apple, YouTube or Google.
