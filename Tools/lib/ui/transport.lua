-- transport: the shared play, pause, stop, latch and pitch controls plus the
-- master preview volume fader. A ui/ module — draws and reports intent only.
-- The Reference View arranges them in ui/reference_controls.lua and the Library
-- in its audition row; each control here draws one item at the cursor.

local theme = require("ui.theme")
local tips = require("ui.tips")
local widgets = require("ui.widgets")
local icons = require("ui.icons")
local icon_motion = require("ui.icon_motion")
local refpicker = require("ui.refpicker")
local pitchwin = require("ui.pitchwin")
local T = theme.tokens

local transport = {}

-- Text fallbacks for when the Lucide icon font isn't available (see ui/icons.lua);
-- normally the transport draws Lucide glyphs, same set as every other icon.
local PLAY = "\u{25B6}" -- ▶
local PAUSE = "\u{23F8}" -- ⏸
local STOP = "\u{25A0}" -- ■
local LOOP = "\u{21BB}" -- ↻

-- Hoisted so the frame loop never rebuilds it (frame-allocation rule).
local SOFT_ACTIVE_FACE = { color = T.ACCENT_HOVER }

local BAR_OPTS = { min = -60, max = 0, default = 0, label = "Vol",
  tip = "Master preview volume.\n"
    .. "Drag left or right \u{00B7} Alt for fine adjustment \u{00B7} click to type \u{00B7} right-click to reset" }

-- Play, pause, stop and loop as one joined group from x0 to x1: the Reference
-- card's and the Library's, cell for cell. `slot` is the opts table the
-- three playback buttons take (its width is set here); the loop toggle uses
-- `loop_id` and `loop_tip`. Each control is drawn, then merged: `action or
-- draw()` would skip a draw.
function transport.draw_playback_group(ctx, state, font, slot, x0, x1, y, loop_id, loop_tip)
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  widgets.begin_segment(ctx, x0, y, x1, y + ctrl)
  slot.width = widgets.segment_cell(ctx, x0, x1, 4, 0, y)
  local play_action = transport.draw_play(ctx, state, font, slot)
  slot.width = widgets.segment_cell(ctx, x0, x1, 4, 1, y)
  local pause_action = transport.draw_pause(ctx, state, font, slot)
  slot.width = widgets.segment_cell(ctx, x0, x1, 4, 2, y)
  local stop_action = transport.draw_stop(ctx, state, font, slot)
  local w = widgets.segment_cell(ctx, x0, x1, 4, 3, y)
  local loop_action
  -- Both groups carry the same loop setting (state.loop).
  if widgets.toggle(ctx, loop_id, LOOP, state.loop, loop_tip, font, "repeat", nil, "loop", w) then
    loop_action = { type = "toggle_loop" }
  end
  widgets.end_segment(ctx, x0, y, x1, y + ctrl, 4)
  return play_action or pause_action or stop_action or loop_action
end

-- The master preview volume as the framed Vol bar `opts.width` wide, the same
-- kind of level control as the Reference card's trim.
function transport.draw_master(ctx, state, opts)
  BAR_OPTS.width = opts.width
  local db, commit = widgets.db_bar(ctx, opts.id, state.master_db, BAR_OPTS)
  if db ~= nil then return { type = "set_master", db = db, commit = commit } end
  return nil
end

------------------------------------------------------- the transport controls

-- PLAY, PAUSE AND STOP LIVE HERE ONCE AND BOTH WINDOWS DRAW THEM. The Reference
-- View's control cluster and the Library's info row call the same three functions, so the two
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

-- Is this slot's own sound sounding, and does this slot own a parked position?
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
  local paused = (not state.preview.playing or state.preview.slot ~= slot) and parked ~= nil
  return playing, paused
end

