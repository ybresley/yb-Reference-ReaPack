-- widgets: the shared library of reusable UI controls. Every control that appears
-- more than once — or that carries a standard behaviour (a fader, a toggle, the
-- reset gesture) — is defined HERE, once, so every screen gets exactly the same
-- thing. This is the same discipline theme.lua enforces for colour: never hand-roll
-- a fader or toggle inline in a screen and never invent a one-off interaction; add
-- it here (or extend the one here) and call it. That's what keeps the whole UI
-- behaving consistently instead of drifting per button.
--
-- A ui/ module: it may call reaper.ImGui_* only.

local theme = require("ui.theme")
local icons = require("ui.icons")
local tips = require("ui.tips")
local pitch = require("core.pitch")
local T = theme.tokens
local M = theme.metrics

local widgets = {}

-- Two actions fill a compact popup's bottom row without unused space at either edge.
function widgets.action_pair(ctx, left_label, right_label)
  local width = reaper.ImGui_GetContentRegionAvail(ctx)
  local left_w = math.floor((width - M.ITEM_SPACING_X) * 0.5)
  local left = reaper.ImGui_Button(ctx, left_label, left_w)
  reaper.ImGui_SameLine(ctx)
  local right = reaper.ImGui_Button(ctx, right_label, width - M.ITEM_SPACING_X - left_w)
  return left, right
end

-- Shared search field: the magnifier uses the input's padding, so it never
-- competes with typed text. Callers retain ownership of their query buffer.
function widgets.search_input(ctx, font, id, hint, query, width)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), M.SEARCH_ICON_PAD, M.FRAME_PAD_Y)
  reaper.ImGui_SetNextItemWidth(ctx, width)
  local changed, text = reaper.ImGui_InputTextWithHint(ctx, id, hint, query)
  reaper.ImGui_PopStyleVar(ctx, 2)
  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local _, y1 = reaper.ImGui_GetItemRectMax(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local cx, cy = x0 + M.SEARCH_ICON_PAD * 0.5, (y0 + y1) * 0.5
  local alpha = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha()))
  local icon_colour = text ~= "" and T.ACCENT or T.TEXT_TERTIARY
  local colour = theme.fade(icon_colour, alpha)
  if not icons.paint_glyph(ctx, font, "search", cx, cy, icon_colour, M.ICON_SM_FS) then
    icons.draw_search(dl, cx, cy, colour)
  end
  return changed, text
end

-- Text has already been ellipsised to its row. Highlight only visible literal
-- matches, using the same font that measured this line.
function widgets.draw_search_text(ctx, dl, x, y, colour, text, query)
  if query and query ~= "" then
    local lower, offset = text:lower(), 1
    while true do
      local first, last = lower:find(query, offset, true)
      if not first then break end
      local before = select(1, reaper.ImGui_CalcTextSize(ctx, text:sub(1, first - 1)))
      local width, height = reaper.ImGui_CalcTextSize(ctx, text:sub(first, last))
      reaper.ImGui_DrawList_AddRectFilled(dl, x + before, y, x + before + width, y + height, T.SEARCH_MATCH_BG)
      offset = last + 1
    end
  end
  reaper.ImGui_DrawList_AddText(dl, x, y, colour, text)
end

