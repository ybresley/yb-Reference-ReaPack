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
local icon_motion = require("ui.icon_motion")
local tips = require("ui.tips")
local focus = require("ui.focus")
local numeric_input = require("ui.numeric_input")
local pitch = require("core.pitch")
local motion = require("core.ui_motion")
local decibels = require("core.decibels")
local T = theme.tokens
local M = theme.metrics

local widgets = {}
local grab_cursor_requested = false
-- ImGui reports a disabled item as never hovered unless asked otherwise; the
-- tooltips that explain why a control is unavailable need the other answer.
local HOVER_DISABLED = reaper.ImGui_HoveredFlags_AllowWhenDisabled
  and reaper.ImGui_HoveredFlags_AllowWhenDisabled() or 0

function widgets.request_grab_cursor()
  grab_cursor_requested = true
end

function widgets.take_grab_cursor()
  local requested = grab_cursor_requested
  grab_cursor_requested = false
  return requested
end

local switch_motion, pitch_unit_motion = motion.new(), motion.new()
local multi_switch_motion = motion.new()
local preference_switch_motion, bloom_motion = motion.new(), motion.new()
local value_motion, event_motion = motion.new(128), motion.new(128)
local motion_generation = theme.motion.generation
local HAS_MOTION_CLOCK = reaper.ImGui_GetTime ~= nil and reaper.ImGui_GetFrameCount ~= nil

-- Turning motion off skips clocks and trackers; re-enabling cannot resume old FX.
local function motion_ready()
  if not theme.motion.enabled or not HAS_MOTION_CLOCK then return false end
  if motion_generation ~= theme.motion.generation then
    switch_motion, pitch_unit_motion, bloom_motion = motion.new(), motion.new(), motion.new()
    multi_switch_motion = motion.new()
    value_motion, event_motion = motion.new(128), motion.new(128)
    motion_generation = theme.motion.generation
  end
  return true
end

-- Release demonstrations draw these controls under the same ids as the live
-- ones but with their own state. Between begin_private_motion and
-- end_private_motion every tracker is swapped for a private one, so a
-- demonstration never restarts or cuts short a live control's transition, nor
-- the reverse. Both tables are reused, so the swap allocates nothing per frame.
local live_trackers, private_trackers = {}, nil
local private_active = false

local function private_set()
  return { motion.new(), motion.new(), motion.new(), motion.new(), motion.new(),
    motion.new(128), motion.new(128), generation = theme.motion.generation }
end

function widgets.begin_private_motion()
  if private_active then return end
  -- Bring the live set up to date first, so a reset can never land on the
  -- private set and leave the live one stale.
  motion_ready()
  if not private_trackers or private_trackers.generation ~= theme.motion.generation then
    private_trackers = private_set()
  end
  local live, private = live_trackers, private_trackers
  live[1], live[2], live[3], live[4] =
    switch_motion, pitch_unit_motion, multi_switch_motion, preference_switch_motion
  live[5], live[6], live[7] = bloom_motion, value_motion, event_motion
  switch_motion, pitch_unit_motion, multi_switch_motion, preference_switch_motion =
    private[1], private[2], private[3], private[4]
  bloom_motion, value_motion, event_motion = private[5], private[6], private[7]
  private_active = true
  icon_motion.begin_private()
end

function widgets.end_private_motion()
  if not private_active then return end
  local live = live_trackers
  switch_motion, pitch_unit_motion, multi_switch_motion, preference_switch_motion =
    live[1], live[2], live[3], live[4]
  bloom_motion, value_motion, event_motion = live[5], live[6], live[7]
  private_active = false
  icon_motion.end_private()
end

-- Distance along a rounded border keeps the glow's speed steady through corners.
-- The second half is the first half reflected through the rectangle's centre.
local function border_point(x0, y0, x1, y1, radius, horizontal, vertical, arc, half, distance)
  local d = distance % (half * 2)
  local reflected = d >= half
  if reflected then d = d - half end
  local x, y
  if d < horizontal then
    x, y = x0 + radius + d, y0
  elseif d < horizontal + arc then
    local angle = (d - horizontal) / radius - math.pi * 0.5
    x, y = x1 - radius + math.cos(angle) * radius,
      y0 + radius + math.sin(angle) * radius
  elseif d < horizontal + arc + vertical then
    x, y = x1, y0 + radius + d - horizontal - arc
  else
    local angle = (d - horizontal - arc - vertical) / radius
    x, y = x1 - radius + math.cos(angle) * radius,
      y1 - radius + math.sin(angle) * radius
  end
  if reflected then return x0 + x1 - x, y0 + y1 - y end
  return x, y
end

-- Paint only: no input item, retained animation state, or per-frame point tables.
function widgets.draw_border_glow(ctx, dl, x0, y0, x1, y1, radius, colour)
  if not motion_ready() or x1 <= x0 or y1 <= y0 then return end
  radius = math.max(0, math.min(radius, (x1 - x0) * 0.5, (y1 - y0) * 0.5))
  local horizontal, vertical = x1 - x0 - radius * 2, y1 - y0 - radius * 2
  local arc = math.pi * radius * 0.5
  local half = horizontal + vertical + arc * 2
  local perimeter = half * 2
  local head = (reaper.ImGui_GetTime(ctx) / theme.motion.BORDER_ORBIT % 1) * perimeter
  local tail = perimeter * 0.12
  local alpha = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha()))
  -- Three translucent strokes approximate a soft glow without textures or blur.
  -- A fixed segment budget bounds the work at every panel size and display scale.
  for layer = 3, 1, -1 do
    local thickness = M.BORDER_GLOW_WIDTH * (layer == 3 and 4 or layer == 2 and 2 or 1)
    local opacity = alpha * (layer == 3 and 0.14 or layer == 2 and 0.28 or 1)
    local px, py = border_point(x0, y0, x1, y1, radius,
      horizontal, vertical, arc, half, head - tail)
    for i = 1, 32 do
      local fraction = i / 32
      local x, y = border_point(x0, y0, x1, y1, radius,
        horizontal, vertical, arc, half, head - tail + tail * fraction)
      reaper.ImGui_DrawList_AddLine(dl, px, py, x, y,
        theme.fade(colour, opacity * fraction * fraction), thickness)
      px, py = x, y
    end
  end
end

-- Broad translucent strokes move behind a steady outline, without a bright tip.
function widgets.draw_border_halo(ctx, dl, x0, y0, x1, y1, radius, colour)
  if x1 <= x0 or y1 <= y0 then return end
  radius = math.max(0, math.min(radius, (x1 - x0) * 0.5, (y1 - y0) * 0.5))
  local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
  if motion_ready() then
    local horizontal, vertical = x1 - x0 - radius * 2, y1 - y0 - radius * 2
    local arc = math.pi * radius * 0.5
    local half = horizontal + vertical + arc * 2
    local centre = (reaper.ImGui_GetTime(ctx) / theme.motion.BORDER_HALO_ORBIT % 1) * half * 2
    local length = half * 0.6
    -- Four exterior strips exclude the panel and the border stroke itself.
    local edge = M.BORDER_GLOW_WIDTH * 0.5
    local spread = M.BORDER_GLOW_WIDTH * 7
    for side = 1, 4 do
      local cx0, cy0, cx1, cy1 = x0 - spread, y0 - spread, x1 + spread, y1 + spread
      if side == 1 then cy1 = y0 - edge
      elseif side == 2 then cy0 = y1 + edge
      elseif side == 3 then cx1, cy0, cy1 = x0 - edge, y0 - edge, y1 + edge
      else cx0, cy0, cy1 = x1 + edge, y0 - edge, y1 + edge end
      reaper.ImGui_DrawList_PushClipRect(dl, cx0, cy0, cx1, cy1, true)
      -- Smoothly taper both ends of a wide glow; no moving stroke sits on the line.
      for layer = 3, 1, -1 do
        local px, py = border_point(x0, y0, x1, y1, radius,
          horizontal, vertical, arc, half, centre - length / 2)
        for segment = 1, 48 do
          local x, y = border_point(x0, y0, x1, y1, radius,
            horizontal, vertical, arc, half, centre - length / 2 + length * segment / 48)
          local taper = math.sin(math.pi * (segment - 0.5) / 48) ^ 2
          reaper.ImGui_DrawList_AddLine(dl, px, py, x, y,
            theme.fade(colour, alpha * taper * (layer == 3 and 0.035 or layer == 2 and 0.055 or 0.08)),
            M.BORDER_GLOW_WIDTH * (layer == 3 and 12 or layer == 2 and 8 or 4))
          px, py = x, y
        end
      end
      reaper.ImGui_DrawList_PopClipRect(dl)
    end
  end
  -- Paint last so the outline retains the same colour and brightness everywhere.
  reaper.ImGui_DrawList_AddRect(dl, x0, y0, x1, y1,
    theme.fade(colour, alpha * 0.7), radius, 0, M.BORDER_GLOW_WIDTH)
