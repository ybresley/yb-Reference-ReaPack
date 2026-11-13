-- matchwin: Normalize — the target button beside the trim bar and the dropdown
-- menu it opens (DESIGN.md "Loudness").
--
-- The file, the module and every internal name stay `match*`: `core/match.lua`
-- owns the arithmetic and the saved preset keys, and renaming those would
-- throw away the user's stored presets for nothing.
--
-- Normalizing is occasional, so it stays behind the button. The menu lists the
-- preset targets, each showing the trim it would set, then a custom target
-- row, then Reset to Original Loudness (trim back to 0 dB) and Edit Presets.
-- Clicking a preset sets the trim at once (arithmetic, no analysis:
-- core/match.lua owns the numbers) and becomes the remembered target, named
-- in the button's tooltip. The menu stays open so several
-- targets can be compared. The readings live in the Reference card; when it is
-- too short for them, the menu shows them above the targets.
--
-- The menu is an ImGui popup, like the reference picker's list: it closes on
-- an outside click (the button included) or Escape.
--
-- A ui/ module: reaper.ImGui_* only. Reports intent as actions; the entry
-- script performs them.

local theme = require("ui.theme")
local decibels = require("core.decibels")
local icons = require("ui.icons")
local widgets = require("ui.widgets")
local tips = require("ui.tips")
local focus = require("ui.focus")
local match = require("core.match")
local anchored_panel = require("ui.anchored_panel")
local numeric_input = require("ui.numeric_input")
local readings = require("ui.readings")
-- Only for pins.drop_target — the tested "insertion gap -> final position"
-- arithmetic the picker's reorder drag uses; the preset list reorders with
-- exactly the same gesture and must not re-derive that off-by-one.
local pins = require("core.pins")
local T = theme.tokens
local M = theme.metrics

local matchwin = {}

local POPUP_ID = "normalize_menu"

-- Transient view state (the refpicker idiom). Never on the shared `state`.
local ui = {
  -- `open` mirrors the popup as of its last drawn frame; `open_request` and
  -- `close_request` are handed to the popup on its next draw.
  open = false,
  open_request = false,
  close_request = false,
  -- The button's rect: the menu opens under it with matching left edges, as the
  -- other anchored panels do, or above it when the screen ends too close below.
  anchor_x0 = nil, anchor_y = nil, anchor_y1 = nil,
  rect = nil, -- last drawn frame's menu rect
  settle = 0,
  place = nil, -- { x, y, pivot_y, max_h } chosen while opening
  edit_mode = false,
  custom_unit = 1, -- 0-based Combo index into UNITS
  custom_text = "-16",
  edit_index = nil, -- preset whose values are loaded into the target row
  drag_index = nil, -- the preset being dragged by its row body (edit mode)
  normalize_pending = nil, -- waits for the owner to apply a requested trim
  motion_generation = nil,
  -- The Reference card has no room for the readings, so the menu shows them.
  show_readings = false,
}

-- The cursor shown over a draggable preset row — same detection refpicker uses.
local REORDER_CURSOR = (reaper.ImGui_MouseCursor_ResizeNS and reaper.ImGui_MouseCursor_ResizeNS())
  or (reaper.ImGui_MouseCursor_Hand and reaper.ImGui_MouseCursor_Hand())
  or nil

-- Preset row rectangles from the last drawn frame, reused in place (frame
-- rules) — the reorder drag resolves against what is actually on screen.
local prow_rects, prow_n = {}, 0