-- Cut text down to `max_w`, ending in an ellipsis. Lives here because two
-- screens now need it — the reference picker's rows and the browser sidebar's
-- category rows (2026-08-07) — and a second copy of a binary search plus its
-- own cache is exactly what this module exists to prevent.
--
-- Cached because the same name is re-measured every frame it is on screen, and
-- the binary search would otherwise be a dozen CalcTextSize calls a frame for a
-- string that almost never changes. Bounded: the whole cache is dropped once it
-- grows past a project's worth of names.
local ell_cache, ell_n = {}, 0
-- `cut` says WHERE the ellipsis goes:
--   nil / "end"  "Some long name…"        — the default; a name is read front-first
--   "middle"     "C:\Users\…\yb-Reference" — a PATH: keeps the drive AND the leaf,
--                the two ends you actually identify a folder by (Windows' own
--                convention, and what Explorer's address bar does)
--   "front"      "…\REAPER\yb-Reference"   — keeps the tail only
--
-- Paths use "middle" (2026-08-08, user's call after seeing "front" running: a
-- leading ellipsis loses the drive, so two libraries on different drives look
-- identical). Never use either on a NAME, where the front is what you read.
function widgets.ellipsize(ctx, text, max_w, cut)
  if text == "" or max_w <= 0 then return "" end
  -- The FONT SIZE is part of the key: the same name at the same width cuts at a
  -- different character in a 13px row than an 11px one, and callers push the
  -- small font around some of these. (It also keeps the cache honest if the UI
  -- scale is ever changed while running.) `cut` is part of it too — the same
  -- string at the same width has a different answer per mode.
  local key = text .. "\0" .. math.floor(max_w) .. "\0" .. reaper.ImGui_GetFontSize(ctx)
    .. "\0" .. (cut or "end")
  local hit = ell_cache[key]
  if hit then return hit end

  local out = text
  if select(1, reaper.ImGui_CalcTextSize(ctx, text)) > max_w then
    -- Character positions, so a multi-byte name is never cut mid-character.
    -- A name that isn't valid UTF-8 falls back to byte positions: a clipped
    -- name beats an error.
    local len = utf8.len(text)
    local function prefix(n)
      if n <= 0 then return "" end
      if not len then return text:sub(1, n) end
      local at = utf8.offset(text, n + 1)
      return text:sub(1, (at or (#text + 1)) - 1)
    end
    local function suffix(n)
      if n <= 0 then return "" end
      if not len then return text:sub(-n) end
      local at = utf8.offset(text, -n)
      return at and text:sub(at) or text
    end
    -- Every mode binary-searches the same thing: the most characters that still
    -- fit once the ellipsis is in. Widening `n` only ever widens the result, in
    -- all three modes, which is what makes the search valid.
    local function build(n)
      if cut == "front" then return "\u{2026}" .. suffix(n) end
      if cut == "middle" then
        local head = math.ceil(n / 2) -- the odd character goes to the front
        return prefix(head) .. "\u{2026}" .. suffix(n - head)
      end
      return prefix(n) .. "\u{2026}"
    end
    local lo, hi = 0, len or #text
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      if select(1, reaper.ImGui_CalcTextSize(ctx, build(mid))) <= max_w then
        lo = mid
      else
        hi = mid - 1
      end
    end
    out = build(lo)
  end

  -- Sized for everything ON SCREEN at once, with room to scroll: the sound table
  -- asks for one entry per visible row (2026-08-12), so a bound of a few dozen
  -- would empty itself every frame and the search would stop being cached at all.
  if ell_n > 512 then ell_cache, ell_n = {}, 0 end
  ell_cache[key] = out
  ell_n = ell_n + 1
  return out
end

-- Pitch keeps double-click available for exact text entry, but still shares the
-- standard control's no-jump right-click path. Call after submitting the item.
function widgets.wants_right_reset(ctx)
  return reaper.ImGui_IsItemHovered(ctx)
    and reaper.ImGui_IsMouseClicked(ctx, 1)
end

function widgets.wants_pitch_reset(ctx)
  return widgets.wants_right_reset(ctx)
    or (reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseClicked(ctx, 0)
      and (reaper.ImGui_GetKeyMods(ctx) & reaper.ImGui_Mod_Ctrl()) ~= 0)
end

-- The standard reset gesture for adjustable controls is right-click or
-- double-click. Pitch is the deliberate exception above.
function widgets.wants_reset(ctx)
  return widgets.wants_right_reset(ctx)
    or (reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0))
end

-- A BARE glyph button: no frame and no fill until the cursor is on it. Born as
-- the reference picker's edit-mode control (2026-08-06, user's call — three
-- framed squares per row put nine boxes on screen at once) and shared here the
-- day the match window needed the same thing. `hot_color` (optional) recolours
-- the GLYPH while hovered — the unpin/remove crosses use it to go DANGER_RED,
-- so a control that takes something away says so before it is clicked. The
-- no-icon-font fallback keeps the theme's text colour, since its label is
-- drawn by the Button itself.
function widgets.glyph_button(ctx, font, id, glyph, fallback, w, h, tip, hot_color)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0)
  local has_icon = font and icons.NAMES[glyph]
  local clicked = reaper.ImGui_Button(ctx, (has_icon and "" or fallback) .. "##" .. id, w, h)
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_PopStyleVar(ctx, 1)
  local hot = reaper.ImGui_IsItemHovered(ctx)
  if has_icon then
    icons.paint_over_item(ctx, font, glyph, (hot and hot_color) and { color = hot_color } or nil)
  end
  -- Tooltip LAST (house rule: SetTooltip replaces ImGui's "last item", so
  -- anything reading the button must run before it).
  tips.show(ctx, tip and reaper.ImGui_IsItemHovered(ctx), tip)
  return clicked
end

-- DrawList colours ignore the style Alpha (which BeginDisabled lowers), so custom
-- drawing must fade itself or a disabled fader would render at full strength.
-- Shared with icons.lua (theme.fade) so every hand-painted glyph agrees.
local fade = theme.fade

-- ---- the tapered (real-fader) shape, opts.taper ------------------------------
--
-- A linear dB fader has to choose between reach and precision: 70 pixels of
-- track either cover a useful range coarsely or a fine range that a match can
-- fall outside. A taper refuses the choice, the way every mixing fader does —
-- the bottom of the travel IS silence, and the steps grow the further down you
-- push, so the fine control stays where the work happens (user's call,
-- 2026-08-07: "as you approach -inf, the increment becomes bigger and bigger").
--
-- Below unity the AMPLITUDE follows a cube law, which is what makes the
-- decibels stretch out at the bottom: half the cut travel is about -18 dB, a
-- quarter of it about -36. Above unity it is plain linear dB — a boost range is
-- short enough not to need shaping.
-- 0 dB sits at the MIDDLE of the track (2026-08-07, second look: at 0.75 the
-- knob rested a few pixels from the right end and the +24 above it was squeezed
-- into 17px, which read as no room at all). Half the track is the same 35px the
-- old linear ±24 fader gave the boost, so boosting feels exactly as it always
-- did; everything the taper buys goes to the cut side, which now reaches
-- silence in the other half. Moving unity right only trades that back: at 0.75
-- the boost ran at 1.37 dB/px against the old fader's 0.69.
local UNITY_T = 0.5           -- where 0 dB sits along the track
local CUT_PER_DECADE = 60     -- 20 dB x the cube law

local function taper_db(t, max_db, silence)
  if t <= 0 then return silence end
  if t >= UNITY_T then return max_db * (t - UNITY_T) / (1 - UNITY_T) end
  local db = CUT_PER_DECADE * math.log(t / UNITY_T, 10)
  return db < silence and silence or db
end

local function taper_t(db, max_db, silence)
  if db <= silence then return 0 end
  if db >= 0 then return UNITY_T + (db / max_db) * (1 - UNITY_T) end
  return UNITY_T * 10 ^ (db / CUT_PER_DECADE)
end

-- Fader ids whose current mouse-hold must NOT drag: a reset fired mid-hold (double
-- click, or right-click during a drag), and without this the very next frame's drag
-- would yank the value straight back to the mouse position, undoing the reset.
-- Cleared when that hold ends. Bounded: one entry per fader id, only while held.
local reset_hold = {}

-- Discrete horizontal slider with visible stop marks. The pointer movement is
-- anchored to the track that existed when the drag began, so a value that
-- resizes the UI cannot change its own mouse-to-value mapping on the next frame.
-- This is the Appearance pane's size control, but the gesture is reusable for
-- any stepped numeric setting. Reports live values with commit=false, then the
-- final value with commit=true on release so callers can preview continuously
-- and persist once. opts = { min, max, step, width, tick_step, pitch }.
-- Pitch adds a centre-origin fill, fine dragging and its own reset gestures.
local step_slider_drag = {}

local function step_slider_value(min, max, step, t)
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  local raw = min + t * (max - min)
  local snapped = min + math.floor((raw - min) / step + 0.5) * step
  if snapped < min then return min end
  if snapped > max then return max end
  return snapped
end

function widgets.step_slider(ctx, id, value, opts)
  opts = opts or {}
  local min, max, step = opts.min or 0, opts.max or 100, opts.step or 1
  local w, h = opts.width or M.SLIDER_W, reaper.ImGui_GetFrameHeight(ctx)
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)

  reaper.ImGui_InvisibleButton(ctx, "##" .. id, w, h)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local active = reaper.ImGui_IsItemActive(ctx)
  local activated = reaper.ImGui_IsItemActivated(ctx)
  local deactivated = reaper.ImGui_IsItemDeactivated(ctx)

  -- Keep the thumb inside the control while letting the full frame remain the
  -- hit target. The captured width is the gesture's stable scale even while the
  -- live UI size changes this frame's drawn width.
  local half_knob = M.FADER_KNOB_W * 0.5
  local track_x0, track_x1 = x0 + half_knob, x0 + w - half_knob
  local track_w = math.max(1, track_x1 - track_x0)
  local mx = select(1, reaper.ImGui_GetMousePos(ctx))
  local result, commit

  if opts.pitch and widgets.wants_pitch_reset(ctx) then
    step_slider_drag[id] = nil
    if active then reset_hold[id] = true end
    result, commit = 0, true
  elseif activated and not reset_hold[id] then
    local t = (mx - track_x0) / track_w
    local fine = opts.pitch and (reaper.ImGui_GetKeyMods(ctx) & reaper.ImGui_Mod_Alt()) ~= 0
    local clicked = fine and value or step_slider_value(min, max, step, t)
    step_slider_drag[id] = {
      t = (clicked - min) / (max - min),
      mx = mx,
      width = track_w,
    }
    if clicked ~= value then result, commit = clicked, false end
  elseif active and not reset_hold[id] and step_slider_drag[id] then
    local drag = step_slider_drag[id]
    local fine = opts.pitch and (reaper.ImGui_GetKeyMods(ctx) & reaper.ImGui_Mod_Alt()) ~= 0
    local t = drag.t + (mx - drag.mx) / drag.width / (fine and 5 or 1)
    local dragged = step_slider_value(min, max, fine and 0.1 or step, t)
    if opts.pitch then drag.t, drag.mx = math.max(0, math.min(1, t)), mx end
    if dragged ~= value then result, commit = dragged, false end
  elseif deactivated then
    local drag = step_slider_drag[id]
    step_slider_drag[id] = nil
    if reset_hold[id] then
      reset_hold[id] = nil
    elseif drag and opts.pitch then
      result, commit = value, true
    elseif drag then
      local t = drag.t + (mx - drag.mx) / drag.width
      result, commit = step_slider_value(min, max, step, t), true
    end
  end

  local shown = result or value
  local shown_t = (shown - min) / (max - min)
  if shown_t < 0 then shown_t = 0 elseif shown_t > 1 then shown_t = 1 end
  local knob_x = track_x0 + shown_t * track_w
  local cy = y0 + h * 0.5
  local half_track = M.FADER_TRACK_H * 0.5
  local alpha = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha()))
  local dl = reaper.ImGui_GetWindowDrawList(ctx)

  reaper.ImGui_DrawList_AddRectFilled(dl, track_x0, cy - half_track,
    track_x1, cy + half_track, fade(T.FADER_TRACK, alpha), half_track)
  local fill_x = opts.pitch and (track_x0 + track_w * 0.5) or track_x0
  if knob_x ~= fill_x then
    reaper.ImGui_DrawList_AddRectFilled(dl, math.min(fill_x, knob_x), cy - half_track,
      math.max(fill_x, knob_x), cy + half_track,
      fade((hovered or active) and T.ACCENT_HOVER or T.FADER_FILL, alpha), half_track)
  end

  -- Paint marks after the fill so they stay visible across the whole range.
  local stops = math.floor((max - min) / (opts.tick_step or step) + 0.5)
  for i = 0, stops do
    local tx = math.floor(track_x0 + (i / stops) * track_w + 0.5)
    reaper.ImGui_DrawList_AddLine(dl, tx, cy + half_track,
      tx, cy + half_track + M.FADER_TRACK_H, fade(T.FADER_TICK, alpha), 1)
  end

  local half_kw, half_kh = M.FADER_KNOB_W * 0.5, M.FADER_KNOB_H * 0.5
  reaper.ImGui_DrawList_AddRectFilled(dl, knob_x - half_kw, cy - half_kh,
    knob_x + half_kw, cy + half_kh, fade(T.FADER_KNOB, alpha), half_kw)

  if result ~= nil then return result, commit end
  return nil
