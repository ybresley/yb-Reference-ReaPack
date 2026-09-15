-- transport: the play/loop/auto-audition controls plus the per-sound trim and
-- master preview volume faders. A ui/ module — draws and reports intent only.
-- Reusable controls (faders, toggles, the reset gesture) come from ui.widgets so
-- they behave identically everywhere; this file only arranges them.

local theme = require("ui.theme")
local tips = require("ui.tips")
local widgets = require("ui.widgets")
local match = require("core.match")
local icons = require("ui.icons")
local icon_motion = require("ui.icon_motion")
local refpicker = require("ui.refpicker")
local matchwin = require("ui.matchwin")
local pitchwin = require("ui.pitchwin")
local settings = require("ui.settings")
local walkthrough_ui = require("ui.walkthrough")
local control_bar_layout = require("core.control_bar_layout")
local T = theme.tokens
local M = theme.metrics

local transport = {}

-- Text fallbacks for when the Lucide icon font isn't available (see ui/icons.lua);
-- normally the transport draws Lucide glyphs, same set as every other icon.
local PLAY = "\u{25B6}" -- ▶
local PAUSE = "\u{23F8}" -- ⏸
local STOP = "\u{25A0}" -- ■
local LOOP = "\u{21BB}" -- ↻

-- Hoisted so the frame loop never rebuilds it (frame-allocation rule).
local SOFT_ACTIVE_FACE = { color = T.ACCENT_HOVER }

local RESET_HINT = " \u{00B7} right-click or double-click to reset"