-- The six units, in the dropdown's established order. Every name is spelled
-- out (user's call, 2026-08-07). The name that follows a preset's VALUE
-- ("-16 LUFS-M") comes from core/match.lua, so the menu and the status line
-- share one vocabulary there.
local UNITS = {
  { key = "lufs_s_max", tag = "LUFS-S",    combo = "LUFS-S" },
  { key = "lufs_m_max", tag = "LUFS-M",    combo = "LUFS-M" },
  { key = "lufs_i",     tag = "LUFS-I",    combo = "LUFS-I" },
  { key = "true_peak",  tag = "True Peak", combo = "True Peak" },
  { key = "peak",       tag = "Peak",      combo = "Peak" },
  { key = "rms",        tag = "RMS",       combo = "RMS" },
}

-- Built once (frame-allocation rule). This ReaImGui's Combo takes the C API's
-- NUL-separated items and REQUIRES the trailing NUL — it raises
-- "items must be null-terminated" without it (live-verified 2026-08-06).
local COMBO_ITEMS
do
  local parts = {}
  for i, u in ipairs(UNITS) do parts[i] = u.combo end
  COMBO_ITEMS = table.concat(parts, "\0") .. "\0"
end

local HEADING = "NORMALIZE TO"
local READINGS_HEADING = "MEASUREMENTS"
local EDITING_TEXT = "Editing…"
local APPLY_TEXT = "Apply"
local UNIT = "dB"
local EMPTY_TEXT = "No presets yet. Choose Edit Presets to add one."
local EMPTY_EDIT_TEXT = "Set a target below, then choose Add."

local function combo_index(unit)
  for i, u in ipairs(UNITS) do
    if u.key == unit then return i - 1 end
  end
  return 0
end

local function unit_label(key)
  return match.label(key)
end

-- What the measurement is called in the dropdown, for sentences that name it.
local function measurement_name(key)
  for _, u in ipairs(UNITS) do
    if u.key == key then return u.tag end
  end
  return match.label(key)
end

-- "-16 LUFS-M" — how a target names itself, in the tooltip and on preset rows.
-- %g keeps a whole-number target free of a pointless ".0".
local function fmt_target(unit, value)
  return string.format("%g %s", value, unit_label(unit))
end

-- Preset trims and the controls use the same rounding and sign rules.
local function fmt_trim(db)
  return decibels.format(db) .. " dB"
end

local function fmt_shortfall(required, trim)
  return string.format("%.1f dB short", math.abs(required - trim))
end

-- One decimal, the precision both the row and the trim bar show. Two trims
-- that read "-3.2 dB" are the same trim as far as the reader is concerned.
local function round1(v) return math.floor(v * 10 + 0.5) / 10 end

-- Snap to a whole pixel: a glyph run at a fractional origin renders softer.
local function px(v) return math.floor(v + 0.5) end

local function draw_limit_marker(ctx, dl, right, y0, y1, colour)
  local marker = "!"
  local mw, mh = reaper.ImGui_CalcTextSize(ctx, marker)
  reaper.ImGui_DrawList_AddText(dl, px(right - mw),
    px((y0 + y1) * 0.5 - mh * 0.5), colour, marker)
end

-- Whether the menu shows the readings, set by the Reference card each frame.
function matchwin.set_show_readings(show)
  ui.show_readings = show
end

-- Whether the menu stands open (or is about to, this frame). open_request
-- counts, or callers would lag the click that opened it by a frame.
function matchwin.is_open()
  return (ui.open or ui.open_request) and not ui.close_request
end

-- Open it from somewhere other than the button, at the button's rect
-- (x_left is its left edge).
function matchwin.open_at(x_left, y_top, y_bottom, options)
  if ui.open then return end
  ui.open_request, ui.close_request = true, false
  ui.edit_mode = false
  ui.edit_index = nil
  if options then
    ui.edit_mode = options.edit_mode == true
    ui.edit_index = options.edit_index
    if options.target then
      ui.custom_unit = combo_index(options.target.unit)
      ui.custom_text = tostring(options.target.value)
    end
    ui.drag_index = nil
  end
  ui.anchor_x0, ui.anchor_y, ui.anchor_y1 = x_left, y_top, y_bottom
end

-- Shut it from outside. Clears a pending open too, so a close on the very
-- frame it was asked for can't leave it opening anyway.
function matchwin.close()
  ui.open_request = false
  if ui.open then ui.close_request = true end
  ui.normalize_pending = nil
end

--------------------------------------------------------------- the button

-- The target icon, centred.
local function paint_button_face(ctx, font, colour)
  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
  local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
  colour = theme.fade(colour, alpha)
  local cx, cy = px((x0 + x1) * 0.5), (y0 + y1) * 0.5
  if not icons.paint_glyph(ctx, font, "target", cx, cy, colour, M.ICON_FS) then
    icons.draw_target(reaper.ImGui_GetWindowDrawList(ctx), cx, cy, colour)
  end
end

-- width: the Reference card's Normalize cell.
function matchwin.draw_button(ctx, state, res, width)
  local font = res and res.icon_font
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  -- A release demonstration's button never shows the live menu as open.
  local shown_open = not state.showcase and matchwin.is_open()
  -- While the menu is open it blocks this button, so a press here only
  -- closes the menu (ImGui's outside click) and its release opens nothing.
  if widgets.panel_button_frame(ctx, "##matchtarget", width or ctrl, ctrl, shown_open)
      and not state.showcase then
    ui.open_request, ui.close_request = true, false
    ui.edit_mode, ui.edit_index = false, nil
    ui.anchor_x0, ui.anchor_y = reaper.ImGui_GetItemRectMin(ctx)
    ui.anchor_y1 = select(2, reaper.ImGui_GetItemRectMax(ctx))
  end
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local colour = shown_open and T.ACCENT_HOVER
    or (hovered and T.TEXT_PRIMARY or T.TEXT_SECONDARY)
  paint_button_face(ctx, font, colour)
  if hovered and not shown_open then
    local target = state.match and state.match.target
    tips.show(ctx, true, (ui.show_readings
      and "Normalize the selected reference to a loudness target, and see its measurements."
      or "Normalize the selected reference to a loudness target.")
      .. (target and ("\nRemembered target: " .. fmt_target(target.unit, target.value)) or ""))
  end
  return nil -- opening is view state; every action comes from the menu
end

--------------------------------------------------------------- preset rows

-- One preset row: the target on the left, the trim it would set on the right
-- (edit mode: edit and remove controls instead). The shown trim IS the capped
-- value — clicking sets exactly what the row promised, never more.
local function draw_preset_row(ctx, state, res, sel, p, i, width)
  local action
  local font = res and res.icon_font
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local pad_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding()))

  -- One computation feeds the preview, the flag, the tooltip and the click, so
  -- they can never disagree. The second return is the cap that bit when a trim
  -- came back, or the reason when none did.
  local trim, aux = match.trim_for(sel, p.unit, p.value)
  local limited = trim and aux or nil
  local why = (not trim) and aux or nil
  local clickable = (not ui.edit_mode) and trim ~= nil and sel ~= nil

  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  local x1, y1 = x0 + width, y0 + ctrl
  local dl = reaper.ImGui_GetWindowDrawList(ctx)

  -- The hit area stops short of edit mode's controls so it can't swallow their
  -- clicks (the refpicker row idiom). Rows sit flush: zero vertical spacing
  -- around the row item only.
  local spacing_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))
  local icon_tools_w = M.PICK_TOOL_W * 2 + M.PICK_TOOL_GAP
  local editing_w, editing_h = reaper.ImGui_CalcTextSize(ctx, EDITING_TEXT)
  local tools_w = icon_tools_w + M.PICK_TOOL_GAP + editing_w
  local hit_w = ui.edit_mode and (width - tools_w - M.PICK_TOOL_LEAD) or width
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), spacing_x, 0)
  local pressed = reaper.ImGui_InvisibleButton(ctx, "##matchpreset_" .. i, math.max(1, hit_w), ctrl)
  reaper.ImGui_PopStyleVar(ctx, 1)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local held = reaper.ImGui_IsItemActive(ctx)

  -- Remembered for the reorder drag (reused in place, never re-allocated).
  prow_n = prow_n + 1
  local r = prow_rects[prow_n]
  if not r then r = {}; prow_rects[prow_n] = r end
  r.y0, r.y1 = y0, y1

  local editing_this = ui.edit_mode and ui.edit_index == i
  local row_fill = editing_this and T.FILL_SECONDARY
    or (hovered and (clickable or ui.edit_mode) and T.FILL_TERTIARY or nil)
  if row_fill then
    reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x1, y1, row_fill, 4)
  end

  -- ACCENT means "the trim is AT this row right now" — nothing else. A hand
  -- trim elsewhere clears it (user-reported 2026-08-07).
  local at_this = trim ~= nil and sel ~= nil
    and round1(sel.trim_db or 0) == round1(trim)
  local label = fmt_target(p.unit, p.value)
  local lh = select(2, reaper.ImGui_CalcTextSize(ctx, label))
  local text_y = px((y0 + y1) * 0.5 - lh * 0.5)
  reaper.ImGui_DrawList_AddText(dl, px(x0 + pad_x), text_y,
    at_this and T.ACCENT or T.TEXT_SECONDARY, label)

  if ui.edit_mode then
    -- Edit mode: the row body is the reorder handle (the picker's exact
    -- gesture — the click already means nothing here, so the body is free).
    if held and reaper.ImGui_IsMouseDragging(ctx, 0) then
      ui.drag_index = i
      ui.edit_index = nil
    end
    if hovered and REORDER_CURSOR then reaper.ImGui_SetMouseCursor(ctx, REORDER_CURSOR) end
    local pencil_x = x1 - pad_x - icon_tools_w
    if editing_this then
      reaper.ImGui_DrawList_AddText(dl,
        px(pencil_x - M.PICK_TOOL_GAP - editing_w),
        px((y0 + y1) * 0.5 - editing_h * 0.5), T.ACCENT, EDITING_TEXT)
    end
    reaper.ImGui_SetCursorScreenPos(ctx, pencil_x, y0)
    if widgets.glyph_button(ctx, font, "matchedit_" .. i, "pencil", "\u{270E}",
        M.PICK_TOOL_W, ctrl, "Edit this preset", T.TEXT_PRIMARY) then
      ui.custom_unit = combo_index(p.unit)
      ui.custom_text = tostring(p.value)
      ui.edit_index = i
    end
    reaper.ImGui_SameLine(ctx, 0, M.PICK_TOOL_GAP)
    if widgets.glyph_button(ctx, font, "matchdel_" .. i, "x", "\u{2715}",
        M.PICK_TOOL_W, ctrl, "Remove this preset", T.DANGER_RED) then
      action = { type = "remove_match_preset", index = i }
      ui.edit_index = nil
    end
    reaper.ImGui_SetCursorScreenPos(ctx, x0, y1)
  else
    -- The trim this preset would set, laid out like the measurements card:
    -- the value ends on a fixed "dB" column. "—" when this sound has no
    -- number in the preset's unit. The "!" sits at one x, left of the widest
    -- possible reading, so it never wanders with the digits.
    local unit_w = M.STRIP_UNIT_GAP + reaper.ImGui_CalcTextSize(ctx, UNIT)
    local right = x1 - pad_x
    if trim then
      local text = decibels.format(trim)
      local tw = reaper.ImGui_CalcTextSize(ctx, text)
      reaper.ImGui_DrawList_AddText(dl, px(right - unit_w - tw), text_y, T.TEXT_PRIMARY, text)
      reaper.ImGui_DrawList_AddText(dl, px(right - unit_w + M.STRIP_UNIT_GAP), text_y, T.TEXT_TERTIARY, UNIT)
    else
      local tw = reaper.ImGui_CalcTextSize(ctx, "\u{2014}")
      reaper.ImGui_DrawList_AddText(dl, px(right - unit_w - tw), text_y, T.TEXT_QUATERNARY, "\u{2014}")
    end
    if limited then
      -- The exact shortfall is in the tooltip so the row keeps its height.
      local zone = reaper.ImGui_CalcTextSize(ctx, "+24.0")
      draw_limit_marker(ctx, dl, right - unit_w - zone - M.ITEM_SPACING_X, y0, y1, T.DANGER_RED)
    end

    if pressed and clickable then
      -- The menu STAYS OPEN on a pick: comparing targets means clicking several.
      action = { type = "match_trim", db = trim, limited = limited, unit = p.unit, value = p.value }
    end
  end

  if hovered then
    local tip
    if ui.edit_mode then
      tip = "Drag to reorder"
    elseif not sel then
      tip = "Choose a reference first."
    elseif why == "unmeasured" then
      tip = "No " .. measurement_name(p.unit) .. " measurement is available. It may still be analysing, or the audio may have no measurable signal."
    elseif limited == "range" then
      local shortfall = fmt_shortfall(p.value - sel[p.unit], trim)
      tip = shortfall .. " of the target. Selecting it applies "
        .. fmt_trim(trim) .. ", the maximum."
    else
      tip = "Set the selected reference's trim to " .. fmt_trim(trim) .. "."
    end
    tips.show(ctx, hovered, tip, nil, tips.rect(x0, y0, x1 - x0, y1 - y0))
  end

  return action
