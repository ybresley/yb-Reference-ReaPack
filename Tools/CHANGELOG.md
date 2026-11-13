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

## 0.6.0 — 2026-11-13

This update adds surround analysis, a combined Reference panel and a Library that can stay beside Reference View, along with Reference mode and metering fixes.

### Highlights

- **Surround** — Reference View now measures surround audio up to 7.1. Meters, loudness and Spectrum follow every speaker, each project remembers its speaker layout, and the Surround Field shows where neighbouring speakers are in or out of phase.
- **Reference Panel** — The Waveform panel and the bottom bar are now one Reference panel beside the analysis panels. It keeps the picker, stored readings, waveform and playback controls together, and folds its parts in a fixed order as the window gets smaller.
- **Docked Library** — The Library can stay open beside Reference View, with its own waveform and audition controls, including a new Mono button. Review Files lists audio in the Library folder that isn't part of your Library, so you can add it or move it to the trash.

### Changes

- **Updates** — When a new version is out, a popup shows its date and overview, with Release Notes, Skip This Version and Update Now. Skipping a version keeps the popup away until a newer one. Turn the popup off from the popup itself or in Settings → Updates.
- **Loudness** — When the meter panel is short, the Readings column keeps two readings instead of hiding. Right-click it to choose which two.
- **Loudness** — Meter bars keep even spacing at every width, with their labels above the values.
- **Loudness** — Very short meter panels now keep their readings, with each label beside its value. The shortest show one or two readings. Click a label to choose another.
- **Library** — The Library reopens open or closed, as you left it. Open Library on Startup is removed.
- **Library** — Adding audio together with other files, such as licences or artwork, no longer reports the other files as errors.
- **Appearance** — Tooltips appear beside the control or area they describe and stay still while the pointer moves. They now wait half a second before appearing.
- **Dialogs** — Info messages, such as Reference mode turning off, now have a close button.

### Fixes

- **Latch Mode** — Reference mode no longer leaves a project muted after Save As, with the project open in two tabs, or when yb-Reference closes while latched.
  A project that still needs unmuting by hand now says so.
- **Projects** — After Save As, a pin no longer picks up a different sound of the same size.
- **Loudness** — The meter now connects after Reaper restarts, instead of reporting that it was changed or not added by yb-Reference.
- **Spectrum Analyser** — The spectrum line no longer thins out or disappears in dense high-frequency detail.
- **Window** — A graphics failure now closes yb-Reference without a second script error.

## 0.5.2 — 2026-10-26

This update adds macOS support and improves live metering and small-window layouts.

### Changes

- **macOS** — yb-Reference can now run on macOS.
- **Loudness** — When space is tight, meter bars switch to numeric M/S/I readings and the highest true peak since reset.
- **Loudness** — Extra Readings adds RMS and Target Diff alongside Crest Factor. Click Target Diff to switch between Integrated, Momentary and Short-Term loudness.
- **Loudness** — L/R peak bars are brighter.
- **Setup** — The tutorial now starts in Reference View and introduces its display panels and the feedback form.
- **Settings** — Spectrum/Filter Settings, Stereo Settings and Loudness Settings now have a Close button.

### Fixes

- **Loudness** — Reconnect no longer adds duplicate meters to Monitor FX after a connection failure.
- **Window** — Loudness and Stereo keep measuring through brief interface pauses.
- **Window** — Switching between Lissajous and Polar Sample no longer resizes the other panels.
- **Spectrum Analyser** — Stopping playback no longer adds false high-frequency energy to the display.
- **Spectrum Analyser** — Starting a reference again now clears its previous Average trace.
- **Updates** — ReaPack update reports now separate the release notes for each version.

## 0.5.1 — 2026-10-16

This update addresses freezes related to live metering.

### Changes

- **Loudness** — Removed the separate True Peak meter from Monitor FX.
  TP Max now measures the same left/right pair as the other meters.
- **Loudness** — The meter stays in Monitor FX and sleeps when yb-Reference closes.
  Reopening reuses it instead of loading another copy.

### Fixes

- **Loudness** — Fixed freezes when starting or stopping playback with live metering enabled.
- **Window** — Fixed repeated pauses when reopening or closing yb-Reference with live metering enabled.

## 0.5.0 — 2026-10-16

This update adds live metering, stereo analysis and panel layout controls to Reference View, alongside monitoring and update fixes.

### Highlights

- **Metering** — Reference View now includes live loudness and channel meters, with loudness history, adjustable targets and retained warnings for comparing your reference playback with the Reaper project.
- **Stereoscope** — The new Stereo panel shows the stereo image in Polar Sample or Lissajous view, with correlation, clipping markers and controls to freeze or clear the display without changing the audio.
- **Panel Layouts** — Waveform, Spectrum, Stereo and Loudness can be arranged together in Settings. Panel choices, positions and sizes are remembered between sessions.

### Fixes

- **Monitoring Filter** — The helper now waits for Reaper's recovery process before it is added, avoiding a conflict during startup.
- **Updates** — Settings no longer shows an error as an in-app update finishes.

## 0.4.1 — 2026-09-19

This update adds configurable hotkeys, separate playback controls and more accent colours, alongside improved release notes and a floating-window crash fix.

### Changes

- **Hotkeys** — Hotkeys are now available for yb-Reference controls and stay in sync with Reaper's Actions list. Assign them in Settings → Hotkeys; assigned shortcuts also appear in the matching button tooltips.
- **Reference Playback** — Reference View and Library now have separate Play and Pause / Resume controls. Play restarts the sound, while Pause / Resume continues from the same position.
- **Updates** — Release Notes now includes every version you missed when updating across several releases. Open the full history from Settings → Updates.
- **Appearance** — Accent Colour now offers twelve choices in Settings → Appearance.

### Fixes

- **Window** — Moving yb-Reference beyond the edges of Reaper's window no longer crashes the tool.

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