end

function widgets.cancel_step_slider(id)
  step_slider_drag[id], reset_hold[id] = nil, nil
end

-- A dB fader, custom-drawn: slim track, accent fill, slim pill knob, and the value
-- as a fixed readout to the RIGHT of the track — never under the knob, so it stays
-- readable mid-drag, and the knob (taller than the track) stays visible parked at
-- the extremes. Total width is M.SLIDER_W and never resizes with state.
-- A range that crosses 0 (trim) fills from the 0 dB detent outward; a cut-only
-- range (master) fills from the left like a level.
-- Reports the live value every drag frame with a `commit` flag set only on release,
-- so callers persist once instead of every frame; resets to `opts.default` on the
-- standard reset gesture. opts = { min, max, default, tip, taper }.
-- `taper` gives the control a real fader's shape (see above), where `min` is
-- the silence the bottom of the track means rather than a number to land on.
-- Returns (value, commit) when something changed this frame, else nil.
function widgets.db_fader(ctx, id, value, opts)
  opts = opts or {}
  local min, max = opts.min or -24, opts.max or 24
  local taper = opts.taper == true
  -- One conversion each way, used by the drag, the knob and the 0 dB detent, so
  -- the value under the cursor and the value drawn can never disagree.
  local to_db = function(t) return taper and taper_db(t, max, min) or (min + t * (max - min)) end
  local to_t = function(db) return taper and taper_t(db, max, min) or ((db - min) / (max - min)) end
  local h = reaper.ImGui_GetFrameHeight(ctx)
  -- `opts.width` lets a narrow host (the side column) say how much room the whole
  -- control has; `opts.stacked` moves the readout BENEATH the track instead of
  -- beside it, which is the only way to have no reserved zone at all — and so no
  -- gap — when the column is barely wider than the number itself.
  local total_w = opts.width or M.SLIDER_W
  local stacked = opts.stacked == true
  local track_w = stacked and total_w or (total_w - M.FADER_VAL_W - M.FADER_VAL_GAP)
  if track_w < 8 then track_w = 8 end
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)

  -- Only the track is interactive; the readout is plain text beside it, so a click
  -- on the number can't jump the value to the far end of the range.
  reaper.ImGui_BeginGroup(ctx)
  reaper.ImGui_InvisibleButton(ctx, "##" .. id, track_w, h)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local active = reaper.ImGui_IsItemActive(ctx)
  tips.show(ctx, opts.tip and hovered, opts.tip)

  -- Resolve this frame's result. Reset wins over the drag value on the same frame,
  -- and always persists.
  local result, commit
  if widgets.wants_reset(ctx) then
    if active then reset_hold[id] = true end
    result, commit = (opts.default or 0), true
  elseif active and not reset_hold[id] then
    local mx = select(1, reaper.ImGui_GetMousePos(ctx))
    local t = (mx - x0) / track_w
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    -- Snap to 0.1 dB so the value IS what the readout shows.
    local v = math.floor(to_db(t) * 10 + 0.5) / 10
    if v ~= (value or 0) then result, commit = v, false end
  elseif reaper.ImGui_IsItemDeactivated(ctx) then
    if reset_hold[id] then
      reset_hold[id] = nil -- the reset already committed; this hold stays inert
    else
      -- The caller applied each dragged value back into `value`, so on the release
      -- frame it already holds the final position — persist it once.
      result, commit = (value or 0), true
    end
  end
  local shown = result or value or 0

  -- Geometry: everything vertically centred in the frame-height hit box. In the
  -- stacked form the track sits in the upper part to leave room for the number
  -- underneath, and the whole control still occupies exactly one frame height.
  local alpha = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha()))
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local cy = stacked and (y0 + h * 0.30) or (y0 + h * 0.5)
  local half_t = M.FADER_TRACK_H * 0.5
  local t_shown = to_t(shown)
  if t_shown < 0 then t_shown = 0 elseif t_shown > 1 then t_shown = 1 end
  local kx = x0 + t_shown * track_w

  -- Track (pill: rounding = half its thickness).
  reaper.ImGui_DrawList_AddRectFilled(dl, x0, cy - half_t, x0 + track_w, cy + half_t,
    fade(T.FADER_TRACK, alpha), half_t)
  -- Fill: from the 0 dB point when the range crosses 0, else from the left edge.
  -- Tapered, 0 dB is three-quarters up rather than mid-track, so the detent and
  -- the fill's origin both come from the same conversion the knob uses.
  local zero_x = x0
  if min < 0 and max > 0 then zero_x = x0 + to_t(0) * track_w end
  local fx0, fx1 = math.min(zero_x, kx), math.max(zero_x, kx)
  if fx1 - fx0 >= 1 then
    reaper.ImGui_DrawList_AddRectFilled(dl, fx0, cy - half_t, fx1, cy + half_t,
      fade((hovered or active) and T.ACCENT_HOVER or T.FADER_FILL, alpha), half_t)
  end
  -- 0 dB detent mark (bipolar ranges only), on top of the fill so it never vanishes.
  if min < 0 and max > 0 then
    local half_tick = M.FADER_TICK_H * 0.5
    reaper.ImGui_DrawList_AddRectFilled(dl, zero_x - 1, cy - half_tick, zero_x + 1,
      cy + half_tick, fade(T.FADER_TICK, alpha))
  end
  -- Knob: a slim pill taller than the track, so it reads clearly parked at an end
  -- without the bulk of a circle.
  local half_kw, half_kh = M.FADER_KNOB_W * 0.5, M.FADER_KNOB_H * 0.5
  reaper.ImGui_DrawList_AddRectFilled(dl, kx - half_kw, cy - half_kh, kx + half_kw,
    cy + half_kh, fade(T.FADER_KNOB, alpha), half_kw)

  -- Readout. Exactly 0 shows as a plain "0.0" — never a signed "+0.0"/"-0.0".
  -- The unit is dimmer than the number so the value stays the thing you read.
  --
  -- Drawn rather than laid out, for two reasons. It fixes a real misalignment:
  -- laid-out text is positioned by FramePadding, which sat it ~1.5px below the
  -- track's centre line (reported 2026-07-30, and visible once you look). And it
  -- lets the number ANCHOR TO THE TRACK instead of being right-aligned inside its
  -- reserved zone — the reservation still exists so the digits can't jitter while
  -- dragging, but its unused part now trails off the outer edge as margin rather
  -- than sitting between track and number as a hole.
  -- At the bottom of a tapered track the value is silence, and "-120.0" would
  -- name a number nobody set — the fader was dragged to the end, not to −120.
  local text = shown == 0 and "0.0"
    or (taper and shown <= min and "-inf")
    or string.format("%+.1f", shown)
  local unit = " dB"
  local tw, th = reaper.ImGui_CalcTextSize(ctx, text)
  local uw = select(1, reaper.ImGui_CalcTextSize(ctx, unit))
  local num_col = fade((hovered or active) and T.TEXT_PRIMARY or T.TEXT_SECONDARY, alpha)
  local tx, ty
  if stacked then
    tx = x0 + (total_w - tw - uw) * 0.5 -- centred under the track
    ty = y0 + h - th - 1
  else
    tx = x0 + track_w + M.FADER_VAL_GAP -- anchored to the track, growing outward
    ty = y0 + (h - th) * 0.5            -- true vertical centre, not frame padding
  end
  reaper.ImGui_DrawList_AddText(dl, tx, ty, num_col, text)
  reaper.ImGui_DrawList_AddText(dl, tx + tw, ty, fade(T.TEXT_TERTIARY, alpha), unit)

  -- The readout is drawn, not laid out, so the control still has to claim the
  -- full width it was promised or a caller placing something beside it would
  -- overlap the number.
  if not stacked and total_w > track_w then
    reaper.ImGui_SameLine(ctx, 0, 0)
    reaper.ImGui_Dummy(ctx, total_w - track_w, h)
  end
  reaper.ImGui_EndGroup(ctx)

  if result ~= nil then return result, commit end
  return nil