-- Play is always a trigger. Repeating it starts the selected sound again from
-- its normal start point; pausing and resuming belong to the neighbouring button.
function transport.draw_play(ctx, state, font, opts)
  local slot = opts.slot
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local playing = playback_state(state, slot, opts.id)
  local use_icon = font and icons.NAMES.play

  local dim = opts.sound == nil
  if dim then reaper.ImGui_BeginDisabled(ctx) end
  local soft_pushed = widgets.push_soft_active(ctx, playing)
  if playing then reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.ACCENT_HOVER) end
  local clicked = reaper.ImGui_Button(ctx,
    (use_icon and "" or PLAY) .. "##play_" .. slot, opts.width or ctrl, ctrl)
  if playing then
    reaper.ImGui_PopStyleColor(ctx)
    widgets.pop_soft_active(ctx, soft_pushed)
  end
  -- Follow confirmed playback, so failed starts and pausing never light a bloom.
  widgets.play_bloom(ctx, slot, playing and not dim, nil, nil,
    state.preview.start_serial)
  -- The painted glyph fades itself against the live style alpha (icons.lua), so
  -- a disabled square dims face and all with no hand-faded colour here.
  if use_icon then
    SOFT_ACTIVE_FACE.color = T.ACCENT_HOVER
    icons.paint_over_item(ctx, font, "play", playing and SOFT_ACTIVE_FACE or nil)
  end
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  if dim then reaper.ImGui_EndDisabled(ctx) end
  tips.show(ctx, hovered,
    tips.with_shortcut(state, slot == "main" and "play" or nil,
      slot == "main" and "Play from the saved start point" or "Play from the start"))

  if clicked then return { type = "trigger_play", target = slot } end
  return nil
end

-- Pause parks the slot's current position. While parked, the same fixed pause
-- icon is accented and resumes that exact sound, even if the selection moved.
function transport.draw_pause(ctx, state, font, opts)
  local slot = opts.slot
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local _, paused = playback_state(state, slot, opts.id)
  local playing = state.preview.playing and state.preview.slot == slot
  local available = playing or paused
  local use_icon = font and icons.NAMES.pause

  if not available then reaper.ImGui_BeginDisabled(ctx) end
  local soft_pushed = widgets.push_soft_active(ctx, paused)
  if paused then reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.ACCENT_HOVER) end
  local clicked = reaper.ImGui_Button(ctx,
    (use_icon and "" or PAUSE) .. "##pause_" .. slot, opts.width or ctrl, ctrl)
  if paused then
    reaper.ImGui_PopStyleColor(ctx)
    widgets.pop_soft_active(ctx, soft_pushed)
  end
  if use_icon then
    SOFT_ACTIVE_FACE.color = T.ACCENT_HOVER
    icons.paint_over_item(ctx, font, "pause", paused and SOFT_ACTIVE_FACE or nil)
  end
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  if not available then reaper.ImGui_EndDisabled(ctx) end
  tips.show(ctx, hovered,
    tips.with_shortcut(state, slot == "main" and "pause" or nil,
      paused and "Resume from the paused position" or "Pause at the current position"))

  if clicked then return { type = "toggle_pause", target = slot } end
  return nil
end

-- What the STOP square acts on: anything this slot has going, whatever sound it
-- happens to be. Deliberately NOT id-matched the way Play is, because the
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
    (use_icon and "" or STOP) .. "##stop_" .. slot, opts.width or ctrl, ctrl)
  if use_icon then icons.paint_over_item(ctx, font, "square") end
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  if dim then reaper.ImGui_EndDisabled(ctx) end
  tips.show(ctx, hovered, "Stop and return to the start")

  if clicked then return { type = "stop_play", target = slot } end
  return nil
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
function transport.draw_latch(ctx, state, font, width)
  local action
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local ref = state.reference
  local latched = ref.latched
  local soft_pushed = widgets.push_soft_active(ctx, latched)
  local clicked = reaper.ImGui_Button(ctx, "##reference", width or ctrl, ctrl)
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
    tips.show(ctx, true, tips.with_shortcut(state, "latch", tip), "reference_latch")
  end
  return action
end

-- The same Pitch button and persistent compact panel are used in both audition surfaces.
-- The icon shows an adjustment; the outline shows that the panel is open.
function transport.draw_pitch(ctx, state, font, slot, width)
  local value = (state.pitch and state.pitch[slot]) or 0
  local sound = (slot == "browse") and state.browse or state.selected
  local id = "pitch_" .. slot
  if not sound then reaper.ImGui_BeginDisabled(ctx) end
  -- A release demonstration's button never shows the live panel as open.
  local open = not state.showcase and pitchwin.is_open(slot)
  local _, hovered = widgets.panel_button(ctx, font, id, "music-2",
    open, "\u{266A}", value ~= 0, sound ~= nil, true, width)
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

  if pressed and sound and not state.showcase then
    pitchwin.toggle_at(slot, x0, y0, y1)
  end
  tips.show(ctx, hovered,
    "Adjust Pitch. Higher values shorten playback; lower values lengthen it.", id)
  return nil
end


return transport
