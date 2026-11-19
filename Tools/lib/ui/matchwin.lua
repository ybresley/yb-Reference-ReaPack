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
local own_level = require("core.own_level")
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
  -- The Reaper Measurement's settings page shows in place of the menu.
  settings_page = false,
  -- The menu's height, kept so the settings page and the return from it draw
  -- at that same size. The window fits its content one frame late, so
  -- without this the swap shows one frame at the wrong size.
  menu_h = nil,
  returning = false,
}

local function set_settings_page(on)
  if ui.settings_page and not on then ui.returning = true end
  ui.settings_page = on
end

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

local HEADING = "NORMALIZE REFERENCE TO..."
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
  -- The panel stays open through clicks elsewhere, so this button is its
  -- switch: one click opens it, the next closes it.
  if widgets.panel_button_frame(ctx, "##matchtarget", width or ctrl, ctrl, shown_open)
      and not state.showcase then
    if matchwin.is_open() then
      matchwin.close()
    else
      ui.open_request, ui.close_request = true, false
      ui.edit_mode, ui.edit_index = false, nil
      ui.anchor_x0, ui.anchor_y = reaper.ImGui_GetItemRectMin(ctx)
      ui.anchor_y1 = select(2, reaper.ImGui_GetItemRectMax(ctx))
    end
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

--------------------------------------------------------------- target locks

-- Every normalize target ends in a small lock. A locked target holds every
-- pinned reference at that level, so the row itself says what the lock uses.

-- The width a row gives up for its lock, gap included.
local function lock_space() return M.PICK_TOOL_W + M.PICK_TOOL_GAP end

local function lock_holds(own, kind, unit, value)
  local held = own.lock and own.target
  if not held or held.kind ~= kind then return false end
  return kind == "own" or (held.unit == unit and held.value == value)
end

local function lock_tip(name, on, missing)
  if not name then return missing end
  if on then return "Every pinned reference is kept at " .. name .. ". Click to unlock." end
  return "Lock every pinned reference to " .. name .. ". Pins you add later follow. "
    .. "A reference you trim by hand keeps its own trim."
end