end

local function preference_switch_active(id)
  local entry = preference_switch_motion.entries[id]
  local slide = entry and entry.slide
  return slide and slide.value ~= slide.target
end

local function clear_preference_switch(id)
  if preference_switch_motion.entries[id] then
    preference_switch_motion.entries[id] = nil
    preference_switch_motion.count = preference_switch_motion.count - 1
  end
end

function widgets.motion_value(ctx, id, target, duration)
  if not motion_ready() then return target end
  return motion.value(value_motion, id, target,
    reaper.ImGui_GetTime(ctx), reaper.ImGui_GetFrameCount(ctx), duration)
end

function widgets.motion_event(ctx, id, on, duration, trigger)
  if not motion_ready() then return nil end
  return motion.event(event_motion, id, on,
    reaper.ImGui_GetTime(ctx), reaper.ImGui_GetFrameCount(ctx), duration, trigger)
end

-- Paint only: the existing button keeps its hit target, state colours and glyph.
-- A few translucent outlines approximate the glow without images or blur passes.
function widgets.button_bloom(ctx, id, on, colour, trigger, strong, glow_gain, bounds, revision)
  if not motion_ready() then return end
  local strength = motion.pulse(bloom_motion, id, on,
    reaper.ImGui_GetTime(ctx), reaper.ImGui_GetFrameCount(ctx),
    theme.motion.BUTTON_BLOOM, trigger, revision)
  if strength <= 0 then return end
  local alpha = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha()))
  local rounding = select(1,
    reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding()))
  local x0, y0, x1, y1
  if bounds then
    x0, y0, x1, y1 = bounds.left, bounds.top, bounds.right, bounds.bottom
  else
    x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
    x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
  end
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local spread = M.BUTTON_BLOOM_SPREAD
  local bands = 8
  local step = spread / bands
  local glow_opacity = 0.22 * (glow_gain or 1)
  for i = bands, 1, -1 do
    local outset = (i - 0.5) * step
    local opacity = glow_opacity * math.exp(-3 * (outset / spread) ^ 2)
    reaper.ImGui_DrawList_AddRect(dl, x0 - outset, y0 - outset,
      x1 + outset, y1 + outset, theme.fade(colour, opacity * strength * alpha),
      rounding + outset, 0, step)
  end
  reaper.ImGui_DrawList_AddRect(dl, x0, y0, x1, y1,
    theme.fade(colour, strength * alpha), rounding, 0, 1.5)
  if strong then
    reaper.ImGui_DrawList_AddRectFilled(dl, x0 + 1, y0 + 1, x1 - 1, y1 - 1,
      theme.fade(colour, 0.42 * strength * alpha), rounding)
  end
end

-- All audio Play controls use the same confirmed-start bloom. Hand-drawn
-- controls supply their painted bounds rather than a neighbouring hit target.
function widgets.play_bloom(ctx, id, playing, bounds, trigger, revision)
  widgets.button_bloom(ctx, "play_" .. id, playing, T.ACCENT,
    trigger, false, 1.6, bounds, revision)
end

-- Match the normal button border. AddRect applies its own half-pixel inset.
function widgets.button_outline(ctx, colour)
  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
  local rounding = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding())
  local thickness = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize())
  local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
  reaper.ImGui_DrawList_AddRect(reaper.ImGui_GetWindowDrawList(ctx),
    x0, y0, x1, y1, theme.fade(colour, alpha), rounding, 0, thickness)
end

-- Persistent button states share a soft accent wash and outline instead of a
-- solid face. Callers keep ownership of what "active" means; this helper only
-- keeps that state looking identical.
function widgets.push_soft_active(ctx, active)
  if not active then return false end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), T.ACTIVE_CONTROL_FILL)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.ACTIVE_CONTROL_HOVER)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), T.ACTIVE_CONTROL_HELD)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), T.ACTIVE_CONTROL_BORDER)
  return true
end

function widgets.pop_soft_active(ctx, pushed)
  if pushed then reaper.ImGui_PopStyleColor(ctx, 4) end
end

-- A joined group of buttons: one rounded frame, square cells of equal width and
-- hairlines between them. Draw it as begin_segment, then each cell at
-- segment_edge(i) with width segment_edge(i + 1) - segment_edge(i), then
-- end_segment. Cells keep their own active wash and hover; only the frame is shared.
function widgets.segment_edge(x0, x1, cells, i)
  return math.floor(x0 + i * (x1 - x0) / cells + 0.5)
end

-- The hairline outline around a card: the Reference card and the docked
-- Library. Inset by half the stroke so it stays inside the window's clip edge.
function widgets.card_outline(ctx, x0, y0, x1, y1)
  local stroke = theme.scale
  local half = stroke * 0.5
  reaper.ImGui_DrawList_AddRect(reaper.ImGui_GetWindowDrawList(ctx),
    x0 + half, y0 + half, x1 - half, y1 - half, T.STROKE_SECONDARY,
    reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding()), 0, stroke)
end

-- Puts the cursor at cell i (0-based) of a joined group of n equal cells
-- from x0 to x1 and returns that cell's width and left edge.
function widgets.segment_cell(ctx, x0, x1, n, i, y)
  local cx = widgets.segment_edge(x0, x1, n, i)
  reaper.ImGui_SetCursorScreenPos(ctx, cx, y)
  return widgets.segment_edge(x0, x1, n, i + 1) - cx, cx
end

-- Previous and next as one joined pair at (x, y), `w` wide. Dim but still in
-- place when `live` is false, so nothing ever disappears. `id` keeps pairs
-- apart. Returns -1 or 1 for the arrow clicked this frame.
function widgets.step_arrows(ctx, font, id, x, y, w, live, prev_tip, next_tip)
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local left_w = math.floor(w / 2 + 0.5)
  local delta
  widgets.begin_segment(ctx, x, y, x + w, y + ctrl)
  if not live then reaper.ImGui_BeginDisabled(ctx) end
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  if reaper.ImGui_Button(ctx, (font and icons.NAMES["chevron-left"] and "" or "\u{2039}") .. "##" .. id .. "_prev",
      left_w, ctrl) then
    delta = -1
  end
  icons.paint_over_item(ctx, font, "chevron-left")
  tips.show(ctx, live and reaper.ImGui_IsItemHovered(ctx), prev_tip)
  reaper.ImGui_SetCursorScreenPos(ctx, x + left_w, y)
  if reaper.ImGui_Button(ctx, (font and icons.NAMES["chevron-right"] and "" or "\u{203A}") .. "##" .. id .. "_next",
      w - left_w, ctrl) then
    delta = 1
  end
  icons.paint_over_item(ctx, font, "chevron-right")
  tips.show(ctx, live and reaper.ImGui_IsItemHovered(ctx), next_tip)
  if not live then reaper.ImGui_EndDisabled(ctx) end
  widgets.end_segment(ctx, x, y, x + w, y + ctrl, 2)
  return delta
end