-- The master preview-volume fader, right-aligned to the current line (it owns its
-- placement so a host row can just drop it in). The "Preview" label introduces it
-- (2026-07-29 review — the user couldn't tell what the fader was for): small, but
-- a label the user is meant to read, so TEXT_SECONDARY like every other label
-- (2026-08-01 — it was TEXT_QUATERNARY, which tokens.md reserves for things
-- nobody has to read; mixed case for the same reason, small caps read as noise
-- here rather than as a heading).
--
-- The caption is RESERVED then painted, not laid out. Laid-out text is positioned
-- by FramePadding, which sits a 13px caption about a pixel above the 15px readout
-- beside it — enough to read as "the number is sitting low". Reserving a
-- full-control-height slot and centring the caption in it by hand lines the
-- caption, the track and the number up on one axis exactly.
function transport.draw_master(ctx, state)
  local label = "Preview"
  -- Read BEFORE the small font goes on: GetFrameHeight follows the CURRENT font,
  -- so asking with 13px pushed answers 25 instead of the row's real 27 — and the
  -- caption would then be centred in a slot two pixels short of the fader's.
  local frame_h = reaper.ImGui_GetFrameHeight(ctx)
  local small = theme.push_small_font(ctx)
  local lw, lh = reaper.ImGui_CalcTextSize(ctx, label)
  local spacing = 6
  local block_w = lw + spacing + M.SLIDER_W
  local cx = reaper.ImGui_GetCursorPosX(ctx)
  local avail = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local target = cx + avail - block_w
  if target > cx then reaper.ImGui_SetCursorPosX(ctx, target) end -- push to the right edge

  reaper.ImGui_Dummy(ctx, lw, frame_h)
  local lx0, ly0 = reaper.ImGui_GetItemRectMin(ctx)
  local _, ly1 = reaper.ImGui_GetItemRectMax(ctx)
  reaper.ImGui_DrawList_AddText(reaper.ImGui_GetWindowDrawList(ctx),
    lx0, (ly0 + ly1) * 0.5 - lh * 0.5, T.TEXT_SECONDARY, label)
  if small then reaper.ImGui_PopFont(ctx) end
  reaper.ImGui_SameLine(ctx, 0, spacing)
  -- Master caps at 0 dB (unity) and only attenuates from there.
  local mdb, mcommit = widgets.db_fader(ctx, "master", state.master_db,
    { min = -60, max = 0, default = 0, tip = "Master preview volume" .. RESET_HINT,
      value_tip = "Click to type a preview volume · right-click to reset" })
  if mdb ~= nil then return { type = "set_master", db = mdb, commit = mcommit } end
  return nil
end

------------------------------------------------------- the transport controls

-- PLAY/PAUSE AND STOP LIVE HERE ONCE AND BOTH WINDOWS DRAW THEM (2026-08-12,
-- when the Library gained a transport of its own): the Reference View's control
-- cluster and the Library's info row call the same two functions, so the two
-- transports cannot drift into looking or behaving differently — which is the
-- whole reason the user asked for a full transport in the Library rather than a
-- lone stop button.
--
-- Each draws ONE control-height square AT THE CURSOR. Placement stays with the
-- caller on purpose: the Reference View positions its cluster absolutely (its bar
-- folds to two lines) while the browser lays its row out with SameLine, and a
-- shared function that owned placement would have to speak both languages.
--
-- `opts` = { slot, id, sound }:
--   slot   which playback this pair speaks for — "main" (the Reference View and
--          reference mode) or "browse" (the Library). It is stamped on the
--          returned action as `target`, exactly the way the browser tags its
--          seek, and the entry script reads it to decide whose remembered pause
--          the click belongs to
--   id     the sound id this window is pointed at (selected_id / browse_id)
--   sound  that sound's record, or nil when this window has nothing to act on

-- Is this slot's own sound sounding, and is it paused? One answer, because it
-- decides three things at once (the face, the tooltip, and whether the square is
-- dim) and the two buttons must agree about it exactly.
--
-- The slot test matters as much as the id: there is ONE live preview and two
-- windows that can speak for it, so without it a Library audition of the very
-- sound the Reference View has armed would light up both transports and let either
-- one pause it. Reading `state.preview.paused` directly (rather than through
-- holders, which pulls in the adapters a ui/ module may not touch) is the same
-- draw-from-state deal every other panel here has.
local function playback_state(state, slot, id)
  local playing = state.preview.playing and state.preview.slot == slot
    and state.preview.sound_id ~= nil and state.preview.sound_id == id
  local parked = state.preview.paused[slot]
  local paused = (not playing) and parked ~= nil and id ~= nil and parked.sound_id == id
  return playing, paused
end

-- Play / pause. Every audio transport uses the shared soft active treatment.
--
-- "Stopped" and "paused" share the same PLAY face: clicking either resumes from
-- wherever this slot was left, or starts fresh. Dimmed — never hidden, never
-- resized — when the window has no sound to act on at all.
function transport.draw_play(ctx, state, font, opts)
  local slot = opts.slot
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local playing, paused = playback_state(state, slot, opts.id)
  local face = playing and "pause" or "play"
  local use_icon = font and icons.NAMES[face]

  local dim = opts.sound == nil
  if dim then reaper.ImGui_BeginDisabled(ctx) end
  local soft_pushed = widgets.push_soft_active(ctx, playing)
  if playing then reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.ACCENT_HOVER) end
  local clicked = reaper.ImGui_Button(ctx,
    (use_icon and "" or (playing and PAUSE or PLAY)) .. "##playpause_" .. slot, ctrl, ctrl)
  if playing then
    reaper.ImGui_PopStyleColor(ctx)
    widgets.pop_soft_active(ctx, soft_pushed)
  end
  -- Follow confirmed playback, so failed starts and pausing never light a bloom.
  widgets.play_bloom(ctx, slot, playing and not dim)
  -- The painted glyph fades itself against the live style alpha (icons.lua), so
  -- a disabled square dims face and all with no hand-faded colour here.
  if use_icon then
    SOFT_ACTIVE_FACE.color = T.ACCENT_HOVER
    icons.paint_over_item(ctx, font, face, playing and SOFT_ACTIVE_FACE or nil)
  end
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  if dim then reaper.ImGui_EndDisabled(ctx) end
  tips.show(ctx, hovered,
    playing and "Pause" or (paused and "Resume" or "Play selected sound"))

  if clicked then return { type = "toggle_play", target = slot } end
  return nil
end