-- One lock at (x, y). `kind` is "own" or "fixed" (with unit and value);
-- `missing` is true while the row has no usable target yet. A lock that is on
-- can always be clicked off, even after its target stopped being usable.
-- Returns the action, whether the pointer is on the lock, and whether this
-- target is the locked one; the caller shows the tooltip, so its text is built
-- only on hover.
local function draw_target_lock(ctx, res, state, id, kind, unit, value, x, y, h, missing)
  local on = lock_holds(state.own_level, kind, unit, value)
  local usable = on or not missing
  local w = M.PICK_TOOL_W
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  local clicked = reaper.ImGui_InvisibleButton(ctx, "##matchlock_" .. id, w, h)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  if on then
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + w, y + h,
      hovered and T.ACTIVE_CONTROL_HOVER or T.ACTIVE_CONTROL_FILL, 4)
  elseif usable and hovered then
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + w, y + h, T.FILL_TERTIARY, 4)
  end
  local colour = on and (hovered and T.ACCENT_HOVER or T.ACCENT)
    or (not usable and T.TEXT_QUATERNARY)
    or (hovered and T.TEXT_PRIMARY or T.TEXT_TERTIARY)
  if not icons.paint_glyph(ctx, res and res.icon_font, "lock", px(x + w * 0.5), y + h * 0.5, colour) then
    local fw, fh = reaper.ImGui_CalcTextSize(ctx, "L")
    reaper.ImGui_DrawList_AddText(dl, px(x + (w - fw) * 0.5), px(y + (h - fh) * 0.5), colour, "L")
  end
  local action
  if clicked and usable then
    local target
    if not on then
      target = kind == "own" and { kind = "own" } or { kind = "fixed", unit = unit, value = value }
    end
    action = { type = "set_level_lock", on = not on, target = target }
  end
  return action, hovered, on
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
  -- The row ends where its lock begins; edit mode's tools take that place.
  local lock_w = (ui.show_own and not ui.edit_mode) and lock_space() or 0
  local x1, y1 = x0 + width - lock_w, y0 + ctrl
  local dl = reaper.ImGui_GetWindowDrawList(ctx)

  -- The hit area stops short of edit mode's controls so it can't swallow their
  -- clicks (the refpicker row idiom). Rows sit flush: zero vertical spacing
  -- around the row item only.
  local spacing_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))
  local icon_tools_w = M.PICK_TOOL_W * 2 + M.PICK_TOOL_GAP
  local editing_w, editing_h = reaper.ImGui_CalcTextSize(ctx, EDITING_TEXT)
  local tools_w = icon_tools_w + M.PICK_TOOL_GAP + editing_w
  local hit_w = ui.edit_mode and (width - tools_w - M.PICK_TOOL_LEAD) or (width - lock_w)
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
    if ui.show_own then
      local lock_action, lock_hovered, on = draw_target_lock(ctx, res, state, "preset_" .. i,
        "fixed", p.unit, p.value, x0 + width - M.PICK_TOOL_W, y0, ctrl)
      if lock_hovered then tips.show(ctx, true, lock_tip(label, on)) end
      action = lock_action or action
      reaper.ImGui_SetCursorScreenPos(ctx, x0, y1)
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
local function draw_target_row(ctx, state, res, sel, presets, width)
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
  local with_lock = ui.show_own and not ui.edit_mode
  local btn_w = width - M.MATCH_UNIT_W - M.MATCH_VAL_W
    - select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing())) * 2
    - (with_lock and lock_space() or 0)
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
    local apply_x1 = reaper.ImGui_GetItemRectMax(ctx)
    local apply_y0 = select(2, reaper.ImGui_GetItemRectMin(ctx))
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
    if with_lock then
      -- The lock takes the typed target as it stands: no Apply first.
      local ready = unit ~= nil and value ~= nil
      local lock_unit, lock_value = unit and unit.key, value
      -- A locked target that no row shows any more (the typed number changed,
      -- or its preset was edited or removed) is shown here, so an active lock
      -- is always visible and can always be clicked off.
      local held = state.own_level.lock and state.own_level.target
      if held and held.kind == "fixed"
          and not (ready and held.unit == lock_unit and held.value == lock_value)
          and not match.preset_exists(presets, held.unit, held.value) then
        lock_unit, lock_value, ready = held.unit, held.value, true
      end
      local lock_action, lock_hovered, on = draw_target_lock(ctx, res, state, "custom",
        "fixed", lock_unit, lock_value,
        apply_x1 + M.PICK_TOOL_GAP, apply_y0, reaper.ImGui_GetFrameHeight(ctx), not ready)
      if lock_hovered then
        tips.show(ctx, true, lock_tip(ready and fmt_target(lock_unit, lock_value) or nil, on,
          "Type a target value first."))
      end
      action = lock_action or action
    end
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
  reaper.ImGui_DrawList_AddText(dl, px(x0 + pad_x),
    px(y0 + (ctrl - lh) * 0.5),
    ui.edit_mode and T.ACCENT_HOVER or (hovered and T.TEXT_PRIMARY or T.TEXT_SECONDARY), label)
  tips.show(ctx, hovered, ui.edit_mode
    and "Finish editing the preset list"
    or "Add, edit, remove and reorder preset targets")
end

--------------------------------------------------------------- reaper measurement

-- One menu row in the Reset / Edit Presets idiom: a label on the left, an
-- optional value on the right. A row keeps its height and place in every
-- state; only its colours and words change.
local function draw_menu_row(ctx, id, label, value, width, o)
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local pad_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding()))
  local live = o.enabled ~= false and o.clickable ~= false
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  local spacing_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))
  -- `flush` drops the gap below the row, as the preset rows do.
  if o.flush then reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), spacing_x, 0) end
  local clicked = reaper.ImGui_InvisibleButton(ctx, "##" .. id, width, ctrl)
  if o.flush then reaper.ImGui_PopStyleVar(ctx, 1) end
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  if live and hovered then
    reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + width, y0 + ctrl, T.FILL_TERTIARY, 4)
  end
  local lh = select(2, reaper.ImGui_CalcTextSize(ctx, label))
  local text_y = px(y0 + (ctrl - lh) * 0.5)
  local colour = o.enabled == false and T.TEXT_QUATERNARY
    or (o.active and T.ACCENT or ((live and hovered) and T.TEXT_PRIMARY or T.TEXT_SECONDARY))
  reaper.ImGui_DrawList_AddText(dl, px(x0 + pad_x), text_y, colour, label)
  if value then
    local vw = reaper.ImGui_CalcTextSize(ctx, value)
    reaper.ImGui_DrawList_AddText(dl, px(x0 + width - pad_x - vw), text_y,
      o.enabled == false and T.TEXT_QUATERNARY or (o.value_colour or T.TEXT_PRIMARY), value)
  end
  if o.tip then tips.show(ctx, hovered, o.tip) end
  return clicked and live
