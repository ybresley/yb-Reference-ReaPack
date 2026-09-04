-- waveform: draws a sound's envelope and playhead, and reports a click as a seek
-- intent. A ui/ module — it may call reaper.ImGui_* only. It never reads `state`
-- selection directly: the caller's `opts` names which sound + which pre-built
-- per-channel envelope to draw (the entry script builds envelopes when a
-- selection changes), so the Reference View and the browser's audition strip can
-- each show their OWN, independent selection through the same widget (Phase 5.9).
-- Scales the envelope to the available width; never reads audio itself.
--
-- One lane per channel (mono = 1, stereo = 2, ...), stacked to fill the panel. The
-- playhead spans all lanes.

local theme = require("ui.theme")
local tips = require("ui.tips")
local widgets = require("ui.widgets")
local core_ruler = require("core.ruler")
local wave_ruler = require("core.wave_ruler")
local viewport = require("core.wave_view")
local navigation = require("ui.wave_navigation")
local T = theme.tokens
local M = theme.metrics

local waveform = {}

-- The east-west resize cursor the start/end handles show, resolved once at
-- load (the house feature-detection idiom); nil on an older ReaImGui — the
-- drag still works, the pointer just doesn't change.
local RESIZE_EW = reaper.ImGui_MouseCursor_ResizeEW and reaper.ImGui_MouseCursor_ResizeEW() or nil

-- The in-flight handle drag (start/end points, loudness tools 2026-08-06).
-- Module-local view state, the refpicker idiom: `which` names the handle
-- ("start"/"finish"), `id` the sound it belongs to (abandoned if the armed
-- sound changes mid-hold), `hold` marks a reset that fired during this mouse
-- hold — without it the very next frame's drag would yank the value straight
-- back to the mouse position, undoing the reset (the db_fader bug).
local sdrag = { which = nil, id = nil, hold = false }

--------------------------------------------------------------- time ruler

-- The ruler tick caches (waveform ruler brief, 2026-08-05): rebuilt only when
-- a sound's duration, floored pixel width or actual label-font size changes,
-- never per frame
-- (frame-loop rule). One slot per RULER-CARRYING view, keyed by opts.slot
-- — "main" (Reference View) and, since 2026-08-06, "browse" (the audition strip)
-- — because a single shared slot would rebuild every frame while both windows
-- are open, each stamping over the other's entry. Bounded at exactly those two.
local ruler_cache = {}
local visible_ruler_cache = {}

local function ruler_ticks(ctx, key, duration, width_px, font_size)
  local width_floor = math.floor(width_px)
  local c = ruler_cache[key]
  if c and c.duration == duration and c.width == width_floor and c.font_size == font_size then
    return c.ticks
  end
  local ticks = core_ruler.build(duration, width_px, function(text)
    return select(1, reaper.ImGui_CalcTextSize(ctx, text))
  end)
  ruler_cache[key] = {
    duration = duration, width = width_floor, font_size = font_size, ticks = ticks,
  }
  return ticks
end

