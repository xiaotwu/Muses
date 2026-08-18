# Muses Visual Design System

- **Status:** implementation-guiding specification; no production UI is implemented by this document
- **Version:** 1.0
- **Date:** 2026-08-17
- **Deployment context:** macOS 14 and later. Custom Liquid Glass SwiftUI APIs such as `glassEffect` and `GlassEffectContainer` require a toolchain/SDK containing the macOS 26 symbols and a runtime `if #available(macOS 26.0, *)` branch. macOS 14–15 receive the semantic fallback described here.

## Evidence and authority

This specification is grounded in:

- the executable SwiftUI source and project contracts in `AGENTS.md`;
- the [52-frame runtime baseline](runtime-baseline-2026-08-16/runtime-baseline-report.md) and its [screenshot catalog](runtime-baseline-2026-08-16/screenshot-catalog.md);
- the [playback/window reproduction](playback-window-repro-2026-08-17/reproduction-report.md), which established that the apparent window loss was main-actor starvation rather than a visual scene-lifecycle problem;
- the corrected, stable playback runtime after the `NowPlayingManager` observation fix;
- Apple's [Liquid Glass overview](https://developer.apple.com/documentation/technologyoverviews/liquid-glass) and [custom-view guidance](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views).

Runtime evidence takes precedence over source-only inference. The baseline confirms that Muses already has a strong calm content canvas, native split-view structure, compact desktop typography, restrained shadows, useful artwork hierarchy, and mature PlayerBar control topology and density. The system formalizes those strengths before adding expression.

### Evidence limits

The runtime library did not contain populated album, artist, user-playlist, or truly local-track states. The baseline also did not reliably validate pointer hover, active artwork-rich Now Playing, live lyrics/spectrum/vinyl behavior, or a complete VoiceOver pass. Policies for those states are supported by source structure and interaction requirements, but remain prospective until their first implementation phase is verified in the real app. In particular, glass-free album/artist browsing and their current geometry are source-confirmed strengths rather than claims from populated runtime captures.

## A. Design philosophy

Muses should feel like one application with a deliberate gradient of expression:

> **Calm Library → Contextual Media → Persistent Playback → Immersive Playback**

The library is the quiet frame around the collection. Artwork introduces identity and color as the user enters media context. Persistent playback has a distinct, carefully bounded layer. Now Playing receives the largest visual and motion budget because it is the closest point to the music.

Five principles define the identity:

1. **Native structure, authored media.** macOS owns window, sidebar, toolbar, menus, sheets, popovers, focus, and ordinary controls whenever system behavior is sufficient. Muses authors the artwork environment and its signature playback surfaces.
2. **Artwork is the chromatic source.** Neutral system colors carry function; artwork supplies atmosphere. Decorative application-wide gradients are unnecessary.
3. **Glass indicates role.** It separates persistent or contextual interaction from content. It does not decorate every object.
4. **Density remains desktop-native.** Richness comes from artwork, depth, environmental color, continuity, and precise interaction—not indiscriminately larger type or controls.
5. **The static hierarchy must work first.** Motion reinforces relationships but never carries the sole burden of explaining depth, state, or navigation.

### Preserve from current Muses

- `NavigationSplitView`, native sidebar selection, toolbar placement, menus, context menus, sheets, forms, and reorder foundations.
- Source-confirmed glass-free album and artist browsing.
- System semantic typography and the compact body/caption rhythm.
- The three-part PlayerBar information topology: media identity, transport/timeline, and auxiliary controls.
- The increasing artwork scale from rows, to cards, to details, to immersive playback.
- Restrained shadows on ordinary surfaces.
- The compact global Search information model.
- Explicit Current Queue, Up Next, and History structure.
- The vinyl view's strong media identity and the EQ editor's direct, tool-like character.

### Deliberate non-goals

- No generic web glassmorphism.
- No universal blurred-album-cover background.
- No iOS-sized control inflation or mobile-first navigation.
- No per-screen visual vocabulary.
- No universal card component or oversized design-system framework.
- No custom recreation of system sheets, popovers, menus, lists, forms, or focus behavior.

## B. Semantic surface system

Surfaces are named by responsibility, not by screen.

| Semantic role | Purpose | Default visual treatment | Typical consumers |
|---|---|---|---|
| **Content Canvas** | Long-session reading, scanning, sorting, and browsing | Opaque semantic canvas, no custom glass, restrained separators, direct artwork and type | Songs, album/artist grids, playlist rows, search results, ordinary sections |
| **Native Structure** | Window organization and primary navigation | System-owned window, split view, sidebar, toolbar, titlebar, and scroll-edge behavior | App shell, sidebar, toolbar, Settings internal navigation |
| **Media Environment** | Establish the identity and context of selected media | Localized, tone-mapped artwork influence that resolves into a neutral canvas; not a glass panel | Conditional Home featured hero; album/artist/playlist/YouTube detail hero |
| **Contextual Control Surface** | Keep a small related action set legible over visually active media | Standard SwiftUI controls inside one restrained grouped glass surface when needed | Detail hero actions, Now Playing transport or top controls |
| **Persistent Playback Surface** | Keep playback identity and essential controls continuously available | One signature custom playback glass surface with compact, adaptive content | PlayerBar |
| **Floating / Transient Surface** | Temporarily supersede the current task | System sheet, popover, menu, or inspector first; one custom command surface only when the interaction model requires it | Search, Queue, editors, selection sheets |
| **Immersive Playback Surface** | Compose artwork, environment, metadata, lyrics, visualization, and playback into the primary expressive state | Environmental base with crisp media and direct text; selected grouped controls may use glass; the viewport itself does not | Now Playing |

### Surface composition rules

- Content Canvas may contain artwork, selections, and native row fills, but never receives a decorative material merely to appear elevated.
- Media Environment sits behind content. It does not become an additional foreground card.
- Contextual Control Surfaces are small and purpose-bound. A detail hero is not itself glass.
- Persistent Playback is visually above ordinary content but remains subordinate to a presented transient surface.
- Transient surfaces are always on the top interaction plane, including when invoked from Now Playing.
- Immersive Playback replaces the browsing context visually; it does not outrank Search, Queue, system menus, sheets, or alerts.

## Surface depth hierarchy

The previous five-level model is refined to correct the runtime Queue/Now Playing stacking failure. Immersive playback is below transient interaction, not above it.

