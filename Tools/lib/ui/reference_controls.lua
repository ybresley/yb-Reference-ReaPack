-- The Reference card, beside or above the panels. A ui/ module: draws from
-- state and returns intent.
--
-- Top row: the name box, then previous and next joined around the count.
-- Then the file details, the six stored readings below a hairline,
-- and the reference's waveform with its ruler. Bottom row: playback (play,
-- pause, stop, loop), listening (latch, mono, pitch, Normalize), the trim
-- value, then Library and Settings. The playback group matches the docked
-- Library's, cell for cell.
-- core/card_plan.lua decides which middle rows fit; the waveform takes the
-- spare height, so the card always fills the docker. With no room for the
-- readings, the Normalize menu shows them.
--
-- The bottom row is ten equal cells and the trim value, which is a number
-- that opens a vertical slider while held: a bar the row has no width for. On
-- the top row the arrows are narrow, so the name box gets the rest.
local theme = require("ui.theme")
local tips = require("ui.tips")
local widgets = require("ui.widgets")
local match = require("core.match")
local own_level = require("core.own_level")
local decibels = require("core.decibels")
local card_plan = require("core.card_plan")
local icons = require("ui.icons")
local refpicker = require("ui.refpicker")
local matchwin = require("ui.matchwin")
local readings = require("ui.readings")
local settings = require("ui.settings")
local transport = require("ui.transport")
local waveform = require("ui.waveform")
local walkthrough_ui = require("ui.walkthrough")
local T = theme.tokens
local M = theme.metrics

local controls = {}

local TRIM_TIP = "Trim: adjust the selected reference's remembered level.\n"
  .. "Drag up or down \u{00B7} Alt for fine adjustment \u{00B7} click to type \u{00B7} right-click to reset"
-- Playback (4), listening (3), then Library and Settings (2). The level
-- control sits between the last two and is not made of cells. Three gaps part
-- the groups.
local CELLS, GROUP_GAPS = 9, 3
local PLAYBACK_CELLS, LISTENING_CELLS = 4, 3
local FACT_SEPARATOR = require("core.techfacts").SEP

local function snap(v) return math.floor(v + 0.5) end

-- Reused every frame; callers read them immediately (frame-allocation rule).
local sizes, plan_sizes, card = {}, { rows = {} }, {}

-- The measured sizes hold until the font size, control height or UI scale
-- changes; the card and the docked Library ask for them several times a frame.
local measured = {}
local function sizes_current(ctx)
  local font, ctrl = reaper.ImGui_GetFontSize(ctx), reaper.ImGui_GetFrameHeight(ctx)
  if measured.font == font and measured.ctrl == ctrl and measured.scale == theme.scale then
    return true
  end
  measured.font, measured.ctrl, measured.scale = font, ctrl, theme.scale
  measured.trim, measured.card = nil, nil
  return false
end

local function trim_width(ctx)
  if sizes_current(ctx) and measured.trim then return measured.trim end
  -- Normalize and the lock each take a square at its left.
  measured.trim = widgets.db_value_width(ctx, 2)
  return measured.trim
end

-- The sizes core/card_plan.lua folds the card with, for content `w` wide.
local function measure_plan_sizes(ctx, w)
  local s = plan_sizes
  s.ctrl = reaper.ImGui_GetFrameHeight(ctx)
  s.pad, s.gap = M.STRIP_PAD, M.STRIP_FACTS_GAP
  s.tight_pad = M.STRIP_TIGHT_PAD
  s.facts_h, s.ruler, s.stroke = M.STRIP_FACTS_H, M.RULER_H, theme.scale
  s.wave_facts, s.wave_readings = M.CARD_WAVE_FACTS_MIN, M.CARD_WAVE_READINGS_MIN
  s.wave_min, s.wave_natural = M.CARD_WAVE_MIN, M.CARD_WAVE_H
  readings.rows_for_width(ctx, w, s.rows)
  return s
end

-- The card's sizes in pixels, measured from the live fonts:
--   block_width    narrowest the card may be
--   card_minimum   shortest the card may be
--   card_natural   its height when it is not stretched to fill a docker
function controls.measure(ctx)
  if sizes_current(ctx) and measured.card then return sizes end
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local gap = M.STRIP_GROUP_GAP
  local r = readings.measure(ctx)
  local content = math.max(CELLS * ctrl + GROUP_GAPS * gap + trim_width(ctx), r.two_w)
  sizes.block_width = math.ceil(content) + 2 * M.STRIP_PAD
  local s = measure_plan_sizes(ctx, content)
  sizes.card_minimum = card_plan.minimum(s)
  sizes.card_natural = card_plan.natural(s)
  measured.card = true
  return sizes
