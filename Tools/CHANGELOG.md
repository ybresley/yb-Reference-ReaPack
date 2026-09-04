# Changelog

<!--
This is the single source of truth for release notes. The script header,
GitHub release notes, What's New card, and Settings > Updates history are
generated from it. Do not write release notes elsewhere.

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
