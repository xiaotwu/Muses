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

## 4. Recommended permissions

| Permission | Why | Where |
| --- | --- | --- |
| Full Disk Access | Reading the browser session for personalized Home; resolving some video sources | System Settings → Privacy & Security → Full Disk Access |
| Keychain (Chrome Safe Storage) | Decrypting Chrome cookies for personalized Home — one "**Always Allow**" makes the keychain prompt permanent | macOS dialog during first personalized Home check |

The YouTube settings page inside the app shows a **System Settings** shortcut that opens the right pane directly whenever a permission is missing, so you should never have to hunt for the right pane.

## 5. Sign in (optional)

- Open **Settings → YouTube → Connect** to sign in with your Google account in the default browser. Muses requests only the read-only scope by default; enabling playlist management is a separate, explicit step.
- To personalize Home, follow the one-click flow after connecting. The helper reads your browser session only when you explicitly allow it, and its temporary cookie jar is deleted on every exit.

## Requirements

- macOS 14 (Sonoma) or newer
- The [yt-dlp](https://github.com/yt-dlp/yt-dlp) binary is bundled in the app package and refreshed with releases