-- The widest "n/total" count in the small font, so a count beside the arrows
-- can reserve its space and never move them as it grows. 0 for no items.
function widgets.count_width(ctx, total)
  if total <= 0 then return 0 end
  local small = theme.push_small_font(ctx)
  local w = reaper.ImGui_CalcTextSize(ctx, total .. "/" .. total)
  if small then reaper.ImGui_PopFont(ctx) end
  return w
end

-- A count such as "2/6" in the small font, centred in `w` at (x, y), so the
-- room either side stays even as it changes.
function widgets.draw_count(ctx, text, x, y, w)
  local small = theme.push_small_font(ctx)
  local tw, th = reaper.ImGui_CalcTextSize(ctx, text)
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  reaper.ImGui_DrawList_AddText(reaper.ImGui_GetWindowDrawList(ctx), math.floor(x + (w - tw) * 0.5 + 0.5),
    math.floor(y + (ctrl - th) * 0.5 + 0.5), T.TEXT_PRIMARY, text)
  if small then reaper.ImGui_PopFont(ctx) end
end

function widgets.begin_segment(ctx, x0, y0, x1, y1)
  local rounding = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding())
  local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
  reaper.ImGui_DrawList_AddRectFilled(reaper.ImGui_GetWindowDrawList(ctx),
    x0, y0, x1, y1, theme.fade(T.FILL_TERTIARY, alpha), rounding)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 0)
  -- The shared background already shows; an idle cell adds nothing on top.
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0)
end

function widgets.end_segment(ctx, x0, y0, x1, y1, cells)
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_PopStyleVar(ctx, 2)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local rounding = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding())
  local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
  local line = theme.fade(T.STROKE_SECONDARY, alpha)
  for i = 1, cells - 1 do
    local dx = widgets.segment_edge(x0, x1, cells, i) + 0.5
    reaper.ImGui_DrawList_AddLine(dl, dx, y0 + 1, dx, y1 - 1, line)
  end
  reaper.ImGui_DrawList_AddRect(dl, x0, y0, x1, y1, line, rounding)
end

-- Share the open-panel frame between square icons and the wide sound picker.
function widgets.panel_button_frame(ctx, label, width, height, open)
  local pushed = widgets.push_soft_active(ctx, open)
  local clicked = reaper.ImGui_Button(ctx, label, width, height)
  widgets.pop_soft_active(ctx, pushed)
  return clicked
end

-- Equal-sized panel choices keep their names visible beneath the identifying icon.
function widgets.icon_label_toggle(ctx, font, id, label, icon, on, width, enabled)
  local disabled = enabled == false
  if disabled then reaper.ImGui_BeginDisabled(ctx) end
  local tw, th = reaper.ImGui_CalcTextSize(ctx, label)
  local height = M.FRAME_PAD_Y*4 + M.ICON_FS + M.FRAME_PAD_Y + th
  local clicked = widgets.panel_button_frame(ctx, '##' .. id, width, height, on)
  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local x1 = select(1, reaper.ImGui_GetItemRectMax(ctx))
  local cx = (x0+x1)*0.5
  local colour = on and T.ACCENT_HOVER or T.TEXT_SECONDARY
  local icon_y = y0 + M.FRAME_PAD_Y*2 + M.ICON_FS*0.5
  local painted = icons.paint_glyph(ctx, font, icon, cx, icon_y, colour, M.ICON_FS)
  local text_y = painted and (icon_y + M.ICON_FS*0.5 + M.FRAME_PAD_Y)
    or (y0 + (height-th)*0.5)
  local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
  reaper.ImGui_DrawList_AddText(reaper.ImGui_GetWindowDrawList(ctx),
    math.floor(cx-tw*0.5+0.5), math.floor(text_y+0.5), theme.fade(colour, alpha), label)
  if disabled then reaper.ImGui_EndDisabled(ctx) end
  return not disabled and clicked
end

-- Independent segments share the stereoscope switch's fixed track and accent face.
function widgets.multi_switch(ctx, id, choices, width)
  local result
  local height = reaper.ImGui_GetFrameHeight(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  for i, choice in ipairs(choices) do
    if i > 1 then reaper.ImGui_SameLine(ctx, 0, 0) end
    local disabled = choice.enabled == false
    if disabled then reaper.ImGui_BeginDisabled(ctx) end
    local clicked = reaper.ImGui_InvisibleButton(ctx, '##' .. id .. choice.key, width / #choices, height)
    local hovered = reaper.ImGui_IsItemHovered(ctx)
    local tip_hovered = disabled and HOVER_DISABLED ~= 0
      and reaper.ImGui_IsItemHovered(ctx, HOVER_DISABLED) or hovered
    local active = reaper.ImGui_IsItemActive(ctx)
    local x0,y0 = reaper.ImGui_GetItemRectMin(ctx)
    local x1,y1 = reaper.ImGui_GetItemRectMax(ctx)
    local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
    local on = choice.on
    if clicked and not disabled then on = not choice.on; result = choice.key end
    local position = on and 1 or 0
    if motion_ready() then
      position = motion.slide(multi_switch_motion, id .. choice.key, on,
        reaper.ImGui_GetTime(ctx), reaper.ImGui_GetFrameCount(ctx), theme.motion.SWITCH_SLIDE)
    end
    local base = active and T.FILL_PRIMARY or hovered and T.FILL_TERTIARY or T.FILL_QUATERNARY
    local selected = active and T.ACTIVE_CONTROL_HELD or hovered and T.ACTIVE_CONTROL_HOVER or T.ACTIVE_CONTROL_FILL
    reaper.ImGui_DrawList_AddRectFilled(dl,x0,y0,x1,y1,theme.fade(theme.blend(base,selected,position),alpha),0)
    reaper.ImGui_DrawList_AddRect(dl,x0,y0,x1,y1,
      theme.fade(theme.blend(T.STROKE_SECONDARY,T.ACTIVE_CONTROL_BORDER,position),alpha),0,0,1)
    local tw,th = reaper.ImGui_CalcTextSize(ctx,choice.label)
    reaper.ImGui_DrawList_AddText(dl,x0+(x1-x0-tw)/2,y0+(y1-y0-th)/2,
      theme.fade(theme.blend(T.TEXT_SECONDARY,T.ACCENT,position),alpha),choice.label)
    if disabled then reaper.ImGui_EndDisabled(ctx) end
    tips.show(ctx,tip_hovered,choice.tip,id .. choice.key)
  end
  return result
end

-- An open panel uses the shared active treatment. `highlighted` also allows
-- Pitch to keep that treatment while an adjustment remains set and the panel
-- itself is closed.
-- width: optional, for a cell in a joined button group; the icon stays centred.
function widgets.panel_button(ctx, font, id, icon, open, fallback, highlighted, enabled, press_on_down, width)
  local size = reaper.ImGui_GetFrameHeight(ctx)
  local use_icon = font and icons.NAMES[icon]
  local accented = open or highlighted
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
    accented and T.ACCENT_HOVER or T.TEXT_SECONDARY)
  local label = not use_icon and not icon_motion.supports(icon)
    and type(fallback) == 'string' and fallback or ''
  local clicked = widgets.panel_button_frame(ctx, label .. '##' .. id, width or size, size, accented)
  reaper.ImGui_PopStyleColor(ctx)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local colour = accented and T.ACCENT_HOVER
    or (hovered and T.TEXT_PRIMARY or T.TEXT_SECONDARY)
  local motion_clicked = clicked
  if press_on_down then
    motion_clicked = enabled ~= false and hovered and reaper.ImGui_IsMouseClicked(ctx, 0)
  end
  local animated = icon_motion.paint_item(ctx, id, icon, colour, open, motion_clicked, enabled, font)
  if not animated and use_icon then
    icons.paint_over_item(ctx, font, icon, {color = colour})
  elseif not animated and type(fallback) == 'function' then
    local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
    local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
    local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
    fallback(reaper.ImGui_GetWindowDrawList(ctx),
      (x0 + x1) * 0.5, (y0 + y1) * 0.5, theme.fade(colour, alpha))
  end
  return clicked, hovered
end

-- Plot settings share Spectrum's opaque backing, hover outline and animated icon.
-- Spectrum supplies the backing for its whole listening-control strip.
function widgets.plot_settings_button(ctx, font, id, open, backing)
  local size = reaper.ImGui_GetFrameHeight(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
  if backing ~= false then
    local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
    local rounding = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding())
    local pad = 2 * theme.scale
    reaper.ImGui_DrawList_AddRectFilled(dl, x-pad, y-pad, x+size+pad, y+size+pad,
      theme.fade(T.BG_POPUP, alpha), rounding+pad)
    reaper.ImGui_DrawList_AddRect(dl, x-pad+.5, y-pad+.5, x+size+pad-.5, y+size+pad-.5,
      theme.fade(T.STROKE_SECONDARY, alpha), rounding+pad, 0, 1)
  end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), open and T.ACTIVE_CONTROL_FILL or 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), open and T.ACTIVE_CONTROL_HOVER or 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), open and T.ACTIVE_CONTROL_HELD or T.FILL_PRIMARY)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), 0)
  local clicked = reaper.ImGui_Button(ctx, '##' .. id, size, size)
  reaper.ImGui_PopStyleColor(ctx, 4)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local colour = open and T.ACCENT_HOVER or hovered and T.TEXT_PRIMARY or T.TEXT_SECONDARY
  if not icon_motion.paint_item(ctx, id, 'sliders-horizontal', colour, open, clicked, nil, font)
      and not icons.paint_over_item(ctx, font, 'sliders-horizontal', {color=colour}) then
    local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
    local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
    icons.draw_gear(dl, (x0+x1)*.5, (y0+y1)*.5, theme.fade(colour, alpha))
  end
  if open or hovered then
    widgets.button_outline(ctx, open and T.ACTIVE_CONTROL_BORDER or T.STROKE_PRIMARY)
  end
  return clicked, hovered
