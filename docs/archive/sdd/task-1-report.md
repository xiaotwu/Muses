# Task 1 Report: Lock artwork-world language in Agents.md

## Status

**DONE**

## Summary

Updated durable agent guidance to lock artwork-world presentation and motion language. Docs only; no Swift touched.

## Changes

### Visual Hierarchy (`### Visual Hierarchy`)

Kept the existing five bullets and appended verbatim:

- Home / New rails may use larger artwork, hover Play, and now-playing identity. They must stay calmer than Now Playing.
- Album, artist, and playlist detail may use environmental color and a playing-row. They are artwork environments, not a second Now Playing.

### Motion (`## Motion`)

Replaced the entire section with the brief’s centralized motion/continuity system, chrome-only glass morphing, hover timing (120–180ms), playback-clock isolation for list/chrome, no glass-morph on browsing cards, and Reduce Motion instant swap/opacity fallback.

### Unchanged locks (Step 3)

Confirmed still present:

- “A Spotify or Apple Music clone.”
- “Use custom glass only for meaningful application-specific surfaces.”
- High-Risk Areas still lists `PlaybackService`, `LocalAudioEngine`, `YouTubeStreamEngine`, `PlayerBar`, `NowPlayingView`.
- “Do not opportunistically refactor these systems during unrelated visual tasks.”

## File identity

- On this macOS worktree, `Agents.md` and `AGENTS.md` are the same inode (case-insensitive volume). Editing one updates both.
- Git tracks the path as `AGENTS.md`.
- `diff -q Agents.md AGENTS.md` → silent (exit 0).

## Commit

- `82f864e` — docs: lock artwork-world motion and presentation language

## Verification

| Check | Result |
|-------|--------|
| `diff -q Agents.md AGENTS.md` | Silent / identical |
| Visual Hierarchy append | Present, five prior bullets retained |
| Motion section replaced | Matches brief verbatim |
| Clone / glass / high-risk locks | Unchanged |
| No Swift / no Liquid Glass WT files | Confirmed (docs-only commit) |

## Self-review

- **Completeness:** All five brief steps done.
- **Quality:** Verbatim brief text; no paraphrasing; surrounding sections untouched.
- **Discipline:** Docs only; no application Swift; no unrelated cleanup.
- **Testing:** `diff -q` silent as required for docs identity.

## Concerns

None. Case-insensitive FS means only one git path (`AGENTS.md`) appears in the commit; both names remain byte-identical on disk.