| Level | Role | Opacity | Glass | Shadow and boundary | Vibrancy and artwork | Interaction and motion |
|---|---|---|---|---|---|---|
| **0 — Content / media** | Canvas, lists, grids, artwork, text, plus Spectrum/Vinyl as media content nested inside an L4 composition | Opaque canvas; artwork is fully opaque | None | Separators only when they aid scanning; no routine shadows | Semantic system foreground colors; no custom vibrancy; intrinsic media color remains within media bounds | Low response; hover and selection must work without motion |
| **1 — Native application structure** | Window, sidebar, toolbar, titlebar, scroll edge | System-controlled | Native structural behavior only | System separators and edge behavior | System vibrancy, weak or no artwork influence | Native focus, collapse, scrolling, and toolbar response |
| **2 — Contextual media hierarchy** | Heroes, metadata, detail actions | Environment is rendered into an opaque final composition | No glass for the environment; one grouped control surface only if contrast requires it | Artwork may cast restrained depth; hero-to-content edge is a tonal taper, not a hard border | Contextual or Hero artwork influence | Moderate continuity; static hierarchy remains complete |
| **3 — Persistent playback** | PlayerBar | Translucent on supported systems; semantic elevated fallback | One `PlaybackGlass` surface | One boundary/elevation treatment; no nested shadows | Neutral glass with weak localized artwork response | Medium interaction; future playback-continuity origin |
| **4 — Immersive playback mode** | Now Playing environment and media | Full-window opaque rendered environment | No glass on the viewport; grouped control glass only | Artwork shadow is allowed; text uses local contrast protection rather than borders | Immersive artwork influence | Highest deliberate motion budget; continuous media renderers isolated |
| **5 — Transient / floating** | Search, Queue, sheets, popovers, menus, alerts | System-controlled or one self-contained custom surface | System transient glass first; contextual custom glass only by exception | Clear boundary and scrim as appropriate; must read above Level 4 | At most thumbnail artwork; environment does not leak into functional text | Short structural motion; never a hero transition |

### Depth without animation

The hierarchy must remain obvious in a still frame:

- L0 is the flattest and most information-dense.
- L1 is identified by native window structure rather than custom decoration.
- L2 gains localized artwork color and stronger media scale.
- L3 gains a distinct, bounded persistent surface.
- L4 changes the whole environmental composition while keeping controls selectively grouped.
- L5 interrupts everything beneath it with the clearest boundary and focus state.

## C. Liquid Glass system

The vocabulary is intentionally small. These are semantic policies, not permission to scatter `glassEffect` modifiers.

### 1. NativeStructuralGlass

- **Use:** sidebar, toolbar, titlebar, scroll-edge structure, and any system structural presentation whose modern appearance is supplied by macOS.
- **Do not use:** as a custom wrapper around content already hosted by native structure.
- **Interaction:** system-owned hover, focus, selection, resizing, and window activation.
- **Tint:** none from Muses. System/accent behavior owns tint.
- **Accessibility fallback:** system behavior; do not overlay another material under Reduce Transparency.
- **Performance:** Low; system-managed.

This is a semantic policy across the deployment range. On macOS 14–15 it means era-appropriate native macOS structure, not an imitation of macOS 26 Liquid Glass. Native controls automatically adopt the appearance supplied by the running OS.

### 2. SystemTransientGlass

- **Use:** native sheets, popovers, menus, alerts, open/save panels, inspectors, and other system-owned transient presentations.
- **Do not use:** an inner full-sheet `ultraThinMaterial` or custom rounded background inside a system-owned presentation.
- **Interaction:** native default/cancel actions, focus traversal, dismissal, selection, and menu feedback.
- **Tint:** none, except normal semantic control accent.
- **Accessibility fallback:** system-owned opaque or higher-contrast presentation.
- **Performance:** Low.

On macOS 14–15 this likewise means the system presentation appropriate to that OS, not simulated Liquid Glass.

### 3. PlaybackGlass

- **Use:** the PlayerBar outer surface only.
- **Do not use:** per transport button, per metadata group, timeline, volume slider, album card, or row.
- **Interaction:** one coherent interactive surface; inner buttons and sliders remain standard controls. The surface may respond subtly to pointer proximity without becoming a collection of capsules.
- **Tint:** neutral by default. A weak, localized tint derived from current artwork may appear near the artwork edge, but playback, error, or selection semantics take priority. Tint must never follow elapsed time.
- **Accessibility fallback:** an opaque semantic playback surface with an explicit boundary and sufficient contrast. Increase Contrast strengthens the boundary.
- **Performance:** Medium. Exactly one large custom glass sampling region; it must not observe position, duration, lyrics cadence, spectrum frames, or vinyl frames.

### 4. InteractiveGlassGroup

- **Use:** one compact group of related controls over a Media Environment, such as Now Playing transport or a detail hero's primary actions when direct placement cannot guarantee contrast.
- **Do not use:** individual button capsules, metadata text, quality badges, lyrics lines, or ordinary toolbar actions.
- **Interaction:** standard buttons are grouped in one nearby glass container. Interactive response belongs to controls, not to a continuously animated background.
- **Tint:** neutral or one restrained semantic tint. Multiple unrelated tints within one group are prohibited.
- **Accessibility fallback:** opaque grouped control fill, visible focus, and explicit separator/boundary where needed.
- **Performance:** Low to Medium. Multiple nearby elements share one container only when they need to blend, coordinate, or morph; glass must not sample Spectrum or Vinyl.

### 5. ContextualGlass

- **Use:** one genuinely custom floating surface whose command model is not representable by a native sheet, popover, or inspector. Global Search is the principal candidate.
- **Do not use:** ordinary cards, detail sections, Queue rows, or as a second layer inside a native presentation.
- **Interaction:** clear focus ownership, keyboard selection, default action, Escape dismissal, and standard row controls are mandatory.
- **Tint:** neutral. Artwork thumbnails do not tint the panel.
- **Accessibility fallback:** opaque elevated panel, explicit border, stable selection fill, and no scale transition under Reduce Motion.
- **Performance:** Low to Medium; one bounded panel, no per-result glass.

### 6. NoGlass

- **Use:** the default.
- **Required for:** album cards, artist cards, playlist rows, song rows, search results, queue rows, lyrics lines, artwork, spectrum, vinyl, quality badges, ordinary section containers, settings groups, forms, EQ content, and media environments.
- **Interaction:** native row/card/control semantics, semantic fills, focus, or artwork—not translucency—communicate response.
- **Tint:** not applicable.
- **Accessibility fallback:** normal semantic color and contrast behavior.
- **Performance:** Low incremental surface cost. Contained media such as Spectrum or Vinyl may have an independent High renderer cost.

### Glass decision order

Before authoring custom glass, answer in order:

1. Can the native macOS structure or control own this surface?
2. Is separation actually needed, or can spacing, typography, or a semantic fill solve it?
3. Is the surface persistent playback or a compact control group over active media?
4. If there are multiple related glass elements, do they need one coordinated container?
5. What is its macOS 14 and Reduce Transparency fallback?
6. Which state identities may invalidate it?

If these questions do not yield a narrow semantic role, use `NoGlass`.

