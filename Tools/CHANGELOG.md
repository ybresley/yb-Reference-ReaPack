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
  ### New | Improved | Fixed
  - **Area** — What changed.
    Optional indented second line.

Groups use those names and that order. `changelog-release` owns the detailed
workflow, area vocabulary, and curation rules. Include only user-noticeable
changes.
-->

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
