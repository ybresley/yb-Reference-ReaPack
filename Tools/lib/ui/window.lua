-- Reference View pictures adapt to the space above the listening and transport
-- controls. Automatic arrangement follows the available width and height.
-- This module only draws and returns actions; it never starts work or saves data.

local theme = require("ui.theme")
local waveform = require("ui.waveform")
local analysis_panel = require("ui.analysis_panel")
local relocation_notice = require("ui.relocation_notice")
local transport = require("ui.transport")
local dropzone = require("ui.dropzone")
local spectrum = require("ui.spectrum")
local spectrum_controls = require("ui.spectrum_controls")
local spectrum_layout = require("core.spectrum_layout")
local icon_motion = require("ui.icon_motion")
local tips = require("ui.tips")
local walkthrough = require("core.walkthrough")
local walkthrough_ui = require("ui.walkthrough")
local T = theme.tokens
local M = theme.metrics

local window = {}
local split_grab_offset, split_mode
local last_layout_mode
local measured_preferences = {}
local swap_button = {}

local function point_in_rect(px, py, x0, y0, x1, y1)
  return px >= x0 and px <= x1 and py >= y0 and py <= y1
end

-- Reveal the swap face from the gap itself, then keep it available while the
-- pointer crosses onto the face. Submit its input before either picture so a
-- handle underneath cannot consume the same click.
local function begin_swap(ctx, geometry, x, y, width)
  local size = math.min(reaper.ImGui_GetFrameHeight(ctx), geometry.visual_h)
  local vertical = geometry.mode == 'vertical'
  swap_button.x = x + geometry.divider_x + (vertical and M.WINDOW_PAD
    or (M.SPECTRUM_SPLIT_GAP - size) / 2)
  swap_button.y = y + geometry.divider_y + (vertical
    and (M.SPECTRUM_SPLIT_GAP - size) / 2
    or math.min(M.WINDOW_PAD, math.max(0, geometry.visual_h - size)))
  swap_button.size = size
  local mx, my = reaper.ImGui_GetMousePos(ctx)
  local gap_hovered = false
  if reaper.ImGui_IsWindowHovered(ctx) then
    if vertical then
      gap_hovered = point_in_rect(mx, my, x, y + geometry.divider_y,
        x + width, y + geometry.divider_y + M.SPECTRUM_SPLIT_GAP)
    else
      gap_hovered = point_in_rect(mx, my, x + geometry.divider_x, y,
        x + geometry.divider_x + M.SPECTRUM_SPLIT_GAP, y + geometry.visual_h)
    end
  end
  local face_hovered = point_in_rect(mx, my, swap_button.x, swap_button.y,
    swap_button.x + size, swap_button.y + size)
  swap_button.visible = gap_hovered
    or (swap_button.visible and face_hovered)
    or swap_button.held == true
  if not swap_button.visible then
    swap_button.hot, swap_button.held, swap_button.pressed = false, false, false
    return
  end
  reaper.ImGui_SetCursorScreenPos(ctx, swap_button.x, swap_button.y)
  local clicked = reaper.ImGui_InvisibleButton(ctx, '##swap_reference_' .. geometry.mode, size, size)
  swap_button.hot = reaper.ImGui_IsItemHovered(ctx)
  swap_button.held = reaper.ImGui_IsItemActive(ctx)
  swap_button.pressed = swap_button.hot and reaper.ImGui_IsMouseClicked(ctx, 0)
  if clicked then
    return {type = 'set_reference_layout',
      key = vertical and 'vertical_first' or 'horizontal_first',
      value = geometry.waveform_first and 'spectrum' or 'waveform'}
  end
end

local function paint_swap(ctx, geometry, res)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local x, y, size = swap_button.x, swap_button.y, swap_button.size
  local rounding = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding())
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + size, y + size, T.BG_CHROME, rounding)
  if swap_button.hot or swap_button.held then
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + size, y + size,
      swap_button.held and T.FILL_PRIMARY or T.FILL_SECONDARY, rounding)
  end
  reaper.ImGui_DrawList_AddRect(dl, x, y, x + size, y + size,
    (swap_button.hot or swap_button.held) and T.STROKE_PRIMARY or T.STROKE_SECONDARY,
    rounding, 0, 1)
  local vertical = geometry.mode == 'vertical'
  local colour = swap_button.hot and T.TEXT_PRIMARY or T.TEXT_TERTIARY
  icon_motion.paint(ctx, 'swap_reference_' .. geometry.mode,
    vertical and 'arrow-up-down' or 'arrow-left-right', x + size / 2, y + size / 2,
    colour, false, swap_button.pressed, true, M.ICON_FS)
  tips.show(ctx, swap_button.hot, 'Swap waveform and spectrum positions.', 'swap_reference')
end

