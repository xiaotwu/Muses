---
layout: default
title: Installation
---

# Installation

## 1. Download

Grab the latest `Muses-x.y.z.dmg` from the [Releases](https://github.com/xiaotwu/Muses/releases) page.

## 2. Install

Mount the DMG and drag **Muses** into the **Applications** folder.

## 3. First launch

Because the DMG is not notarized, macOS Gatekeeper may report that the app "cannot be verified". Either:

- **Right-click → Open** on the first launch, or
- Open **System Settings → Privacy & Security** and click **Open Anyway**.

## 4. Choose your Home

Muses starts with **Muses Home**, which creates private recommendations from the library and listening activity on this Mac. It needs no Google account or browser access.

In **Settings → Account → Home & Recommendations**, you can switch to **YouTube Music**. Anonymous YouTube Music recommendations need no browser permission. Signed-in YouTube Music recommendations are optional and use a separate authorization flow.

## 5. Optional permissions

| Permission | Why | Where |
| --- | --- | --- |
| Full Disk Access | Reading a browser session for signed-in YouTube Music recommendations; resolving some video sources | System Settings → Privacy & Security → Full Disk Access |
| Keychain (Chrome Safe Storage) | Decrypting Chrome cookies for signed-in YouTube Music recommendations — approve only if you enable this optional feature | macOS dialog during the first signed-in Home check |

The YouTube settings page inside the app shows a **System Settings** shortcut that opens the right pane directly whenever a permission is missing, so you should never have to hunt for the right pane.

## 6. Sign in (configured builds only)

The public 0.5.0 preview has no OAuth client configured. Public playback and browsing work without signing in; the following account features require a source build with a configured OAuth client.

- Open **Settings → Account → Connect** to sign in with your Google account in the default browser. Muses requests only the read-only scope by default; enabling playlist management is a separate, explicit step.
- To use signed-in YouTube Music recommendations, follow the dedicated authorization flow after connecting. The helper reads your browser session only when you explicitly allow it, and its temporary cookie jar is deleted on every exit.

## Requirements

- macOS 14 (Sonoma) or newer
- The [yt-dlp](https://github.com/yt-dlp/yt-dlp) binary is bundled in the app package and refreshed with releases
