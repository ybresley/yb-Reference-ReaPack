-- Hosts the Reference View: the Reference card, the docked Library when it is
-- open here, and the panels. Selection, playback and library actions stay with
-- the hosted views. core/reference_sidebar_layout.lua decides the placement.
local theme = require('ui.theme')
local browser = require('ui.browser')
local reference = require('ui.window')
local controls = require('ui.reference_controls')
local readings = require('ui.readings')
local walkthrough = require('ui.walkthrough')
local widgets = require('ui.widgets')
local actions = require('core.actions')
local card_plan = require('core.card_plan')
local layout = require('core.reference_sidebar_layout')
local panel_layout = require('core.browser_panel_layout')
local host = {}
-- In-flight drags: the Library's width, and the card's height above it.
local drag, card_drag
-- Reused every frame (frame-allocation rule).
local library_opts = { embedded = true }
local library_plan, library_sizes = {}, { rows = {} }
local card_info = {}

local function library_docked(state)
  return state.browser_open and state.library_placement == 'embedded'
end

local function library_minimum(ctx)
  -- Measure live font and button sizes; nominal UI scale can understate them.
  local pad_x = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding())
  local volume_width = reaper.ImGui_CalcTextSize(ctx, '-60.0 dB') + 2 * pad_x
  return panel_layout.minimum_width(reaper.ImGui_GetFrameHeight(ctx), volume_width, theme.metrics)
    + 2 * theme.metrics.WINDOW_PAD
end

-- The heights each of the docked Library's forms with a list needs, from live
-- sizes, when it shows `n` rows of readings: heading and category row, a few
-- rows, the selected name, the readings, the waveform and its ruler, and the
-- audition row.
local form_sizes, library_forms = {}, {}
local function library_heights(ctx, n)
  local m, s = theme.metrics, form_sizes
  local cell_padding = select(2, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_CellPadding()))
  s.control, s.gap = reaper.ImGui_GetFrameHeight(ctx), m.ITEM_SPACING_Y
  -- The same first-row inset as the Reference card, so the two line up.
  s.inset = m.STRIP_PAD
  -- The list's header and minimum rows, plus its outline.
  s.list = (reaper.ImGui_GetTextLineHeight(ctx) + 2 * cell_padding) * (m.BROWSER_LIST_MIN_ROWS + 1)
    + theme.scale
  s.readings = readings.section_height(n)
  s.wave, s.ruler = m.BROWSER_PANEL_WAVE_H, m.RULER_H
  s.frame_pad = m.FRAME_PAD_Y
  s.bottom_pad = m.STRIP_PAD
  return panel_layout.form_heights(s, library_forms)
end

-- The most rows of readings, up to limit, that fit a Library `width` wide.
local function library_reading_rows(ctx, width, limit)
  readings.rows_for_width(ctx, width - 2 * theme.metrics.WINDOW_PAD, library_sizes.rows)
  return card_plan.rows_up_to(library_sizes, limit)
end

local function layout_options(ctx, state, width, height)
  local sizes = controls.measure(ctx)
  local o = {
    width = width, height = height, scale = theme.scale,
    library = library_docked(state),
    library_width = drag and drag.width or state.library_panel_width,
    library_minimum = library_minimum(ctx),
    block_width = sizes.block_width,
    card_minimum = sizes.card_minimum,
    card_natural = sizes.card_natural,
    card_height = card_drag and card_drag.height or state.stacked_card_height,
  }
  -- Stacking needs the Library to show its list with its readings below, at
  -- the width it would have there.
  library_heights(ctx, library_reading_rows(ctx, layout.stacked_width(o), 3))
  o.library_min_height = library_forms.list
  -- Dragging the card down stops before the Library's waveform would
  -- shrink from the height the user gave it.
  o.library_keep_height = library_forms.list + math.max(0,
    (state.browser_wave_h or 0) * theme.scale - theme.metrics.BROWSER_PANEL_WAVE_H)
  return o
end

-- The floating window's floor, excluding its own padding and title bar.
function host.minimum_size(ctx, state)
  return layout.minimum(layout_options(ctx, state, 0, 0))
end