-- Feature detection for the window-wide drop coverage (checked once at load,
-- the house idiom). Without these calls an internal drag simply can't be
-- dropped here — nothing breaks, the browser's own targets still work.
local HAS_RECT_HOVER = reaper.ImGui_IsMouseHoveringRect ~= nil
local HAS_WIN_HOVER_BLOCKED = reaper.ImGui_IsWindowHovered ~= nil
  and reaper.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem ~= nil

-- A sound dragged from the browser's table onto ANY part of the Reference View
-- pins it to this project. The reference row used to be that target; with the
-- row gone the whole window is, which is both simpler and a bigger target
-- (Codex's 2026-07-28 point about blank space silently cancelling drops applies
-- here too). A dragged PIN is already here, and damaged pin data refuses every
-- mutation, so neither gets the invite.
local function pin_drop_target(ctx, state, x0, y0, x1, y1)
  local drag = state.drag
  if not drag or not HAS_RECT_HOVER then return nil end
  local ps = state.pins
  if ps and ps.load_error then return nil end
  if type(drag.sound_id) == "string" and drag.sound_id:sub(1, 1) == "p" then return nil end

  -- Gated on this window being the hovered one, so a drag over a browser window
  -- overlapping this rect can't light the Reference View through it.
  if HAS_WIN_HOVER_BLOCKED and not reaper.ImGui_IsWindowHovered(ctx,
      reaper.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem()) then
    return nil
  end
  if not reaper.ImGui_IsMouseHoveringRect(ctx, x0, y0, x1, y1) then return nil end

  dropzone.draw_drop_rect(ctx, x0, y0, x1, y1, "Pin To This Project")
  dropzone.show_hand_cursor(ctx)
  if reaper.ImGui_IsMouseReleased(ctx, 0) then
    return { type = "pin_sounds", ids = drag.sound_ids or { drag.sound_id },
      progress_view = "main", wins_release = true }
  end
  return nil
end