end

local HAS_GROUP_CHILD = reaper.ImGui_ChildFlags_AutoResizeY ~= nil
  and reaper.ImGui_Col_Border ~= nil

-- Untitled panels use the title bar's quiet cross and inset red hover chip.
function widgets.close_button(ctx, id)
  local size = reaper.ImGui_GetFrameHeight(ctx)
  local clicked = reaper.ImGui_InvisibleButton(ctx, '##' .. id, size, size)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local held = reaper.ImGui_IsItemActive(ctx)
  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
  local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  x0, y0 = math.floor(x0 + M.CLOSE_INSET), math.floor(y0 + M.CLOSE_INSET)
  x1, y1 = math.floor(x1 - M.CLOSE_INSET), math.floor(y1 - M.CLOSE_INSET)
  if hovered then
    reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x1, y1,
      theme.fade(held and T.CLOSE_HELD or T.CLOSE_HOVER, alpha), M.CLOSE_ROUNDING)
  end
  local cx, cy = (x0 + x1) * .5, (y0 + y1) * .5
  local arm = (x1 - x0) * .21
  local colour = theme.fade(hovered and T.TEXT_PRIMARY or T.TEXT_TERTIARY, alpha)
  reaper.ImGui_DrawList_AddLine(dl, cx-arm, cy-arm, cx+arm, cy+arm, colour, M.CLOSE_STROKE)
  reaper.ImGui_DrawList_AddLine(dl, cx-arm, cy+arm, cx+arm, cy-arm, colour, M.CLOSE_STROKE)
  tips.show(ctx, hovered, 'Close', id)
  return clicked
end

-- Settings windows share the heading and box; each caller owns its row layout.
-- Omit title when the caller provides a heading inside the box, such as a foldout.
-- fill_height accepts true for remaining space, or a measured height to avoid auto-sizing.
-- close_id adds a frame-height close control beside the heading.
function widgets.begin_settings_group(ctx, id, title, first, fill_height, inset, close_id)
  local pad_x = inset and inset.pad_x or M.WINDOW_PAD
  local pad_y = inset and inset.pad_y or M.WINDOW_PAD
  if not first then
    reaper.ImGui_SetCursorPosY(ctx,
      reaper.ImGui_GetCursorPosY(ctx) + M.ITEM_SPACING_Y)
  end
  local closed
  if title then
    local x = reaper.ImGui_GetCursorPosX(ctx)
    local width = close_id and reaper.ImGui_GetContentRegionAvail(ctx)
    reaper.ImGui_SetCursorPosX(ctx, x + pad_x)
    if close_id then reaper.ImGui_AlignTextToFramePadding(ctx) end
    local bold = theme.push_bold_font(ctx)
    reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, title:upper())
    if bold then reaper.ImGui_PopFont(ctx) end
    if close_id then
      reaper.ImGui_SameLine(ctx, x + width - reaper.ImGui_GetFrameHeight(ctx))
      closed = widgets.close_button(ctx, close_id)
    end
    reaper.ImGui_SetCursorPosX(ctx, x)
  end

  if not HAS_GROUP_CHILD then return true, false, closed end
  local height = type(fill_height) == 'number' and fill_height
    or (inset and inset.height or 0)
  local child_flags = (fill_height or height > 0) and 0 or reaper.ImGui_ChildFlags_AutoResizeY()
  if reaper.ImGui_ChildFlags_Borders then
    child_flags = child_flags | reaper.ImGui_ChildFlags_Borders()
  elseif reaper.ImGui_ChildFlags_AlwaysUseWindowPadding then
    child_flags = child_flags | reaper.ImGui_ChildFlags_AlwaysUseWindowPadding()
  end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), T.SET_GROUP_BG)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),
    inset and inset.border or T.STROKE_SECONDARY)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), pad_x, pad_y)
  local opened = reaper.ImGui_BeginChild(ctx, id, 0, height, child_flags,
    reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse())
  reaper.ImGui_PopStyleVar(ctx)
  reaper.ImGui_PopStyleColor(ctx, 2)
  -- ReaImGui ends a clipped child itself; only an opened child needs EndChild.
  return opened, opened, closed
end

function widgets.end_settings_group(ctx, child)
  if child then reaper.ImGui_EndChild(ctx) end
end

local foldout_inset = {pad_x=0, pad_y=0}
local foldout_body_inset = {border=0}

-- One surface surrounds the header and body; only the body receives content padding.
function widgets.settings_foldout(ctx, id, label, draw)
  local opened, child = widgets.begin_settings_group(ctx, id, nil, false, nil, foldout_inset)
  local action
  if opened then
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 0)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), M.ITEM_SPACING_X, 0)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(), 0)
    local bold = theme.push_bold_font(ctx)
    local expanded = reaper.ImGui_CollapsingHeader(ctx, label .. '##foldout')
    if bold then reaper.ImGui_PopFont(ctx) end
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_PopStyleVar(ctx, 2)
    if expanded then
      local body_open, body_child = widgets.begin_settings_group(ctx, id .. '_body', nil, true, nil, foldout_body_inset)
      if body_open then action = draw() end
      widgets.end_settings_group(ctx, body_child)
    end
  end
  widgets.end_settings_group(ctx, child)
  return action
end

-- The selected tab meets the content below it with an open bottom edge.
function widgets.attached_tab(ctx, label, id, selected, width, height)
  local clicked = reaper.ImGui_InvisibleButton(ctx, id, width, height)
  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
  local rounding = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding())
  local corners = reaper.ImGui_DrawFlags_RoundCornersTop()
  if selected or hovered then
    reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x1, selected and y1 + 1 or y1,
      theme.fade(selected and T.BG_WINDOW or T.FILL_TERTIARY, alpha), rounding, corners)
  end
  if selected then
    -- An open outline avoids the faint bottom edge left by painting over a border.
    local radius = math.min(rounding, width * 0.5, height)
    reaper.ImGui_DrawList_PathLineTo(dl, x0, y1)
    reaper.ImGui_DrawList_PathArcTo(dl, x0 + radius, y0 + radius,
      radius, math.pi, math.pi * 1.5)
    reaper.ImGui_DrawList_PathArcTo(dl, x1 - radius, y0 + radius,
      radius, math.pi * 1.5, math.pi * 2)
    reaper.ImGui_DrawList_PathLineTo(dl, x1, y1)
    reaper.ImGui_DrawList_PathStroke(dl, theme.fade(T.STROKE_SECONDARY, alpha), 0, 1)
  end
  local bold = theme.push_bold_font(ctx, M.SETTINGS_TAB_FS)
  local tw, th = reaper.ImGui_CalcTextSize(ctx, label)
  reaper.ImGui_DrawList_AddText(dl,
    math.floor((x0 + x1 - tw) * 0.5 + 0.5), math.floor((y0 + y1 - th) * 0.5 + 0.5),
    theme.fade(selected and T.ACCENT or T.TEXT_PRIMARY, alpha), label)
  if bold then reaper.ImGui_PopFont(ctx) end
  return clicked
