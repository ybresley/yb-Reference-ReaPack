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
local switch_motion, pitch_unit_motion = motion.new(), motion.new()
local preference_switch_motion, bloom_motion = motion.new(), motion.new()
local value_motion, event_motion = motion.new(128), motion.new(128)
local motion_generation = theme.motion.generation
local HAS_MOTION_CLOCK = reaper.ImGui_GetTime ~= nil and reaper.ImGui_GetFrameCount ~= nil

-- Turning motion off skips clocks and trackers; re-enabling cannot resume old FX.
local function motion_ready()
  if not theme.motion.enabled or not HAS_MOTION_CLOCK then return false end
  if motion_generation ~= theme.motion.generation then
    switch_motion, pitch_unit_motion, bloom_motion = motion.new(), motion.new(), motion.new()
    value_motion, event_motion = motion.new(128), motion.new(128)
    motion_generation = theme.motion.generation
  end
  return true
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
function widgets.button_bloom(ctx, id, on, colour, trigger, strong, glow_gain, bounds)
  if not motion_ready() then return end
  local strength = motion.pulse(bloom_motion, id, on,
    reaper.ImGui_GetTime(ctx), reaper.ImGui_GetFrameCount(ctx),
    theme.motion.BUTTON_BLOOM, trigger)
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
function widgets.play_bloom(ctx, id, playing, bounds, trigger)
  widgets.button_bloom(ctx, "play_" .. id, playing, T.ACCENT, trigger, false, 1.6, bounds)
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

-- Share the open-panel frame between square icons and the wide sound picker.
function widgets.panel_button_frame(ctx, label, width, height, open)
  local pushed = widgets.push_soft_active(ctx, open)
  local clicked = reaper.ImGui_Button(ctx, label, width, height)
  widgets.pop_soft_active(ctx, pushed)
  return clicked
end

-- An open panel uses the shared active treatment. `highlighted` also allows
-- Pitch to keep that treatment while an adjustment remains set and the panel
-- itself is closed.
function widgets.panel_button(ctx, font, id, icon, open, fallback, highlighted, enabled, press_on_down)
  local size = reaper.ImGui_GetFrameHeight(ctx)
  local use_icon = font and icons.NAMES[icon]
  local accented = open or highlighted
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
    accented and T.ACCENT_HOVER or T.TEXT_SECONDARY)
  local label = not use_icon and not icon_motion.supports(icon)
    and type(fallback) == 'string' and fallback or ''
  local clicked = widgets.panel_button_frame(ctx, label .. '##' .. id, size, size, accented)
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

local HAS_GROUP_CHILD = reaper.ImGui_ChildFlags_AutoResizeY ~= nil
  and reaper.ImGui_Col_Border ~= nil

-- Settings windows share the heading and box; each caller owns its row layout.
function widgets.begin_settings_group(ctx, id, title, first, fill_height, inset)
  local pad_x = inset and inset.pad_x or M.WINDOW_PAD
  local pad_y = inset and inset.pad_y or M.WINDOW_PAD
  if not first then
    reaper.ImGui_SetCursorPosY(ctx,
      reaper.ImGui_GetCursorPosY(ctx) + M.ITEM_SPACING_Y)
  end
  local x = reaper.ImGui_GetCursorPosX(ctx)
  reaper.ImGui_SetCursorPosX(ctx, x + pad_x)
  local bold = theme.push_bold_font(ctx)
  reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, title:upper())
  if bold then reaper.ImGui_PopFont(ctx) end
  reaper.ImGui_SetCursorPosX(ctx, x)

  if not HAS_GROUP_CHILD then return true, false end
  local child_flags = fill_height and 0 or reaper.ImGui_ChildFlags_AutoResizeY()
  if reaper.ImGui_ChildFlags_Borders then
    child_flags = child_flags | reaper.ImGui_ChildFlags_Borders()
  elseif reaper.ImGui_ChildFlags_AlwaysUseWindowPadding then
    child_flags = child_flags | reaper.ImGui_ChildFlags_AlwaysUseWindowPadding()
  end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), T.SET_GROUP_BG)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),
    inset and inset.border or T.STROKE_SECONDARY)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), pad_x, pad_y)
  local opened = reaper.ImGui_BeginChild(ctx, id, 0, 0, child_flags,
    reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse())
  reaper.ImGui_PopStyleVar(ctx)
  reaper.ImGui_PopStyleColor(ctx, 2)
  -- ReaImGui ends a clipped child itself; only an opened child needs EndChild.
  return opened, opened