When macOS 26 APIs are used later, multiple nearby glass elements share a `GlassEffectContainer` only when they need to blend, coordinate, or morph; a single outer PlayerBar glass surface does not need a container merely for conformity. Identity-driven morphs may use stable glass IDs. New glass replaces redundant backdrop materials, duplicate fills, and decorative strokes rather than stacking over them. Media clipping, Increase Contrast and opaque-fallback boundaries, and semantically justified elevation shadows remain when their branch requires them. The macOS 26 and fallback branches each own a complete shape, boundary, and elevation treatment.

## D. Geometry

Muses already clusters around a coherent radius family. The system names that family rather than inventing a new one.

| Token | Radius / shape | Intended use |
|---|---:|---|
| **badge** | 4 pt continuous | Small status and quality badges |
| **denseMedia** | 4 pt continuous | Dense 32–40 pt row and Search thumbnails |
| **compactMedia** | 6 pt continuous | Approximately 28–56 pt artwork, including the sidebar mark and PlayerBar art |
| **media** | 8 pt continuous | Ordinary album/playlist artwork and 16:9 media thumbnails |
| **hero** | 12 pt continuous | Prominent artwork and matching placeholders; not the environmental field itself |
| **controlGroup** | 12 pt continuous | Compact grouped custom controls over media |
| **playbackSurface** | 16 pt continuous | PlayerBar only |
| **floatingPanel** | 16 pt continuous | Genuinely custom floating command surfaces only |
| **circle** | Circle | Artist images, avatars, vinyl platter, circular transport controls where semantically justified |

The PlayerBar's 16 pt radius is provisional but is the system default until its dedicated design phase proves a different value is necessary.

### Media shape families

- Albums and square playlists: square continuous rounded rectangle.
- Artists and avatars: circle.
- YouTube/video media: 16:9 continuous rounded rectangle.
- Vinyl: circle with artwork used as a label, never coerced into a rounded card.
- Placeholder geometry matches the eventual media geometry to prevent layout change.

### Concentric geometry

- Nested surfaces use container-relative or mathematically derived concentric shapes.
- An inner radius is derived from the outer shape and inset; it is not selected independently because it “looks close.”
- One outer PlayerBar shape contains artwork and controls; it must not become capsules inside a capsule.
- A glass control group may contain circular icon hit regions, but it does not place each icon in a second visible capsule at rest.
- Native sheet, popover, menu, search field, slider, and focus geometry remains system-owned.

### Clipping philosophy

- Clip media to communicate its semantic shape.
- Do not clip an entire card merely because its artwork is rounded.
- Ordinary sections do not become rounded containers.
- Shadows are never used as clipping masks or the only boundary.
- Spectrum and waveform corner details remain renderer-specific, not global geometry tokens.

### Artwork size roles

| Role | Preferred range | Notes |
|---|---:|---|
| **denseThumbnail** | 32–40 pt | Search, Queue, dense rows |
| **compactArtwork** | 52–80 pt | PlayerBar and compact contextual rows |
| **compactCardArtwork** | 120–160 pt | Dense Home strips and secondary media |
| **libraryCardArtwork** | 160–200 pt preferred | Adaptive grid; never force five fixed 200 pt columns |
| **contextHeroArtwork** | 180–240 pt | Shrinks before metadata/actions collide; may recompose |
| **immersiveArtwork** | 240–480 pt preferred | May reach 180–220 pt only in a short/stress layout before controls clip |

These are ranges, not one universal card size. Media aspect and information density remain meaningful.

## E. Spacing

The spacing system follows recurring source values. Names describe relationship rather than generic size alone.

| Token | Value | Semantic use |
|---|---:|---|
| **micro** | 2 pt | Title/artist pairing, very small optical separation |
| **compact** | 4 pt | Dense-row vertical breathing and tightly related metadata |
| **related** | 6 pt | Card title stacks, badges, closely related track information |
| **control** | 8 pt | Spacing around compact controls, custom control content, and local metadata groups |
| **rowInline** | 10 pt | Thumbnail-to-text spacing in dense rows |
| **cluster** | 12 pt | Control clusters, compact panel padding, section label-to-content |
| **grid** | 16 pt | Card gaps, media strips, bounded panel content |
| **canvasInset** | 20 pt | Ordinary collection page and compact sheet inset |
| **windowInset** | 24 pt | Primary content edge and standard hero composition |
| **section** | 32 pt | Top-level content-section rhythm |
| **immersiveGap** | 40 pt | Major immersive-region separation |
| **immersiveEdge** | 48 pt | Spacious Now Playing edge; must reduce adaptively |

### Spacing rules

- Use the smallest token that accurately expresses the relationship.
- Dense rows target a native minimum height around 44 pt but may expand for multiline status or accessibility.
- `canvasInset` and `windowInset` are alternatives selected by context, not cumulative padding.
- `immersiveGap` and `immersiveEdge` are reserved for layouts that can afford them.
- A copied 100 pt bottom padding is not a spacing token. Persistent playback clearance must eventually be owned by layout/safe-area composition.
- Values such as 14, 28, 60, and 80 may remain component-specific optical or control metrics when a named system token would obscure intent.
- Native controls keep native internal padding.

## F. Typography

System semantic text styles remain the foundation. The MonteCarlo face remains a brand-wordmark exception, not a content typeface.

| Text role | Relative treatment | Weight / prominence | Line and density behavior |
|---|---|---|---|
| **nativePageTitle** | System navigation/titlebar title | System-owned | One line; follows toolbar behavior |
| **heroTitle** | `largeTitle` range | Semibold or bold | Up to two lines; shrinks/recomposes with hero, never marquee-scrolls |
| **immersiveTitle** | `title` / `title2` range | Semibold | Up to two lines; subordinate to artwork |
| **sectionTitleProminent** | `title2` | Bold or semibold | One line where possible |
| **sectionTitleDense** | `headline` | Semibold | One line; compact list/detail sections |
| **eyebrow** | `caption` | Semibold/bold with restrained tracking | Short uppercase/source label only |
| **primaryMetadata** | `body` / `callout` | Medium or semibold | One line in compact surfaces; two only in heroes |
| **secondaryMetadata** | `subheadline` / `caption` | Regular | One line; secondary foreground |
| **tertiaryMetadata** | `caption2` or low-prominence `caption` | Regular | Counts, dates, codec, channel |
| **denseRowTitle** | `body` | Regular/medium; stronger only for current item | One line with tail truncation |
| **cardTitle** | `subheadline` or `caption` by card density | Medium | One line; no arbitrary downscaling |
| **playbackTime** | `caption2.monospacedDigit()` | Regular | Fixed-width behavior; never competes with title |
| **status** | `caption` | Medium | Icon/label plus semantic state |
| **badge** | `caption2` | Medium/semibold | Short; no multiword capsule proliferation |
| **lyricsCurrent** | `title2`-like | Semibold/bold | Wraps naturally; no truncation |
| **lyricsInactive** | `body` by default | Regular | Wraps naturally; lower prominence without becoming illegible; any proximity-based enlargement requires separate reflow validation |