end

-- Clickable labels keep the same quiet appearance as nearby readouts.
function widgets.text_button(ctx, id, label, width, height, size, tip)
  local x,y=reaper.ImGui_GetCursorScreenPos(ctx)
  local clicked=reaper.ImGui_InvisibleButton(ctx,id,width,height)
  local hovered=reaper.ImGui_IsItemHovered(ctx)
  local font=theme.push_release_font(ctx,size)
  local tw,th=reaper.ImGui_CalcTextSize(ctx,label)
  local colour=hovered and T.TEXT_PRIMARY or T.TEXT_SECONDARY
  local alpha=reaper.ImGui_GetStyleVar(ctx,reaper.ImGui_StyleVar_Alpha())
  local dl=reaper.ImGui_GetWindowDrawList(ctx)
  local text_x=x+(width-tw)/2
  reaper.ImGui_DrawList_AddText(dl,text_x,y,theme.fade(colour,alpha),label)
  if hovered then
    local underline_y=y+th+theme.scale
    reaper.ImGui_DrawList_AddLine(dl,text_x,underline_y,text_x+tw,underline_y,
      theme.fade(T.TEXT_TERTIARY,alpha),theme.scale)
  end
  if font then reaper.ImGui_PopFont(ctx) end
  tips.show(ctx,hovered,tip,id)
  return clicked
end

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
-- drawn by the Button itself. An active tool keeps a quiet fill and accent
-- glyph without changing its bounds.
function widgets.glyph_button(ctx, font, id, glyph, fallback, w, h, tip, hot_color, active)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), active and T.FILL_SECONDARY or 0)
  local has_icon = font and icons.NAMES[glyph]
  local clicked = reaper.ImGui_Button(ctx, (has_icon and "" or fallback) .. "##" .. id, w, h)
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_PopStyleVar(ctx, 1)
  local hot = reaper.ImGui_IsItemHovered(ctx)
  if has_icon then
    local colour = active and (hot and T.ACCENT_HOVER or T.ACCENT)
      or ((hot and hot_color) and hot_color or nil)
    icons.paint_over_item(ctx, font, glyph, colour and { color = colour } or nil)
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

-- Shared with release demonstrations, so a scripted drag shows the bar's own values.
widgets.taper_db = taper_db

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

-- Every stepped slider shares one quiet confirmation at the knob's
-- new position. The outline grows around the existing notch without affecting
-- the slider's hit target or layout.
local function draw_notch_echo(ctx, id, knob_x, cy, alpha, trigger)
  local progress = widgets.motion_event(ctx, id .. "_notch_echo", true,
    theme.motion.SLIDER_NOTCH_ECHO, trigger)
  if not progress then return end
  local half_kw, half_kh = M.FADER_KNOB_W * 0.5, M.FADER_KNOB_H * 0.5
  local growth = 1 - (1 - progress) ^ 3
  local outset_x = M.FADER_KNOB_W * (0.25 + growth * 1.2)
  local outset_y = M.FADER_KNOB_W * (0.5 + growth * 0.8)
  local echo_alpha = (1 - progress) * 0.65 * alpha
  reaper.ImGui_DrawList_AddRect(reaper.ImGui_GetWindowDrawList(ctx),
    knob_x - half_kw - outset_x, cy - half_kh - outset_y,
    knob_x + half_kw + outset_x, cy + half_kh + outset_y,
    fade(T.ACCENT, echo_alpha), half_kw + outset_x * 0.25, 0, 1.25)
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
  if opts.pitch then
    draw_notch_echo(ctx, id, knob_x, cy, alpha, result ~= nil and result ~= value)
  end
  reaper.ImGui_DrawList_AddRectFilled(dl, knob_x - half_kw, cy - half_kh,
    knob_x + half_kw, cy + half_kh, fade(T.FADER_KNOB, alpha), half_kw)

  if result ~= nil then return result, commit end
  return nil
end

function widgets.cancel_step_slider(id)
  step_slider_drag[id], reset_hold[id] = nil, nil
end

-- Open exact-entry fields of the dB bars, by control id.
local db_edit = {}
local HAS_DB_ENTER = reaper.ImGui_IsKeyPressed ~= nil and reaper.ImGui_Key_Enter ~= nil
local HAS_DB_ESCAPE = reaper.ImGui_IsKeyPressed ~= nil and reaper.ImGui_Key_Escape ~= nil
local DB_AUTO_SELECT = reaper.ImGui_InputTextFlags_AutoSelectAll
  and reaper.ImGui_InputTextFlags_AutoSelectAll() or 0

local function parse_db_entry(text, min, max)
  local value = tonumber(text)
  if not value or value ~= value then return nil end
  value = math.floor(value * 10 + 0.5) / 10
  if value < min then return min end
  if value > max then return max end
  return value
end

-- The dB bar's drag: right is louder, over opts.track pixels for the full
-- range. Integrating each movement separately lets Alt change precision
-- without jumping the value.
local HAS_ALT = reaper.ImGui_GetKeyMods ~= nil and reaper.ImGui_Mod_Alt ~= nil
local DRAG_EW_CURSOR = reaper.ImGui_MouseCursor_ResizeEW and reaper.ImGui_MouseCursor_ResizeEW()
local drag_anchor = {}

local function db_number_gesture(ctx, id, value, opts, to_t, to_db, reset, clicked)
  local active, hovered = reaper.ImGui_IsItemActive(ctx), reaper.ImGui_IsItemHovered(ctx)
  if (active or hovered) and DRAG_EW_CURSOR then reaper.ImGui_SetMouseCursor(ctx, DRAG_EW_CURSOR) end
  local key = opts.edit_key == nil and id or opts.edit_key
  local anchor = drag_anchor[id]
  if anchor and anchor.key ~= key then anchor.blocked = true end
  if reset then
    drag_anchor[id] = active and { blocked = true, key = key } or nil
    return opts.default or 0, true
  elseif reaper.ImGui_IsItemActivated(ctx) then
    drag_anchor[id] = { t = to_t(value or 0), m = (reaper.ImGui_GetMousePos(ctx)),
      moved = false, key = key }
  elseif active and anchor and not anchor.blocked then
    if reaper.ImGui_IsMouseDragging(ctx, 0) then anchor.moved = true end
    if anchor.moved then
      local m = (reaper.ImGui_GetMousePos(ctx))
      local fine = HAS_ALT and (reaper.ImGui_GetKeyMods(ctx) & reaper.ImGui_Mod_Alt()) ~= 0
      local track = opts.track
      anchor.t = math.max(0, math.min(1, anchor.t + (m - anchor.m) / track / (fine and 5 or 1)))
      anchor.m = m
      local changed = math.floor(to_db(anchor.t) * 10 + 0.5) / 10
      if changed ~= (value or 0) then return changed, false end
    end
  elseif reaper.ImGui_IsItemDeactivated(ctx) then
    drag_anchor[id] = nil
    if anchor and not anchor.blocked then
      return value or 0, true, not anchor.moved and hovered
    end
  elseif clicked then
    return nil, nil, true
  end
end