-- What the STOP square acts on: anything this slot has going, whatever sound it
-- happens to be. Deliberately NOT id-matched the way play/pause is, because the
-- two buttons answer different questions. "Play" means "play the sound this
-- window is pointed at", so it follows the selection. "Stop" means "stop what
-- this window has going" — and a window whose selection has moved on while its
-- own audio still runs (clicking a row with auto-audition off) must still be
-- able to stop it. Id-matched, the square went dim exactly then, and the only
-- way to silence the sound was to start another one.
local function slot_busy(state, slot)
  return (state.preview.playing and state.preview.slot == slot)
    or state.preview.paused[slot] ~= nil
end

-- Stop: back to the start, no remembered position. Dimmed while this slot has
-- nothing sounding and nothing paused — there is genuinely nothing to stop.
-- (It used to be drawn bright and inert instead, because a dimmed button would
-- have left a bright glyph sitting on a faded square; the painters read the
-- style alpha themselves since 2026-08-12, so BeginDisabled is now enough.)
function transport.draw_stop(ctx, state, font, opts)
  local slot = opts.slot
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local use_icon = font and icons.NAMES["square"]

  local dim = not slot_busy(state, slot)
  if dim then reaper.ImGui_BeginDisabled(ctx) end
  local clicked = reaper.ImGui_Button(ctx,
    (use_icon and "" or STOP) .. "##stop_" .. slot, ctrl, ctrl)
  if use_icon then icons.paint_over_item(ctx, font, "square") end
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  if dim then reaper.ImGui_EndDisabled(ctx) end
  tips.show(ctx, hovered, "Stop and return to the start")

  if clicked then return { type = "stop_play", target = slot } end
  return nil
end

--------------------------------------------------------------- bar geometry

-- Measure host-controlled sizes here, then pass them with the live scaled theme
-- metrics to the pure policy. `transport.measure` and `transport.draw` both use
-- this function, so the reserved and drawn heights agree.
-- Squares in the transport cluster: play, stop, loop, mono, pitch. A constant so `cluster_w`
-- and the draw loop can never disagree about how many squares exist.
local N_CLUSTER = 5

local function geometry(ctx, width, count_w)
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local gap, gap_y = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing())

  local measured = {
    ctrl = ctrl,
    gap = gap,
    gap_y = gap_y,
    count_w = count_w or 0,
    cluster_count = N_CLUSTER,
  }
  -- Asked of the picker, never re-derived here: this used to be its own
  -- `ctrl * 2`, which silently went stale the day the arrow pair gained a
  -- gap between them, so the fit test measured a bar 4px narrower than the
  -- one that draws (Codex, 2026-08-06).
  measured.arrows_w = refpicker.arrows_width(ctx)
  -- The collapsed trim's number, sized for its widest reading ("+24.0 dB").
  measured.num_w = select(1, reaper.ImGui_CalcTextSize(ctx, "+24.0 dB"))
    + select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding())) * 2
  return control_bar_layout.geometry(width, measured, M)
end

-- How tall the bar needs to be at `width`. Called before anything else is laid
-- out in the Reference View. `state` is needed because the count reserves its
-- width from the project's pin total.
function transport.measure(ctx, width, state)
  return geometry(ctx, width, refpicker.count_width(ctx, state)).height
end