local function child(ctx, id, x, y, width, height, padding)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  -- The outer window supplies vertical padding. The Library adds its own
  -- horizontal inset; the card and the panels use the full width.
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), padding, 0)
  -- None of them scroll: a docker shorter than the card cuts it off instead.
  local flags = reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
  local child_flags = reaper.ImGui_ChildFlags_AlwaysUseWindowPadding
    and reaper.ImGui_ChildFlags_AlwaysUseWindowPadding() or 0
  local visible = reaper.ImGui_BeginChild(ctx, id, width, height, child_flags, flags)
  reaper.ImGui_PopStyleVar(ctx)
  return visible
end

-- A drop the hosted view consumed must reach the outer release handler intact.
local function merge(action, new)
  if new and new.wins_release then return new end
  if action and action.wins_release then return action end
  return actions.combine(action, new)
end

-- Drags the Library's right edge. The same edge resizes the shared column
-- when the card and Library are stacked.
local function resize_handle(ctx, x, y, width, height, gap, scale)
  local action
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_InvisibleButton(ctx, '##library_divider', gap, height)
  local hot, held = reaper.ImGui_IsItemHovered(ctx), reaper.ImGui_IsItemActive(ctx)
  local mx = reaper.ImGui_GetMousePos(ctx)
  if reaper.ImGui_IsItemActivated(ctx) then
    drag = { mouse = mx, initial = width / scale, width = width / scale }
  end
  if held and drag then
    drag.width = drag.initial + (mx - drag.mouse) / scale
  elseif drag then
    action = { type = 'set_library_panel_width', width = drag.width }
    drag = nil
  end
  if hot or held then reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeEW()) end
  return action, hot, held
end

-- Drags the gap between the card and the Library stacked below it. The
-- height is committed on release; double-click or right-click returns the
-- card to its natural height.
local function card_handle(ctx, x, y, width, gap, card_h, scale)
  local action
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_InvisibleButton(ctx, '##card_divider', width, gap)
  local hot, held = reaper.ImGui_IsItemHovered(ctx), reaper.ImGui_IsItemActive(ctx)
  local my = select(2, reaper.ImGui_GetMousePos(ctx))
  if widgets.wants_reset(ctx) then
    -- The double-click's own press must not start a drag that commits on release.
    card_drag = nil
    action = { type = 'set_stacked_card_height' }
  elseif reaper.ImGui_IsItemActivated(ctx) then
    card_drag = { mouse = my, initial = card_h / scale, height = card_h / scale }
  elseif held and card_drag then
    card_drag.height = card_drag.initial + (my - card_drag.mouse) / scale
  elseif card_drag and not held then
    action = { type = 'set_stacked_card_height', height = card_drag.height }
    card_drag = nil
  end
  if hot or held then reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeNS()) end
  return action, hot, held
end