end

--------------------------------------------------------------- the target row

-- Unit dropdown, typed number and Apply. In edit mode the button becomes Add,
-- or Save after a row's pencil loads that preset into the same two inputs.
local function draw_target_row(ctx, sel, presets, width)
  local action, limit_text
  -- The sweep follows the state that the owner has actually applied, rather
  -- than the click that requested it. This keeps failed or superseded actions
  -- from looking confirmed.
  local confirmed = false
  if theme.motion.enabled and ui.normalize_pending then
    confirmed = sel and sel.id == ui.normalize_pending.id
      and math.abs((sel.trim_db or 0) - ui.normalize_pending.db) < 0.001
    -- A one-frame acknowledgement: a later hand trim must not make an old
    -- Apply click look confirmed.
    ui.normalize_pending = nil
  end

  -- The Combo paints its arrow square Col_Button and its text area FrameBg —
  -- two different fills in this theme, a seam the user read as a mistake
  -- (2026-08-06). The arrow zone takes the frame's own fills instead.
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
    reaper.ImGui_GetStyleColor(ctx, reaper.ImGui_Col_FrameBg()))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),
    reaper.ImGui_GetStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered()))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),
    reaper.ImGui_GetStyleColor(ctx, reaper.ImGui_Col_FrameBgActive()))
  reaper.ImGui_SetNextItemWidth(ctx, M.MATCH_UNIT_W)
  local changed, idx = reaper.ImGui_Combo(ctx, "##matchunit", ui.custom_unit, COMBO_ITEMS)
  reaper.ImGui_PopStyleColor(ctx, 3)
  if changed then ui.custom_unit = idx end
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, M.MATCH_VAL_W)
  local edited, text = numeric_input.text(ctx, "##matchvalue", ui.custom_text,
    "signed_decimal")
  if edited then ui.custom_text = text end
  reaper.ImGui_SameLine(ctx)

  local unit = UNITS[ui.custom_unit + 1]
  local value = tonumber(ui.custom_text)
  local btn_w = width - M.MATCH_UNIT_W - M.MATCH_VAL_W
    - select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing())) * 2
  if ui.edit_mode then
    if ui.edit_index and not presets[ui.edit_index] then ui.edit_index = nil end
    local editing = ui.edit_index ~= nil
    local full = not editing and #presets >= match.PRESET_MAX
    -- The same target twice would be two rows doing one job (user's rule,
    -- 2026-08-06). An edited row excludes itself from the check.
    local dup = unit and value
      and match.preset_exists(presets, unit.key, value, ui.edit_index) or false
    local ok_save = unit and value and not full and not dup
    if not ok_save then reaper.ImGui_BeginDisabled(ctx) end
    local button = editing and "Save##matcheditpreset" or "Add##matchadd"
    if reaper.ImGui_Button(ctx, button, btn_w, 0) and ok_save then
      action = { type = editing and "edit_match_preset" or "add_match_preset",
        index = ui.edit_index, unit = unit.key, value = value }
      ui.edit_index = nil
    end
    if not ok_save then reaper.ImGui_EndDisabled(ctx) end
    local tip = editing and "Save changes to this preset." or "Save this target as a preset."
    if dup then tip = "This target is already another preset."
    elseif full then tip = "The preset list is full (" .. match.PRESET_MAX .. "). Remove a preset first." end
    tips.show(ctx, reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_AllowWhenDisabled()), tip)
  else
    local trim, aux
    if unit and value then trim, aux = match.trim_for(sel, unit.key, value) end
    if trim and aux == "range" and sel and type(sel[unit.key]) == "number" then
      limit_text = fmt_shortfall(value - sel[unit.key], trim)
    end
    local why = (not trim) and aux or nil
    local ok_match = trim ~= nil and sel ~= nil
    if not ok_match then reaper.ImGui_BeginDisabled(ctx) end
    local clicked = reaper.ImGui_Button(ctx, APPLY_TEXT .. "##matchcustom", btn_w, 0)
    local button_hovered = reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_AllowWhenDisabled())
    if limit_text then
      local _, by0 = reaper.ImGui_GetItemRectMin(ctx)
      local bx1, by1 = reaper.ImGui_GetItemRectMax(ctx)
      local alpha = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha()))
      draw_limit_marker(ctx, reaper.ImGui_GetWindowDrawList(ctx),
        bx1 - M.FRAME_PAD_X, by0, by1, theme.fade(T.DANGER_RED, alpha))
    end
    if clicked and ok_match then
      action = { type = "match_trim", db = trim, limited = trim and aux or nil,
        unit = unit.key, value = value }
      if theme.motion.enabled then
        ui.normalize_pending = { id = sel.id, db = trim }
      end
    end
    if not ok_match then reaper.ImGui_EndDisabled(ctx) end
    local sweep = widgets.motion_event(ctx, "match_normalize_sheen", true, 0.62, confirmed)
    if sweep then
      -- A quiet satin pass is paint-only, so the button stays usable.
      local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
      local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
      local span = x1 - x0
      local centre = x0 + span * (-0.35 + sweep * 1.7)
      local half = math.max(3 * theme.scale, span * 0.22)
      local dl = reaper.ImGui_GetWindowDrawList(ctx)
      local alpha = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha()))
      local clear = T.TEXT_PRIMARY & 0xFFFFFF00
      local light = theme.fade(T.TEXT_PRIMARY, 0.30 * alpha)
      reaper.ImGui_DrawList_PushClipRect(dl, x0, y0, x1, y1, true)
      reaper.ImGui_DrawList_AddRectFilledMultiColor(dl, centre - half, y0,
        centre, y1, clear, light, light, clear)
      reaper.ImGui_DrawList_AddRectFilledMultiColor(dl, centre, y0,
        centre + half, y1, light, clear, clear, light)
      reaper.ImGui_DrawList_PopClipRect(dl)
      -- Repaint the label over the brighter pass to keep its contrast.
      local tw, th = reaper.ImGui_CalcTextSize(ctx, APPLY_TEXT)
      local text_col = theme.fade(reaper.ImGui_GetStyleColor(ctx,
        reaper.ImGui_Col_Text()), alpha)
      reaper.ImGui_DrawList_AddText(dl, x0 + (span - tw) * 0.5,
        y0 + (y1 - y0 - th) * 0.5, text_col, APPLY_TEXT)
    end
    local tip
    if not value then tip = "Type a target value first."
    elseif not sel then tip = "Choose a reference first."
    elseif why == "unmeasured" then
      tip = "No " .. measurement_name(unit.key) .. " measurement is available. It may still be analysing, or the audio may have no measurable signal."
    elseif trim then tip = "Set the selected reference's trim to " .. fmt_trim(trim) .. "." end
    if limit_text then
      tip = limit_text .. " of the target. Apply sets "
        .. fmt_trim(trim) .. ", the maximum."
    end
    tips.show(ctx, button_hovered, tip)
  end
  return action
