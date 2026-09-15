# Changelog

<!--
This is the single source of truth for full release notes. The script header,
GitHub release notes, Full Release Notes view, and Settings > Updates history
are generated from it. Illustrated introductions use separate, curated feature
and topic copy; see
.claude/skills/changelog-release/references/illustrated-updates.md.

It intentionally starts empty: 0.3.0 was the beta release, not an update for
existing testers. The first entry is the first post-beta update. Until then,
the app shows no What's New card or Release notes row, and
scripts/gen_header.lua emits no @changelog tag.

lib/core/changelog.lua parses this exact grammar:

  ## <version> — <YYYY-MM-DD>
  A short overview of the update's focus.
  ### Highlights | Changes | Fixes
  - **Area** — What changed.
    Optional indented second line.

Omit groups without entries. Published New/Improved/Fixed groups remain readable.
Groups use those names and that order. `changelog-release` owns the detailed
workflow, area vocabulary, and curation rules. Include only user-noticeable
changes.
-->

## 0.4.0 — 2026-09-15

This update brings a new high-quality frequency spectrum analyser, an improved waveform display and new interface animations, alongside smaller improvements and bug fixes.

### Highlights

- **Spectrum Analyser** — A new high-quality frequency spectrum analyser shows the frequency balance of reference playback, Library auditioning and the Reaper project. It includes detailed frequency readouts and adjustable listening bands, so you can inspect and hear specific parts of a sound.
- **Improved Waveform** — The waveform now shows finer detail down to individual samples, with combined time navigation and zoom, plus independent waveform height adjustment.
- **Panel Layout** — The waveform and spectrum now arrange themselves to fit the available space, with Side by Side and Stacked options in Settings and a swap button to change their order.
- **UI Animations** — Buttons, switches and colour changes now have subtle animations, adding motion to everyday controls. Interface Animations in Settings → Appearance turns them on or off.

### Changes

- **Reference Picker** — Pinned-reference labels can now be edited in place without closing the dropdown.
- **Reference Playback** — Reference View and Library volume readouts now accept exact typed values and reset with right-click.
- **Updates** — What's New can now present substantial release features with silent guided demonstrations while keeping the full release notes available.
- **Library** — New categories can now be confirmed with Enter.

### Fixes

- **Library** — Library waveforms now continue loading after a sound file cannot be read.
- **Waveform** — Start and end markers now match in size and stay aligned to the waveform.
- **Reference Playback** — Library Pitch changes now apply reliably during audition.
- **Reference Playback** — Pitch panels now stay on the current monitor and remain scrollable when screen space is limited.
- **Reference Playback** — Volume readouts now show rounded zero consistently while keeping the sign of nonzero values.
- **Loudness** — The Loudness panel now stays on the current monitor, opens clear of its button and keeps all controls reachable.
- **Reference Picker** — Dropdown rows now keep consistent widths, and the scrollbar appears only when needed.

## 0.3.2 — 2026-09-04

This update focuses on reference browsing and playback, alongside Library improvements and bug fixes.

### Changes

- **Waveform** — The Reference View waveform can now be zoomed and panned, with a time ruler that adapts to the zoom level.
- **Waveform** — Waveforms now show finer detail when zoomed in, with continuous outlines and more consistent thickness.
- **Waveform** — Clicking the Reference View waveform now starts playback from that position.
- **Reference Picker** — References can now be previewed from the dropdown without changing the selected reference.
- **Reference Picker** — Pinned references can now be searched by filename or label.
- **Reference Picker** — The dropdown now sizes to its contents and available screen space.
- **Loudness** — Pending pinned references now take priority, and measurement pauses between steps during recording.
- **Loudness** — A progress panel now shows measurement status and the number of sounds remaining.
- **Reference Playback** — Pitch controls now include a slider and a choice of semitone or percentage units.
- **Library** — Category deletion now asks for confirmation only when sounds would become Uncategorised.
- **Library** — Category counts now reflect search results, and active searches highlight the search icon.
- **Hotkeys** — Ctrl+A and Delete now work in the Library’s category and sound lists.
- **Dialogs** — Small dialogs now fit their contents and use consistent button layouts. Deletion prompts no longer dim surrounding windows.
- **Latch Mode** — The Latch button now uses a chain-link icon.

### Fixes

- **Reference Playback** — The playhead, seeking and start/end points now stay aligned with the sound when Pitch changes.
- **Reference Playback** — Changing the selected reference now stops the previous reference’s playback.
- **Loudness** — References pinned before measurement finishes now receive their missing readings.

## 0.3.1 — 2026-08-26

### New

- **Preview** — References can now be pitch-shifted.
- **Library** — References with up to eight channels are now supported.
- **UI** — UI size and accent colour can now be changed.

### Improved

- **Library** — Category, sound, sorting and column choices are now remembered.
- **UI** — The Settings panel now has a cleaner layout.
- **Settings** — Settings now include new quality-of-life options.
- **Setup** — The walkthrough now includes a Back button.

### Fixed

- **Latch mode** — The Latch button now works on more Reaper setups.
- **Projects** — Unsaved projects now show a warning when pinning is unavailable.
- **Library** — File drops no longer stall between yb-Reference windows.
- **Library** — The sound table no longer moves when switching categories.