end

-- The width of one bottom-row cell in a card `card_w` wide. The docked
-- Library sizes its audition buttons from it, so the two rows match.
function controls.cell_width(ctx, card_w)
  local w = snap(card_w - 2 * M.STRIP_PAD)
  return (w - trim_width(ctx) - GROUP_GAPS * M.STRIP_GROUP_GAP) / CELLS
end

-- What a card `w` wide shows at height `h` (core/card_plan.lua). Fills `out`,
-- or the card's own reused table.
function controls.plan(ctx, h, w, out)
  local s = measure_plan_sizes(ctx, w - 2 * M.STRIP_PAD)
  return card_plan.fit(h, s, out or card)
end

local cell = widgets.segment_cell

--------------------------------------------------------------- top row

-- Library and Settings, at the right end of the bottom row.
local function draw_app(ctx, state, font, x0, x1, y)
  local action
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  widgets.begin_segment(ctx, x0, y, x1, y + ctrl)

  local w, cx = cell(ctx, x0, x1, 2, 0, y)
  walkthrough_ui.note_rect(ctx, state.walkthrough, "library_button", cx, y, cx + w, y + ctrl)
  if widgets.panel_button(ctx, font, "openlibrary", "library", state.browser_open,
      icons.draw_folder, nil, nil, nil, w) then
    action = { type = "toggle_browser" }
  end
  tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), tips.with_shortcut(state, "library", "Open the Library."))

  w, cx = cell(ctx, x0, x1, 2, 1, y)
  walkthrough_ui.note_rect(ctx, state.walkthrough, "settings_button", cx, y, cx + w, y + ctrl)
  local update_due = state.update and state.update.available ~= nil
  -- A release demonstration's card has no Settings of its own to show open.
  local settings_open = not state.showcase and settings.is_open()
  -- Settings toggles on release, so its motion starts on that same release.
  if widgets.panel_button(ctx, font, "settings", "settings", settings_open, icons.draw_gear,
      nil, nil, nil, w) and not state.showcase then
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
  -- No tip while Settings is open, so it never draws over the window it opened.
  tips.show(ctx, reaper.ImGui_IsItemHovered(ctx)
    and (state.showcase or not settings.is_open()),
    tips.with_shortcut(state, "settings", update_due and "Settings. An update is available" or "Settings"))
  widgets.end_segment(ctx, x0, y, x1, y + ctrl, 2)
  return action
end

-- The name box, then previous and next joined around the count. The name box
-- takes the width the arrows leave, and opens the card's list: the Library's
-- sounds or the pinned references.
local function draw_top_row(ctx, state, res, x, y, w)
  local gap = M.STRIP_GROUP_GAP
  local stepper_w = refpicker.stepper_width(ctx, state)
  local stepper_x = w - stepper_w

  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  local action = refpicker.draw_slot(ctx, state, res, math.max(1, stepper_x - gap))
  local step_action = refpicker.draw_stepper(ctx, state, res, x + stepper_x, y, stepper_w)
  return action or step_action
end

--------------------------------------------------------------- middle rows

-- File facts as one line of plain text separated by dots, with the duration at
-- the right. A fact that would run into the duration is left out rather than
-- cut. Each piece is drawn separately so no string is built per frame.
local function draw_facts(ctx, state, x, y, w)
  local facts = state.selected and state.selected_tech
  if not facts then return end
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local h = M.STRIP_FACTS_H
  local small = theme.push_small_font(ctx)
  local limit = x + w
  if facts.duration then
    local dw, dh = reaper.ImGui_CalcTextSize(ctx, facts.duration)
    limit = x + w - dw - M.STRIP_GROUP_GAP
    reaper.ImGui_DrawList_AddText(dl, snap(x + w - dw), snap(y + (h - dh) * 0.5),
      T.TEXT_SECONDARY, facts.duration)
  end
  local sep_w = reaper.ImGui_CalcTextSize(ctx, FACT_SEPARATOR)
  local tx = x
  for i, fact in ipairs(facts) do
    local fw, fh = reaper.ImGui_CalcTextSize(ctx, fact)
    local lead = i > 1 and sep_w or 0
    if tx + lead + fw > limit then break end
    local ty = snap(y + (h - fh) * 0.5)
    if i > 1 then
      reaper.ImGui_DrawList_AddText(dl, snap(tx), ty, T.TEXT_QUATERNARY, FACT_SEPARATOR)
    end
    reaper.ImGui_DrawList_AddText(dl, snap(tx + lead), ty, T.TEXT_SECONDARY, fact)
    tx = tx + lead + fw
  end
  if small then reaper.ImGui_PopFont(ctx) end