### Typography rules

- Cards, rows, Search, Queue, and PlayerBar metadata favor one-line truncation.
- Heroes alone routinely permit a second title line.
- Increase hierarchy through weight and foreground contrast before increasing point size.
- Lyrics may use a larger scale because they are primary content, but changing line state must not reflow the whole viewport at 10 Hz.
- Eyebrow tracking is restricted to short labels such as “ALBUM” or “NOW PLAYING.”
- Numeric playback values use monospaced digits.
- Fixed custom font sizes require a demonstrated renderer or layout need.

## G. Color and vibrancy

Muses remains predominantly neutral. Runtime evidence shows that the system accent—blue in the captured configuration—is already a meaningful part of selection, focus, and action. The future system is therefore **neutral plus user/system accent plus artwork**, not strictly monochrome.

| Semantic role | Treatment | Required secondary cue |
|---|---|---|
| **foregroundPrimary** | System primary on native canvas; contrast-selected foreground over media | Weight or hierarchy |
| **foregroundSecondary** | System secondary or controlled custom value over artwork | Position and type role |
| **foregroundTertiary** | Lower prominence but still legible | Caption/status context |
| **separator** | System separator; strengthens in Increase Contrast | Spatial grouping |
| **selection** | System accent fill or outline with readable selected foreground | Persistent selection geometry |
| **focus** | Native focus ring/accent | Keyboard focus semantics |
| **playing** | Accent emphasis | Playing glyph/static equalizer and accessibility value |
| **primaryAction** | System accent or primary control style | Label/icon and control prominence |
| **liked** | Semantic accent only when needed | Filled heart plus state label |
| **pinned** | Semantic accent only when needed | Filled pin plus state label |
| **success** | System success color | Checkmark and text |
| **warning** | System warning color | Warning symbol and text |
| **error** | System error color | Error symbol, message, and recovery action |
| **quality** | Primarily neutral badge/status treatment | Explicit text such as lossless/Hi-Res |
| **sourceLocal** | Neutral source label | Device/file symbol and label |
| **sourceYouTube** | Neutral label; brand red may be confined to the source mark | YouTube/source icon and text |
| **glassTint** | Near-neutral; optional restrained semantic tint | Surface role and boundary |
| **artworkEnvironment** | Tone-mapped extracted color | Never carries functional state |
| **scrim** | Appearance-aware neutral darkening/light protection | Clear modal/focus ownership |

### Vibrancy policy

- On native structure, use system primary/secondary foregrounds and system vibrancy.
- Over custom glass, prefer semantic foregrounds that the glass role can guarantee.
- Over artwork environments, choose foreground from measured luminance; do not assume dark mode means white or light mode means black.
- Functional state color never comes from artwork.
- Selection and focus remain distinct: selection persists; focus identifies the current keyboard target.
- Tinting is sparse. One surface does not display decorative magenta, cyan, and green accents merely to appear richer.

The current `BrandColors.magenta`, `cyan`, and `green` resolve to the same neutral values and no longer communicate their names. A future token migration should replace such names with semantic roles, but that migration is not part of this specification phase.

### Contrast targets

- Normal functional text targets at least 4.5:1 against its effective background.
- Large text and meaningful control boundaries target at least 3:1.
- Meaningful secondary and tertiary text at normal text sizes still targets 4.5:1; lower prominence comes from hierarchy and weight, not unreadable contrast.
- Shadows are not counted as the sole contrast mechanism.

## H. Artwork environment

Artwork is Muses' primary chromatic system. Its environmental influence increases with listening proximity.

| Intensity | Environmental contribution | Typical surfaces |
|---|---|---|
| **None** | No sampled color outside the artwork | Settings, sheets, ordinary song-only content, functional panels |
| **Thumbnail** | Artwork remains inside its bounds; no palette propagation | Rows, Search results, Queue, ordinary cards |
| **Contextual** | Localized low-intensity tint near a hero or featured module | Conditional Home featured hero, compact featured content, strictly capped PlayerBar edge tint |
| **Hero** | Stronger localized extension around a detail header that tapers to neutral before the list | Album, artist, playlist, YouTube detail |
| **Immersive** | Viewport-scale tone-mapped environment with protected functional regions | Now Playing |

### Normalization policy

Extracted color is input, not output. The environment pipeline must normalize it before display.

| Intensity | Approximate chromatic blend into neutral | Suggested saturation ceiling after normalization | Spatial rule |
|---|---:|---:|---|
| Contextual | 8–14% | 0.35 | Confined to the hero/module neighborhood; fades within roughly one artwork width |
| Hero | 16–28% | 0.50 | May occupy the hero, but reaches neutral before ordinary list content |
| Immersive | 24–42% | 0.60 | May span the viewport with localized variation; never becomes a uniform saturated wash |

These ranges are guardrails, not authoring constants. Contrast and image character may require less color.

- Dark environments generally remap background luminance toward a controlled dark range rather than reproducing bright sampled pixels.
- Light environments remap toward a controlled light range rather than placing near-black bands behind dark text.
- Light and dark descriptors are computed independently; one is not simply inverted.
- Highly saturated cluster ordering must not directly determine the dominant background.

For unprotected functional-text regions, the composited environmental background should remain at or below roughly 0.25 relative luminance in dark appearance, or at or above roughly 0.70 in light appearance. A Hero or Immersive field may exceed those envelopes away from functional content, but only with a spatial protection mask and a verified foreground choice. Near-black and near-white samples lose chroma rather than becoming saturated color at an unusable luminance extreme. Effective contrast is measured after every gradient, scrim, and glass layer is composited.

### Environmental composition

- Keep source artwork crisp and visually primary.
- Prefer localized gradients, edge-color continuation, or pre-rendered low-frequency color fields.
- Blur, if used at all, is a bounded ingredient of a cached background asset—not a live full-screen copy of the cover.
- Contextual and Hero environments taper into the neutral Content Canvas. They must not produce the hard dark/light band observed in the baseline YouTube detail.
- Functional text and controls receive a local contrast-protection layer when the environment cannot guarantee contrast.
- The PlayerBar may receive only weak, localized artwork influence; it does not become a miniature Now Playing background.
- Spectrum and Vinyl do not supply colors back into glass every frame.

### Processing and identity

The future pipeline is:

`Artwork identity → resolved source → cached decode/downsample → palette analysis off main actor → normalized palette descriptor → surface-specific environment policy → identity-checked render`

Requirements:

- Cache the palette descriptor by stable media/artwork identity, appearance, and normalization-policy version. Environment intensity and spatial composition remain lightweight surface policies.
- Cancel obsolete work and verify identity before publishing.
- Never pass live SwiftData model objects into detached palette work.
- Never compute palettes per card during grid rendering.
- Reuse the prepared palette descriptor across detail, PlayerBar, and Now Playing; apply a surface-specific Contextual, Hero, or Immersive environment policy at render time.
- A missing, corrupt, remote-failed, or low-information image always maps to a deterministic appearance-aware neutral fallback.
- Track changes crossfade between already prepared descriptors; elapsed playback time does not recompute them.

## I. Player state and interaction language

### Player and content state semantics

| State | Required visual signals | Motion | Nonvisual / accessibility |
|---|---|---|---|
| **playing** | Playing glyph or equalizer, stronger current title, semantic accent | Optional restrained equalizer only where affordable | “Currently playing” value; not color-only |
| **paused current** | Same current-item identity with static glyph and reduced activity | Continuous playback indicator stops | “Paused, current track” |
| **buffering** | Native progress indicator plus retained media identity | Indeterminate system progress only | Announces buffering without repeated chatter |
| **unavailable** | Disabled foreground, unavailable/slash icon, concise reason | None | Disabled trait and reason |
| **selected** | Persistent selection fill/outline | Short color transition at most | Selection trait |
| **focused** | Native or equivalent focus ring distinct from selection | Immediate or system-owned | Keyboard focus |
| **hovered** | Temporary luminance/fill/action reveal | Micro Motion | No semantic state change |
| **liked** | Filled heart and semantic state emphasis | Micro response on action only | Toggle value/label |
| **pinned** | Filled pin and semantic state emphasis | Micro response on action only | Toggle value/label |
| **loading** | Native progress and stable placeholder geometry | No universal shimmer | Announces loading once |
| **error** | Error symbol, message, and recovery affordance | Optional brief appearance only | Error announcement and actionable label |

Playing, selected, focused, and hovered may coexist. Their signals cannot overwrite one another.

### Pointer interaction primitives

| Interaction role | Visual response | Timing / character | Keyboard equivalent | Accessibility constraint |
|---|---|---|---|---|
| **Media Card Hover** | Artwork luminance rises slightly; artwork may scale up to 1.01–1.015; a small shadow may strengthen; one primary action may appear in reserved space | 120–180 ms ease-out | Focus exposes the same primary action; Return activates | Reduce Motion removes scale; card label and action remain accessible |
| **Dense Row Hover** | Low-opacity full-row fill; trailing secondary actions reveal without reflow | 80–140 ms ease-out | Focus uses a stronger ring/selection treatment; actions enter focus order | No scale; hover-only actions also exist in context menu/VoiceOver |
| **Control Hover** | Prefer native control response; custom icons gain restrained luminance or semantic backing | 80–120 ms, no bounce | Native focus and Space/Return activation | Hit target stays stable; tooltip is not the accessible name |
| **Pressed** | Native pressed state first; custom media/control may use slight luminance reduction and at most a very small compression | 60–100 ms | Space/Return receives equivalent state | Reduce Motion uses opacity/luminance only |
| **Selection** | Stable semantic fill or outline that persists after pointer exit | Immediate to 120 ms | Arrow keys move selection; Return activates where appropriate | Never inferred from hover or color alone |
| **Focus** | Native focus ring or a system-equivalent explicit outline | System-owned or immediate | Tab/arrow navigation | Must remain visible in Increase Contrast and over artwork |
| **Drag / Reorder** | Preserve dimensions; slight lift/elevation, reduced neighbor emphasis, explicit insertion line | 100–160 ms lift; position follows pointer | Provide native move actions where practical | No capsule conversion; VoiceOver reorder actions |

### Interaction rules

- Ordinary browsing uses the arrow pointer. Use text, resize, and scrub cursors only where semantically correct; do not import web “hand cursor everywhere” behavior.
- Hover state is local to the hovered view and does not enter global playback observation.
- Revealing actions may not change row/card geometry or cause text reflow.
- Full-row and full-card hit regions are explicit, but nested controls retain independent semantics.
- Native sidebar, list, menu, toolbar, slider, and form interaction should not be restyled away.

## J. Motion language

Motion categories encode purpose, not arbitrary spring constants.

| Category | Purpose | Duration range | Character | Geometry allowed | Performance sensitivity | Reduce Motion |
|---|---|---:|---|---|---|---|
| **Micro Motion** | Hover, press, icon/state response | 80–160 ms | Ease-out; no bounce | Tiny card/control scale only | Low | Luminance/opacity only or immediate |
| **Structural Motion** | Search, Queue, panel, disclosure | 180–280 ms | Smooth ease-in-out; system transition preferred | Bounded panel travel allowed | Low–Medium | Fade or immediate presentation |
| **Continuity Motion** | Artwork/card to detail | 280–450 ms | Low-bounce spring or matched transition | Artwork frame/shape may transform | Medium | Short crossfade preserving destination layout |
| **Playback Continuity** | PlayerBar to Now Playing | 400–650 ms | Deliberate, critically controlled morph | Artwork and one glass/control composition may recompose | Medium; High if implemented with live sampling | Direct destination or short crossfade |
| **Environmental Motion** | Track-change color/environment | 350–700 ms | Slow ease; double-buffered crossfade | No layout changes | Medium | Immediate swap or very short dissolve |
| **Media Motion** | Vinyl and spectrum | Continuous only while meaningful | Renderer-specific; physically calm | Renderer-local only | High | Static vinyl; reduced/static visualization |

### Motion ownership

- One presentation layer owns each transition. Parent and child must not apply competing implicit animations.
- Never attach broad implicit animation to playback position, duration, lyrics time, or spectrum samples.
- Lyrics animate by line identity/change, not every 10 Hz timeline tick.
- Continuous renderers stop or reduce work when hidden, paused where semantically correct, inactive, or under accessibility policy.
- Structural panels do not animate every result as Search text changes.

### Hero moment budget

Only five interactions receive exceptional treatment:

1. **PlayerBar → Now Playing.** The application's signature continuity moment. Artwork identity expands; the persistent control surface recomposes; metadata maintains continuity.
2. **Track-change environment.** A prepared, identity-safe environment transitions without flashing or repainting functional controls.
3. **Artwork → detail.** Selected artwork anchors navigation into album, artist, playlist, or YouTube context.
4. **Cover ↔ Vinyl.** The same artwork changes media role while the platter is introduced or removed.
5. **Lyrics reveal.** The composition makes deliberate room for lyrics while preserving current-line continuity.

Search and Queue opening, Settings, sorting, disclosures, menus, and ordinary navigation remain polished and fast. They must not compete with listening.

## K. Responsive system

### Philosophy

Muses chooses layout from available content width **and height**, intrinsic control requirements, and semantic priority. A single global width breakpoint is prohibited.