end

-- The collapsed trim's cursor: a vertical-drag affordance, resolved once at
-- load (the house feature-detection idiom) — nil on an older ReaImGui, where
-- the tooltip carries the affordance alone.
local DRAG_NS_CURSOR = (reaper.ImGui_MouseCursor_ResizeNS and reaper.ImGui_MouseCursor_ResizeNS())
  or nil
-- Pitch accepts either drag direction, so an axis-specific resize cursor would
-- promise the wrong gesture half the time. The hand says "adjustable" without
-- choosing an axis; the tooltip carries the exact behaviour.
local DRAG_FREE_CURSOR = (reaper.ImGui_MouseCursor_Hand and reaper.ImGui_MouseCursor_Hand())
  or nil

-- Where each in-flight vertical drag started: id -> { t, my }. One entry per
-- control, only while its mouse button is held (cleared on release), so this
-- can't grow (frame-allocation rule).
local drag_anchor = {}

-- A dB value as a bare draggable NUMBER — the trim fader's collapsed form
-- (horizontal-layout brief page 12, 2026-08-07): when the bar runs out of
-- width the track goes and the number becomes the control. Drag up = louder,
-- down = quieter; the shared wants_reset gesture resets, exactly like the
-- fader it stands in for.
--
-- The drag runs through the SAME taper as the trim fader's track, over the
-- same virtual track length, so a pixel of vertical drag here moves the value
-- exactly as far as a pixel of horizontal drag on the full fader — collapsing
-- must change the control's shape, never its feel. Anchored at the value the
-- drag STARTED on (a vertical drag has no track under it to read positions
-- from), so there is no jump on grab.
--
-- opts = { min, max, default, tip, width, taper } — the fader's vocabulary.
-- Returns (value, commit) when something changed this frame, else nil.
function widgets.db_drag(ctx, id, value, opts)
  opts = opts or {}
  local min, max = opts.min or -24, opts.max or 24
  local taper = opts.taper == true
  local to_db = function(t) return taper and taper_db(t, max, min) or (min + t * (max - min)) end
  local to_t = function(db) return taper and taper_t(db, max, min) or ((db - min) / (max - min)) end
  local h = reaper.ImGui_GetFrameHeight(ctx)
  local pad_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding()))
  local w = opts.width or (select(1, reaper.ImGui_CalcTextSize(ctx, "+24.0 dB")) + pad_x * 2)
  -- The full fader's track length, so the dB-per-pixel feel matches it.
  local track = M.SLIDER_W - M.FADER_VAL_W - M.FADER_VAL_GAP
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)

  reaper.ImGui_InvisibleButton(ctx, "##" .. id, w, h)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local active = reaper.ImGui_IsItemActive(ctx)
  if (hovered or active) and DRAG_NS_CURSOR then reaper.ImGui_SetMouseCursor(ctx, DRAG_NS_CURSOR) end
  tips.show(ctx, opts.tip and hovered, opts.tip)

  -- Same resolution order as db_fader: a reset wins over the drag on its frame,
  -- and a reset fired mid-hold parks the rest of that hold (reset_hold) so the
  -- next frame's drag can't yank the value straight back.
  local result, commit
  if widgets.wants_reset(ctx) then
    if active then reset_hold[id] = true end
    drag_anchor[id] = nil
    result, commit = (opts.default or 0), true
  elseif reaper.ImGui_IsItemActivated(ctx) then
    drag_anchor[id] = { t = to_t(value or 0), my = select(2, reaper.ImGui_GetMousePos(ctx)) }
  elseif active and not reset_hold[id] and drag_anchor[id] then
    local a = drag_anchor[id]
    local t = a.t + (a.my - select(2, reaper.ImGui_GetMousePos(ctx))) / track
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    -- Snap to 0.1 dB so the value IS what the readout shows.
    local v = math.floor(to_db(t) * 10 + 0.5) / 10
    if v ~= (value or 0) then result, commit = v, false end
  elseif reaper.ImGui_IsItemDeactivated(ctx) then
    drag_anchor[id] = nil
    if reset_hold[id] then
      reset_hold[id] = nil -- the reset already committed; this hold stays inert
    else
      result, commit = (value or 0), true
    end
  end
  local shown = result or value or 0

  -- Drawn like the fader's readout, right-aligned inside the reserved width so
  -- the digits' right edge (and the " dB" beside it) never wanders as the
  -- number changes sign or grows a digit.
  local alpha = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha()))
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local text = shown == 0 and "0.0"
    or (taper and shown <= min and "-inf")
    or string.format("%+.1f", shown)
  local unit = " dB"
  local tw, th = reaper.ImGui_CalcTextSize(ctx, text)
  local uw = select(1, reaper.ImGui_CalcTextSize(ctx, unit))
  local tx = x0 + w - pad_x - uw - tw
  local ty = y0 + (h - th) * 0.5
  reaper.ImGui_DrawList_AddText(dl, tx, ty,
    fade((hovered or active) and T.TEXT_PRIMARY or T.TEXT_SECONDARY, alpha), text)
  reaper.ImGui_DrawList_AddText(dl, tx + tw, ty, fade(T.TEXT_TERTIARY, alpha), unit)

  if result ~= nil then return result, commit end
  return nil