-- The typed-entry field shared by the dB controls, at the cursor. Typing
-- applies each valid value live; Enter or leaving the field commits it,
-- Escape cancels and right-click resets to `default`. Returns (value, commit)
-- when something changed this frame, whether the field ended, and whether it
-- is hovered.
local function db_entry_field(ctx, id, edit, value, min, max, default, entry_w, entry_pad, frame_pad_y)
  if edit.focus then
    reaper.ImGui_SetKeyboardFocusHere(ctx)
    edit.focus = false
  end
  reaper.ImGui_SetNextItemWidth(ctx, entry_w)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.ACCENT)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), entry_pad, frame_pad_y)
  local changed, text = numeric_input.text(ctx, "##" .. id .. "_value",
    edit.text, "signed_decimal", DB_AUTO_SELECT)
  reaper.ImGui_PopStyleVar(ctx)
  reaper.ImGui_PopStyleColor(ctx)
  local result, commit
  if changed then
    edit.text = text
    local typed = parse_db_entry(text, min, max)
    if typed ~= nil and typed ~= (value or 0) then result, commit = typed, false end
  end
  local field_active = reaper.ImGui_IsItemActive(ctx)
  if field_active then edit.active = true end
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local reset = widgets.wants_right_reset(ctx)
  local submit = field_active and HAS_DB_ENTER
    and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter())
  local cancel = field_active and HAS_DB_ESCAPE
    and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape())
  local deactivated = edit.active and reaper.ImGui_IsItemDeactivated(ctx)
  if reset then
    return default or 0, true, true, hovered
  elseif cancel then
    return nil, nil, true, hovered
  elseif submit or deactivated then
    return parse_db_entry(edit.text, min, max) or (value or 0), true, true, hovered
  end
  return result, commit, false, hovered
end

-- Pitch accepts either drag direction, so an axis-specific resize cursor would
-- promise the wrong gesture half the time. The hand says "adjustable" without
-- choosing an axis; the tooltip carries the exact behaviour.
local DRAG_FREE_CURSOR = (reaper.ImGui_MouseCursor_Hand and reaper.ImGui_MouseCursor_Hand())
  or nil

-- Whether a vertical line at `line_x` passes within `clear` of the span a..b.
local function line_crosses(line_x, clear, a, b)
  return line_x ~= nil and line_x >= a - clear and line_x <= b + clear
end

-- A dB value as one framed bar: its name inside on the left, the value and a
-- dim " dB" inside on the right, and an accent wash filling from the left up to
-- the value's position along the taper. A line marks that position and a short
-- tick marks 0 dB. The bar is a relative control: dragging left or right moves
-- the value from where it was (Alt for fine adjustment), so grabbing it never
-- jumps. A click without a drag opens exact entry over the value; Enter or
-- leaving the field applies it and Escape cancels. Right-click resets.
-- opts = { min, max, default, width, label, taper, edit_key, tip }.
-- Returns (value, commit) when something changed this frame, else nil.
function widgets.db_bar(ctx, id, value, opts)
  opts = opts or {}
  local min, max = opts.min or -24, opts.max or 24
  local taper = opts.taper == true
  local to_db = function(t) return taper and taper_db(t, max, min) or (min + t * (max - min)) end
  local to_t = function(db) return taper and taper_t(db, max, min) or ((db - min) / (max - min)) end
  local h = reaper.ImGui_GetFrameHeight(ctx)
  local pad_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding()))
  local w = opts.width or M.SLIDER_W
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  local x1, y1 = x0 + w, y0 + h
  local edit_key = opts.edit_key == nil and id or opts.edit_key
  local edit = db_edit[id]
  if edit and (edit.key ~= edit_key
      or (reaper.ImGui_IsWindowAppearing and reaper.ImGui_IsWindowAppearing(ctx))) then
    db_edit[id], edit = nil, nil
  end

  local hovered, active, reset = false, false, false
  local result, commit, enter
  if edit then
    -- While typing, the bar takes no clicks, so the entry field drawn over it
    -- owns its own text cursor and selection.
    reaper.ImGui_Dummy(ctx, w, h)
    hovered = reaper.ImGui_IsItemHovered(ctx)
  else
    local clicked = reaper.ImGui_InvisibleButton(ctx, "##" .. id, w, h)
    hovered = reaper.ImGui_IsItemHovered(ctx)
    active = reaper.ImGui_IsItemActive(ctx)
    reset = widgets.wants_reset(ctx)
    -- The full range spans the bar, so a pixel of drag matches what the fill shows.
    local gesture = { default = opts.default, edit_key = opts.edit_key, track = w }
    result, commit, enter = db_number_gesture(ctx, id .. "_bar", value, gesture,
      to_t, to_db, reset, clicked)
  end
  if not edit then tips.show(ctx, opts.tip and hovered, opts.tip, id) end
  if enter then
    edit = { key = edit_key, text = decibels.format(value or 0), focus = true, active = false }
    db_edit[id] = edit
  end
  local shown = result or value or 0

  local alpha = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha()))
  local rounding = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding())
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local hot = hovered or active
  reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x1, y1,
    fade(hot and T.FILL_TERTIARY or T.FILL_QUATERNARY, alpha), rounding)

  local t = to_t(shown)
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  local vx = math.floor(x0 + t * w + 0.5)
  if vx - x0 >= 1 then
    reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, vx, y1,
      fade(hot and T.ACTIVE_CONTROL_HOVER or T.ACTIVE_CONTROL_FILL, alpha), rounding,
      reaper.ImGui_DrawFlags_RoundCornersLeft())
  end
  -- 0 dB: one dim full-height line.
  if min < 0 and max > 0 then
    local zx = math.floor(x0 + to_t(0) * w + 0.5)
    reaper.ImGui_DrawList_AddLine(dl, zx + 0.5, y0 + 1, zx + 0.5, y1 - 1, fade(T.FADER_TICK, alpha))
  end
  reaper.ImGui_DrawList_AddRect(dl, x0, y0, x1, y1,
    fade(hot and T.STROKE_PRIMARY or T.STROKE_SECONDARY, alpha), rounding)

  local th = select(2, reaper.ImGui_CalcTextSize(ctx, "0"))
  local ty = math.floor(y0 + (h - th) * 0.5 + 0.5)
  local unit = " dB"
  local uw = select(1, reaper.ImGui_CalcTextSize(ctx, unit))

  -- Text keeps clear of the value line. A reading the line would cross moves
  -- to the line's other side when it fits there; the label moves the same way
  -- and gives way to the reading if they would meet. `clear` is the breathing
  -- room kept between the line and any text.
  local line_x = t > 0 and vx - 0.5 or nil
  local clear = math.max(3, pad_x)
  local inner0, inner1 = x0 + pad_x, x1 - pad_x
  local value_text, value_w, value_x
  if not edit then
    value_text = decibels.format(shown, taper and min or nil)
    value_w = select(1, reaper.ImGui_CalcTextSize(ctx, value_text)) + uw
    value_x = inner1 - value_w
    if line_crosses(line_x, clear, value_x, inner1) then
      if line_x - clear - value_w >= inner0 then
        value_x = line_x - clear - value_w
      elseif line_x + clear + value_w <= inner1 then
        value_x = line_x + clear
      end
    end
  end
  local value_left = value_x or inner1 - uw
  local label_x
  if opts.label then
    local lw = select(1, reaper.ImGui_CalcTextSize(ctx, opts.label))
    label_x = inner0
    if line_crosses(line_x, clear, label_x, label_x + lw) then label_x = line_x + clear end
    local value_right = value_x and value_x + value_w or inner1
    local overlaps = label_x < value_right and label_x + lw > value_left - clear
    if overlaps or label_x + lw > inner1 then label_x = nil end
  end

  if line_x then
    reaper.ImGui_DrawList_AddLine(dl, line_x, y0 + 1, line_x, y1 - 1,
      fade(hot and T.ACCENT_HOVER or T.ACCENT, alpha), 1.5)
  end
  if label_x then
    reaper.ImGui_DrawList_AddText(dl, label_x, ty, fade(T.TEXT_SECONDARY, alpha), opts.label)
  end

  if edit then
    -- The field covers the number only; the unit and label stay where they are.
    local min_w = reaper.ImGui_CalcTextSize(ctx, decibels.format(min))
    local max_w = reaper.ImGui_CalcTextSize(ctx, decibels.format(max))
    local entry_pad = math.min(pad_x, M.FRAME_PAD_Y)
    local entry_w = math.max(min_w, max_w) + entry_pad * 2
    local ex = x1 - pad_x - uw - entry_w + entry_pad
    reaper.ImGui_SetCursorScreenPos(ctx, ex, y0)
    if edit.focus then focus.keep_zone(ex, y0, x1, y1) end
    local frame_pad_y = select(2, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding()))
    local ended
    local typed, typed_commit
    typed, typed_commit, ended = db_entry_field(ctx, id, edit, value, min, max, opts.default,
      entry_w, entry_pad, frame_pad_y)
    -- Escape cancels a typed value but never a drag the bar made this frame.
    if typed ~= nil then result, commit = typed, typed_commit end
    if ended then db_edit[id] = nil end
    reaper.ImGui_DrawList_AddText(dl, x1 - pad_x - uw, ty, fade(T.TEXT_TERTIARY, alpha), unit)
    -- Leave the cursor where the bar ends, as an ordinary item would.
    reaper.ImGui_SetCursorScreenPos(ctx, x0, y1)
    reaper.ImGui_Dummy(ctx, 0, 0)
  else
    local tx = math.floor(value_x + 0.5)
    reaper.ImGui_DrawList_AddText(dl, tx, ty,
      fade(hot and T.TEXT_PRIMARY or T.TEXT_SECONDARY, alpha), value_text)
    reaper.ImGui_DrawList_AddText(dl, tx + value_w - uw, ty, fade(T.TEXT_TERTIARY, alpha), unit)
  end

  local reset_progress = widgets.motion_event(ctx, id .. "_reset_bar", true, 0.55, reset)
  if reset_progress then
    local outset = M.FRAME_PAD_Y * reset_progress
    reaper.ImGui_DrawList_AddRect(dl, x0 - outset, y0 - outset, x1 + outset, y1 + outset,
      fade(T.ACCENT_HOVER, (1 - reset_progress) * alpha), rounding + outset, 0, 1.5)
  end

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