end

function widgets.end_settings_group(ctx, child)
  if child then reaper.ImGui_EndChild(ctx) end
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

-- Pitch, trim and preview volume share one quiet confirmation at the knob's
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

-- A dB fader, custom-drawn: slim track, accent fill, slim pill knob, and the value
-- as a fixed readout to the RIGHT of the track — never under the knob, so it stays
-- readable mid-drag, and the knob (taller than the track) stays visible parked at
-- the extremes. Total width is M.SLIDER_W and never resizes with state.
-- A range that crosses 0 (trim) fills from the 0 dB detent outward; a cut-only
-- range (master) fills from the left like a level.
-- Reports the live value every drag or entry frame with a `commit` flag set only
-- on release, Enter or blur, so callers persist once instead of every frame.
-- The track resets through the standard gesture; the adjacent value resets on
-- right-click and becomes an exact-entry field on left-click.
-- opts = { min, max, default, tip, value_tip, taper, edit_key }.
-- `taper` gives the control a real fader's shape (see above), where `min` is
-- the silence the bottom of the track means rather than a number to land on.
-- Returns (value, commit) when something changed this frame, else nil.
local db_fader_edit = {}
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
  local edit_key = opts.edit_key == nil and id or opts.edit_key
  local edit = db_fader_edit[id]
  if edit and (edit.key ~= edit_key
      or (reaper.ImGui_IsWindowAppearing and reaper.ImGui_IsWindowAppearing(ctx))) then
    db_fader_edit[id], edit = nil, nil
  end

  -- The track and readout are separate items, so clicking the number can enter
  -- an exact value without also moving the slider beneath the pointer.
  reaper.ImGui_BeginGroup(ctx)
  reaper.ImGui_InvisibleButton(ctx, "##" .. id, track_w, h)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local active = reaper.ImGui_IsItemActive(ctx)
  tips.show(ctx, opts.tip and hovered, opts.tip)

  -- Resolve this frame's result. Reset wins over the drag value on the same frame,
  -- and always persists.
  local result, commit
  local reset = widgets.wants_reset(ctx)
  if reset then
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
  if active or reset then
    db_fader_edit[id], edit = nil, nil
  end

  -- The readout keeps its fixed-width slot while switching between painted text
  -- and exact entry. The optional stacked form has no value beside the slider,
  -- so its existing painted readout remains non-editable.
  local value_hovered = false
  local edit_visible = edit ~= nil
  if not stacked then
    if edit then
      local frame_pad_x, frame_pad_y = reaper.ImGui_GetStyleVar(ctx,
        reaper.ImGui_StyleVar_FramePadding())
      local entry_pad = math.min(frame_pad_x, M.FRAME_PAD_Y)
      local min_text_w = select(1, reaper.ImGui_CalcTextSize(ctx,
        decibels.format(min)))
      local max_text_w = select(1, reaper.ImGui_CalcTextSize(ctx,
        decibels.format(max)))
      local entry_w = math.max(min_text_w, max_text_w) + entry_pad * 2
      -- Begin the field before the normal readout origin by exactly its inner
      -- padding. The typed number therefore stays on the same pixel as the
      -- painted number, while the field wraps only the widest valid value.
      reaper.ImGui_SameLine(ctx, 0, M.FADER_VAL_GAP - entry_pad)
      if edit.focus then
        reaper.ImGui_SetKeyboardFocusHere(ctx)
        edit.focus = false
      end
      reaper.ImGui_SetNextItemWidth(ctx, entry_w)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.ACCENT)
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),
        entry_pad, frame_pad_y)
      local changed, text = numeric_input.text(ctx, "##" .. id .. "_value",
        edit.text, "signed_decimal", DB_AUTO_SELECT)
      reaper.ImGui_PopStyleVar(ctx)
      reaper.ImGui_PopStyleColor(ctx)
      if changed then
        edit.text = text
        local typed = parse_db_entry(text, min, max)
        if typed ~= nil and typed ~= (value or 0) then result, commit = typed, false end
      end
      local field_active = reaper.ImGui_IsItemActive(ctx)
      if field_active then edit.active = true end
      value_hovered = reaper.ImGui_IsItemHovered(ctx)
      local value_reset = widgets.wants_right_reset(ctx)
      local submit = field_active and HAS_DB_ENTER
        and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter())
      local cancel = field_active and HAS_DB_ESCAPE
        and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape())
      local deactivated = edit.active and reaper.ImGui_IsItemDeactivated(ctx)
      if value_reset then
        result, commit = (opts.default or 0), true
        db_fader_edit[id], edit = nil, nil
      elseif cancel then
        db_fader_edit[id], edit = nil, nil
      elseif submit or deactivated then
        result, commit = parse_db_entry(edit.text, min, max) or (value or 0), true
        db_fader_edit[id], edit = nil, nil
      end
      local remaining = M.FADER_VAL_W - math.max(min_text_w, max_text_w) - entry_pad
      if remaining > 0 then
        reaper.ImGui_SameLine(ctx, 0, 0)
        reaper.ImGui_Dummy(ctx, remaining, h)
      end
    else
      reaper.ImGui_SameLine(ctx, 0, M.FADER_VAL_GAP)
      local clicked = reaper.ImGui_InvisibleButton(ctx, "##" .. id .. "_value",
        M.FADER_VAL_W, h)
      value_hovered = reaper.ImGui_IsItemHovered(ctx)
      if widgets.wants_right_reset(ctx) then
        result, commit = (opts.default or 0), true
      elseif clicked then
        db_fader_edit[id] = {
          key = edit_key,
          text = decibels.format(value or 0),
          focus = true,
          active = false,
        }
        focus.keep_zone(x0 + track_w + M.FADER_VAL_GAP, y0,
          x0 + total_w, y0 + h)
      end
    end
    tips.show(ctx, opts.value_tip and value_hovered, opts.value_tip, id .. "_value")
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
  draw_notch_echo(ctx, id, kx, cy, alpha,
    result ~= nil and result ~= (value or 0))
  reaper.ImGui_DrawList_AddRectFilled(dl, kx - half_kw, cy - half_kh, kx + half_kw,
    cy + half_kh, fade(T.FADER_KNOB, alpha), half_kw)

  -- Readout. Rounded zero has no sign, matching the Loudness panel.
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
  local text = decibels.format(shown, taper and min or nil)
  local unit = " dB"
  local tw, th = reaper.ImGui_CalcTextSize(ctx, text)
  local uw = select(1, reaper.ImGui_CalcTextSize(ctx, unit))
  local num_col = fade((hovered or active or value_hovered) and T.TEXT_PRIMARY
    or T.TEXT_SECONDARY, alpha)
  local tx, ty
  if stacked then
    tx = x0 + (total_w - tw - uw) * 0.5 -- centred under the track
    ty = y0 + h - th - 1
  else
    tx = x0 + track_w + M.FADER_VAL_GAP -- anchored to the track, growing outward
    ty = y0 + (h - th) * 0.5            -- true vertical centre, not frame padding
  end
  if not edit_visible then
    reaper.ImGui_DrawList_AddText(dl, tx, ty, num_col, text)
    reaper.ImGui_DrawList_AddText(dl, tx + tw, ty, fade(T.TEXT_TERTIARY, alpha), unit)
  end

  -- The separate value item claims the readout's fixed width even though its
  -- normal state is custom-painted.
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
  db_fader_edit[id] = nil
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
  local reset = widgets.wants_reset(ctx)
  if reset then
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
  local text = decibels.format(shown, taper and min or nil)
  local unit = " dB"
  local tw, th = reaper.ImGui_CalcTextSize(ctx, text)
  local uw = select(1, reaper.ImGui_CalcTextSize(ctx, unit))
  local tx = x0 + w - pad_x - uw - tw
  local ty = y0 + (h - th) * 0.5
  reaper.ImGui_DrawList_AddText(dl, tx, ty,
    fade((hovered or active) and T.TEXT_PRIMARY or T.TEXT_SECONDARY, alpha), text)
  reaper.ImGui_DrawList_AddText(dl, tx + tw, ty, fade(T.TEXT_TERTIARY, alpha), unit)

  local reset_progress = widgets.motion_event(ctx, id .. "_reset_value", true, 0.55, reset)
  if reset_progress then
    local outset = M.FRAME_PAD_Y * reset_progress
    reaper.ImGui_DrawList_AddRect(dl, x0 - outset, y0 - outset,
      x0 + w + outset, y0 + h + outset,
      theme.fade(T.ACCENT_HOVER, (1 - reset_progress) * alpha), M.FRAME_PAD_Y, 0, 1.5)
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
function widgets.pitch_units(ctx, id, unit, size_scale)
  size_scale = size_scale or 1
  local result, rects, hovered, active = nil, {}, {}, {}
  local frame_h = reaper.ImGui_GetFrameHeight(ctx) * size_scale
  for i = 1, 2 do
    local key, label = i == 1 and "st" or "percent", i == 1 and "st" or "%"
    if i == 2 then reaper.ImGui_SameLine(ctx, 0, 0) end
    if reaper.ImGui_InvisibleButton(ctx, "##" .. id .. key,
        M.PITCH_UNIT_W * size_scale, frame_h) then
      result = key
    end
    local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
    local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
    rects[i] = { x0 = x0, y0 = y0, x1 = x1, y1 = y1, label = label }
    hovered[i], active[i] = reaper.ImGui_IsItemHovered(ctx), reaper.ImGui_IsItemActive(ctx)
  end

  local shown = result or unit
  local target = shown == "percent" and 1 or 0
  local position = target
  if motion_ready() then
    local now, frame = reaper.ImGui_GetTime(ctx), reaper.ImGui_GetFrameCount(ctx)
    if result and result ~= unit then
      motion.slide(pitch_unit_motion, id, unit == "percent", now, frame,
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
  reaper.ImGui_DrawList_AddRectFilled(dl, selected_x0, first.y0, selected_x1, first.y1,
    fade(target_hovered and T.FILL_PRIMARY or T.FILL_SECONDARY, alpha), 0)
  reaper.ImGui_DrawList_AddRect(dl, first.x0, first.y0, second.x1, first.y1,
    fade(T.STROKE_SECONDARY, alpha), 0, 0, 1)
  reaper.ImGui_DrawList_AddLine(dl, first.x1, first.y0, first.x1, first.y1,
    fade(T.STROKE_SECONDARY, alpha), 1)

  for i = 1, 2 do
    local r = rects[i]
    local weight = i == 1 and (1 - position) or position
    local colour = theme.blend(T.TEXT_SECONDARY, T.ACCENT, weight)
    local tw, th = reaper.ImGui_CalcTextSize(ctx, r.label)
    reaper.ImGui_DrawList_AddText(dl, r.x0 + (r.x1 - r.x0 - tw) * 0.5,
      r.y0 + (r.y1 - r.y0 - th) * 0.5, fade(colour, alpha), r.label)
  end
  return result
end

-- Hoisted so the frame loop never rebuilds it (frame-allocation rule).
local ACCENT_FACE = { color = T.ACCENT_HOVER }
local HOVER_DISABLED = reaper.ImGui_HoveredFlags_AllowWhenDisabled
  and reaper.ImGui_HoveredFlags_AllowWhenDisabled() or 0

-- A square toggle, the same square as every icon button — never a size change
-- (UI-stability rule). ON uses the shared soft accent wash, outline and bright
-- face, keeping the resting state distinct from ordinary neutral hover feedback.
-- With `font` (the Lucide font) and `icon` (an icons.NAMES key) the face is that
-- glyph; `label` stays as the fallback face when the icon font isn't available.
-- The stable `id` also owns the tooltip delay, so a state-dependent explanation
-- can change under the pointer without looking like a different control.
function widgets.toggle(ctx, id, label, on, tip, font, icon, enabled, effect)
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
  local clicked = reaper.ImGui_Button(ctx, ((use_icon or mono or loop_icon) and "" or label) .. "##" .. id, size, size)
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