end

-- A semitone value that accepts horizontal or vertical dragging. The first
-- intentional movement locks one axis for the rest of that hold, so a diagonal
-- gesture never changes Pitch faster by accidentally counting both directions.
-- Right/up raise Pitch; left/down lower it. Normal movement snaps to whole
-- semitones; Alt slows the movement and exposes tenths. A click without a drag
-- asks the caller to replace the readout with an exact-entry field immediately.
-- Pitch deliberately resets only on right-click, leaving a double-click free to
-- behave like an ordinary text-field interaction once exact entry is active.
local pitch_drag = {}
local HAS_ALT = reaper.ImGui_GetKeyMods ~= nil and reaper.ImGui_Mod_Alt ~= nil
local AXIS_LOCK_PX = 2

-- Returns (value, commit, edit_requested). Live drag frames use commit=false;
-- release and reset use commit=true. Pitch is temporary, but the distinction
-- keeps the control's contract consistent with every other adjustable widget.
function widgets.semitone_drag(ctx, id, value, opts)
  opts = opts or {}
  value = pitch.clamp(value)
  local h = reaper.ImGui_GetFrameHeight(ctx)
  local pad_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding()))
  local w = opts.width or (select(1, reaper.ImGui_CalcTextSize(ctx, "+24.0 st")) + pad_x * 2)
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_InvisibleButton(ctx, "##" .. id, w, h)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local active = reaper.ImGui_IsItemActive(ctx)
  local edit_requested = false
  if (hovered or active) and DRAG_FREE_CURSOR then
    reaper.ImGui_SetMouseCursor(ctx, DRAG_FREE_CURSOR)
  end

  local result, commit
  if widgets.wants_pitch_reset(ctx) then
    pitch_drag[id] = nil
    if active then reset_hold[id] = true end
    result, commit = pitch.clamp(opts.default or 0), true
  elseif reaper.ImGui_IsItemActivated(ctx) then
    local mx, my = reaper.ImGui_GetMousePos(ctx)
    pitch_drag[id] = {
      raw = value,
      first_mx = mx, first_my = my,
      last_mx = mx, last_my = my,
      axis = nil,
      moved = false,
    }
  elseif active and not reset_hold[id] and pitch_drag[id] then
    local a = pitch_drag[id]
    local mx, my = reaper.ImGui_GetMousePos(ctx)
    if not a.axis then
      local dx, dy = mx - a.first_mx, my - a.first_my
      if math.max(math.abs(dx), math.abs(dy)) >= AXIS_LOCK_PX then
        a.axis = math.abs(dx) >= math.abs(dy) and "x" or "y"
        a.moved = true
      end
    end
    if a.axis then
      local pixels = a.axis == "x" and (mx - a.last_mx) or (a.last_my - my)
      local fine = HAS_ALT and (reaper.ImGui_GetKeyMods(ctx) & reaper.ImGui_Mod_Alt()) ~= 0
      a.raw = pitch.clamp(a.raw + pixels / (fine and 40 or 8))
      a.last_mx, a.last_my = mx, my
      local v = fine and (math.floor(a.raw * 10 + 0.5) / 10)
        or math.floor(a.raw + 0.5)
      v = pitch.clamp(v)
      if v ~= value then result, commit = v, false end
    end
  elseif reaper.ImGui_IsItemDeactivated(ctx) then
    local a = pitch_drag[id]
    pitch_drag[id] = nil
    if reset_hold[id] then
      reset_hold[id] = nil
    elseif a and a.moved then
      result, commit = value, true
    else
      edit_requested = true
    end
  end

  local shown = result ~= nil and result or value
  local alpha = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha()))
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local text = pitch.format(shown, opts.unit)
  local tw, th = reaper.ImGui_CalcTextSize(ctx, text)
  local rounding = select(1,
    reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding()))
  local fill = active and T.FILL_PRIMARY or (hovered and T.FILL_SECONDARY or T.FILL_TERTIARY)
  reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + h,
    fade(fill, alpha), rounding)
  reaper.ImGui_DrawList_AddRect(dl, x0, y0, x0 + w, y0 + h,
    fade((hovered or active) and T.STROKE_PRIMARY or T.STROKE_SECONDARY, alpha),
    rounding, 0, 1)
  reaper.ImGui_DrawList_AddText(dl, x0 + (w - tw) * 0.5, y0 + (h - th) * 0.5,
    fade(T.ACCENT, alpha), text)

  -- Tooltip last: SetTooltip replaces ImGui's last item, while every gesture
  -- above must keep reading the semitone field itself.
  tips.show(ctx, opts.tip and hovered, opts.tip)
  return result, commit, edit_requested or nil