end

--------------------------------------------------------------- menu pieces

-- The preset reorder drag (edit mode), resolved against the rows just drawn —
-- the picker's exact mechanics: an insertion line at the gap while held, the
-- move itself on release, the tested gap arithmetic in core.
local function resolve_drag(ctx, presets, x, width)
  if not ui.drag_index then return nil end
  local action
  local gap_i = nil
  if prow_n > 0 then
    local my = select(2, reaper.ImGui_GetMousePos(ctx))
    for ri = 1, prow_n do
      if my < (prow_rects[ri].y0 + prow_rects[ri].y1) * 0.5 then gap_i = ri break end
    end
    gap_i = gap_i or (prow_n + 1)
    local edge = prow_rects[gap_i] and prow_rects[gap_i].y0
      or (prow_rects[prow_n] and prow_rects[prow_n].y1)
    if edge then
      reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(ctx),
        x, edge - 1, x + width, edge - 1, T.ACCENT, 2)
    end
  end
  if not reaper.ImGui_IsMouseDown(ctx, 0) then
    local to = gap_i and pins.drop_target(ui.drag_index, gap_i) or nil
    if to and presets[ui.drag_index] then
      action = { type = "reorder_match_preset", from = ui.drag_index, to = to }
    end
    ui.drag_index = nil
  end
  return action