The runtime sizes are reference conditions, not constants:

| Reference | Design expectation |
|---|---|
| **Spacious, 1500–1600 × 900–1000** | Use intentional alignment, bounded content widths, and balanced negative space; do not stretch every grid/card |
| **Standard, about 1280 × 800** | Canonical desktop composition |
| **Compact, about 1000 × 700** | Preserve all essential workflows with smaller heroes, adaptive grids, and condensed auxiliary playback controls |
| **Stress, about 829 × 600** | First practical degradation point; essential playback and dismissal controls remain visible, panels fit, content scrolls |

### Adaptive grids

- Use adaptive columns driven by semantic minimum/preferred card width, not fixed five-column counts.
- Album/artist library artwork prefers 180–200 pt and may contract toward 160 pt before reducing column count.
- Grid gaps remain semantically stable while column count changes.
- Wide layouts use a content max/alignment strategy so additional width creates meaningful breathing room, not a large empty lower half.
- Text height is reserved consistently so mixed title lengths do not break row alignment.

### Horizontal media strips and scroll edges

- Horizontal media strips retain a trailing canvas inset. A partial-card peek is used only deliberately as a scrolling cue; accidental artwork or text clipping is prohibited.
- Keyboard focus must scroll the focused card fully into view.
- Content and section headings respect native toolbar safe areas and scroll-edge behavior. A heading may not clip beneath toolbar controls as it did in the baseline scrolled Home state.

### Detail heroes

- Artwork clamps within 180–240 pt under ordinary conditions.
- Metadata and actions compress in priority order; they never collide with artwork.
- When horizontal regions no longer fit, the hero recomposes rather than merely shrinking text.
- Environmental color fades to neutral before track/list content in every mode.

### PlayerBar priority

The later PlayerBar redesign must preserve content in this order:

1. Play/pause, current media identity/title, and access to Queue/Now Playing.
2. Previous/next and a usable seek affordance.
3. Volume, which may condense from slider to icon/popover.
4. Time labels, which disappear before the seek affordance.
5. Auxiliary actions, which consolidate into overflow.

Current-media title must not disappear completely at the stress width. Long metadata truncates; control clusters do not overlap. Height may adapt modestly if that preserves essential content, but an iOS-style oversized bar is prohibited.

### Now Playing layout modes

Use fit-driven composition with at least:

- **Wide:** artwork/playback region and lyrics/context region coexist.
- **Compact:** smaller artwork and tighter major gaps; both regions remain balanced.
- **Stacked:** artwork, metadata/controls, and lyrics flow vertically with explicit scroll ownership.
- **Short:** essential metadata/transport/timeline remain visible; artwork shrinks and spectrum/secondary preview collapses before controls are lost.

The current 960 pt switch is not a design token. A layout may not select Wide unless its actual artwork, gap, rail, and edge requirements fit. Width and height modes combine independently.

### Transient surfaces

- Search keeps a comfortable 560 pt ideal width but clamps to available width with at least a 24 pt window margin; results scroll.
- A native resizable inspector is the leading Queue candidate, pending a separately scoped runtime validation of overlay semantics, Now Playing stacking, reordering, keyboard focus, and dismissal. Whether native or corrected custom overlay, its ideal 360 pt width is bounded and should not consume roughly half the stress window unless that is the only usable mode.
- Settings and selection sheets keep comfortable ideal sizes but constrain to the scene and scroll internally.
- Every transient opened from Now Playing presents above Now Playing.

## L. Accessibility system

Accessibility behavior ships with each semantic primitive rather than being added screen by screen.

| Mode / need | System response |
|---|---|
| **Reduce Transparency** | `PlaybackGlass`, `InteractiveGlassGroup`, and `ContextualGlass` become opaque semantic elevated fills with explicit boundaries. Native structure uses system behavior. Artwork environments remain tone-mapped but functional controls receive opaque protection. |
| **Reduce Motion** | Micro scale becomes luminance; structural travel becomes fade/immediate; continuity becomes short crossfade; environment swaps immediately or briefly dissolves; vinyl is static; spectrum reduces or becomes static; lyric auto-scroll/type changes avoid animation. |
| **Increase Contrast** | Strengthen secondary/tertiary foregrounds, separators, selection fills, focus rings, glass boundaries, and control protection over artwork. Do not rely on shadows or transparency for separation. |
| **VoiceOver** | Artwork is represented once with meaningful media identity. Gradients, palette layers, shadows, vinyl grooves, and spectrum bars are hidden. Current-playing state, buffering, source, quality, and Queue section are meaningful values. Reorder exposes move actions. |
| **Keyboard** | Every hover-revealed action is focusable or available in a context menu. Selection, focus, default action, Escape dismissal, and arrow navigation remain distinct concepts. |
| **Differentiate Without Color** | Playing uses a glyph/weight/value; selected uses geometry; liked/pinned use filled symbols; source uses icon/text; success/warning/error use symbol and text; quality uses explicit label. |
| **Light / dark appearance** | Environment descriptors, foreground choices, scrims, and glass fallbacks are independently evaluated. No simple inversion and no theme-assumed foreground over artwork. |

Decorative visualizations must not lengthen the accessibility reading order. Native controls retain native roles and focus behavior even when hosted inside custom glass.

## M. Performance budget

### Cost classes

| Class | Allowed examples | Policy |
|---|---|---|
| **Low** | Static semantic fills, native controls/lists, native structural glass, simple local hover, cached environment application | Default for browsing and settings |
| **Medium** | One PlayerBar glass surface, one bounded custom Search panel, localized cached artwork transition, matched artwork continuity | Use only for semantic hierarchy; verify in packaged app |
| **High** | Existing isolated Spectrum/Vinyl renderers; proposed continuous animated blur, large glass over animated media, per-card palette computation, nested glass sampling, or layout tied to high-frequency state | Existing dedicated media renderers may remain High when isolated. New high-cost compositing and high-frequency layout work are prohibited by default and require a separate measured proposal. |

### Hard performance rules

- High-frequency playback state never drives glass appearance.
- PlayerBar glass observes media identity, appearance, presentation, and low-frequency semantic state only—not position or duration.
- Timeline/time labels update in an isolated subtree.
- Lyrics updates invalidate lyrics only, not playback controls or the environment.
- Spectrum and Vinyl render outside glass sampling regions.
- Artwork decode, downsample, and palette analysis happen off the main actor where safe, are cached, cancellable, and identity-checked.
- A grid does not start palette work for every card.
- No broad SwiftUI observation is added to support hover, glass, or environment effects.
- Continuous visual work pauses when offscreen; hidden Now Playing media renderers do not continue merely because playback is active.
- Animation must not allocate or retain work in proportion to playback duration.
- No large shadow radius, blur radius, or material bounds animate continuously.
- A new Medium-cost effect requires packaged-app CPU, memory, responsiveness, and energy inspection at Standard and Stress sizes.
- A High-cost exception requires profiling against the stable post-fix playback baseline and an explicit accessibility fallback.