end

-- Forget a drag or reset hold when its panel closes.
function widgets.cancel_semitone_drag(id)
  pitch_drag[id], reset_hold[id] = nil, nil
end

-- Equal-width segments keep the Pitch header fixed when the unit changes.
function widgets.pitch_units(ctx, id, unit)
  local result
  for i = 1, 2 do
    local key, label = i == 1 and "st" or "percent", i == 1 and "st" or "%"
    if i == 2 then reaper.ImGui_SameLine(ctx, 0, 0) end
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
      unit == key and T.FILL_SECONDARY or T.FILL_QUATERNARY)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
      unit == key and T.ACCENT or T.TEXT_SECONDARY)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 0)
    if reaper.ImGui_Button(ctx, label .. "##" .. id .. key, M.PITCH_UNIT_W) then result = key end
    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_PopStyleColor(ctx, 2)
  end
  return result
end

-- Hoisted so the frame loop never rebuilds it (frame-allocation rule).
local ACCENT_FACE = { color = T.ACCENT }
local HOVER_DISABLED = reaper.ImGui_HoveredFlags_AllowWhenDisabled
  and reaper.ImGui_HoveredFlags_AllowWhenDisabled() or 0

-- A square toggle, the same square as every icon button — never a size change
-- (UI-stability rule). ON is signalled by the FACE turning accent (accent = active
-- throughout the UI: playing fill, selection edge, active sort), NOT by a
-- background fill: the old ON fill shared its token with the hover fill, so an
-- active toggle and a hovered one were literally the same colour. The background
-- keeps its one meaning — hover/press feedback — in every state.
-- With `font` (the Lucide font) and `icon` (an icons.NAMES key) the face is that
-- glyph; `label` stays as the fallback face when the icon font isn't available.
-- The stable `id` also owns the tooltip delay, so a state-dependent explanation
-- can change under the pointer without looking like a different control.
function widgets.toggle(ctx, id, label, on, tip, font, icon, enabled)
  local size = reaper.ImGui_GetFrameHeight(ctx)
  local use_icon = font and icon and icons.NAMES[icon]
  local disabled = enabled == false
  if disabled then reaper.ImGui_BeginDisabled(ctx) end
  if on and not use_icon then reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.ACCENT) end
  local clicked = reaper.ImGui_Button(ctx, (use_icon and "" or label) .. "##" .. id, size, size)
  if on and not use_icon then reaper.ImGui_PopStyleColor(ctx) end
  if use_icon then
    -- Paint the state this click PRODUCES, not the state that was passed in: the
    -- entry script flips the real value next frame, and both callers flip
    -- unconditionally, so the face may safely answer the press instantly instead
    -- of one frame late.
    local shown = on
    if clicked then shown = not shown end
    -- The Appearance setting can change ACCENT while the tool is running. Keep
    -- this hoisted face table, but refresh its one value before it is painted.
    ACCENT_FACE.color = T.ACCENT
    icons.paint_over_item(ctx, font, icon, shown and ACCENT_FACE or nil)
  end
  if disabled then reaper.ImGui_EndDisabled(ctx) end
  local hovered = disabled and HOVER_DISABLED ~= 0
    and reaper.ImGui_IsItemHovered(ctx, HOVER_DISABLED)
    or reaper.ImGui_IsItemHovered(ctx)
  tips.show(ctx, tip and hovered, tip, id)
  return not disabled and clicked