end

local OWN_HEADING = "REAPER MEASUREMENT"
local OWN_NAME = "Reaper Measurement"
local PRESETS_TEXT = "Presets"
-- Rows and headings the Reaper Measurement adds to the menu, for its
-- first-frame height estimate: its section of four and its target row.
local OWN_ROWS = 5
local LISTEN_STATUS = {
  waiting = "Waiting For Playback…",
  measuring = "Measuring… Stop To Finish",
}
local READING_SHORT = { lufs_m_max = "M", lufs_s_max = "S", lufs_i = "I" }
local READING_TIPS = {
  lufs_m_max = "LUFS-M: the loudest 0.4 seconds.",
  lufs_s_max = "LUFS-S: the loudest 3 seconds.",
  lufs_i = "LUFS-I: the whole measured section.",
}

-- The three ways to measure, left to right. Playback stays lit while its
-- pass is waiting or measuring; a click then cancels it.
local MEASURE_BUTTONS = {
  { key = "selection", label = "Time Selection", action = "measure_own_selection",
    tip = "Measure your project inside the time selection, without playback. "
      .. "A long selection can take a few seconds." },
  { key = "item", label = "Item", action = "measure_own_item",
    tip = "Measure the item selected in Reaper, without playback. "
      .. "Select a folder item to measure its whole folder." },
  { key = "playback", label = "Playback", action = "measure_own_playback",
    tip = "Play your project, then stop. The level is measured from what played. "
      .. "References and Reference mode are not measured." },
}

local MEASURED_TIPS = {
  selection = "Your project's level, measured from the time selection.",
  playback = "Your project's level, measured during playback.",
  item = "The selected item's level, with its FX.",
  item_raw = "The selected item's level, from its audio file alone.",
  folder = "The selected folder's level, with its FX.",
}

local SETTINGS_HEADING = "MEASUREMENT SETTINGS"
local ITEM_SETTING_GROUP = "Item Button"
local ITEM_SETTING_LABEL = "Measure"
local ITEM_SETTING_TIP = "What the Item button measures when you select an item in Reaper."
local ITEM_SOUND_LABELS = { fx = "With FX", raw = "Raw" }
local ITEM_SOUND_TIPS = {
  fx = "The item as it plays on its track: take FX, track FX and the track's volume. "
    .. "Master FX are not included.",
  raw = "The item's audio file on its own, before any FX or volume changes.",
}
-- One short line under the switch, so the choice reads without hovering.
local ITEM_SOUND_NOTE = {
  fx = "Take FX, track FX and track volume. Not master FX.",
  raw = "The audio file alone, before any FX or volume.",
}

local function draw_heading(ctx, text)
  local heading = theme.push_heading_font(ctx)
  reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, text)
  if heading then reaper.ImGui_PopFont(ctx) end
end

