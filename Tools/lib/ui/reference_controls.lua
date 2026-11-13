-- The Reference card, beside or above the panels. A ui/ module: draws from
-- state and returns intent.
--
-- Top row: the picker, previous and next, the count, then Library and
-- Settings. Then the file details, the six stored readings below a hairline,
-- and the reference's waveform with its ruler. Bottom row: playback (play,
-- pause, stop, loop), listening (latch, mono, pitch, Normalize) and the trim
-- bar. The playback group matches the docked Library's, cell for cell.
-- core/card_plan.lua decides which middle rows fit; the waveform takes the
-- spare height, so the card always fills the docker. With no room for the
-- readings, the Normalize menu shows them.
--
-- The bottom row is eight equal cells and the trim bar. On the top row the
-- arrows and Library and Settings are square buttons, so the name box gets
-- the rest of the width. Extra width goes to the cells and the name box.
local theme = require("ui.theme")
local tips = require("ui.tips")
local widgets = require("ui.widgets")
local match = require("core.match")
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

local TRIM_TIP = "Adjust the selected reference's remembered trim.\n"
  .. "Drag left or right \u{00B7} Alt for fine adjustment \u{00B7} click to type \u{00B7} right-click to reset"
local CELLS = 8
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
  local pad_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding()))
  measured.trim = math.ceil(reaper.ImGui_CalcTextSize(ctx, "Trim") + M.STRIP_GROUP_GAP
    + reaper.ImGui_CalcTextSize(ctx, "-60.0 dB") + 2 * pad_x)
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
  local content = math.max(CELLS * ctrl + 2 * gap + trim_width(ctx), r.two_w)
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
  return (w - trim_width(ctx) - 2 * M.STRIP_GROUP_GAP) / CELLS
end

-- What a card `w` wide shows at height `h` (core/card_plan.lua). Fills `out`,
-- or the card's own reused table.
function controls.plan(ctx, h, w, out)
  local s = measure_plan_sizes(ctx, w - 2 * M.STRIP_PAD)
  return card_plan.fit(h, s, out or card)
end

local cell = widgets.segment_cell

--------------------------------------------------------------- top row

-- Library and Settings.
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
  tips.show(ctx, reaper.ImGui_IsItemHovered(ctx),
    tips.with_shortcut(state, "settings", update_due and "Settings. An update is available" or "Settings"))
  widgets.end_segment(ctx, x0, y, x1, y + ctrl, 2)
  return action
end

-- The picker, previous and next, the count, then Library and Settings at the
-- right. The count is centred in its space, which fits the widest count, so
-- it has even room either side.
local function draw_top_row(ctx, state, res, x, y, w)
  local gap = M.STRIP_GROUP_GAP
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local app_x = w - 2 * ctrl
  local count_w = refpicker.count_width(ctx, state)
  local count_space = count_w > 0 and count_w + 2 * gap or gap
  local arrows_w = 2 * ctrl
  local arrows_x = app_x - count_space - arrows_w
  local name_end = arrows_x - gap

  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  local action = refpicker.draw_slot(ctx, state, res, math.max(1, name_end), "pin")
  if count_w > 0 then refpicker.draw_count(ctx, state, x + arrows_x + arrows_w, y, count_space) end
  local arrow_action = refpicker.draw_arrows(ctx, state, res, x + arrows_x, y, arrows_w)

  local app_action = draw_app(ctx, state, res and res.icon_font, x + app_x, x + w, y)
  return action or arrow_action or app_action
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
      trim_db = sel and sel.trim_db or 0,
      ruler = true, duration = sel and sel.duration or nil,
      -- Thin lanes overlay into one, as the Library's short waveform does.
      min_lane_h = M.BROWSER_PICKER_LANE_MIN_H,
      span_edit = true,
      span_start = sel and sel.span_start or nil,
      span_end = sel and sel.span_end or nil })
  return action, wave_id, wave_cols
end

--------------------------------------------------------------- bottom row

local main_slot = { slot = "main" }