function window.draw(ctx, state, res)
  local action
  local wave_id, wave_cols
  local analysis_x0, analysis_y0, analysis_x1, analysis_y1

  -- The WHOLE Reference View is one OS-file drop target (2026-08-01, user's call
  -- — supersedes the old "browser opens itself" auto-open): files dropped
  -- anywhere on this window import into the library (Uncategorised) and pin to
  -- this project in one motion, with the full-window treatment while the drag
  -- hovers. Submitted only while a files payload is in flight, so it can never
  -- steal a click — see dropzone.file_drop_over_rect.
  local cx0, cy0 = reaper.ImGui_GetCursorScreenPos(ctx)
  local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  action = dropzone.file_drop_over_rect(ctx, state, cx0, cy0, cx0 + avail_w, cy0 + avail_h,
    { action_type = "import_and_pin", label = "Add to Library and Pin To This Project" })
  local drag_action = pin_drop_target(ctx, state, cx0, cy0, cx0 + avail_w, cy0 + avail_h)
  action = action or drag_action

  -- Reserve the measured controls first. Automatic arrangement uses the room
  -- left for pictures, independently of playback, selection and divider shares.
  local spacing_y = select(2, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))
  local bar_h = transport.measure(ctx, avail_w, state)

  -- The waveform adds its ruler back when drawn, so its picture height excludes
  -- that strip. Listening controls are painted over the spectrum, so they do
  -- not reserve a separate rail between the pictures and transport.
  local prefs = state.reference_layout
  -- Moving a divider changes sizes, never the arrangement being dragged.
  measured_preferences.mode = split_mode or prefs.mode
  measured_preferences.horizontal_first = prefs.horizontal_first
  measured_preferences.vertical_first = prefs.vertical_first
  -- Saved shares describe the waveform for compatibility with earlier builds.
  -- Geometry receives the first frame's share so swapping content cannot move it.
  local horizontal_first_share = prefs.horizontal_first == 'spectrum'
    and 1 - state.spectrum.prefs.split or state.spectrum.prefs.split
  local vertical_first_share = prefs.vertical_first == 'spectrum'
    and 1 - state.reference_stack_split or state.reference_stack_split
  local geometry = spectrum_layout.measure(avail_w, avail_h, bar_h, spacing_y,
    M.RULER_H, M.WAVE_MIN_H, M.WAVE_HIDE_H, M.SPECTRUM_PANE_MIN_W,
    M.SPECTRUM_SPLIT_GAP, horizontal_first_share, vertical_first_share,
    M.SPECTRUM_STACK_WAVE_MIN_H, M.SPECTRUM_STACK_MIN_H,
    measured_preferences, last_layout_mode)
  if geometry.both then last_layout_mode = geometry.mode end
  local wave_h = geometry.wave_h
  local stop = walkthrough.current(state.walkthrough)
  local visual = state.spectrum.prefs.visual
  walkthrough_ui.note_rect(ctx, state.walkthrough, 'layout',
    cx0, cy0, cx0 + avail_w, cy0 + geometry.visual_h)
  local swap_blocks_pictures = false
  if geometry.both then
    local swap_action = begin_swap(ctx, geometry, cx0, cy0, avail_w)
    action = action or swap_action
    swap_blocks_pictures = swap_button.hot or swap_button.held
  else
    swap_button.visible, swap_button.hot, swap_button.held = false, false, false
  end
  -- The overlay owns only its small face. Keep picture colours unchanged while
  -- preventing span/filter handles beneath that face from responding as well.
  if swap_blocks_pictures then
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_DisabledAlpha(), 1)
    reaper.ImGui_BeginDisabled(ctx)
  end

  -- A short window gives the ruler's space back to the waveform picture.
  local ruler_on = geometry.ruler
  local switch_x = cx0 + M.SPECTRUM_PLOT_PAD + M.SPECTRUM_BAND_GAP
  local switch_y = cy0 + M.SPECTRUM_PLOT_PAD + M.SPECTRUM_BAND_GAP
  local switch_bounds = not geometry.both and geometry.visual_h > 0
    and spectrum_controls.visual_switch_bounds(switch_x, switch_y)
    or nil
  local visual_hovered = switch_bounds and reaper.ImGui_IsWindowHovered(ctx)
    and reaper.ImGui_IsMouseHoveringRect(ctx,
      cx0, cy0, cx0 + avail_w, cy0 + geometry.visual_h)
  local switch_interaction, switch_action = spectrum_controls.visual_switch_input(
    ctx, state, switch_bounds, visual_hovered)
  action = switch_action or action

  if wave_h > 0 and (geometry.both or visual == 'waveform') then
    reaper.ImGui_SetCursorScreenPos(ctx, cx0 + geometry.wave_x, cy0 + geometry.wave_y)
    -- The Reference View always shows the ARMED reference — never the browser's
    -- own selection (Phase 5.9: the two are independent). Its trim scales the
    -- drawing, so riding the trim fader resizes the wave as it resizes the sound.
    -- `ruler`/`duration` opt in to the time ruler beneath it (the browser's
    -- strip passes its own since 2026-08-06). `slot` names which view this
    -- panel is — its ruler cache, and which remembered pause its playhead
    -- reads (the browser's strip passes "browse").
    -- `span_*` opt in to the start/end handles (loudness tools, 2026-08-06) —
    -- the Reference View only; the browser strip passes none and stays plain.
    -- `empty_hint` is what the panel says with nothing armed: this window's
    -- whole area is a drop target, and an empty picture is exactly when that
    -- needs saying (2026-08-11, user's ask). Drawn over the baseline, so it
    -- costs no layout and can never shift the bar below it.
    local wave_action, wx0, wy0, wx1, wy1
    wave_action, wave_id, wave_cols, wx0, wy0, wx1, wy1 = waveform.draw(
      ctx, state, wave_h,
      { id = state.selected_id, waveform = state.waveform, slot = "main",
        width = geometry.wave_w,
        view = state.wave_view, detail = state.wave_detail, navigation = true,
        modifiers = state.mouse_modifiers,
        trim_db = state.selected and state.selected.trim_db or 0,
        ruler = ruler_on, duration = state.selected and state.selected.duration or nil,
        span_edit = true,
        input_exclusion = switch_bounds,
        span_start = state.selected and state.selected.span_start or nil,
        span_end = state.selected and state.selected.span_end or nil,
        empty_hint = "Drop audio files here to add them to the Library and pin them to this project." })
    action = action or wave_action
    analysis_x0, analysis_y0, analysis_x1, analysis_y1 = wx0, wy0, wx1, wy1
  end

  if geometry.visual_h > 0 and (geometry.both or visual == 'spectrum') then
    local sx, sy = cx0 + geometry.spectrum_x, cy0 + geometry.spectrum_y
    reaper.ImGui_SetCursorScreenPos(ctx, sx, sy)
    local graph_action = spectrum.draw(ctx, state, geometry.spectrum_w, geometry.spectrum_h,
      res, switch_bounds)
    action = action or graph_action
    walkthrough_ui.note_rect(ctx, state.walkthrough, 'spectrum',
      sx, sy, sx + geometry.spectrum_w, sy + geometry.spectrum_h)
    if not analysis_x0 then
      analysis_x0, analysis_y0 = sx, sy
      analysis_x1, analysis_y1 = sx + geometry.spectrum_w, sy + geometry.spectrum_h
    end
  else
    spectrum.clear_handle_focus()
  end
  if swap_blocks_pictures then
    reaper.ImGui_EndDisabled(ctx)
    reaper.ImGui_PopStyleVar(ctx)
  end
  if geometry.visual_h > 0 then
    if geometry.both then
      local vertical = geometry.mode == 'vertical'
      local dx, dy = cx0 + geometry.divider_x, cy0 + geometry.divider_y
      local dw = vertical and avail_w or M.SPECTRUM_SPLIT_GAP
      local dh = vertical and M.SPECTRUM_SPLIT_GAP or geometry.visual_h
      local hot, held = false, false
      -- The full gap stays draggable. Only skip its input while the swap face
      -- itself owns the pointer, so there is no dead strip around that button.
      if not swap_blocks_pictures then
        reaper.ImGui_SetCursorScreenPos(ctx, dx, dy)
        -- Separate IDs prevent a resize from transferring an active drag to the other axis.
        reaper.ImGui_InvisibleButton(ctx, '##spectrum_split_' .. geometry.mode, dw, dh)
        hot, held = reaper.ImGui_IsItemHovered(ctx), reaper.ImGui_IsItemActive(ctx)
      end
      if hot or held then
        reaper.ImGui_SetMouseCursor(ctx, vertical and reaper.ImGui_MouseCursor_ResizeNS()
          or reaper.ImGui_MouseCursor_ResizeEW())
      end
      local mx, my = reaper.ImGui_GetMousePos(ctx)
      local pointer = vertical and my or mx
      if reaper.ImGui_IsItemActivated(ctx) then
        split_grab_offset = pointer - ((vertical and dy or dx) + M.SPECTRUM_SPLIT_GAP / 2)
        split_mode = geometry.mode
      end
      if held and split_mode == geometry.mode then
        local frame_min = vertical
          and math.min(M.SPECTRUM_STACK_WAVE_MIN_H, M.SPECTRUM_STACK_MIN_H)
          or M.SPECTRUM_PANE_MIN_W
        local value = spectrum_layout.clamp_split(pointer - split_grab_offset,
          vertical and cy0 or cx0, vertical and geometry.visual_h or avail_w,
          M.SPECTRUM_SPLIT_GAP,
          frame_min, frame_min)
        -- The stored value remains the waveform share so older development
        -- copies open with the same two frame sizes and content order.
        if not geometry.waveform_first then value = math.max(0.2, math.min(0.8, 1 - value)) end
        action = action or (vertical
          and {type = 'set_reference_stack_split', value = value, commit = false}
          or {type = 'set_spectrum_preference', key = 'split', value = value, commit = false})
      end
      if hot or held or swap_button.visible or (type(stop) == 'table' and stop.id == 'layout') then
        local dl = reaper.ImGui_GetWindowDrawList(ctx)
        reaper.ImGui_DrawList_AddRectFilled(dl, dx, dy, dx + dw, dy + dh,
          held and T.FILL_PRIMARY or T.FILL_SECONDARY)
      end
      if swap_button.visible then paint_swap(ctx, geometry, res) end
    else
      split_grab_offset = nil
      spectrum_controls.visual_switch(ctx, state, res, switch_interaction)
    end
  end
  -- A window resize can remove the active gap before ImGui reports deactivation.
  -- Commit the last proportion on release or a layout change in either case.
  if split_mode and (split_mode ~= geometry.mode or not reaper.ImGui_IsMouseDown(ctx, 0)) then
    local finished = split_mode == 'vertical'
      and {type = 'set_reference_stack_split', value = state.reference_stack_split}
      or {type = 'set_spectrum_preference', key = 'split', value = state.spectrum.prefs.split}
    if not action then
      action = finished
      split_grab_offset, split_mode = nil, nil
    end
  end
  if analysis_panel.is_visible(state, "main", dropzone.file_drag_active()) then
    if not geometry.both and analysis_y0 then
      -- The card is paint-only and draws last, so keep its top edge below the
      -- overlaid visual switch without taking height away from either picture.
      analysis_y0 = math.max(analysis_y0, switch_bounds.y1)
    end
    analysis_panel.draw(ctx, state.analysis_progress,
      analysis_x0, analysis_y0, analysis_x1, analysis_y1)
  end
  reaper.ImGui_SetCursorScreenPos(ctx, cx0, cy0 + geometry.bar_y)
  local bar_action = transport.draw(ctx, state, res)
  action = action or bar_action

  -- A failed Save As can leave the saved project pointing at a References folder
  -- that does not contain these pins. Keep the recovery instruction in the
  -- always-open Reference View until the project reaches a valid folder again.
  local relocation_y0 = switch_bounds
    and switch_bounds.y1 + M.ITEM_SPACING_Y
    or cy0
  relocation_notice.draw(ctx, state, cx0, relocation_y0,
    cx0 + avail_w, cy0 + geometry.visual_h)

  return action, wave_id, wave_cols
end

return window