-- A labelled row of joined buttons, one per choice.
-- The chosen one carries the shared soft accent; the row keeps its size
-- whichever is chosen. `cell_w` is one cell's width.
local function draw_choice_row(ctx, id, label, choices, current, short, choice_tips, cell_w, width)
  local picked
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local pad_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding()))
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  local lh = select(2, reaper.ImGui_CalcTextSize(ctx, label))
  reaper.ImGui_DrawList_AddText(reaper.ImGui_GetWindowDrawList(ctx), px(x0 + pad_x),
    px(y0 + (ctrl - lh) * 0.5), T.TEXT_SECONDARY, label)

  local n = #choices
  local sx1 = x0 + width
  local sx0 = px(sx1 - n * cell_w)
  widgets.begin_segment(ctx, sx0, y0, sx1, y0 + ctrl)
  for i, choice in ipairs(choices) do
    local w = widgets.segment_cell(ctx, sx0, sx1, n, i - 1, y0)
    local on = current == choice
    local pushed = widgets.push_soft_active(ctx, on)
    if on then reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.ACCENT_HOVER) end
    if reaper.ImGui_Button(ctx, short[choice] .. "##" .. id .. "_" .. choice, w, ctrl) and not on then
      picked = choice
    end
    if on then reaper.ImGui_PopStyleColor(ctx) end
    widgets.pop_soft_active(ctx, pushed)
    tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), choice_tips[choice])
  end
  widgets.end_segment(ctx, sx0, y0, sx1, y0 + ctrl, n)
  -- Hand the row's full rect back to the layout, as every other row does.
  reaper.ImGui_SetCursorScreenPos(ctx, x0, y0)
  reaper.ImGui_Dummy(ctx, width, ctrl)
  return picked
end

local function draw_reading_row(ctx, own, width)
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local unit = draw_choice_row(ctx, "ownunit", "Loudness Type", own_level.UNITS, own.unit,
    READING_SHORT, READING_TIPS, ctrl * 1.5, width)
  return unit and { type = "set_own_unit", unit = unit } or nil
end

-- The section heading with the settings button at its right edge. On the
-- settings page the heading itself also leads back, behind a chevron.
local function draw_heading_with_settings(ctx, res, text, width, back)
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local clicked = false
  local heading = theme.push_heading_font(ctx)
  local tw, th = reaper.ImGui_CalcTextSize(ctx, text)
  local text_y = px(y0 + (ctrl - th) * 0.5)
  if back then
    local glyph = th
    if reaper.ImGui_InvisibleButton(ctx, "##ownsettings_back", glyph + 4 + tw, ctrl) then clicked = true end
    local hovered = reaper.ImGui_IsItemHovered(ctx)
    local colour = hovered and T.TEXT_PRIMARY or T.TEXT_SECONDARY
    if not icons.paint_glyph(ctx, res and res.icon_font, "chevron-left", px(x0 + glyph * 0.5),
        y0 + ctrl * 0.5, colour) then
      reaper.ImGui_DrawList_AddText(dl, x0, text_y, colour, "<")
    end
    reaper.ImGui_DrawList_AddText(dl, px(x0 + glyph + 4), text_y, colour, text)
    tips.show(ctx, hovered, "Back to the measurement.")
  else
    reaper.ImGui_DrawList_AddText(dl, x0, text_y, T.TEXT_SECONDARY, text)
  end
  if heading then reaper.ImGui_PopFont(ctx) end
  reaper.ImGui_SetCursorScreenPos(ctx, x0 + width - ctrl, y0)
  local pressed, hovered = widgets.plot_settings_button(ctx, res and res.icon_font, "ownsettings",
    ui.settings_page, false)
  tips.show(ctx, hovered, ui.settings_page and "Back to the measurement." or "Measurement settings")
  if pressed then clicked = true end
  reaper.ImGui_SetCursorScreenPos(ctx, x0, y0)
  reaper.ImGui_Dummy(ctx, width, ctrl)
  if clicked then set_settings_page(not ui.settings_page) end
end

-- Time Selection, Item and Playback as one joined row filling `width`. Each
-- cell is as wide as its words need and the spare width is shared out
-- equally, so the longest label still fits at any UI size.
local function draw_measure_buttons(ctx, own, width)
  local action
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local pad_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding()))
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  local n = #MEASURE_BUTTONS
  local needs, total = {}, 0
  for i, b in ipairs(MEASURE_BUTTONS) do
    needs[i] = reaper.ImGui_CalcTextSize(ctx, b.label) + pad_x * 2
    total = total + needs[i]
  end
  local spare = math.max(0, width - total) / n
  local edges, x = {}, x0
  widgets.begin_segment(ctx, x0, y0, x0 + width, y0 + ctrl)
  for i, b in ipairs(MEASURE_BUTTONS) do
    local right = (i == n) and (x0 + width) or px(x + needs[i] + spare)
    if i < n then edges[i] = right end
    reaper.ImGui_SetCursorScreenPos(ctx, x, y0)
    local on = b.key == "playback" and own.listening ~= nil
    local pushed = widgets.push_soft_active(ctx, on)
    if on then reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.ACCENT_HOVER) end
    if reaper.ImGui_Button(ctx, b.label .. "##ownmeasure_" .. b.key, right - x, ctrl) then
      action = { type = b.action }
    end
    if on then reaper.ImGui_PopStyleColor(ctx) end
    widgets.pop_soft_active(ctx, pushed)
    tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), on and "Select to cancel." or b.tip)
    x = right
  end
  widgets.end_segment(ctx, x0, y0, x0 + width, y0 + ctrl, n, edges)
  reaper.ImGui_SetCursorScreenPos(ctx, x0, y0)
  reaper.ImGui_Dummy(ctx, width, ctrl)
  return action