## N. Proposed SwiftUI design-system architecture

Muses needs a few narrow primitives, not a generalized UI framework.

### Tokens versus semantic components

Reusable **tokens** should cover values whose meaning remains stable across unrelated views:

- spacing relationships;
- geometry and media-shape roles;
- semantic foreground/status roles;
- artwork-environment intensity;
- semantic motion categories;
- preferred artwork size ranges.

Reusable **semantic components or modifiers** should exist only where behavior, fallback, and composition must remain consistent:

- playback glass;
- grouped interactive glass over media;
- artwork-environment rendering;
- role-parameterized card/row/control interaction;
- pure playback-state presentation.

Responsive page composition, hero layout, Search result content, Queue behavior, and individual media-card content remain feature-specific. They consume tokens and narrow modifiers without being forced through one generic component.

| Proposed abstraction | Why it exists | Consumers | Must not contain |
|---|---|---|---|
| **`MusesVisualMetrics`** | Names spacing, radius, and artwork ranges | All feature views | Component-specific layout metrics, services, state, actions, animations, hard screen breakpoints |
| **`MusesSemanticColors`** | Becomes the migration destination for current `BrandColors` and names custom foreground-over-media, semantic status, scrim, and fallback roles while deferring to system colors on native surfaces | Artwork heroes, custom glass, playback state | A parallel permanent palette, decorative colors, extracted artwork colors, screen-specific values |
| **`ArtworkPaletteDescriptor`** | Immutable, Sendable value carrying media/artwork identity, normalized colors, appearance, and contrast facts | Environment policies and renderers | Intensity, spatial layout, SwiftData models, arbitrary-resolution images, playback time |
| **`ArtworkEnvironmentPolicy`** | Defines Contextual/Hero/Immersive intensity, localization, taper, and protection rules independently of palette data | Home/detail/PlayerBar/Now Playing renderers | I/O, palette extraction, playback observation |
| **`ArtworkEnvironmentResolver`** | Coordinates the existing `ArtworkSource`, `ArtworkCache`, and `AlbumArtworkExtractor` to resolve/cache descriptors, cancel stale work, and enforce identity | Media-context feature models/services | A parallel artwork-loading source of truth, SwiftUI layout, glass, animations, direct view mutation |
| **`ArtworkEnvironmentView`** | Renders a prepared palette descriptor plus a surface policy | Conditional Home hero, details, PlayerBar edge tint, Now Playing | Palette computation, network/file I/O, playback observation |
| **`MusesMotionPolicy`** | Small value/policy namespace mapping semantic categories to accessibility-aware transitions | Presentation and interaction styles | An observable global service, global implicit animation, media-timeline observation |
| **`MusesInteractionStyle`** | Reuses visual hover/press/focus/action reveal through narrow `mediaCard`, `denseRow`, and `control` roles | Cards, Songs, Queue, Search, playlist rows, custom controls | Card/row content, navigation, playback actions, data loading, reorder persistence |
| **`PlaybackGlassSurface`** | PlayerBar-local infrastructure owning its one glass/fallback boundary and platform availability | PlayerBar only | A general-purpose container, playback service, timeline state, individual control styling |
| **`InteractiveGlassGroup`** | Hosts compact related controls over rich media with one grouped glass container and fallback | Detail/Now Playing action groups | Per-button capsules, metadata, arbitrary content cards |
| **`PlaybackVisualState`** | Pure immutable semantic state and accessibility description shared across playback representations | Rows, Queue, PlayerBar, Now Playing, Search | A duplicate `PlayerState`, independent observation, engine calls, timers, surface-specific glyph size/weight |

### Architecture constraints

- Do not create one universal `MusesSurface(role:)` that can turn arbitrary content into glass.
- Do not create a universal `MediaCard` that erases album/artist/playlist semantics or layout needs.
- Responsive layout remains component-specific, using adaptive grids, `ViewThatFits`, custom `Layout`, or measured fit where appropriate. There is no global “960” service.
- Standard SwiftUI buttons, sliders, menus, lists, forms, sheets, popovers, and inspectors remain direct wherever possible.
- The glass wrappers own API availability, Reduce Transparency, Increase Contrast, boundary, and shape policy. Their content owns actions and accessibility labels.
- Design primitives never acquire `PlaybackService`, SwiftData contexts, MediaRemote integration, or high-frequency timers.
- Except for the small metrics/color migration namespaces, introduce an abstraction with its first real consumer rather than scaffolding the full list upfront.
- A custom Search panel remains Search-local until a second real consumer proves that a shared command-surface abstraction is warranted.

### Suggested implementation order for the system itself

1. Introduce static metrics and make semantic colors the migration destination for existing `BrandColors` without visually redesigning screens.
2. Add the role-parameterized interaction style with its first restrained browsing consumer and validate native focus.
3. Build the identity-safe palette descriptor pipeline with its first media-environment consumer, coordinating the existing artwork stack.
4. Add each narrow glass wrapper only with its first approved consumer, including macOS 14–15 and accessibility fallbacks.
5. Validate that the first migrated family does not require a universal card or surface abstraction.
6. Only then begin separately scoped PlayerBar and Now Playing work.

## O. Design system matrix