-- Shared two-choice control: content stays fixed while selection slides beneath it.
function widgets.two_way_switch(ctx, id, value, choices, width, height, accented)
  local result, rects, hovered, active = nil, {}, {}, {}
  local frame_h = height or reaper.ImGui_GetFrameHeight(ctx)
  for i = 1, 2 do
    local key, label = choices[i].value, choices[i].label
    if i == 2 then reaper.ImGui_SameLine(ctx, 0, 0) end
    if reaper.ImGui_InvisibleButton(ctx, "##" .. id .. key,
        width / 2, frame_h) then
      result = key
    end
    local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
    local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
    rects[i] = { x0 = x0, y0 = y0, x1 = x1, y1 = y1, label = label }
    hovered[i], active[i] = reaper.ImGui_IsItemHovered(ctx), reaper.ImGui_IsItemActive(ctx)
  end

  local shown = result or value
  local target = shown == choices[2].value and 1 or 0
  local position = target
  if motion_ready() then
    local now, frame = reaper.ImGui_GetTime(ctx), reaper.ImGui_GetFrameCount(ctx)
    if result and result ~= value then
      motion.slide(pitch_unit_motion, id, value == choices[2].value, now, frame,
        theme.motion.PITCH_UNIT_SLIDE)
    end
    position = motion.slide(pitch_unit_motion, id, target == 1, now, frame,
      theme.motion.PITCH_UNIT_SLIDE)
  end

  local alpha = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha()))
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  for i = 1, 2 do
    local r = rects[i]
    local fill = active[i] and T.FILL_PRIMARY
      or (hovered[i] and T.FILL_TERTIARY or T.FILL_QUATERNARY)
    reaper.ImGui_DrawList_AddRectFilled(dl, r.x0, r.y0, r.x1, r.y1,
      fade(fill, alpha), 0)
  end

  local first, second = rects[1], rects[2]
  local selected_x0 = first.x0 + (second.x0 - first.x0) * position
  local selected_x1 = first.x1 + (second.x1 - first.x1) * position
  local target_hovered = hovered[target + 1] or active[target + 1]
  local selection_fill = target_hovered and T.FILL_PRIMARY or T.FILL_SECONDARY
  if accented then
    selection_fill = active[target + 1] and T.ACTIVE_CONTROL_HELD
      or (target_hovered and T.ACTIVE_CONTROL_HOVER or T.ACTIVE_CONTROL_FILL)
  end
  reaper.ImGui_DrawList_AddRectFilled(dl, selected_x0, first.y0, selected_x1, first.y1,
    fade(selection_fill, alpha), 0)
  reaper.ImGui_DrawList_AddRect(dl, first.x0, first.y0, second.x1, first.y1,
    fade(T.STROKE_SECONDARY, alpha), 0, 0, 1)
  reaper.ImGui_DrawList_AddLine(dl, first.x1, first.y0, first.x1, first.y1,
    fade(T.STROKE_SECONDARY, alpha), 1)
  if accented then
    reaper.ImGui_DrawList_AddRect(dl, selected_x0, first.y0, selected_x1, first.y1,
      fade(T.ACTIVE_CONTROL_BORDER, alpha), 0, 0, 1)
  end

  for i = 1, 2 do
    local r = rects[i]
    local weight = i == 1 and (1 - position) or position
    local colour = theme.blend(T.TEXT_SECONDARY, T.ACCENT, weight)
    if choices[i].draw then
      choices[i].draw(dl, (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2,
        fade(colour, alpha), math.min(r.x1 - r.x0, frame_h) * 0.7)
    else
      local tw, th = reaper.ImGui_CalcTextSize(ctx, r.label)
      reaper.ImGui_DrawList_AddText(dl, r.x0 + (r.x1 - r.x0 - tw) * 0.5,
        r.y0 + (r.y1 - r.y0 - th) * 0.5, fade(colour, alpha), r.label)
    end
  end
  for i = 1, 2 do
    local r = rects[i]
    tips.show(ctx, hovered[i], choices[i].tip, id .. '_' .. choices[i].value,
      tips.rect(r.x0, r.y0, r.x1 - r.x0, r.y1 - r.y0))
  end
  return result
end

local PITCH_UNITS = {{value='st', label='st'}, {value='percent', label='%'}}
function widgets.pitch_units(ctx, id, unit, size_scale)
  size_scale = size_scale or 1
  return widgets.two_way_switch(ctx, id, unit, PITCH_UNITS,
    M.PITCH_UNIT_W * 2 * size_scale, reaper.ImGui_GetFrameHeight(ctx) * size_scale)
end

-- Hoisted so the frame loop never rebuilds it (frame-allocation rule).
local ACCENT_FACE = { color = T.ACCENT_HOVER }
-- A square toggle, the same square as every icon button — never a size change
-- (UI-stability rule). ON uses the shared soft accent wash, outline and bright
-- face, keeping the resting state distinct from ordinary neutral hover feedback.
-- With `font` (the Lucide font) and `icon` (an icons.NAMES key) the face is that
-- glyph; `label` stays as the fallback face when the icon font isn't available.
-- The stable `id` also owns the tooltip delay, so a state-dependent explanation
-- can change under the pointer without looking like a different control.
-- width: optional, for a cell in a joined button group; the face stays centred.
function widgets.toggle(ctx, id, label, on, tip, font, icon, enabled, effect, width)
  local size = reaper.ImGui_GetFrameHeight(ctx)
  local use_icon = font and icon and icons.NAMES[icon]
  local disabled = enabled == false
  if disabled then reaper.ImGui_BeginDisabled(ctx) end
  local mono = effect == "mono"
  local loop_icon = effect == "loop"
  local audition_icon = effect == "audition" and use_icon
  local pushed = widgets.push_soft_active(ctx, on)
  if on and not use_icon then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.ACCENT_HOVER)
  end
  local clicked = reaper.ImGui_Button(ctx, ((use_icon or mono or loop_icon) and "" or label) .. "##" .. id, width or size, size)
  if on and not use_icon then reaper.ImGui_PopStyleColor(ctx) end
  widgets.pop_soft_active(ctx, pushed)
  if use_icon and not loop_icon and not audition_icon then
    -- Paint the state this click PRODUCES, not the state that was passed in: the
    -- entry script flips the real value next frame, and both callers flip
    -- unconditionally, so the face may safely answer the press instantly instead
    -- of one frame late.
    local shown = on
    if clicked then shown = not shown end
    -- The Appearance setting can change ACCENT while the tool is running. Keep
    -- this hoisted face table, but refresh its one value before it is painted.
    ACCENT_FACE.color = T.ACCENT_HOVER
    icons.paint_over_item(ctx, font, icon, shown and ACCENT_FACE or nil)
  end
  if mono then
    local shown = on
    if clicked and not disabled then shown = not shown end
    local duration = disabled and 0 or 0.4
    if clicked and not disabled then
      widgets.motion_value(ctx, id .. "_mono", on and 1 or 0, duration)
    end
    local position = widgets.motion_value(ctx, id .. "_mono", shown and 1 or 0, duration)
    local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
    local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
    local cx, cy = (x0 + x1) * 0.5, (y0 + y1) * 0.5
    local radius = size * 0.2
    local separation = size * 0.13 * (1 - position)
    local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
    local colour = theme.fade(shown and T.ACCENT_HOVER or T.TEXT_SECONDARY, alpha)
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    reaper.ImGui_DrawList_AddCircle(dl, cx - separation, cy, radius, colour, 20, 1.5)
    -- At rest in Mono there is one circle, without doubled opacity at the join.
    if separation > 0.1 then
      reaper.ImGui_DrawList_AddCircle(dl, cx + separation, cy, radius, colour, 20, 1.5)
    end
  elseif loop_icon then
    local shown = on
    if clicked then shown = not shown end
    icon_motion.paint_item(ctx, id, "repeat", shown and T.ACCENT_HOVER or T.TEXT_SECONDARY,
      on, clicked, not disabled)
  elseif audition_icon then
    local shown = on
    if clicked then shown = not shown end
    ACCENT_FACE.color = T.ACCENT_HOVER
    local animated = icon_motion.paint_item(ctx, id, "ear",
      shown and T.ACCENT_HOVER or T.TEXT_SECONDARY,
      on, clicked, not disabled, font)
    if not animated then
      icons.paint_over_item(ctx, font, icon, shown and ACCENT_FACE or nil)
    end
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
function widgets.switch(ctx, id, on, tip, enabled, animate_when_disabled, size_scale)
  size_scale = size_scale or 1
  local w, h, knob = M.SET_SWITCH_W * size_scale,
    M.SET_SWITCH_H * size_scale, M.SET_SWITCH_KNOB * size_scale
  local frame_h = reaper.ImGui_GetFrameHeight(ctx) * size_scale
  local disabled = enabled == false
  if disabled then reaper.ImGui_BeginDisabled(ctx) end
  local clicked = reaper.ImGui_InvisibleButton(ctx, "##" .. id, w, frame_h)
  local hovered = disabled and HOVER_DISABLED ~= 0
    and reaper.ImGui_IsItemHovered(ctx, HOVER_DISABLED)
    or reaper.ImGui_IsItemHovered(ctx)
  local x0, item_y0 = reaper.ImGui_GetItemRectMin(ctx)
  local x1, item_y1 = reaper.ImGui_GetItemRectMax(ctx)
  local y0 = math.floor((item_y0 + item_y1 - h) * 0.5 + 0.5)
  local y1 = y0 + h
  local pad = (h - knob) * 0.5
  local shown = on
  if clicked then shown = not shown end
  local position = shown and 1 or 0
  if animate_when_disabled and not disabled and (clicked or preference_switch_active(id)) then
    -- This preference owns its short, user-triggered transition. It must finish
    -- after disabling global motion, but drops its tracker at rest so disabled
    -- mode does not keep reading the animation clock.
    if HAS_MOTION_CLOCK then
      local now, frame = reaper.ImGui_GetTime(ctx), reaper.ImGui_GetFrameCount(ctx)
      if clicked then
        motion.slide(preference_switch_motion, id, on, now, frame, theme.motion.SWITCH_SLIDE)
      end
      position = motion.slide(preference_switch_motion, id, shown, now, frame,
        theme.motion.SWITCH_SLIDE)
      if not preference_switch_active(id) then clear_preference_switch(id) end
    else
      clear_preference_switch(id)
    end
  elseif motion_ready() then
    local now, frame = reaper.ImGui_GetTime(ctx), reaper.ImGui_GetFrameCount(ctx)
    local duration = disabled and 0 or theme.motion.SWITCH_SLIDE
    -- Seed the old state if a click arrives on this switch's first visible frame.
    if clicked then motion.slide(switch_motion, id, on, now, frame, duration) end
    position = motion.slide(switch_motion, id, shown, now, frame, duration)
  end
  local knob_x = x0 + pad + (x1 - x0 - pad * 2 - knob) * position
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local fill = theme.blend(hovered and T.FILL_PRIMARY or T.FILL_SECONDARY,
    hovered and T.ACCENT_HOVER or T.ACCENT, position)
  local alpha = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha()))

  reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x1, y1,
    theme.fade(fill, alpha), h * 0.5)
  reaper.ImGui_DrawList_AddCircleFilled(dl, knob_x + knob * 0.5,
    y0 + h * 0.5, knob * 0.5,
    theme.fade(theme.blend(T.TEXT_SECONDARY, T.TEXT_ON_ACCENT, position), alpha))
  if disabled then reaper.ImGui_EndDisabled(ctx) end
  tips.show(ctx, tip and hovered, tip)
  return not disabled and clicked