end

-- REAPER MEASUREMENT: the three ways to measure, the measured level, and the
-- loudness type the rest of the menu compares by.
local function draw_measure_section(ctx, state, res, width)
  local own = state.own_level
  local unit = own.unit
  local mine = own.measurement
  local value = mine and mine[unit]

  draw_heading_with_settings(ctx, res, OWN_HEADING, width, false)
  local action = draw_measure_buttons(ctx, own, width)

  -- During a playback pass the row says what is happening instead of
  -- showing a level, so it reads as one message, not "Measured" plus a status.
  local status = LISTEN_STATUS[own.listening]
  if status then
    draw_menu_row(ctx, "ownreading", status, nil, width, {
      clickable = false,
      tip = "Stop playback to finish, or select Playback to cancel.",
    })
  else
    draw_menu_row(ctx, "ownreading", "Measured",
      (value and string.format("%.1f %s", value, unit_label(unit)))
        or (mine and ("No " .. measurement_name(unit)) or "Not Measured"),
      width, {
        clickable = false,
        value_colour = value and T.ACCENT or T.TEXT_QUATERNARY,
        tip = (mine and (MEASURED_TIPS[mine.method] or MEASURED_TIPS.playback))
          or "Measure your project in Reaper to compare references at its level.",
      })
  end

  local reading_action = draw_reading_row(ctx, own, width)
  return action or reading_action
end

-- The page the heading's settings button swaps the menu to. It replaces the
-- whole menu, so no second panel opens over the first. Below its heading it
-- follows the other settings panels: a titled group box, one row per setting
-- with the name on the left and the control at the standard width.
local function draw_measure_settings(ctx, state, res, width)
  local own = state.own_level
  draw_heading_with_settings(ctx, res, SETTINGS_HEADING, width, true)

  local picked
  -- The box's height is worked out before drawing, as the other settings
  -- panels do: a box that sizes itself is hidden for its first frame, which
  -- shows as a flash every time the page opens.
  local pad = M.WINDOW_PAD
  local note_h = select(2, reaper.ImGui_CalcTextSize(ctx, ITEM_SOUND_NOTE[own.item_sound],
    nil, nil, false, math.max(1, width - pad * 2)))
  local group_h = math.ceil(pad * 2 + reaper.ImGui_GetFrameHeight(ctx) + M.ITEM_SPACING_Y + note_h)
  local opened, child = widgets.begin_settings_group(ctx, "ownsettings_item", ITEM_SETTING_GROUP, true, group_h)
  if opened then
    local x = reaper.ImGui_GetCursorPosX(ctx)
    local available = reaper.ImGui_GetContentRegionAvail(ctx)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, ITEM_SETTING_LABEL)
    tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), ITEM_SETTING_TIP)
    reaper.ImGui_SameLine(ctx, x + available - M.SPECTRUM_OPTION_W)
    local choices = {}
    for _, key in ipairs(own_level.ITEM_SOUNDS) do
      choices[#choices + 1] = { key = key, label = ITEM_SOUND_LABELS[key],
        on = own.item_sound == key, tip = ITEM_SOUND_TIPS[key] }
    end
    picked = widgets.multi_switch(ctx, "ownitemsound", choices, M.SPECTRUM_OPTION_W)

    reaper.ImGui_PushTextWrapPos(ctx, x + available)
    reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY, ITEM_SOUND_NOTE[own.item_sound])
    reaper.ImGui_PopTextWrapPos(ctx)
  end
  widgets.end_settings_group(ctx, child)
  if picked and picked ~= own.item_sound then return { type = "set_item_sound", value = picked } end