| Surface | Surface role | Glass role | Artwork intensity | Geometry role | Motion role | Interaction role | Accessibility fallback | Performance class |
|---|---|---|---|---|---|---|---|---|
| **Sidebar** | Native Structure | NativeStructuralGlass | None | Native rows | Native structural | Native selection/focus | System RT/contrast; explicit selected label | Low |
| **Toolbar / titlebar** | Native Structure | NativeStructuralGlass | None | System-owned | Native structural | Native controls | System focus/contrast | Low |
| **Conditional Home featured hero** | Media Environment | NoGlass base; InteractiveGlassGroup only for actions if needed | Contextual | hero artwork | Continuity | Media actions, restrained hover | Neutral fallback; opaque action group under RT | Medium |
| **Album cards** | Content Canvas | NoGlass | Thumbnail | media artwork | Micro only | Media Card Hover | No-scale RM; focus ring; action available by keyboard | Low |
| **Artist cards** | Content Canvas | NoGlass | Thumbnail | circle | Micro only | Media Card Hover | Same, with meaningful artist image label | Low |
| **Playlist cards** | Content Canvas | NoGlass | Thumbnail | media artwork | Micro only | Media Card Hover | Focus/selection distinct; source/text cues | Low |
| **Playlist rows** | Content Canvas | NoGlass | Thumbnail | denseMedia / native row | Micro only | Dense Row Hover | Focus/selection distinct; actions remain keyboard-accessible | Low |
| **Song rows** | Content Canvas | NoGlass | Thumbnail | denseMedia / native row | Micro only | Dense Row Hover | Persistent selection and current glyph; no color-only state | Low |
| **Detail heroes** | Media Environment | NoGlass base; InteractiveGlassGroup for compact actions | Hero | contextHeroArtwork / hero | Continuity | Hero actions and media identity | Neutral taper; opaque controls; contrast-selected text | Medium |
| **YouTube import management** | Content Canvas | NoGlass | Thumbnail | media thumbnail / dense row | Micro + restrained disclosure | Dense Row / disclosure | Source icon+label; stable expansion; no color-only remote/local | Low |
| **Search** | Floating / Transient | ContextualGlass as one panel, if native presentation is insufficient | Thumbnail | floatingPanel; native rows | Structural | Dense Row + keyboard selection | Opaque panel under RT; fade under RM; explicit focus/default/Escape | Medium |
| **Queue** | Floating / Transient | SystemTransientGlass preferred; one ContextualGlass drawer only if behavior validation requires a custom overlay | Thumbnail | System inspector or bounded custom drawer; dense rows | Structural + drag | Dense Row + Drag/Reorder | Opaque fallback; current-state label; move actions | Low native / Medium custom |
| **PlayerBar** | Persistent Playback | PlaybackGlass, one outer surface | Contextual—strictly weak/localized; direct artwork remains contained | playbackSurface + compactMedia | Playback Continuity + control Micro | Control Hover; stable adaptive groups | Opaque playback surface; strong boundary/focus; no-scale RM | Medium |
| **Now Playing environment** | Immersive Playback | NoGlass base | Immersive | Full viewport plus responsive immersiveArtwork | Environmental + Playback Continuity | Direct media and control regions | Deterministic neutral environment; protected text/control contrast | Medium |
| **Now Playing controls** | Contextual Control Surface | One InteractiveGlassGroup per spatially distinct control region; adjacent controls share one group/container; never per-button glass | None—inherits the protected environment without sampling artwork | controlGroup | Playback Continuity + Micro | Control Hover / focus | Opaque group under RT; direct layout under RM | Medium |
| **Lyrics** | Immersive Playback content | NoGlass | None—inherits the protected environment without sampling artwork | Text flow, no card | Line continuity / reveal | Scroll, focus where interactive | No animated auto-scroll under RM; readable protected region; grouped VO | Medium |
| **Spectrum** | Immersive Playback media | NoGlass | None—may consume a prepared semantic color but performs no artwork sampling | Renderer-specific | Media Motion | Noninteractive/decorative by default | Hidden from VO; reduced/static under RM | High—existing isolated renderer |
| **Vinyl** | Immersive Playback media | NoGlass | Thumbnail—direct artwork remains within the vinyl label; immersive scale is geometry, not environmental propagation | circle | Media Motion + cover continuity | Mode control outside renderer | Static under RM; grooves hidden from VO | High—existing isolated renderer |
| **Settings** | Floating / Transient | SystemTransientGlass | None | System Form/List | Native structural | Native controls/focus | System RT/contrast; scroll at small size | Low |
| **Sheets / popovers / menus** | Floating / Transient | SystemTransientGlass | None or Thumbnail only if task requires | System-owned | Native structural | Native actions/selection | System behavior; no redundant inner material | Low |
| **EQ editor** | Floating / Transient | SystemTransientGlass shell; NoGlass content | None | Native sheet + opaque chart | Micro only | Native sliders/chips/focus | Opaque chart; labels and numeric values; no color-only curve state | Low |

### Matrix interpretation

- “NoGlass base; InteractiveGlassGroup” means the content/environment itself stays glass-free and only a compact control group may receive custom glass.
- A High performance class does not authorize additional effects. It identifies an existing continuous renderer that must remain isolated.
- Native presentation is a design-system choice, not a temporary fallback.

## P. Implementation principles

Future visual implementation and code review must enforce these rules:

1. Ordinary album, artist, playlist, song, Search, and Queue items never receive custom Liquid Glass.
2. Native sidebar, toolbar, sheet, popover, menu, form, list, and inspector behavior is the first implementation choice.
3. The Now Playing viewport is an artwork environment, never one giant glass panel.
4. PlayerBar uses at most one outer `PlaybackGlass` surface; its controls do not become independent glass capsules.
5. Multiple nearby custom glass elements share one grouped container when they blend, coordinate, or morph; nested custom glass is prohibited.
6. New glass replaces redundant `ultraThinMaterial`, duplicate fills, and decorative strokes; media clipping, accessibility boundaries, fallback boundaries, and justified elevation remain branch-owned.
7. Every custom glass primitive compiles only with an SDK that supplies the macOS 26 APIs, uses a macOS 26 runtime availability branch, and ships macOS 14–15, Reduce Transparency, and Increase Contrast fallbacks.
8. Artwork environments always taper to a neutral Content Canvas before ordinary list content.
9. Artwork-derived color never supplies functional state or the sole foreground color decision.
10. Artwork environment work is cached, cancellable, off-main where safe, and guarded by stable media identity.
11. Every artwork environment has a deterministic appearance-aware neutral fallback.
12. PlayerBar glass appearance is not invalidated by playback position or duration updates.
13. Lyrics, timeline, spectrum, and vinyl updates remain isolated from unrelated playback controls and environmental surfaces.
14. Spectrum and Vinyl never sit beneath expensive live custom glass sampling.
15. Hover and action reveal never change card/row geometry; keyboard focus remains visibly distinct from hover and selection.
16. Every hover-only action also has a keyboard, context-menu, or VoiceOver path.
17. Playing, selected, focused, source, quality, success, warning, and error states never rely on color alone.
18. Semantic geometry and spacing tokens are used by intent; optical exceptions are documented rather than promoted into global tokens.
19. Responsive layout is selected by content fit and height; essential controls survive before artwork, visualization, time labels, or auxiliary actions.
20. Only the five budgeted hero moments may use exceptional continuity; every Medium/High-cost visual change is validated in the packaged app across relevant Spacious/Wide, Standard, Compact, Stress, Short-height, light/dark, and accessibility conditions.

## Acceptance criteria for future phases

A future surface migration conforms to this specification only when:

- its semantic surface and glass role are named;
- its static depth is legible without motion;
- its geometry, spacing, typography, color, artwork intensity, and state semantics map to this document;
- native interaction behavior is preserved or any replacement is explicitly validated;
- light, dark, Reduce Transparency, Reduce Motion, Increase Contrast, keyboard, and VoiceOver behavior are defined;
- its invalidation and rendering cost are bounded;
- it has been rendered in the real `.app` at relevant Spacious/Wide, Standard, Compact, Stress, and Short-height conditions;
- it does not broaden the scope into unrelated playback or product behavior.
