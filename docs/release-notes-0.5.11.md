# Muses 0.5.11

Settings are more compact, with consistent actions and less standing explanatory text.

- General, shortcuts and gestures, playback, appearance, account, lyrics, diagnostics, help and privacy, and About use the selected compact design. Library Review uses summary statistics and a searchable review list.
- Appearance and Home source choices use native Liquid Glass capsule controls with champagne-gold selection. Library Review summary cards have white backgrounds in light appearance and adaptive backgrounds in dark appearance.
- Font selection includes a searchable system-font popover. Detailed explanations remain available through information buttons and disclosure sections.
- Fix an automatic-update cleanup-path validation failure caused by directory URL trailing-slash differences. Existing symlink validation and active-installer protection remain in place.

Requires macOS 14 or later on Apple Silicon (arm64). Native Liquid Glass is available on macOS 26; earlier supported systems use system material fallbacks.

Validation: 758 tests in 105 suites passed. Settings were inspected in the running native application, including font selection, help popovers, compact windows, and dark appearance with large text. Account authorization and update installation are not claimed as live end-to-end acceptance checks.