end

-- Reset to Original Loudness: trim back to 0 dB, so the reference plays as
-- recorded. A committed set_trim, the same as the trim bar's right-click.
-- Disabled with nothing selected or no trim to remove, so the row never moves.
local RESET_TEXT = "Reset to Original Loudness"
local function draw_reset_item(ctx, sel, width)
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local pad_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding()))
  local live = sel ~= nil and round1(sel.trim_db or 0) ~= 0
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  local clicked = reaper.ImGui_InvisibleButton(ctx, "##matchreset", width, ctrl)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  if live and hovered then
    reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + width, y0 + ctrl, T.FILL_TERTIARY, 4)
  end
  local lh = select(2, reaper.ImGui_CalcTextSize(ctx, RESET_TEXT))
  local colour = not live and T.TEXT_QUATERNARY or (hovered and T.TEXT_PRIMARY or T.TEXT_SECONDARY)
  reaper.ImGui_DrawList_AddText(dl, px(x0 + pad_x), px(y0 + (ctrl - lh) * 0.5), colour, RESET_TEXT)
  tips.show(ctx, hovered, live
    and "Set the trim back to 0 dB so the reference plays at its recorded level."
    or (sel and "The reference already plays at its recorded level." or "Select a reference first."))
  if clicked and live then return { type = "set_trim", db = 0, commit = true } end
  return nil