end

-- The reference's waveform: seek, start and end points, zoom and scroll.
-- Returns its action, the sound it drew and its width in columns (the entry
-- script sizes detailed reads from it).
local function draw_wave(ctx, state, x, y, w, bars)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  local sel = state.selected
  local action, wave_id, wave_cols = waveform.draw(ctx, state, bars,
    { id = state.selected_id, waveform = state.waveform, slot = "main", width = w,
      -- A release demonstration paints the same waveform without taking input.
      paint_only = state.showcase == true,
      view = state.wave_view, detail = state.wave_detail, navigation = true,
      modifiers = state.mouse_modifiers,
      -- The level it plays at: the normalize lock's while that holds it.
      trim_db = sel and own_level.playing_trim(state.own_level, sel) or 0,
      ruler = true, duration = sel and sel.duration or nil,
      -- Thin lanes overlay into one, as the Library's short waveform does.
      min_lane_h = M.BROWSER_PICKER_LANE_MIN_H,
      span_edit = true,
      span_start = sel and sel.span_start or nil,
      span_end = sel and sel.span_end or nil })
  return action, wave_id, wave_cols
end

-- With no reference selected, the details, readings and waveform have nothing
-- to show. Their space stays blank, with one message centred in it when a
-- drop there can pin. The message wraps by whole words and is rebuilt only
-- when its text, the width or the font changes.
local empty_cache = { lines = {} }
local function draw_empty(ctx, state, x, y0, y1, w)
  local msg = refpicker.empty_message(state)
  if not msg or y1 <= y0 then return end
  local c, font = empty_cache, reaper.ImGui_GetFontSize(ctx)
  if c.msg ~= msg or c.w ~= w or c.font ~= font then
    c.msg, c.w, c.font = msg, w, font
    c.lines, c.widths, c.widest = widgets.wrap_words(ctx, msg, w), {}, 0
    for i, text in ipairs(c.lines) do
      c.widths[i] = reaper.ImGui_CalcTextSize(ctx, text)
      c.widest = math.max(c.widest, c.widths[i])
    end
  end
  local line_h = reaper.ImGui_GetTextLineHeight(ctx)
  -- A card too short or too narrow for the whole message shows none of it.
  if #c.lines * line_h > y1 - y0 or c.widest > w then return end
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local top = (y0 + y1 - #c.lines * line_h) * 0.5
  for i, text in ipairs(c.lines) do
    reaper.ImGui_DrawList_AddText(dl, snap(x + (w - c.widths[i]) * 0.5), snap(top + (i - 1) * line_h),
      T.TEXT_SECONDARY, text)
  end
end

--------------------------------------------------------------- bottom row

local main_slot = { slot = "main" }

-- Play, pause, stop, loop: the same group as the docked Library's.
local function draw_playback(ctx, state, font, x0, x1, y)
  main_slot.id, main_slot.sound = state.selected_id, state.selected
  return transport.draw_playback_group(ctx, state, font, main_slot, x0, x1, y,
    "loop", tips.with_shortcut(state, "loop", "Loop"))
end

-- Latch, mono, pitch. Normalize sits with the lock and the trim it sets.
local function draw_listening(ctx, state, res, x0, x1, y)
  local font = res and res.icon_font
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  widgets.begin_segment(ctx, x0, y, x1, y + ctrl)

  local w = cell(ctx, x0, x1, LISTENING_CELLS, 0, y)
  local action = transport.draw_latch(ctx, state, font, w)

  w = cell(ctx, x0, x1, LISTENING_CELLS, 1, y)
  local sound = state.selected
  local channels = state.preview.playing and (tonumber(state.preview.channels) or 0)
    or (sound and (tonumber(sound.channels) or 0) or 0)
  local available = channels <= 2
  local tip = available
    and "Fold left and right together in both speakers to check mono compatibility."
    or "Mono is available for mono and stereo sounds."
  if widgets.toggle(ctx, "mono", "M", state.mono, tips.with_shortcut(state, "mono", tip),
      font, nil, available, "mono", w) then
    action = action or { type = "toggle_mono" }
  end

  w = cell(ctx, x0, x1, LISTENING_CELLS, 2, y)
  transport.draw_pitch(ctx, state, font, "main", w)
  widgets.end_segment(ctx, x0, y, x1, y + ctrl, LISTENING_CELLS)
  return action
end

local UNLOCK_HINT = "Unlock to change the trim."
-- The state the two tooltips below describe, set each frame by draw_trim. They
-- are functions so their text is built only while the pointer is on the box.
local tip_state

local function lock_tip()
  local own = tip_state.own_level
  local name = own_level.target_label(own.target)
  if own.lock then
    return "Locked to " .. (name or "the target")
      .. ". Every reference you select plays at that level.\nClick to unlock."
  end
  if not name then
    return "The lock needs a target. Normalize a reference to one first."
  end
  if not own_level.usable_target(own, own.target) then
    return "Measure your project first. The lock then uses the Reaper Measurement."
  end
  return "Lock to " .. name .. ". Every reference you select plays at that level.\n"
    .. "Saved trims do not change."
end

local function locked_trim_tip()
  local own, sel = tip_state.own_level, tip_state.selected
  local name = own_level.target_label(own.target) or "the target"
  if not own_level.holds_sound(own, sel) then
    return "Locked to " .. name .. ". This sound has no measurement for that target yet, "
      .. "so it plays at its own trim.\n" .. UNLOCK_HINT
  end
  local _, limited = own_level.playing_trim(own, sel)
  local first = limited
    and ("Locked to " .. name .. ". This sound stops at the trim's limit, short of the target.")
    or ("Plays at " .. name .. " while the lock is on.")
  return first .. " Its own trim is " .. decibels.format(sel.trim_db or 0) .. " dB.\n" .. UNLOCK_HINT
end

-- Reused every frame (frame-allocation rule).
local trim_lock = {}
-- The Normalize button at the box's left edge. It opens the menu of targets;
-- the lock beside it uses the target chosen there, and the number shows the
-- result, so the three read in the order they are used.
local lead_state, lead_res
local trim_lead = { draw = function(ctx, w)
  matchwin.draw_button(ctx, lead_state, lead_res, w, true)
  -- Tells the box to outline the button while its menu is open.
  return not lead_state.showcase and matchwin.is_open()
end }

-- The level control: Normalize, the normalize lock, then the trim value, in
-- one box. The lock is always
-- there: dim when off, accent when on, and faint while there is no target to
-- lock to. While it is on, the number is the level the lock plays the
-- reference at and the box is read-only, so a reference can never sit apart
-- from the lock unnoticed. Its own trim is kept and returns on unlock.
local function draw_trim(ctx, state, res, x, y, w)
  local action
  local sel = state.selected
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  local opts = { min = match.TRIM_SILENCE, max = match.TRIM_MAX, default = 0, taper = true,
    width = w, edit_key = sel and sel.id or false,
    -- A demonstration has no press of its own to open the slider with.
    held = state.showcase == true and state.trim_held == true }
  -- The box keeps its drag and typed entry by id; a demonstration's copy must
  -- never cancel the live one's.
  local id = state.showcase and "showcase_trim" or "trim"
  local own = state.own_level
  local live = own ~= nil and state.showcase ~= true
  local lock = trim_lock
  lock.font = res and res.icon_font
  lock.on = live and own.lock == true
  lock.enabled = live and (own.lock == true or own_level.usable_target(own, own.target))
  -- No tips beside an open Normalize menu: they would draw over the menu the
  -- neighbouring button opened.
  local menu_open = live and matchwin.is_open()
  lock.tip = (live and not menu_open) and lock_tip or nil
  opts.lock = lock
  lead_state, lead_res = state, res
  opts.lead = trim_lead
  tip_state = state
  if sel then
    local shown = sel.trim_db
    opts.tip = TRIM_TIP
    if lock.on then
      local limited
      shown, limited = own_level.playing_trim(own, sel)
      opts.read_only, opts.tip = true, locked_trim_tip
      -- Accent says the lock sets this level. The warning colour says the
      -- trim's limit kept it short of the target.
      if own_level.holds_sound(own, sel) then
        opts.colour = limited and T.WARNING_TEXT or T.ACCENT
      end
    end
    if menu_open then opts.tip = nil end
    local db, commit, lock_clicked = widgets.db_value(ctx, id, shown, opts)
    if db ~= nil then
      action = { type = "set_trim", db = db, commit = commit }
    elseif lock_clicked then
      action = { type = "set_level_lock", on = not own.lock, target = own.target }
    end
  else
    -- Present, so the card never changes shape. The number is faint and takes
    -- no input; the lock stays live, because it needs no selected reference.
    opts.tip = not menu_open and "Select a reference to adjust its trim." or nil
    opts.read_only, opts.colour = true, T.TEXT_QUATERNARY
    local _, _, lock_clicked = widgets.db_value(ctx, id, 0, opts)
    if lock_clicked then
      action = { type = "set_level_lock", on = not own.lock, target = own.target }
    end
  end
  return action
end

--------------------------------------------------------------- the card

-- Draws the card into the current child, whose top-left corner is the strip's
-- position in `g` (core/reference_sidebar_layout.lua's result). Returns its
-- action, and the waveform's sound and width in columns.
-- `state.showcase` marks a release demonstration's private state: the card
-- then neither reads nor changes the live picker list, Normalize menu, Pitch
-- panel, Settings or waveform and trim drags.
function controls.draw(ctx, state, res, g)
  local ox, oy = reaper.ImGui_GetCursorScreenPos(ctx)
  ox, oy = ox - g.strip.x, oy - g.strip.y
  local b = g.reference
  local p = controls.plan(ctx, b.h, b.w)
  if not state.showcase then matchwin.set_show_readings(p.readings == 0) end

  local top, bottom_edge = oy + b.y, oy + b.y + p.height
  widgets.card_outline(ctx, ox + b.x, top, ox + b.x + b.w, bottom_edge)
  local pad, ctrl, gap = M.STRIP_PAD, reaper.ImGui_GetFrameHeight(ctx), M.STRIP_FACTS_GAP
  local group_gap = M.STRIP_GROUP_GAP
  -- Whole pixels, so hairlines and text stay sharp at any width.
  local x, w = snap(ox + b.x + pad), snap(b.w - 2 * pad)
  local trim_w = trim_width(ctx)
  local cell_w = controls.cell_width(ctx, b.w)

  local y = snap(top + p.pad)
  local bottom_y = snap(bottom_edge - p.pad - ctrl)
  local action = draw_top_row(ctx, state, res, x, y, w)
  y = y + ctrl

  local wave_action, wave_id, wave_cols, readings_action
  if p.wave > 0 and not state.selected then
    draw_empty(ctx, state, x, y + gap, bottom_y - gap, w)
  elseif p.wave > 0 then
    if p.facts then
      draw_facts(ctx, state, x, y + gap, w)
      y = y + gap + M.STRIP_FACTS_H
    end
    if p.readings > 0 then
      readings_action = readings.draw_section(ctx, state, state.selected, ox + b.x, ox + b.x + b.w,
        y + gap, x, w, p.readings, "##card_reading_extra")
      y = y + readings.section_height(p.readings)
    end
    wave_action, wave_id, wave_cols = draw_wave(ctx, state, x, y + gap, w, p.wave - M.RULER_H)
  elseif p.facts then
    -- Centred between the two rows.
    draw_facts(ctx, state, x, snap((y + bottom_y - M.STRIP_FACTS_H) * 0.5), w)
  end

  local playback_end = snap(x + PLAYBACK_CELLS * cell_w)
  local listening_x = playback_end + group_gap
  local listening_end = snap(x + (PLAYBACK_CELLS + LISTENING_CELLS) * cell_w + group_gap)
  local trim_x = listening_end + group_gap
  local app_x = trim_x + trim_w + group_gap
  local playback_action = draw_playback(ctx, state, res and res.icon_font, x, playback_end, bottom_y)
  local listening_action = draw_listening(ctx, state, res, listening_x, listening_end, bottom_y)
  -- The tour points at playback and the latch together, then at the rest of
  -- the row through the trim value, so the two rings never overlap.
  local latch_end = widgets.segment_edge(listening_x, listening_end, LISTENING_CELLS, 1)
  walkthrough_ui.note_rect(ctx, state.walkthrough, "latch", x, bottom_y, latch_end, bottom_y + ctrl)
  walkthrough_ui.note_rect(ctx, state.walkthrough, "transport", latch_end, bottom_y,
    trim_x + trim_w, bottom_y + ctrl)
  local trim_action = draw_trim(ctx, state, res, trim_x, bottom_y, trim_w)
  local app_action = draw_app(ctx, state, res and res.icon_font, app_x, x + w, bottom_y)
  action = action or readings_action or wave_action or playback_action or listening_action
    or trim_action or app_action

  -- Leave the cursor below the card so a short child can scroll to it.
  reaper.ImGui_SetCursorScreenPos(ctx, ox + g.strip.x, bottom_edge)
  reaper.ImGui_Dummy(ctx, 0, 0)
  return action, wave_id, wave_cols
end

-- The picker's list and the Normalize panel are separate windows. Submit them
-- after the strip so they never steal a click meant for a control beneath.
-- `library` is the Library's list for the name box's dropdown (refpicker.draw_popup).
function controls.draw_popups(ctx, state, res, library)
  local action = refpicker.draw_popup(ctx, state, res, library)
  local match_action = matchwin.draw_popup(ctx, state, res)
  return action or match_action
end

return controls