end

-- A Settings switch: one compact pill centred inside a full control-height hit
-- target. The active state uses the same accent meaning as every other toggle;
-- the knob moves inside the reserved pill, so neighbouring controls never shift.
function widgets.switch(ctx, id, on, tip)
  local w, h, knob = M.SET_SWITCH_W, M.SET_SWITCH_H, M.SET_SWITCH_KNOB
  local frame_h = reaper.ImGui_GetFrameHeight(ctx)
  local clicked = reaper.ImGui_InvisibleButton(ctx, "##" .. id, w, frame_h)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local x0, item_y0 = reaper.ImGui_GetItemRectMin(ctx)
  local x1, item_y1 = reaper.ImGui_GetItemRectMax(ctx)
  local y0 = math.floor((item_y0 + item_y1 - h) * 0.5 + 0.5)
  local y1 = y0 + h
  local pad = (h - knob) * 0.5
  local shown = on
  if clicked then shown = not shown end
  local knob_x = shown and (x1 - pad - knob) or (x0 + pad)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local fill = shown and (hovered and T.ACCENT_HOVER or T.ACCENT)
    or (hovered and T.FILL_PRIMARY or T.FILL_SECONDARY)

  reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x1, y1, fill, h * 0.5)
  reaper.ImGui_DrawList_AddCircleFilled(dl, knob_x + knob * 0.5,
    y0 + h * 0.5, knob * 0.5, shown and T.TEXT_ON_ACCENT or T.TEXT_SECONDARY)
  tips.show(ctx, tip and hovered, tip)
  return clicked
end