end

-- The Reaper Measurement as the first normalize target, in the presets' own
-- row style: the trim it would set on the right, accent when the trim is there.
local function draw_own_target_row(ctx, state, res, sel, width)
  local own = state.own_level
  local trim, why
  if sel then trim, why = own_level.trim_for(sel, own.measurement, own.unit) end
  local at_this = trim ~= nil and round1(sel.trim_db or 0) == round1(trim)
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  local action
  if draw_menu_row(ctx, "ownnormalize", OWN_NAME, trim and fmt_trim(trim) or "\u{2014}",
      width - lock_space(), {
      enabled = trim ~= nil,
      clickable = not ui.edit_mode,
      active = at_this,
      flush = true,
      tip = (not sel and "Choose a reference first.")
        or (why == "no_measurement" and "Measure your project first.")
        or (why == "unmeasured" and ("No " .. measurement_name(own.unit)
          .. " measurement is available for this reference."))
        or ("Set the selected reference's trim to " .. fmt_trim(trim) .. "."),
    }) then
    action = { type = "normalize_to_own", db = trim }
  end
  -- The lock needs only the measurement, not a selected reference.
  local level = own.measurement and own.measurement[own.unit]
  local measured = type(level) == "number"
  local lock_action, lock_hovered, on = draw_target_lock(ctx, res, state, "own",
    "own", nil, nil, x0 + width - M.PICK_TOOL_W, y0, ctrl, not measured)
  if lock_hovered then
    -- Still locked with no reading in this unit: nothing is held until one
    -- arrives, and the lock can be clicked off meanwhile.
    local name = measured and string.format("the %s (%.1f %s)", OWN_NAME, level, unit_label(own.unit))
      or (on and ("the " .. OWN_NAME) or nil)
    tips.show(ctx, true, lock_tip(name, on, "Measure your project first."))
  end
  reaper.ImGui_SetCursorScreenPos(ctx, x0, y0 + ctrl)
  return lock_action or action
end

-- The Presets row: one click shows the preset list under it, the next hides
-- it. While the list is hidden the row names the locked preset with a lock
-- mark, or else the preset the trim is at, so the panel still says which
-- target is in force.
local function draw_presets_row(ctx, state, res, sel, presets, width, open)
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local pad_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding()))
  local spacing_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  -- Flush against the list it opens, as the list's own rows are.
  if open then reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), spacing_x, 0) end
  local clicked = reaper.ImGui_InvisibleButton(ctx, "##matchpresets", width, ctrl)
  if open then reaper.ImGui_PopStyleVar(ctx, 1) end
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  if hovered then
    reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + width, y0 + ctrl, T.FILL_TERTIARY, 4)
  end

  local current
  if sel then
    for _, p in ipairs(presets) do
      local trim = match.trim_for(sel, p.unit, p.value)
      if trim and round1(sel.trim_db or 0) == round1(trim) then
        current = fmt_target(p.unit, p.value)
        break
      end
    end
  end
  local held = ui.show_own and state.own_level.lock and state.own_level.target
  local locked = false
  if held and held.kind == "fixed" then
    for _, p in ipairs(presets) do
      if p.unit == held.unit and p.value == held.value then
        current, locked = fmt_target(p.unit, p.value), true
        break
      end
    end
  end
  local lh = select(2, reaper.ImGui_CalcTextSize(ctx, PRESETS_TEXT))
  local text_y = px(y0 + (ctrl - lh) * 0.5)
  reaper.ImGui_DrawList_AddText(dl, px(x0 + pad_x), text_y,
    hovered and T.TEXT_PRIMARY or T.TEXT_SECONDARY, PRESETS_TEXT)

  local mark_w = M.ICON_SM_FS * theme.scale
  local mark_cx = x0 + width - pad_x - mark_w * 0.5
  local mark_col = hovered and T.TEXT_PRIMARY or T.TEXT_TERTIARY
  if not icons.paint_glyph(ctx, res and res.icon_font, open and "chevron-down" or "chevron-right",
      px(mark_cx), y0 + ctrl * 0.5, mark_col) then
    local fallback = open and "v" or ">"
    local fw = reaper.ImGui_CalcTextSize(ctx, fallback)
    reaper.ImGui_DrawList_AddText(dl, px(mark_cx - fw * 0.5), text_y, mark_col, fallback)
  end
  if current and not open then
    local cw = reaper.ImGui_CalcTextSize(ctx, current)
    local cx = x0 + width - pad_x - mark_w - spacing_x - cw
    reaper.ImGui_DrawList_AddText(dl, px(cx), text_y, T.ACCENT, current)
    if locked then
      icons.paint_glyph(ctx, res and res.icon_font, "lock",
        px(cx - spacing_x - mark_w * 0.5), y0 + ctrl * 0.5, T.ACCENT)
    end
  end
  tips.show(ctx, hovered, open and "Hide the preset targets." or "Show the preset targets.")
  if clicked then
    -- Editing needs the list; hiding the list ends it.
    if open then ui.edit_mode, ui.edit_index, ui.drag_index = false, nil, nil end
    return { type = "set_match_presets_open", open = not open }
  end
  return nil
