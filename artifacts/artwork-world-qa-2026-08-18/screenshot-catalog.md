# Artwork-world QA screenshot catalog

Audit date: 2026-08-18. Packaged `build/Muses.app` from this worktree (`make app`, ad-hoc). Default capture: 1280×800, window origin (40, 60), app Dark, English. Screen Recording and Accessibility were available. Pointer clicks and System Events keystrokes drove the UI.

Runtime library: the worktree app created `~/Library/Application Support/Muses/muses-corrupt-2026-08-19T05-46-02Z.sqlite` at launch and presented an empty library (Home has no hero / rails; Songs / Albums / Artists empty). On-disk `muses.sqlite` still has five YouTube tracks and one import, but this session did not surface them. No current track, so PlayerBar → Now Playing morph interpolation and vinyl host crossfade could not be proven.

## Required catalog

| File | Appearance | What it proves | Result |
|---|---|---|---|
| [01-home-hero-dark.png](01-home-hero-dark.png) | dark, wide 1280 | hero + rails + hover Play | **Partial.** Home + SectionHeader rails render. No hero (empty library). No hover Play target. |
| [02-home-retry.png](02-home-retry.png) | dark | failed rail + Retry | **Pass.** Late-night picks + Trending now keep headers; “Couldn’t load this section” + Retry. |
| [02-home-retry-after-click.png](02-home-retry-after-click.png) | dark | Retry → skeleton | **Pass.** First Retry replaced the error with the existing 16:9 skeleton carousel. Second rail stayed on Retry. |
| [03-library-albums.png](03-library-albums.png) | dark | 200pt Album objects | **Not available.** Empty-state only (`Library is empty`, ⌘F copy). No 200pt grid. |
| *04-album-detail.png* | dark | 240pt hero + playing row | **Not captured.** No album to open. |
| [05-artist-detail.png](05-artist-detail.png) | dark | 180pt circle + albums | **Not available.** Empty-state (`No artists in library`). Same file as `05-artist-detail-empty.png`. |
| [06-songs-selection.png](06-songs-selection.png) | dark | durable row selection | **Not available.** Empty-state (`No songs in library`, ⌘F copy). Click-select / double-click-play not exercised. |
| [07-search-overlay.png](07-search-overlay.png) | dark | overlay from sidebar Search | **Pass.** Overlay over Home; sidebar highlight stays on Home (Search is not a route). |
| [07c-search-cmd-f.png](07c-search-cmd-f.png) | dark | overlay from ⌘F | **Pass.** ⌘F opens the same overlay over Home. |
| [07b-search-query-typed.png](07b-search-query-typed.png) | dark | focused non-empty query | **Pass.** Field focused with `query` + caret. |
| [08-escape-search.png](08-escape-search.png) | dark | focused non-empty query dismissed | **Pass.** System Events Escape dismissed the overlay; Home remains. |
| [09-queue-open-only.png](09-queue-open-only.png) | dark | Queue drawer | **Pass.** ⌘K / PlayerBar list opens Current Queue / Up Next / History. |
| [09-queue-escape.png](09-queue-escape.png) | dark | drawer dismiss via Escape | **Fail in this run.** Escape with the drawer visible did not close it. |
| [09-queue-scrim-close.png](09-queue-scrim-close.png) | dark | drawer dismiss via scrim | **Pass.** Clicking the left scrim closed the drawer. |
| [09-queue-closed-via-x.png](09-queue-closed-via-x.png) | dark | drawer dismiss via Close | **Pass.** AX `Close` (`xmark.circle.fill`) closed the drawer. |
| [10-morph-wide.png](10-morph-wide.png) | dark, ≥960 | PlayerBar → NP morph | **Skip path only.** No `track?.id`, so morph is skipped. Wide two-column NP with 480pt placeholder cover + lyrics rail. Interpolation not proven. |
| [11-morph-skipped-narrow.png](11-morph-skipped-narrow.png) | dark, <960 | no morph, in-scroll cover | **Partial.** Resized to 940×800 with NP already open. Cover stays in-tree (single-column-ish). No live morph to skip. |
| [12-home-light.png](12-home-light.png) | light | light-mode contrast | **Pass.** Relaunched with `muses.theme=light`. Titles, Retry, sidebar, and PlayerBar stay readable on the pale field. |

## Extra captures

| File | What it shows |
|---|---|
| [13-new-dark.png](13-new-dark.png) | New page title ~30pt + situational skeleton rails (no computed recs on empty library). |
| [14-home-hover-attempt.png](14-home-hover-attempt.png) | Pointer over Home; no rail card / hover Play (no art). |
| [15-home-reduce-transparency.png](15-home-reduce-transparency.png) | `defaults write reduceTransparency` did **not** change rendering. |
| [16-home-reduce-motion.png](16-home-reduce-motion.png) | `defaults write reduceMotion` did **not** change rendering. |
| [09-queue-escape-open.png](09-queue-escape-open.png) | Search overlay + Queue stacked (⌘K while Search was still up). |
| [00-probe-home.png](00-probe-home.png) | First Home probe after launch. |
| probe-*.png | Sidebar route probes (Pins / Recently / History empty). |

## Carried click-tests

| Item | Result |
|---|---|
| Search overlay from sidebar | Pass. Overlay only; Home stays selected. |
| Search overlay from ⌘F | Pass. |
| Escape with focused non-empty query | Pass (System Events Escape). Raw `CGEvent` Escape did not reach the field. |
| Queue Escape | **Did not dismiss.** Scrim and Close did. |
| Failed rail Retry | Pass. Header kept; Retry → skeleton. |
| Hover Play vs click-to-open | **Not run.** No album/hero/rail objects. |
| Songs click-select / double-click-play | **Not run.** Empty list. |
| PlayerBar → NP morph (wide ≥960) | **Not run.** No current track (`skipArtworkMorph`). NP opens. |
| Morph skip narrow <960 | Partial. Narrow NP shown after resize; no interpolation. |
| Vinyl host crossfade | **Not run.** No track, vinyl mode not exercised. |
| Reduce Motion / Reduce Transparency | **Not run.** Writing `com.apple.universalaccess` keys did not change the live or relaunched appearance. |

## Named capture blockers

- In-memory / corrupt-store fallback at launch emptied the session library (hero, 200pt albums, 240pt album detail, 180pt artist header, song rows, hover Play, playing-row, morph, vinyl).
- YouTube discovery rails failed (`Couldn’t load this section`) — useful for Retry, not for 160pt card type-scale.
- Reduce Motion / Reduce Transparency / Increase Contrast could not be toggled from this agent without System Settings.
- Pointer hover over artwork requires a rendered object; none existed.
- Starting YouTube playback was not attempted (prior baseline: window can disappear).