-- The reference-mode latch uses a chain link to show that reference playback
-- follows the project transport. Its active state uses the same soft accent
-- wash, outline and bright icon as the rest of this row.
-- Fixed size always: latching signals itself by colour alone, never by changing
-- shape.
--
-- Since 2026-08-13 it is deliberately project-specific: its accent fill means
-- THIS project owns the one active latch. Other tabs stay grey and usable; a
-- closed owner waits in the recovery queue without leaving a stuck-looking button.
-- Genuine recovery failures are surfaced as errors instead of overloading this
-- current-project control.
--
-- The icon cannot explain the safety behaviour by itself, so the tooltip carries
-- the full explanation and the accent fill still makes the on state clear.
function transport.draw_latch(ctx, state, font)
  local action
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local ref = state.reference
  local latched = ref.latched
  local soft_pushed = widgets.push_soft_active(ctx, latched)
  local clicked = reaper.ImGui_Button(ctx, "##reference", ctrl, ctrl)
  icon_motion.paint_item(ctx, "reference_latch", "link",
    latched and T.ACCENT_HOVER or T.TEXT_SECONDARY,
    latched, clicked and (latched or state.selected ~= nil))
  if clicked then
    if not latched and not state.selected then
      -- Muting an empty project would buy silence for nothing. Opening this
      -- project's chooser makes the missing step visible instead of making
      -- the latch appear dead; once a reference is armed, it is fully usable.
      refpicker.request_open()
    else
      action = { type = "toggle_reference" }
    end
  end
  widgets.pop_soft_active(ctx, soft_pushed)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  if hovered then
    local tip = latched
      and ("Reference mode is on for " .. (ref.owner_name or "this project") ..
        ". Its master is muted. Press Play in Reaper to hear the selected reference. " ..
        "Click the Latch button to turn it off.")
      or (state.selected
        and "Turn on Reference mode. This mutes the project so Play in Reaper hears the selected reference instead. You can bind the Latch button to a Reaper shortcut."
        or "Choose a reference first. Click the Latch button to open the reference list.")
    tips.show(ctx, true, tip, "reference_latch")
  end
  return action
end

-- The same Pitch button and persistent compact panel are used in both audition surfaces.
-- The icon shows an adjustment; the outline shows that the panel is open.
function transport.draw_pitch(ctx, state, font, slot)
  local value = (state.pitch and state.pitch[slot]) or 0
  local sound = (slot == "browse") and state.browse or state.selected
  local id = "pitch_" .. slot
  if not sound then reaper.ImGui_BeginDisabled(ctx) end
  local _, hovered = widgets.panel_button(ctx, font, id, "music-2",
    pitchwin.is_open(slot), "\u{266A}", value ~= 0, sound ~= nil, true)
  -- Open on mouse-down instead of waiting for the ordinary button release.
  -- The compact panel cannot overlap this button, so there is no accidental
  -- interaction with the newly appeared window during the same hold.
  local pressed = hovered and reaper.ImGui_IsMouseClicked(ctx, 0)
  local x0, y0, y1
  if pressed and sound then
    x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
    local _, rect_y1 = reaper.ImGui_GetItemRectMax(ctx)
    y1 = rect_y1
  end
  if not sound then reaper.ImGui_EndDisabled(ctx) end

  if pressed and sound then
    pitchwin.toggle_at(slot, x0, y0, y1)
  end
  tips.show(ctx, hovered,
    "Adjust Pitch. Higher values shorten playback; lower values lengthen it.", id)
  return nil
end