function host.draw(ctx, state, res)
  local t, scale = theme.tokens, theme.scale
  local action, wave_id, wave_cols, browse_id, browse_cols
  -- Overflow is reserved for undersized dockers; a normal floating window fits everything.
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
  local visible = reaper.ImGui_BeginChild(ctx, 'library_reference_host', 0, 0, 0,
    reaper.ImGui_WindowFlags_HorizontalScrollbar())
  reaper.ImGui_PopStyleVar(ctx)
  if not visible then return end

  local width, height = reaper.ImGui_GetContentRegionAvail(ctx)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local options = layout_options(ctx, state, width, height)
  local g = layout.resolve(options)
  -- A drag reports the size the layout actually allowed, not the raw mouse.
  if drag and g.library then drag.width = g.library.w / scale end
  if card_drag and g.resize_y then card_drag.height = g.reference.h / scale end

  local card_hot, card_held
  if g.resize_y then
    local card_action
    card_action, card_hot, card_held = card_handle(ctx, x, y + g.resize_y, g.reference.w, g.gap,
      g.reference.h, scale)
    action = merge(action, card_action)
  end

  local hot, held
  if g.library then
    local resize_action
    resize_action, hot, held = resize_handle(ctx, x + g.resize_x, y, g.library.w, height, g.gap, scale)
    action = merge(action, resize_action)
    local l = g.library
    -- What a card of the Library's height shows. Beside the card the two have
    -- the same height and width rules, so the Library's picker form matches
    -- the card row for row; its own width may fit fewer readings, and then its
    -- waveform takes their height.
    local plan = controls.plan(ctx, l.h, g.placement == 'beside_library' and g.reference.w or l.w,
      library_plan)
    local rows = library_reading_rows(ctx, l.w, plan.readings)
    library_heights(ctx, rows)
    local form = panel_layout.form(l.h, library_forms)
    library_opts.bottom_pad = theme.metrics.STRIP_PAD
    library_opts.plan, library_opts.readings = plan, rows
    -- The audition buttons match the card's bottom-row buttons.
    library_opts.cell_w = controls.cell_width(ctx, g.reference.w)
    -- Clipped to the docker, so a short docker cuts the Library off rather
    -- than growing the host a scrollbar.
    if child(ctx, 'embedded_library', x + l.x, y + l.y, l.w, math.min(l.h, height - l.y),
        theme.metrics.WINDOW_PAD) then
      local library_action
      library_opts.form = form
      library_action, browse_id, browse_cols = browser.draw(ctx, state, res, library_opts)
      action = merge(action, library_action)
      walkthrough.note_rect(ctx, state.walkthrough, 'library', x + l.x, y + l.y, x + l.x + l.w, y + l.y + l.h)
      walkthrough.wash(ctx, state.walkthrough, 'browser')
      reaper.ImGui_EndChild(ctx)
    end
  end

  -- The panels first: when they share their area with the card, its height
  -- comes from their rows, and the card drawn after them takes the mouse
  -- over its own corner.
  local s, p = g.strip, g.panels
  local card
  if g.shared then
    card_info.width, card_info.natural = s.w + g.gap, options.card_natural
    card_info.minimum = options.card_minimum
    card = card_info
  end
  if child(ctx, 'embedded_reference', x + p.x, y + p.y, p.w, p.h, 0) then
    local reference_action, card_h = reference.draw(ctx, state, res, card)
    action = merge(action, reference_action)
    if card then
      g.reference.h = math.max(card_h, options.card_minimum)
      s.h = math.min(s.h, card_h)
    end
    walkthrough.note_rect(ctx, state.walkthrough, 'pin', x + s.x, y, x + g.width, y + height)
    -- Sharing its area with the card, the panels' wash waits until the card
    -- has noted its own targets, and then covers the card too.
    if not card then walkthrough.wash(ctx, state.walkthrough, 'main') end
    reaper.ImGui_EndChild(ctx)
  end

  if child(ctx, 'reference_strip', x + s.x, y + s.y, s.w, s.h, 0) then
    local card_action
    card_action, wave_id, wave_cols = controls.draw(ctx, state, res, g)
    action = merge(action, card_action)
    -- The drop target puts the cursor back where it found it. Below the card's
    -- last control that would be past the drawn content, which ImGui rejects
    -- when the child closes, so it starts from the card's top-left corner.
    -- Submitted after the controls, so they keep the pointer outside a drag.
    reaper.ImGui_SetCursorScreenPos(ctx, x + s.x, y + s.y)
    action = merge(action, reference.drop_targets(ctx, state, x + s.x, y + s.y, x + s.x + s.w, y + s.y + s.h))
    if not card then walkthrough.wash(ctx, state.walkthrough, 'main') end
    reaper.ImGui_EndChild(ctx)
  end
  if card then walkthrough.wash(ctx, state.walkthrough, 'main', x + p.x, y + p.y, p.w, p.h) end

  -- The regions are separated by plain gaps, like the panels' dividers. The
  -- Library's resizable gap fills while hovered or dragged, as theirs do.
  if hot or held then
    local gx = x + g.resize_x
    reaper.ImGui_DrawList_AddRectFilled(reaper.ImGui_GetWindowDrawList(ctx), gx, y, gx + g.gap,
      y + height, held and t.FILL_PRIMARY or t.FILL_SECONDARY)
  end
  if card_hot or card_held then
    local gy = y + g.resize_y
    reaper.ImGui_DrawList_AddRectFilled(reaper.ImGui_GetWindowDrawList(ctx), x, gy,
      x + g.reference.w, gy + g.gap, card_held and t.FILL_PRIMARY or t.FILL_SECONDARY)
  end
  reaper.ImGui_EndChild(ctx)

  action = merge(action, controls.draw_popups(ctx, state, res))
  return action, wave_id, wave_cols, browse_id, browse_cols
end

return host