-- Draws the ~22px ruler band directly under the waveform bars: two-tier ticks
-- pointing up from the strip's top edge (majors + labels, minors), CONFINED
-- to the strip — nothing here draws above `y_top`, into the waveform. Majors
-- and their labels use TEXT_TERTIARY, minors use STROKE_TERTIARY — both
-- existing tokens, no new colours (tokens.md "Time ruler").
--
-- Drawn even with no duration (reserved-but-empty strip, no ticks) — the
-- caller always reserves RULER_H worth of space once `opts.ruler` is true,
-- regardless of whether a sound is currently armed, so the strip's presence
-- never changes with state (see ui/window.lua's layout arithmetic).
local function draw_ruler(ctx, dl, key, x, y_top, avail_w, duration, view)
  if not duration or duration <= 0 then return end
  -- Measure, cache and draw under one exact font push. The actual current size
  -- is part of the cache key so changing UI Size can never reuse a cadence that
  -- was chosen for smaller labels.
  local small = theme.push_small_font(ctx)
  local font_size = reaper.ImGui_GetFontSize(ctx)
  local ticks
  if view then
    local width_floor = math.floor(avail_w)
    local c = visible_ruler_cache[key]
    if c and c.duration == duration and c.width == width_floor
      and c.font_size == font_size and c.t0 == view.t0 and c.t1 == view.t1 then
      ticks = c.ticks
    else
      ticks = wave_ruler.build(view.t0 * duration, view.t1 * duration, avail_w,
        function(text) return select(1, reaper.ImGui_CalcTextSize(ctx, text)) end)
      visible_ruler_cache[key] = { duration = duration, width = width_floor,
        font_size = font_size, t0 = view.t0, t1 = view.t1, ticks = ticks }
    end
  else
    ticks = ruler_ticks(ctx, key, duration, avail_w, font_size)
  end
  for _, tk in ipairs(ticks) do
    local tx = x + tk.x
    if tk.major then
      reaper.ImGui_DrawList_AddLine(dl, tx, y_top, tx, y_top + M.RULER_TICK_MAJOR, T.TEXT_TERTIARY)
      if tk.label then
        local lw = select(1, reaper.ImGui_CalcTextSize(ctx, tk.label))
        -- Edge labels clamp inside the panel (the brief's mock behaviour): a
        -- centred "0" would straddle the panel's left edge, and a major landing
        -- exactly at the full width would hang its label half outside.
        local lx = x + (tk.label_x or
          math.max(0, math.min(tk.x - lw * 0.5, math.max(0, avail_w - lw))))
        reaper.ImGui_DrawList_AddText(dl, lx, y_top + M.RULER_TICK_MAJOR + 2, T.TEXT_TERTIARY, tk.label)
      end
    else
      -- STROKE_PRIMARY, not STROKE_TERTIARY (2026-08-06): the hairline shade
      -- is invisible at 1px on the band — the user asked where the minors
      -- were. 20% white keeps them clearly subordinate to the 37% majors.
      reaper.ImGui_DrawList_AddLine(dl, tx, y_top, tx, y_top + M.RULER_TICK_MINOR, T.STROKE_PRIMARY)
    end
  end
  if small then reaper.ImGui_PopFont(ctx) end
end

-- Draw one channel's envelope into a horizontal lane [lane_y, lane_y+lane_h].
-- `show_head` covers both a sound actually playing and one paused mid-way —
-- either way there's a real position to colour up to (see waveform.draw).
-- `gain` is the trim expressed as a multiplier, so louder draws taller.
local function flatten_colour(foreground, background)
  local alpha = (foreground & 0xFF) / 255
  local function channel(shift)
    local front = (foreground >> shift) & 0xFF
    local back = (background >> shift) & 0xFF
    return math.floor(front * alpha + back * (1 - alpha) + 0.5)
  end
  return (channel(24) << 24) | (channel(16) << 16) | (channel(8) << 8) | 0xFF
end

local WAVE_PANEL_SOLID = flatten_colour(T.WAVE_BG, T.BG_WINDOW)
local WAVE_UNPLAYED_SOLID = flatten_colour(T.WAVE_BARS, WAVE_PANEL_SOLID)

local function projected_y(view, amplitude, gain, lane_y, lane_h)
  local inset = math.min(M.WAVE_LANE_PAD, lane_h * 0.1)
  local draw_h = math.max(1, lane_h - inset * 2)
  return lane_y + inset + viewport.y_of_amp(view, amplitude * gain) * draw_h
end

local function draw_lane(dl, x, lane_y, lane_h, cols, overview, detail, detail_count, detail_cols,
    view, show_head, play_frac, gain)
  local source = detail or overview
  local n = detail and detail_count or #overview.maxs
  if not source or not n or n < 1 then return end
  local view_span = view.t1 - view.t0
  reaper.ImGui_DrawList_PushClipRect(dl, x, lane_y, x + cols, lane_y + lane_h, true)
  -- Compare the returned count with the peak request, not the panel width,
  -- so a capped request still draws bars across the full panel.
  if detail and n > 1 and n < detail_cols then
    local previous_x, previous_y
    for sample = 1, n do
      local frac = (sample - 1) / (n - 1)
      local cx = x + frac * cols
      local cy = projected_y(view, (source.maxs[sample] + source.mins[sample]) * 0.5,
        gain, lane_y, lane_h)
      if previous_x then
        local sample_time = view.t0 + frac * view_span
        local col = (show_head and sample_time <= play_frac) and T.WAVE_PLAYED or WAVE_UNPLAYED_SOLID
        reaper.ImGui_DrawList_AddLine(dl, previous_x, previous_y, cx, cy, col, 1.25)
      end
      previous_x, previous_y = cx, cy
    end
  else
    local previous_hi, previous_lo
    for px = 0, cols - 1 do
      local b0, b1
      if detail then
        b0 = math.max(1, math.min(n, math.floor(px * n / cols) + 1))
        b1 = math.max(b0, math.min(n, math.ceil((px + 1) * n / cols)))
      else
        local f0 = view.t0 + (px / cols) * view_span
        local f1 = view.t0 + ((px + 1) / cols) * view_span
        b0 = math.max(1, math.min(n, math.floor(f0 * n) + 1))
        b1 = math.max(b0, math.min(n, math.ceil(f1 * n)))
      end
      local hi, lo = -math.huge, math.huge
      for b = b0, b1 do
        if source.maxs[b] > hi then hi = source.maxs[b] end
        if source.mins[b] < lo then lo = source.mins[b] end
      end
      local y_hi = projected_y(view, hi, gain, lane_y, lane_h)
      local y_lo = projected_y(view, lo, gain, lane_y, lane_h)
      local cx = math.floor(x) + px
      local sample_time = view.t0 + ((px + 0.5) / cols) * view_span
      local col = (show_head and sample_time <= play_frac) and T.WAVE_PLAYED or WAVE_UNPLAYED_SOLID
      local top, bottom = math.floor(y_hi), math.ceil(y_lo)
      if bottom <= top then bottom = top + 1 end
      reaper.ImGui_DrawList_AddRectFilled(dl, cx, top, cx + 1, bottom, col)
      if previous_hi then
        reaper.ImGui_DrawList_AddLine(dl, cx - 0.5, previous_hi, cx + 0.5,
          math.floor(y_hi + 0.5), col)
        reaper.ImGui_DrawList_AddLine(dl, cx - 0.5, previous_lo, cx + 0.5,
          math.floor(y_lo + 0.5), col)
      end
      previous_hi, previous_lo = math.floor(y_hi + 0.5), math.floor(y_lo + 0.5)
    end
  end
  reaper.ImGui_DrawList_PopClipRect(dl)
end

-- Draw the panel. `height` is the pixel height the caller has measured out for
-- it this frame (Phase 5.7 Stage 2 — the Reference View hands it everything left
-- over between the reference row and the transport row, so the waveform grows
-- and shrinks with the WINDOW, never with any state change). Falls back to the
-- floor metric if a caller doesn't pass one.
--
-- `opts` tells this draw WHICH sound + envelope to show — the Reference View
-- passes the armed reference (`state.selected_id`/`state.waveform`), the
-- browser's audition strip passes its own browse selection instead (Phase
-- 5.9 — independent browsing). Reading `state.selected*` in here directly
-- would make the two views draw the same thing, which is exactly what they
-- must not do. Returns a seek action { type="seek", fraction } on a click
-- inside it, else nil — the CALLER tags which sound it seeks (see
-- ui/browser.lua's target="browse").
--
-- `opts.trim_db` scales the drawing the way a DAW scales an item whose take volume
-- you change: louder trim, taller wave (2026-07-30). It comes from the caller for
-- the same reason the sound does — the browser passes none, because a browse
-- audition applies no trim either, and a picture that disagreed with the audio
-- would be worse than no picture.
--
-- `opts.ruler` (waveform ruler brief 2026-08-05; the browser strip joined
-- 2026-08-06) adds the ~22px time ruler directly beneath the bars: `height`
-- still means the BARS' own height exactly as before (the caller has already
-- budgeted RULER_H in its own layout — ui/window.lua carves it out of the
-- wave, ui/browser.lua grows the strip block), and this draw adds RULER_H
-- more on top of it, unconditionally, so the reserved space never changes
-- with state. `opts.duration` (seconds) only controls whether the strip shows
-- any TICKS — with no valid duration it stays reserved but empty, same as the
-- bars' own "nothing to show yet" baseline.
--
-- `opts.slot` names WHICH VIEW this panel belongs to ("main" default /
-- "browse"), and it answers two questions with one word: which tick-cache slot
-- the ruler owns, and which of the two remembered pauses the playhead reads.
-- They were `ruler_slot` and an implicit single pause memory until 2026-08-12 —
-- the same identity written twice is exactly how the two drift apart.
function waveform.draw(ctx, state, height, opts)
  opts = opts or {}
  local target_id = opts.id
  local slot = opts.slot or "main"
  local view = opts.view or { t0 = 0, t1 = 1, a0 = -1, a1 = 1 }
  local gain = 10 ^ ((opts.trim_db or 0) / 20) -- dB -> multiplier; 0 dB = 1.0
  local action
  local avail_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  if avail_w < 1 then avail_w = 1 end
  local h = height or M.WAVE_MIN_H
  local has_ruler = opts.ruler == true
  local total_h = has_ruler and (h + M.RULER_H) or h
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)

  -- The wave fill stops at the lane bottom; the ruler band beneath draws NO
  -- fill of its own — ticks sit on the naked window background (user pick,
  -- 2026-08-06 brief round: the interim chrome band made the ruler the darkest
  -- zone in the window). The fill-stop edge IS the 0 dBFS line — bars clamp
  -- exactly there. With no ruler, total_h == h and this is the whole panel.
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + avail_w, y + h, T.WAVE_BG, 4)

  -- Where the playhead sits (0..1 of the file), only while the sound being shown
  -- is the one this preview slot actually owns (auto-audition off, or the OTHER
  -- slot auditioning, can leave a different sound playing than this one — its
  -- playhead must not slide over this one). A paused sound owns the slot just as
  -- much as a playing one — the playhead should stay put at the paused position
  -- rather than vanish — so both count as "showing a head", just from different
  -- position fields. The pause is read from THIS PANEL'S OWN slot, kept separate
  -- from `sound_id` (which follows whatever the ONE shared preview is CURRENTLY
  -- sounding) and from the other panel's pause, so neither an unrelated audition
  -- nor the other window's park can move or erase this playhead.
  -- Both tests are against THIS SLOT, never against the shared engine's global
  -- "is anything playing" flag: there is one preview for two panels, so a
  -- library audition makes that flag true for the Reference View too. Reading it
  -- directly hid the Reference View's parked playhead for as long as the library
  -- was sounding (user-reported 2026-08-12), and let an audition of a sound the
  -- Reference View happens to have armed drag that panel's playhead along with it.
  local sounding = state.preview.playing and state.preview.slot == slot
    and state.preview.sound_id == target_id
  local parked = state.preview.paused[slot]
  local paused = (not sounding) and parked ~= nil
    and parked.sound_id == target_id
  -- Paused reads its OWN length snapshot, not the shared `length` field — that
  -- field follows whatever's currently sounding, which may by now be a
  -- completely different (browsed) sound with a different duration.
  local pos, len
  if sounding then
    pos, len = state.preview.position, state.preview.length
  elseif paused then
    pos, len = parked.at, parked.length
  end
  local show_head = pos ~= nil and len ~= nil and len > 0
  local play_frac = -1
  if show_head then
    play_frac = pos / len
    if play_frac < 0 then play_frac = 0 elseif play_frac > 1 then play_frac = 1 end
  end

  local wf = opts.waveform
  local chans = (wf and wf.sound_id == target_id) and wf.channels or nil
  local have_wave = chans and #chans > 0 and chans[1].maxs and #chans[1].maxs > 0

  if have_wave then
    local nch = #chans
    local lane_h = h / nch
    local cols = math.max(1, math.floor(avail_w))
    local detail = opts.detail
    local detail_channels = detail and detail.sound_id == target_id
      and detail.count and detail.count > 0
      and detail.t0 == view.t0 and detail.t1 == view.t1 and detail.width == cols
      and detail.channels or nil
    local detail_count = detail_channels and detail.count or nil
    for ci = 1, nch do
      local lane_y = y + (ci - 1) * lane_h
      draw_lane(dl, x, lane_y, lane_h, cols, chans[ci],
        detail_channels and detail_channels[ci] or nil, detail_count, detail and detail.cols,
        view, show_head, play_frac, gain)

      -- Each channel zooms around its own zero line. Match the waveform colour
      -- on either side of the playhead, so the baseline reads as part of the
      -- waveform rather than as a second pale outline.
      local zero_y = projected_y(view, 0, gain, lane_y, lane_h)
      if zero_y >= lane_y and zero_y <= lane_y + lane_h then
        zero_y = math.floor(zero_y + 0.5)
        local split = math.max(x, math.min(x + avail_w,
          x + viewport.x_of_time(view, play_frac) * avail_w))
        if split > x then
          reaper.ImGui_DrawList_AddLine(dl, x, zero_y, split, zero_y, T.WAVE_PLAYED)
        end
        if split < x + avail_w then
          reaper.ImGui_DrawList_AddLine(dl, split, zero_y, x + avail_w,
            zero_y, WAVE_UNPLAYED_SOLID)
        end
      end
    end
  else
    -- Nothing to show yet: a single centre baseline, plus one line of text over
    -- it — "reading…" while a build runs for this sound, or the caller's
    -- `empty_hint` when nothing is armed at all. Both are DRAWN, not laid out,
    -- so the panel's own geometry never shifts with them.
    --
    -- The hint is the caller's because the two panels that draw waveforms mean
    -- different things by "empty": a drop on the Reference View PINS to the
    -- project, a drop on the browser's strip adds to the library. Only the
    -- Reference View passes one.
    local midy = y + h * 0.5
    reaper.ImGui_DrawList_AddLine(dl, x, midy, x + avail_w, midy, T.WAVE_CENTER)
    local label, col
    if state.wave_loading and state.wave_loading == target_id then
      label, col = "Reading waveform\u{2026}", T.TEXT_QUATERNARY
    elseif not target_id and opts.empty_hint then
      label, col = opts.empty_hint, T.TEXT_TERTIARY
    end
    if label then
      local tw, th = reaper.ImGui_CalcTextSize(ctx, label)
      -- Only when it actually fits: half a sentence centred in a narrow docked
      -- strip reads as a broken label, and the baseline alone says "empty" well
      -- enough there.
      if tw <= avail_w - M.WINDOW_PAD * 2 then
        reaper.ImGui_DrawList_AddText(dl, x + (avail_w - tw) * 0.5, midy - th * 0.5, col, label)
      end
    end
  end

  -- Playhead line spanning all lanes (bars only — kept out of the ruler band
  -- beneath it, which is its own confined strip).
  if show_head then
    local play_x = viewport.x_of_time(view, play_frac)
    if play_x >= 0 and play_x <= 1 then
      local px = x + play_x * avail_w
      reaper.ImGui_DrawList_AddLine(dl, px, y, px, y + h, T.WAVE_PLAYHEAD, 1)
    end
  end

  if has_ruler then
    draw_ruler(ctx, dl, slot, x, y + h, avail_w, opts.duration,
      opts.navigation and view or nil)
    -- The band's playhead caret (brief, 2026-08-06): the DAW-universal small
    -- triangle, so the position stays readable where the line crosses busy
    -- bars. Same white as the line, drawn after the ticks so it rides them;
    -- the line itself still stops at the wave's bottom edge.
    if show_head then
      local play_x = viewport.x_of_time(view, play_frac)
      if play_x >= 0 and play_x <= 1 then
        local px = x + play_x * avail_w
        reaper.ImGui_DrawList_AddTriangleFilled(dl,
          px - 4, y + h + 8, px + 4, y + h + 8, px, y + h + 1, T.WAVE_PLAYHEAD)
      end
    end
  end

  -- One InvisibleButton reserves the layout space AND captures both clicks and
  -- hover — extended down over the ruler band instead of adding a second
  -- handler, so a click anywhere in either zone reports the same position
  -- (downstream, the Reference View plays from it and the Library applies its
  -- own audition rules). The
  -- start/end handles are resolved inside this SAME item by mouse proximity —
  -- never a second widget overlapping it, which would fight the seek click for
  -- hover (the refpicker rows' "hit area stops short" reasoning).
  reaper.ImGui_InvisibleButton(ctx, "##waveform", avail_w, total_h)
  local clicked = reaper.ImGui_IsItemClicked(ctx)
  -- Duration governs seeking, spans, and navigation even when a short window
  -- yields its ruler. Hiding ticks must not disable the waveform itself.
  local has_duration = type(opts.duration) == "number" and opts.duration > 0
  local hovered = has_duration and reaper.ImGui_IsItemHovered(ctx)
  local item_active = reaper.ImGui_IsItemActive(ctx)
  local mx, my = reaper.ImGui_GetMousePos(ctx)

  -- Start/end points (loudness tools, 2026-08-06): only where the caller
  -- opted in (the Reference View — the browser strip stays plain) and there is
  -- a real file to frame. Drawn here, after the bars and playhead, so the dim
  -- wash sits over the picture it excludes.
  local span_on = opts.span_edit and has_duration and target_id ~= nil
  local near -- which handle the mouse is on, this frame
  local dur = opts.duration
  if span_on then
    local s0 = opts.span_start or 0
    local s1 = opts.span_end or dur
    if s1 > dur then s1 = dur end
    if s0 < 0 or s0 >= s1 then s0 = 0 end
    local hx0 = x + viewport.x_of_time(view, s0 / dur) * avail_w
    local hx1 = x + viewport.x_of_time(view, s1 / dur) * avail_w

    -- The picture dims OUTSIDE the span; the framed stretch is what plays.
    if hx0 > x then
      reaper.ImGui_DrawList_AddRectFilled(dl, x, y, math.min(x + avail_w, hx0), y + h, T.SPAN_DIM)
    end
    if hx1 < x + avail_w then
      reaper.ImGui_DrawList_AddRectFilled(dl, math.max(x, hx1), y, x + avail_w, y + h, T.SPAN_DIM)
    end

    -- Which handle is the mouse on? Bars zone only — the ruler band beneath
    -- keeps its plain position click. The nearer line wins when the grab zones
    -- overlap on a tight span.
    if (hovered or item_active) and my <= y + h then
      local d0, d1 = math.abs(mx - hx0), math.abs(mx - hx1)
      if math.min(d0, d1) <= M.SPAN_GRAB then
        near = (d0 <= d1) and "start" or "finish"
      end
    end

    -- The handles: a small inward flag at the top, and a full-height line only
    -- while the cursor is on the panel (brief, 2026-08-08 — at rest the dim
    -- wash already draws the boundary, so a bright line over the picture said
    -- it twice). Reaching in is what asks for them, so the whole panel wakes
    -- them at once in a faint grey. The line under the pointer turns white.
    -- Only the RESTING flag grades: a
    -- point still at its own extreme is stored nil (never moved, or moved
    -- back), marks nothing, and sits a step dimmer than one that does.
    local woke = hovered or item_active
    local function handle(which, hx, untouched)
      local hot
      if sdrag.which == which then hot = T.ACCENT
      elseif near == which and not sdrag.which then hot = T.TEXT_PRIMARY
      elseif woke then hot = T.TEXT_QUATERNARY
      else hot = untouched and T.TEXT_QUATERNARY or T.TEXT_TERTIARY end
      if woke and hx >= x and hx <= x + avail_w then
        reaper.ImGui_DrawList_AddLine(dl, hx, y, hx, y + h, hot, 2)
      end
      if hx < x or hx > x + avail_w then return end
      local dirn = (which == "start") and 1 or -1
      reaper.ImGui_DrawList_AddTriangleFilled(dl,
        hx, y, hx, y + 7, hx + dirn * 6, y, hot)
    end
    handle("start", hx0, opts.span_start == nil)
    handle("finish", hx1, opts.span_end == nil)

    -- Interaction, all inside the one item. Reset first (the shared gesture),
    -- so a double-click can never race its own drag; `hold` then mutes the
    -- rest of that mouse-hold.
    if clicked and near then
      sdrag.which, sdrag.id, sdrag.hold = near, target_id, false
    end
    if (near or sdrag.which) and widgets.wants_reset(ctx) then
      action = { type = "set_span", which = sdrag.which or near, reset = true }
      sdrag.hold = true
    end
    if sdrag.which then
      if sdrag.id ~= target_id then
        sdrag.which, sdrag.hold = nil, false -- the armed sound changed mid-hold
      elseif item_active then
        if not sdrag.hold and reaper.ImGui_IsMouseDragging(ctx, 0) then
          local frac = viewport.time_at(view, (mx - x) / avail_w)
          action = action or { type = "set_span", which = sdrag.which, seconds = frac * dur }
        end
      else
        -- Released: persist once, like a fader's commit-on-release.
        action = action or { type = "set_span", which = sdrag.which, commit = true }
        sdrag.which, sdrag.hold = nil, false
      end
    end
    if (near or sdrag.which) and RESIZE_EW then
      reaper.ImGui_SetMouseCursor(ctx, RESIZE_EW)
    end
  end

  local on_handle = span_on and (near ~= nil or sdrag.which ~= nil)
  local nav_action, nav_claimed, nav_hot
  if opts.navigation and has_duration then
    nav_action, nav_claimed, nav_hot = navigation.handle(ctx, target_id, view,
      x, y, avail_w, h, has_ruler and M.RULER_H or 0, on_handle, opts.modifiers)
    action = action or nav_action
  end
  if (clicked or hovered) and not on_handle then
    local local_frac = (mx - x) / avail_w
    if local_frac < 0 then local_frac = 0 elseif local_frac > 1 then local_frac = 1 end
    local frac = viewport.time_at(view, local_frac)
    -- Navigation still owns its clicks, but the mouse-position guide remains
    -- visible while a wheel gesture is changing the view. Hiding the whole
    -- block on each wheel-event frame made that vertical line visibly flash.
    if clicked and not nav_claimed then
      action = action or { type = "seek", fraction = frac }
    end
    -- Exact-time hover readout, one notch finer than the tick labels — the
    -- standard fix for a no-zoom ruler where labels alone get sparse on long
    -- files (tooltip LAST: SetTooltip replaces ImGui's "last item", so it must
    -- run after IsItemClicked above, which it does).
    if hovered then
      -- The hover ghost-line (brief, 2026-08-06): the thin line the tooltip
      -- belongs to — where exactly a click will land. TEXT_TERTIARY keeps it
      -- clearly quieter than the full-white playhead, and the clamped frac
      -- keeps it inside the panel. Tooltip stays LAST (the house rule).
      local gx = x + local_frac * avail_w
      reaper.ImGui_DrawList_AddLine(dl, gx, y, gx, y + total_h, T.TEXT_TERTIARY, 1)
      -- Keyed, not text-identified: this readout rewrites itself every pixel
      -- the cursor moves, and the wait must run on the panel, not the words.
      tips.show(ctx, true, core_ruler.hover_label(frac * opts.duration, opts.duration), "wave-time")
    end
  elseif on_handle and hovered and not sdrag.which then
    -- The handle's own tooltip: which point, where it sits, and the shared
    -- reset gesture — the affordance the flag alone can't spell out.
    local at = (near == "start") and (opts.span_start or 0) or (opts.span_end or dur)
    tips.show(ctx, true, string.format(
      "%s point \u{00B7} %s. Drag to frame what plays; right-click or double-click to reset",
      near == "start" and "Start" or "End", core_ruler.hover_label(at, dur)), "wave-handle")
  end

  if opts.navigation then
    navigation.draw_rails(dl, view, x, y, avail_w, h,
      has_ruler and M.RULER_H or 0, nav_hot)
  end

  if opts.navigation and target_id then
    return action, target_id, math.max(1, math.floor(avail_w)), x, y, x + avail_w, y + total_h
  end
  -- A tooltip can replace ImGui's last item. Callers need the waveform bounds
  -- themselves for progress feedback, idle text and file-drop targets.
  return action, nil, nil, x, y, x + avail_w, y + total_h
end

return waveform