-- Play, pause, stop, loop: the same group as the docked Library's.
local function draw_playback(ctx, state, font, x0, x1, y)
  main_slot.id, main_slot.sound = state.selected_id, state.selected
  return transport.draw_playback_group(ctx, state, font, main_slot, x0, x1, y,
    "loop", tips.with_shortcut(state, "loop", "Loop"))
end

-- Latch, mono, pitch, Normalize.
local function draw_listening(ctx, state, res, x0, x1, y)
  local font = res and res.icon_font
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  widgets.begin_segment(ctx, x0, y, x1, y + ctrl)

  local w = cell(ctx, x0, x1, 4, 0, y)
  local action = transport.draw_latch(ctx, state, font, w)

  w = cell(ctx, x0, x1, 4, 1, y)
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

  w = cell(ctx, x0, x1, 4, 2, y)
  transport.draw_pitch(ctx, state, font, "main", w)

  -- Normalize opens a dropdown of targets: rarely needed, so it stays hidden.
  w = cell(ctx, x0, x1, 4, 3, y)
  matchwin.draw_button(ctx, state, res, w)
  widgets.end_segment(ctx, x0, y, x1, y + ctrl, 4)
  return action
end

local function draw_trim(ctx, state, x, y, w)
  local action
  local sel = state.selected
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  local opts = { min = match.TRIM_SILENCE, max = match.TRIM_MAX, default = 0, taper = true,
    width = w, label = "Trim", edit_key = sel and sel.id or false }
  -- The bar keeps its drag and typed entry by id; a demonstration's copy must
  -- never cancel the live one's.
  local id = state.showcase and "showcase_trim" or "trim"
  if sel then
    opts.tip = TRIM_TIP
    local db, commit = widgets.db_bar(ctx, id, sel.trim_db, opts)
    if db ~= nil then action = { type = "set_trim", db = db, commit = commit } end
  else
    -- Present but disabled, so the card never changes shape.
    opts.tip = "Select a reference to adjust its trim."
    reaper.ImGui_BeginDisabled(ctx)
    widgets.db_bar(ctx, id, 0, opts)
    reaper.ImGui_EndDisabled(ctx)
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
  local column_x = w - trim_w
  local cell_w = controls.cell_width(ctx, b.w)

  local y = snap(top + p.pad)
  local bottom_y = snap(bottom_edge - p.pad - ctrl)
  local action = draw_top_row(ctx, state, res, x, y, w)
  y = y + ctrl

  local wave_action, wave_id, wave_cols, readings_action
  if p.wave > 0 then
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

  local playback_end = snap(x + 4 * cell_w)
  local listening_x = playback_end + group_gap
  local listening_end = snap(x + 8 * cell_w + group_gap)
  local playback_action = draw_playback(ctx, state, res and res.icon_font, x, playback_end, bottom_y)
  local listening_action = draw_listening(ctx, state, res, listening_x, listening_end, bottom_y)
  -- The tour points at Play and the latch together, then at the rest.
  walkthrough_ui.note_rect(ctx, state.walkthrough, "latch", x, bottom_y,
    widgets.segment_edge(listening_x, listening_end, 4, 1), bottom_y + ctrl)
  walkthrough_ui.note_rect(ctx, state.walkthrough, "transport", x, bottom_y, listening_end, bottom_y + ctrl)
  local trim_action = draw_trim(ctx, state, x + column_x, bottom_y, trim_w)
  action = action or readings_action or wave_action or playback_action or listening_action
    or trim_action

  -- Leave the cursor below the card so a short child can scroll to it.
  reaper.ImGui_SetCursorScreenPos(ctx, ox + g.strip.x, bottom_edge)
  reaper.ImGui_Dummy(ctx, 0, 0)
  return action, wave_id, wave_cols
end

-- The picker's list and the Normalize panel are separate windows. Submit them
-- after the strip so they never steal a click meant for a control beneath.
function controls.draw_popups(ctx, state, res)
  local action = refpicker.draw_popup(ctx, state, res)
  local match_action = matchwin.draw_popup(ctx, state, res)
  return action or match_action
end

return controls