end

-- Chooses the menu's side and position while it opens: right-aligned under the
-- button, or above it when the screen ends too close below. The first frame
-- estimates the height; the second uses the measured one.
local function place_menu(ctx, res, presets, outer_width)
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  -- Heading, Presets row, custom target and reset, plus the open list and its
  -- Edit Presets row.
  local rows = 4 + (ui.presets_open and (#presets + 1) or 0)
  local est_h = 2 * M.WINDOW_PAD + rows * ctrl + 6 * M.ITEM_SPACING_Y
    + (ui.show_readings and (ctrl + 3 * M.STRIP_READING_H + 2 * M.ITEM_SPACING_Y) or 0)
    + (ui.show_own and (OWN_ROWS * (ctrl + M.ITEM_SPACING_Y)) or 0)
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

-- An ordinary window, not a popup: a popup closes on any click outside it, and
-- this panel has to stand open while the user plays, pins and measures. TopMost
-- keeps it over the tool's own window after that window is clicked.
local WINDOW_FLAGS = reaper.ImGui_WindowFlags_NoTitleBar()
  | reaper.ImGui_WindowFlags_NoCollapse()
  | reaper.ImGui_WindowFlags_AlwaysAutoResize()
  | reaper.ImGui_WindowFlags_NoSavedSettings()
if reaper.ImGui_WindowFlags_NoDocking then
  WINDOW_FLAGS = WINDOW_FLAGS | reaper.ImGui_WindowFlags_NoDocking()
end
if reaper.ImGui_WindowFlags_TopMost then
  WINDOW_FLAGS = WINDOW_FLAGS | reaper.ImGui_WindowFlags_TopMost()
end

function matchwin.draw_popup(ctx, state, res)
  local action
  local width = M.MATCH_WIN_W
  if ui.show_readings then width = math.max(width, math.ceil(readings.measure(ctx).two_w)) end
  local outer_width = width + M.WINDOW_PAD * 2
  local presets = (state.match and state.match.presets) or {}
  ui.show_own = state.own_level ~= nil and not state.showcase
  -- Editing presets needs the list, so a request to edit shows it.
  ui.presets_open = (state.match and state.match.presets_open == true) or ui.edit_mode

  if theme.motion.enabled and ui.motion_generation ~= theme.motion.generation then
    ui.motion_generation = theme.motion.generation
    ui.normalize_pending = nil
  end

  if ui.open_request then
    ui.open_request = false
    ui.open = true
    ui.rect, ui.settle = nil, 0
  end
  if ui.open and ui.close_request then ui.open = false end
  if not ui.open then
    ui.close_request, ui.drag_index, ui.edit_index = false, nil, nil
    ui.edit_mode, ui.scrolls = false, false
    ui.settings_page, ui.returning = false, false
    return nil
  end

  -- The settings page, and the frame that returns from it, keep the menu's size.
  local fixed_h = ui.show_own and (ui.settings_page or ui.returning) and ui.menu_h or nil
  ui.returning = false

  if ui.anchor_x0 then
    -- Placed while it opens and after a UI size change. Between those it stays
    -- where the user drags it, because it can stand open for a long time.
    if ui.settle < 2 or ui.scale ~= theme.scale then
      place_menu(ctx, res, presets, outer_width)
      reaper.ImGui_SetNextWindowPos(ctx, ui.place.x, ui.place.y,
        reaper.ImGui_Cond_Always(), 0, ui.place.pivot_y)
    end
    ui.scale = theme.scale
    -- A menu taller than the room scrolls; its scrollbar gets its own width
    -- so the rows keep theirs and nothing at their right edge is cut off.
    local window_w = outer_width
    if ui.scrolls then
      window_w = window_w + reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ScrollbarSize())
    end
    local max_h = fixed_h and math.min(fixed_h, ui.place.max_h) or ui.place.max_h
    reaper.ImGui_SetNextWindowSizeConstraints(ctx, window_w, fixed_h and max_h or 0, window_w, max_h)
  elseif fixed_h then
    reaper.ImGui_SetNextWindowSizeConstraints(ctx, outer_width, fixed_h, outer_width, fixed_h)
  end

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), M.WINDOW_PAD, M.WINDOW_PAD)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), T.BG_WINDOW)
  local visible = reaper.ImGui_Begin(ctx, POPUP_ID, nil, WINDOW_FLAGS)
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_PopStyleVar(ctx, 1)
  if not visible then return nil end
  ui.scrolls = reaper.ImGui_GetScrollMaxY(ctx) > 0

  local wx, wy = reaper.ImGui_GetWindowPos(ctx)
  local ww, wh = reaper.ImGui_GetWindowSize(ctx)
  ui.rect = ui.rect or {}
  ui.rect.x1, ui.rect.y1, ui.rect.x2, ui.rect.y2 = wx, wy, wx + ww, wy + wh
  ui.settle = ui.settle + 1
  if not ui.settings_page then ui.menu_h = wh end

  local sel = state.selected
  local heading
  if ui.show_own and ui.settings_page then
    action = draw_measure_settings(ctx, state, res, width)
    if reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_RootAndChildWindows())
        and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
      -- Escape steps back to the measurement before it closes the menu.
      set_settings_page(false)
    end
    reaper.ImGui_End(ctx)
    return action
  end
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
  if ui.show_own then
    action = draw_measure_section(ctx, state, res, width)
    reaper.ImGui_Separator(ctx)
  end
  heading = theme.push_heading_font(ctx)
  reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, HEADING)
  if heading then reaper.ImGui_PopFont(ctx) end

  if ui.show_own then
    local own_action = draw_own_target_row(ctx, state, res, sel, width)
    action = action or own_action
  end
  local open = ui.presets_open
  local presets_action = draw_presets_row(ctx, state, res, sel, presets, width, open)
  action = action or presets_action
  prow_n = 0
  if open then
    local rows_x = reaper.ImGui_GetCursorScreenPos(ctx)
    for i, p in ipairs(presets) do
      local row_action = draw_preset_row(ctx, state, res, sel, p, i, width)
      action = action or row_action
    end
    if #presets == 0 then
      reaper.ImGui_PushTextWrapPos(ctx, reaper.ImGui_GetCursorPosX(ctx) + width)
      reaper.ImGui_TextColored(ctx, T.TEXT_QUATERNARY, ui.edit_mode and EMPTY_EDIT_TEXT or EMPTY_TEXT)
      reaper.ImGui_PopTextWrapPos(ctx)
    end
    local drag_action = resolve_drag(ctx, presets, rows_x, width)
    action = action or drag_action
    -- Ends the list. Its normal spacing also hands back the gap the flush
    -- rows above it swallowed.
    draw_edit_item(ctx, width)
  end

  local target_action = draw_target_row(ctx, state, res, sel, presets, width)
  action = action or target_action
  reaper.ImGui_Separator(ctx)
  local reset_action = draw_reset_item(ctx, sel, width)
  action = action or reset_action

  local escape = reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_RootAndChildWindows())
    and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape())
  if escape then
    ui.open = false
    ui.normalize_pending = nil
    -- Escape leaves the panel that had focus; hand it back to REAPER.
    focus.request()
  end
  reaper.ImGui_End(ctx)
  return action
end

return matchwin