-- The slim scrollbar (brief `table-scrollbar`, 2026-08-09): a thumb-only pill
-- in a strip the CALLER has reserved — the empty strip is the track. It
-- replaces ImGui's own bar wherever it's used (the browser's sound table and
-- its sidebar): that bar carves its width out of the content — which is what
-- made the table's columns jump whenever it appeared — and runs the full
-- window height, frozen headers included.
--
-- The table rail splits input from paint. Input is submitted before the table,
-- using its previous scroll values, and returns the requested position. Paint
-- happens after the table reports the current view's values. Applying a scroll
-- request stays with the caller because only it owns the scrolled window.
-- The sidebar uses overlay_scrollbar instead: its rail sits over category rows,
-- so interaction and paint both happen inside that child after the rows.
--
-- The layout cursor is saved and restored around the hit item, so the widget
-- can be dropped anywhere in a window's draw order without displacing what
-- comes after it.
local grab_off = {}
local function scrollbar_thumb_geometry(y, h, scroll_y, scroll_max)
  if not (scroll_max > 0 and h > 0) then return nil end
  -- Thumb length mirrors how much of the list is on screen (the native ratio),
  -- floored so a huge library still leaves something to grab.
  local thumb_h = h * (h / (h + scroll_max))
  if thumb_h < M.SCROLL_THUMB_MIN_H then thumb_h = M.SCROLL_THUMB_MIN_H end
  if thumb_h > h then thumb_h = h end
  local travel = h - thumb_h
  local t = scroll_y / scroll_max
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  return y + travel * t, thumb_h, travel
end

local function paint_scrollbar_thumb(ctx, x, w, thumb_y, thumb_h, hot, align_right)
  local alpha = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha()))
  local tx = align_right and (x + w - M.SCROLL_THUMB_W)
    or (x + (w - M.SCROLL_THUMB_W) * 0.5)
  reaper.ImGui_DrawList_AddRectFilled(reaper.ImGui_GetWindowDrawList(ctx),
    tx, thumb_y, tx + M.SCROLL_THUMB_W, thumb_y + thumb_h,
    fade(hot and T.SCROLL_THUMB_HOT or T.SCROLL_THUMB, alpha),
    M.SCROLL_THUMB_W * 0.5)
end

-- Submit the rail's input before the caller's table/child. The caller can then
-- paint the thumb after reading that window's current scroll values without
-- moving the layout cursor at the end of the parent window.
function widgets.scrollbar_input(ctx, id, x, y, w, h, scroll_y, scroll_max)
  local thumb_y, thumb_h, travel = scrollbar_thumb_geometry(y, h, scroll_y, scroll_max)
  if not thumb_y then grab_off[id] = nil; return nil, false end

  -- The whole strip is the hit area. A drag keeps the point that was grabbed
  -- under the cursor; a press elsewhere in the strip centres the thumb there
  -- and drags on from that grip without releasing.
  local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_InvisibleButton(ctx, "##" .. id, w, h)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local active = reaper.ImGui_IsItemActive(ctx)
  reaper.ImGui_SetCursorScreenPos(ctx, cx, cy)

  local result
  if active and travel > 0 then
    local my = select(2, reaper.ImGui_GetMousePos(ctx))
    if reaper.ImGui_IsItemActivated(ctx) then
      local on_thumb = my >= thumb_y and my <= thumb_y + thumb_h
      grab_off[id] = on_thumb and (my - thumb_y) or thumb_h * 0.5
    end
    local nt = (my - (grab_off[id] or thumb_h * 0.5) - y) / travel
    if nt < 0 then nt = 0 elseif nt > 1 then nt = 1 end
    if math.abs(nt * scroll_max - scroll_y) >= 0.5 then result = nt * scroll_max end
    thumb_y = y + travel * nt -- draw at the drag's own answer, not a frame behind
  else
    grab_off[id] = nil
  end

  return result, hovered or active
end

function widgets.scrollbar_thumb(ctx, x, y, w, h, scroll_y, scroll_max, hot)
  local thumb_y, thumb_h = scrollbar_thumb_geometry(y, h, scroll_y, scroll_max)
  if not thumb_y then return end
  paint_scrollbar_thumb(ctx, x, w, thumb_y, thumb_h, hot, false)
end

-- An overlay rail cannot use an ImGui item: the category rows underneath would
-- own hover first. The caller excludes this strip from those rows' hit areas,
-- then calls here from inside the child after drawing them. Window hover keeps
-- popups and overlapping windows authoritative; a drag remains active outside
-- the rail until the mouse button is released.
function widgets.overlay_scrollbar(ctx, id, x, y, w, h, scroll_y, scroll_max)
  local thumb_y, thumb_h, travel = scrollbar_thumb_geometry(y, h, scroll_y, scroll_max)
  if not thumb_y then grab_off[id] = nil; return nil, false end

  local mx, my = reaper.ImGui_GetMousePos(ctx)
  local hovered = reaper.ImGui_IsWindowHovered(ctx)
    and mx >= x and mx < x + w and my >= y and my < y + h
  local active = grab_off[id] ~= nil

  if hovered and reaper.ImGui_IsMouseClicked(ctx, 0) then
    local on_thumb = my >= thumb_y and my <= thumb_y + thumb_h
    grab_off[id] = on_thumb and (my - thumb_y) or thumb_h * 0.5
    active = true
  end

  local result
  if active then
    if not reaper.ImGui_IsMouseDown(ctx, 0) then
      grab_off[id] = nil
      active = false
    elseif travel > 0 then
      local nt = (my - (grab_off[id] or thumb_h * 0.5) - y) / travel
      if nt < 0 then nt = 0 elseif nt > 1 then nt = 1 end
      if math.abs(nt * scroll_max - scroll_y) >= 0.5 then result = nt * scroll_max end
      thumb_y = y + travel * nt
    end
  end

  local hot = hovered or active
  paint_scrollbar_thumb(ctx, x, w, thumb_y, thumb_h, hot, true)
  return result, hot
end

return widgets