function transport.draw(ctx, state, res)
  local action
  local font = res and res.icon_font

  -- Bar geometry, worked out once up front by the shared `geometry` helper above
  -- so the height reserved for the bar matches the height it takes. Everything
  -- is fixed-size except the picker's name slot; only that slot and the gaps
  -- flex, which is what makes the collapse order work.
  local row_x0, row_y0 = reaper.ImGui_GetCursorPos(ctx)
  local row_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local g = geometry(ctx, row_w, refpicker.count_width(ctx, state))
  local ctrl, gap = g.ctrl, g.gap
  local trim_shown = g.trim_shown -- "fader" | "number" | false

  -- Absolute placement for the cluster: every button lives on `ctrl_y`'s line
  -- (line one normally, line two after the fold), so SameLine can't express it.
  -- `cluster_gap`, not the theme gap: a squeezed line two tightens it.
  local function place_cluster(i) -- i is 0-based
    reaper.ImGui_SetCursorPos(ctx,
      row_x0 + g.cluster_x + i * (ctrl + g.cluster_gap),
      row_y0 + g.ctrl_y)
  end

  -- LATCH: the A/B-against-your-project reference-mode toggle (labeled "LATCH"
  -- on the button, 2026-07-28 — a label change only; the action type and every
  -- internal name stay "reference"). The shared soft accent treatment appears
  -- only while ON and follows the user's chosen palette.
  -- Fixed width, always present: latching signals itself by colour alone, never
  -- by changing the row's shape. After the fold it leads line two.
  reaper.ImGui_SetCursorPos(ctx, row_x0 + g.latch_x, row_y0 + g.ctrl_y)
  -- Walkthrough targets are noted from GEOMETRY, not from "the last item":
  -- these buttons show tooltips, and a tooltip's own text becomes the last
  -- item the frame it appears — the ring would jump onto it (the same
  -- last-item trap tips.show documents).
  local walk_x, walk_y = reaper.ImGui_GetCursorScreenPos(ctx)
  action = transport.draw_latch(ctx, state, font) or action
  walkthrough_ui.note_rect(ctx, state.walkthrough, "latch",
    walk_x, walk_y, walk_x + ctrl, walk_y + ctrl)

  -- The transport cluster. The play/pause and stop squares are the SHARED pair
  -- (see the top of this file) — the Library's info row draws the same two —
  -- pointed at the "main" slot, so they speak only for the Reference View even
  -- while the one live preview is a browse audition (Phase 5.9: independent
  -- browsing).
  --
  -- Drawn, THEN merged (`local a = draw(...)`, never `action = action or
  -- draw(...)`): Lua's `or` short-circuits, so merging the wrong way round
  -- would skip the button's whole submission for any frame an earlier control
  -- already reported something, and the square would vanish for that frame.
  local main_slot = { slot = "main", id = state.selected_id, sound = state.selected }
  place_cluster(0)
  local play_x, play_y = reaper.ImGui_GetCursorScreenPos(ctx)
  local play_action = transport.draw_play(ctx, state, font, main_slot)
  walkthrough_ui.note_rect(ctx, state.walkthrough, "latch",
    play_x, play_y, play_x + ctrl, play_y + ctrl)
  action = action or play_action

  place_cluster(1)
  local stop_action = transport.draw_stop(ctx, state, font, main_slot)
  action = action or stop_action

  place_cluster(2)
  local controls_x, controls_y = reaper.ImGui_GetCursorScreenPos(ctx)
  local controls_right = controls_x + (g.trim_x + g.trim_w)
    - (g.cluster_x + 2 * (ctrl + g.cluster_gap))
  walkthrough_ui.note_rect(ctx, state.walkthrough, "transport",
    controls_x, controls_y, controls_right, controls_y + ctrl)
  if widgets.toggle(ctx, "loop", LOOP, state.loop, "Loop", font, "repeat", nil,
      "loop") then action = { type = "toggle_loop" } end
  -- (The auto-audition ear left the bar 2026-08-07 — it only ever governed the
  -- browser's click-to-hear, so it lives beside the browser's audition strip.)

  -- MONO: fold both channels together and hear the result in both speakers, the
  -- console mono button. Two circles converge into one while the channels fold.
  --
  -- A plain accent-faced toggle like loop. Unlike the latch, it changes only
  -- what you hear right now and does not mute the project.
  place_cluster(3)
  local mono_channels = state.preview.playing and (tonumber(state.preview.channels) or 0)
    or (main_slot.sound and (tonumber(main_slot.sound.channels) or 0) or 0)
  local mono_available = mono_channels <= 2
  local mono_tip = mono_available
    and "Fold left and right together in both speakers to check mono compatibility."
    or "Mono is available for mono and stereo sounds."
  if widgets.toggle(ctx, "mono", "M", state.mono,
      mono_tip, font, nil, mono_available, "mono") then
    action = { type = "toggle_mono" }
  end

  -- PITCH: natural rate-style pitch in semitones. The value stays inside its
  -- compact panel; the bar keeps one stable musical-note square.
  place_cluster(4)
  local pitch_action = transport.draw_pitch(ctx, state, font, "main")
  action = action or pitch_action
  -- The reference picker: the name slot (the bar's one flexible element), the
  -- position count in its reserved width, then the joined step arrows — count
  -- BETWEEN slot and arrows since 2026-08-07 ("name · 1/3" is one fact). This
  -- is what replaced the reference-tab row AND the old armed-reference readout
  -- — one place that says what's armed and changes it (see ui/refpicker.lua).
  --
  -- Always draw, then merge (`action = action or …`, never the other way round):
  -- Lua's `or` short-circuits, so merging the wrong way would skip a draw
  -- entirely for the frame an earlier control reported something.
  reaper.ImGui_SetCursorPos(ctx, row_x0 + g.slot_x, row_y0)
  local slot_action = refpicker.draw_slot(ctx, state, res, g.slot_w)
  action = action or slot_action
  if g.count_w > 0 then
    reaper.ImGui_SetCursorPos(ctx, row_x0 + g.count_x, row_y0)
    refpicker.draw_count(ctx, state, g.count_w)
  end
  reaper.ImGui_SetCursorPos(ctx, row_x0 + g.arrows_x, row_y0)
  local arrow_action = refpicker.draw_arrows(ctx, state, res)
  action = action or arrow_action

  -- The armed sound's tech facts ("48 kHz · 24-bit · WAV · stereo"), following
  -- the picker unit, using normal label contrast for legibility at the small size
  -- (the text is state.selected_tech, formatted by the entry script once per
  -- selection through the same core.techfacts the browser uses).
  --
  -- A BORROWER, never a tenant (2026-08-08 brief, retiring the ~200px held
  -- seat that starved the name box): it draws only into `tech_max`, the room
  -- that is genuinely spare once the box has everything it may take — so its
  -- coming and going moves nothing, and a longer line on the next sound can't
  -- resize the box. All-or-nothing on purpose: a partially-fitting line would
  -- ellipsise and re-cut with every pixel of resize, a flicker in the corner
  -- of the eye for text nobody is reading at that moment.
  if g.tech_x and state.selected_tech then
    local small = theme.push_small_font(ctx)
    local tw, th = reaper.ImGui_CalcTextSize(ctx, state.selected_tech)
    if tw <= g.tech_max then
      -- Placed-then-painted, the draw_count idiom.
      reaper.ImGui_SetCursorPos(ctx, row_x0 + g.tech_x, row_y0)
      reaper.ImGui_Dummy(ctx, tw, ctrl)
      local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
      local _, y1 = reaper.ImGui_GetItemRectMax(ctx)
      reaper.ImGui_DrawList_AddText(reaper.ImGui_GetWindowDrawList(ctx),
        x0, (y0 + y1) * 0.5 - th * 0.5, T.TEXT_SECONDARY, state.selected_tech)
    end
    if small then reaper.ImGui_PopFont(ctx) end
  end

  -- Per-sound trim, pinned to the row's right edge (disabled, but still drawn,
  -- when nothing is selected so the row never changes shape). Trim can boost as
  -- well as cut, unlike the master.
  --
  -- Responsive collapse (tokens.md "Reference View — responsive collapse order"):
  -- the trim gives way AFTER the count and the tech facts —
  -- and it collapses rather than hides (2026-08-07 brief pages 6/12): the
  -- track goes and the dB number itself becomes the control, so the value
  -- stays adjustable and the ◎ beside it keeps the match window reachable at
  -- every one-line width. Driven only by window size (via `geometry` above),
  -- never by selection or latch state — the SAME disabled-but-present control
  -- still draws whenever there's room, whether or not a sound is selected.
  if trim_shown then
    -- The target button (◎) rides with the trim control it drives: same
    -- collapse step, immediately to its left, in both shapes. Clicking it
    -- opens the match window (submitted at the end of this function).
    reaper.ImGui_SetCursorPos(ctx, row_x0 + g.target_x, row_y0 + g.ctrl_y)
    matchwin.draw_button(ctx, state, res)

    reaper.ImGui_SetCursorPos(ctx, row_x0 + g.trim_x, row_y0 + g.ctrl_y)
    local sel = state.selected
    -- Both shapes ride the same set_trim action, the same taper and the same
    -- reset gesture — collapsing changes the control's shape, never its feel
    -- or its wiring (widgets.db_drag matches the fader's dB-per-pixel).
    local trim_opts = { min = match.TRIM_SILENCE, max = match.TRIM_MAX, default = 0,
      taper = true, width = g.trim_w, edit_key = sel and sel.id or false }
    local draw_trim = trim_shown == "fader" and widgets.db_fader or widgets.db_drag
    if sel then
      trim_opts.tip = (trim_shown == "fader"
          and "Adjust the selected reference's remembered trim"
          or "Adjust the selected reference's remembered trim \u{00B7} drag up or down")
        .. RESET_HINT
      if trim_shown == "fader" then
        trim_opts.value_tip = "Click to type trim · right-click to reset"
      end
      -- A real fader's shape since 2026-08-07: silence at the bottom, +24 at
      -- the top, steps growing as it goes down. No cut a match asks for can be
      -- out of its reach any more (core/match.lua owns both numbers).
      local db, commit = draw_trim(ctx, "trim", sel.trim_db, trim_opts)
      if db ~= nil then action = { type = "set_trim", db = db, commit = commit } end
    else
      trim_opts.tip = "Select a reference to adjust its trim."
      reaper.ImGui_BeginDisabled(ctx)
      draw_trim(ctx, "trim", 0, trim_opts)
      reaper.ImGui_EndDisabled(ctx)
    end
  end

  -- The Library button. It moved here from the retired reference row
  -- (2026-08-06) and never collapses: it is the only way to the browser. The
  -- References-folder square that used to sit in this slot became a Settings
  -- row (2026-08-10, `.brief/settings-move`).
  reaper.ImGui_SetCursorPos(ctx, row_x0 + g.library_x, row_y0 + g.ctrl_y)
  -- Walkthrough stop 1's target — and the frozen state's ring, since this is
  -- the button that reopens the Library. Geometry-noted (see the latch).
  local lib_x, lib_y = reaper.ImGui_GetCursorScreenPos(ctx)
  walkthrough_ui.note_rect(ctx, state.walkthrough, "library_button",
    lib_x, lib_y, lib_x + ctrl, lib_y + ctrl)
  if widgets.panel_button(ctx, font, "openlibrary", "library",
      state.browser_open, icons.draw_folder) then
    action = action or { type = "toggle_browser" }
  end
  tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), "Open the Library.")

  -- Settings, the bar's corner (the user's pick over gear-beside-Library —
  -- same brief). Moved here from the browser toolbar so Settings is one click
  -- from the window that's on screen all day. The update notice comes with it:
  -- an ACCENT dot over the gear's corner, nothing else anywhere, persisting
  -- until the update actually installs (state.update.available goes nil then)
  -- — and it's now visible without the browser open, which the old placement
  -- never managed.
  reaper.ImGui_SetCursorPos(ctx, row_x0 + g.gear_x, row_y0 + g.ctrl_y)
  local update_due = state.update and state.update.available ~= nil
  -- Settings changes state on the button's release, so its motion must start
  -- from that same release. Starting it on mouse-down lets the intervening
  -- closed frames cancel the turn before the window opens.
  if widgets.panel_button(ctx, font, "settings", "settings",
      settings.is_open(), icons.draw_gear) then
    if settings.is_open() then
      settings.close()
    else
      settings.open(state)
      -- Refresh update information only when opening the panel.
      action = action or { type = "settings_opened" }
    end
  end
  if update_due then
    local max_x = reaper.ImGui_GetItemRectMax(ctx)
    local _, min_y = reaper.ImGui_GetItemRectMin(ctx)
    local r = M.UPDATE_DOT_R
    reaper.ImGui_DrawList_AddCircleFilled(reaper.ImGui_GetWindowDrawList(ctx),
      max_x - r - 2, min_y + r + 2, r, T.ACCENT)
  end
  tips.show(ctx, reaper.ImGui_IsItemHovered(ctx),
    update_due and "Settings. An update is available" or "Settings")

  -- Every item above was placed absolutely, so leave the cursor where a normal
  -- row would have left it — directly below the bar's full (possibly wrapped)
  -- height, so a caller that adds something after it needn't know about the
  -- wrapping.
  reaper.ImGui_SetCursorPos(ctx, row_x0, row_y0 + g.height)

  -- The popups LAST: submitted in this window's own scope (never inside a
  -- child), and after everything the bar draws, so they can never steal a
  -- click meant for a control beneath them.
  local popup_action = refpicker.draw_popup(ctx, state, res)
  action = action or popup_action
  local match_action = matchwin.draw_popup(ctx, state, res)
  action = action or match_action

  return action
end

return transport