end

-- The slim scrollbar (brief `table-scrollbar`, 2026-08-09): a thumb-only pill
-- in a strip the CALLER has reserved — the empty strip is the track. It
-- replaces ImGui's own bar wherever it's used (the browser's sound table and
-- its sidebar): that bar carves its width out of the content — which is what
-- made the table's columns jump whenever it appeared — and runs the full
-- window height, frozen headers included.
--
-- Both lists claim rail input before their content, then paint after it. The
-- content submission establishes layout bounds after the input restores its
-- cursor. The caller applies the requested scroll.
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

local function paint_scrollbar_thumb(ctx, x, w, thumb_y, thumb_h, hot, right_inset)
  local alpha = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha()))
  local tx = x + w - M.SCROLL_THUMB_W - (right_inset or 0)
  reaper.ImGui_DrawList_AddRectFilled(reaper.ImGui_GetWindowDrawList(ctx),
    tx, thumb_y, tx + M.SCROLL_THUMB_W, thumb_y + thumb_h,
    fade(hot and T.SCROLL_THUMB_HOT or T.SCROLL_THUMB, alpha),
    M.SCROLL_THUMB_W * 0.5)
end

-- Call before the list/table so its normal content submission follows the
-- restored cursor. Painting alone would let a rail press move the window.
function widgets.scrollbar_input(ctx, id, x, y, w, h, enabled)
  if not enabled or h <= 0 then grab_off[id] = nil; return false, false end
  local cursor_x, cursor_y = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_InvisibleButton(ctx, "##" .. id, w, h)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local active = reaper.ImGui_IsItemActive(ctx)
  reaper.ImGui_SetCursorScreenPos(ctx, cursor_x, cursor_y)
  return hovered, active
end

function widgets.overlay_scrollbar(ctx, id, x, y, w, h, scroll_y, scroll_max, hovered, input_active, right_inset)
  local thumb_y, thumb_h, travel = scrollbar_thumb_geometry(y, h, scroll_y, scroll_max)
  if not thumb_y then grab_off[id] = nil; return nil, false end

  local _, my = reaper.ImGui_GetMousePos(ctx)
  if not input_active then grab_off[id] = nil end
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
  paint_scrollbar_thumb(ctx, x, w, thumb_y, thumb_h, hot, right_inset)
  return result, hot
end

return widgets