end

-- Edit Presets / Done: a menu row rather than a full button, since it is the
-- least used thing here.
local function draw_edit_item(ctx, width)
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local pad_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding()))
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  if reaper.ImGui_InvisibleButton(ctx, "##matchedit", width, ctrl) then
    ui.edit_mode = not ui.edit_mode
    ui.edit_index = nil
  end
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  if hovered then
    reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + width, y0 + ctrl, T.FILL_TERTIARY, 4)
  end
  local label = ui.edit_mode and "Done" or "Edit Presets"
  local lh = select(2, reaper.ImGui_CalcTextSize(ctx, label))
  reaper.ImGui_DrawList_AddText(dl, px(x0 + pad_x), px(y0 + (ctrl - lh) * 0.5),
    ui.edit_mode and T.ACCENT_HOVER or (hovered and T.TEXT_PRIMARY or T.TEXT_SECONDARY), label)
  tips.show(ctx, hovered, ui.edit_mode
    and "Finish editing the preset list"
    or "Add, edit, remove and reorder preset targets")
end

-- Chooses the menu's side and position while it opens: right-aligned under the
-- button, or above it when the screen ends too close below. The first frame
-- estimates the height; the second uses the measured one.
local function place_menu(ctx, res, presets, outer_width)
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local est_h = 2 * M.WINDOW_PAD + (#presets + 5) * ctrl + 6 * M.ITEM_SPACING_Y
    + (ui.show_readings and (ctrl + 3 * M.STRIP_READING_H + 2 * M.ITEM_SPACING_Y) or 0)
  local measured_h = ui.rect and (ui.rect.y2 - ui.rect.y1) or 0
  local height = math.max(est_h, measured_h)
  local anchor = {
    left = ui.anchor_x0, right = ui.anchor_x0,
    top = ui.anchor_y, bottom = ui.anchor_y1 or ui.anchor_y,
  }
  local geometry, work = anchored_panel.place(ctx, res, anchor, {
    width = outer_width, height = height, min_height = 0,
    gap = M.PANEL_ANCHOR_GAP, margin = M.PICK_SCREEN_MARGIN, prefer_above = false,
  })
  local above = geometry.y < anchor.top
  local edge = above and (anchor.top - M.PANEL_ANCHOR_GAP)
    or (anchor.bottom + M.PANEL_ANCHOR_GAP)
  local top = work.top + M.PICK_SCREEN_MARGIN
  ui.place = ui.place or {}
  ui.place.x, ui.place.y, ui.place.pivot_y = geometry.x, edge, above and 1 or 0
  ui.place.max_h = above and math.max(0, edge - top)
    or anchored_panel.available_height(work, edge, M.PICK_SCREEN_MARGIN)
end

--------------------------------------------------------------- the menu

function matchwin.draw_popup(ctx, state, res)
  local action
  local width = M.MATCH_WIN_W
  if ui.show_readings then width = math.max(width, math.ceil(readings.measure(ctx).two_w)) end
  local outer_width = width + M.WINDOW_PAD * 2
  local presets = (state.match and state.match.presets) or {}

  if theme.motion.enabled and ui.motion_generation ~= theme.motion.generation then
    ui.motion_generation = theme.motion.generation
    ui.normalize_pending = nil
  end

  if ui.open_request then
    ui.open_request = false
    ui.rect, ui.settle = nil, 0
    reaper.ImGui_OpenPopup(ctx, POPUP_ID)
  end

  if ui.anchor_x0 and reaper.ImGui_IsPopupOpen(ctx, POPUP_ID) then
    if ui.settle < 2 or ui.scale ~= theme.scale then place_menu(ctx, res, presets, outer_width) end
    ui.scale = theme.scale
    reaper.ImGui_SetNextWindowPos(ctx, ui.place.x, ui.place.y,
      reaper.ImGui_Cond_Always(), 0, ui.place.pivot_y)
    -- A menu taller than the room scrolls; its scrollbar gets its own width
    -- so the rows keep theirs and nothing at their right edge is cut off.
    local window_w = outer_width
    if ui.scrolls then
      window_w = window_w + reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ScrollbarSize())
    end
    reaper.ImGui_SetNextWindowSizeConstraints(ctx, window_w, 0, window_w, ui.place.max_h)
  end

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), M.WINDOW_PAD, M.WINDOW_PAD)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(), T.BG_WINDOW)
  local opened = reaper.ImGui_BeginPopup(ctx, POPUP_ID, reaper.ImGui_WindowFlags_NoMove())
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_PopStyleVar(ctx, 1)
  ui.open = opened
  if not opened then
    ui.close_request, ui.drag_index, ui.edit_index = false, nil, nil
    ui.edit_mode, ui.scrolls = false, false
    return nil
  end
  ui.scrolls = reaper.ImGui_GetScrollMaxY(ctx) > 0

  local wx, wy = reaper.ImGui_GetWindowPos(ctx)
  local ww, wh = reaper.ImGui_GetWindowSize(ctx)
  ui.rect = ui.rect or {}
  ui.rect.x1, ui.rect.y1, ui.rect.x2, ui.rect.y2 = wx, wy, wx + ww, wy + wh
  ui.settle = ui.settle + 1

  local sel = state.selected
  local heading
  if ui.show_readings then
    heading = theme.push_heading_font(ctx)
    reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, READINGS_HEADING)
    if heading then reaper.ImGui_PopFont(ctx) end
    local rx, ry = reaper.ImGui_GetCursorScreenPos(ctx)
    local row_h = M.STRIP_READING_H
    readings.draw_columns(ctx, reaper.ImGui_GetWindowDrawList(ctx), sel, rx, ry, width, row_h)
    reaper.ImGui_Dummy(ctx, width, 3 * row_h)
    reaper.ImGui_Separator(ctx)
  end
  heading = theme.push_heading_font(ctx)
  reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, HEADING)
  if heading then reaper.ImGui_PopFont(ctx) end

  local rows_x = reaper.ImGui_GetCursorScreenPos(ctx)
  prow_n = 0
  for i, p in ipairs(presets) do
    local row_action = draw_preset_row(ctx, state, res, sel, p, i, width)
    action = action or row_action
  end
  if #presets == 0 then
    reaper.ImGui_PushTextWrapPos(ctx, reaper.ImGui_GetCursorPosX(ctx) + width)
    reaper.ImGui_TextColored(ctx, T.TEXT_QUATERNARY, ui.edit_mode and EMPTY_EDIT_TEXT or EMPTY_TEXT)
    reaper.ImGui_PopTextWrapPos(ctx)
  else
    -- The rows sit flush, which also swallows the gap after the last row. A
    -- zero-height item hands the theme's normal spacing back.
    reaper.ImGui_Dummy(ctx, 0, 0)
  end
  local drag_action = resolve_drag(ctx, presets, rows_x, width)
  action = action or drag_action

  reaper.ImGui_Separator(ctx)
  local target_action = draw_target_row(ctx, sel, presets, width)
  action = action or target_action
  reaper.ImGui_Separator(ctx)
  local reset_action = draw_reset_item(ctx, sel, width)
  action = action or reset_action
  draw_edit_item(ctx, width)

  local escape = reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_RootAndChildWindows())
    and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape())
  if ui.close_request or escape then
    ui.close_request = false
    ui.normalize_pending = nil
    reaper.ImGui_CloseCurrentPopup(ctx)
    -- Escape leaves the menu that had focus; hand it back to REAPER.
    if escape then focus.request() end
  end
  reaper.ImGui_EndPopup(ctx)
  return action
end

return matchwin
