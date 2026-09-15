-- Mouse navigation and zoom-only overlay rails for the Reference View waveform.
-- Long-lived values come in as a plain view and leave as an action; only the
-- in-flight mouse drag is kept here.

local viewport = require("core.wave_view")
local theme = require("ui.theme")
local T, M = theme.tokens, theme.metrics

local navigation = {}
local drag = {}

local DRAG_THRESHOLD = 4
local MIDDLE_BUTTON = reaper.ImGui_MouseButton_Middle and reaper.ImGui_MouseButton_Middle() or 2
local HAS_KEY_MODS = reaper.ImGui_GetKeyMods ~= nil
local CTRL_MOD = HAS_KEY_MODS and reaper.ImGui_Mod_Ctrl and reaper.ImGui_Mod_Ctrl() or nil
local ALT_MOD = HAS_KEY_MODS and reaper.ImGui_Mod_Alt and reaper.ImGui_Mod_Alt() or nil
local SHIFT_MOD = HAS_KEY_MODS and reaper.ImGui_Mod_Shift and reaper.ImGui_Mod_Shift() or nil
local RESIZE_EW = reaper.ImGui_MouseCursor_ResizeEW and reaper.ImGui_MouseCursor_ResizeEW() or nil
local RESIZE_NS = reaper.ImGui_MouseCursor_ResizeNS and reaper.ImGui_MouseCursor_ResizeNS() or nil
local RESIZE_ALL = reaper.ImGui_MouseCursor_ResizeAll and reaper.ImGui_MouseCursor_ResizeAll() or nil

local function zoomed_time(v) return v.t1 - v.t0 < 1 - 1e-9 end
local function zoomed_amp(v) return v.a1 - v.a0 < 2 - 1e-9 end
local function inside(mx, my, x0, y0, x1, y1)
  return mx >= x0 and mx <= x1 and my >= y0 and my <= y1
end

local function geometry(x, y, w, h, ruler_h)
  local rail = M.SCROLL_RAIL_W
  return {
    x = x, y = y, w = w, h = h, ruler_y = y + h, ruler_h = ruler_h,
    rail = rail, hit = math.max(4, rail * 0.5),
    time_x = x, time_y = y + h - rail, time_w = w,
    amp_x = x + w - rail, amp_y = y, amp_h = math.max(1, h - rail),
  }
end

local function time_thumb(v, g)
  local left, right =
    viewport.time_rail_bounds(v, g.time_w, M.WAVE_TIME_THUMB_MIN_W)
  return g.time_x + left, g.time_y, g.time_x + right, g.time_y + g.rail
end

local function amp_thumb(v, g)
  local top = g.amp_y + ((1 - v.a1) / 2) * g.amp_h
  local bottom = g.amp_y + ((1 - v.a0) / 2) * g.amp_h
  return g.amp_x, top, g.amp_x + g.rail, bottom
end

local function classify(v, mx, my, g)
  if zoomed_time(v) then
    local tx0, ty0, tx1, ty1 = time_thumb(v, g)
    if inside(mx, my, g.time_x, g.time_y, g.time_x + g.time_w, g.time_y + g.rail) then
      local part = viewport.thumb_part(mx, tx0, tx1, g.hit)
      if part == "start" then return "time_left" end
      if part == "finish" then return "time_right" end
      if part == "body" then return "time_body" end
      return mx < tx0 and "time_page_left" or "time_page_right"
    end
  end
  if zoomed_amp(v) then
    local ax0, ay0, ax1, ay1 = amp_thumb(v, g)
    if inside(mx, my, g.amp_x, g.amp_y, g.amp_x + g.rail, g.amp_y + g.amp_h) then
      local part = viewport.thumb_part(my, ay0, ay1, g.hit)
      if part == "start" then return "amp_top" end
      if part == "finish" then return "amp_bottom" end
      if part == "body" then return "amp_body" end
      return my < ay0 and "amp_page_up" or "amp_page_down"
    end
  end
  if g.ruler_h > 0 and inside(mx, my, g.x, g.ruler_y, g.x + g.w, g.ruler_y + g.ruler_h) then
    return "ruler"
  end
end

function navigation.draw_rails(dl, v, x, y, w, h, ruler_h, hot, ruler_hovered)
  local g = geometry(x, y, w, h, ruler_h)
  if zoomed_amp(v) then
    reaper.ImGui_DrawList_AddRectFilled(dl, g.amp_x, g.amp_y,
      g.amp_x + g.rail, g.amp_y + g.amp_h, T.FILL_QUATERNARY, 4)
    local ax0, ay0, ax1, ay1 = amp_thumb(v, g)
    local active = (hot and hot:sub(1, 4) == "amp_") or ruler_hovered
    local inset = math.max(0, (g.rail - M.SCROLL_THUMB_W) * 0.5)
    reaper.ImGui_DrawList_AddRectFilled(dl, ax0 + inset, ay0, ax1 - inset, ay1,
      active and T.SCROLL_THUMB_HOT or T.SCROLL_THUMB, 4)
  end
  if zoomed_time(v) then
    reaper.ImGui_DrawList_AddRectFilled(dl, g.time_x, g.time_y,
      g.time_x + g.time_w, g.time_y + g.rail, T.FILL_QUATERNARY, 4)
    local tx0, ty0, tx1, ty1 = time_thumb(v, g)
    local active = (hot and hot:sub(1, 5) == "time_") or ruler_hovered
    local inset = math.max(0, (g.rail - M.SCROLL_THUMB_W) * 0.5)
    reaper.ImGui_DrawList_AddRectFilled(dl, tx0, ty0 + inset, tx1, ty1 - inset,
      active and T.SCROLL_THUMB_HOT or T.SCROLL_THUMB, 4)
  end
end

local function action(v, width)
  return { type = "wave_view", view = v, cols = math.max(1, math.floor(width)) }
end

function navigation.is_active(id)
  return drag.id == id and drag.mode ~= nil
end

local function start_drag(mode, id, mx, my, v)
  drag = { mode = mode, id = id, x = mx, y = my, view = viewport.copy(v), moved = false }
end

local function drag_view(g, mx, my)
  local dx, dy = mx - drag.x, my - drag.y
  local v = viewport.copy(drag.view)
  local time_pointer_x = drag.x - dx
  if drag.mode == "ruler" then
    viewport.drag_ruler(v, math.exp(-dy * 0.012), drag.anchor, (time_pointer_x - g.x) / g.w)
  elseif drag.mode == "time_body" then
    viewport.drag_time_thumb(v, math.exp(-dy * 0.012), drag.grab_fraction,
      (time_pointer_x - g.time_x) / g.time_w, M.WAVE_TIME_THUMB_MIN_W / g.time_w)
  elseif drag.mode == "middle_pan" then
    viewport.pan_time(v, -dx / g.w * (drag.view.t1 - drag.view.t0))
  elseif drag.mode == "time_left" then viewport.set_time(v, drag.view.t0 + dx / g.time_w, drag.view.t1)
  elseif drag.mode == "time_right" then viewport.set_time(v, drag.view.t0, drag.view.t1 + dx / g.time_w)
  elseif drag.mode == "amp_body" then
    viewport.set_amp_span(v, (drag.view.a1 - drag.view.a0) * math.exp(dy * 0.012))
  elseif drag.mode == "amp_top" then
    viewport.set_amp_span(v, drag.view.a1 - drag.view.a0 - dy / g.amp_h * 4)
  elseif drag.mode == "amp_bottom" then
    viewport.set_amp_span(v, drag.view.a1 - drag.view.a0 + dy / g.amp_h * 4)
  end
  return v
end

function navigation.handle(ctx, id, v, x, y, w, h, ruler_h, blocked, physical_mods)
  local g = geometry(x, y, w, h, ruler_h)
  local mx, my = reaper.ImGui_GetMousePos(ctx)
  if drag.id and drag.id ~= id then drag = {} end
  local hot = blocked and nil or classify(v, mx, my, g)
  local result, claimed

  if not blocked and reaper.ImGui_IsItemActivated(ctx) and hot then
    claimed = true
    if hot:find("_page_", 1, true) then
      local next_view = viewport.copy(v)
      local tspan, aspan = v.t1 - v.t0, v.a1 - v.a0
      if hot == "time_page_left" then viewport.pan_time(next_view, -tspan * 0.85)
      elseif hot == "time_page_right" then viewport.pan_time(next_view, tspan * 0.85)
      elseif hot == "amp_page_up" then viewport.set_amp_span(next_view, aspan * 0.85)
      else viewport.set_amp_span(next_view, aspan / 0.85) end
      result = action(next_view, w)
    else
      start_drag(hot, id, mx, my, v)
      if hot == "ruler" then
        drag.anchor = viewport.time_at(v, (mx - x) / w)
      elseif hot == "time_body" then
        local tx0, _, tx1 = time_thumb(v, g)
        drag.grab_fraction = (mx - tx0) / (tx1 - tx0)
      end
    end
  end

  if drag.mode and drag.id == id and drag.mode ~= "middle_pan" then
    claimed = true
    if reaper.ImGui_IsItemActive(ctx) then
      if (drag.mode ~= "ruler" and drag.mode ~= "time_body") or drag.moved
        or math.max(math.abs(mx - drag.x), math.abs(my - drag.y)) >= DRAG_THRESHOLD then
        drag.moved = true
        result = action(drag_view(g, mx, my), w)
      end
    elseif reaper.ImGui_IsItemDeactivated(ctx) then
      if drag.mode == "ruler" and not drag.moved then
        result = { type = "seek", fraction = viewport.time_at(v, (mx - x) / w) }
      end
      drag = {}
    end
  end

  local hovered = reaper.ImGui_IsItemHovered(ctx)
  if hovered and not blocked and not drag.mode and reaper.ImGui_IsMouseClicked(ctx, MIDDLE_BUTTON) then
    start_drag("middle_pan", id, mx, my, v)
    claimed = true
  end
  if drag.mode == "middle_pan" and drag.id == id then
    claimed = true
    if reaper.ImGui_IsMouseDown(ctx, MIDDLE_BUTTON) then
      result = action(drag_view(g, mx, my), w)
    else
      drag = {}
    end
  end

  if hovered and not blocked and reaper.ImGui_GetMouseWheel then
    local wheel_y, wheel_x = reaper.ImGui_GetMouseWheel(ctx)
    if wheel_y ~= 0 or wheel_x ~= 0 then
      local wheel = wheel_y + wheel_x
      local next_view = viewport.copy(v)
      local ctrl, alt, shift
      if physical_mods ~= nil then
        ctrl = (physical_mods & 1) ~= 0
        shift = (physical_mods & 2) ~= 0
        alt = (physical_mods & 4) ~= 0
      else
        local mods = HAS_KEY_MODS and reaper.ImGui_GetKeyMods(ctx) or 0
        ctrl = CTRL_MOD and (mods & CTRL_MOD) ~= 0
        alt = ALT_MOD and (mods & ALT_MOD) ~= 0
        shift = SHIFT_MOD and (mods & SHIFT_MOD) ~= 0
      end
      if hot and hot:sub(1, 4) == "amp_" then
        viewport.set_amp_span(next_view, (v.a1 - v.a0) * math.exp(-wheel * 0.18))
      elseif ctrl then
        viewport.zoom_time(next_view, math.exp(wheel * 0.18),
          viewport.time_at(v, (mx - x) / w))
      elseif alt then
        viewport.zoom_amp(next_view, math.exp(wheel * 0.18), 0)
      elseif shift then
        viewport.pan_time(next_view, -wheel * (v.t1 - v.t0) * 0.08)
      else
        viewport.pan_amp(next_view, wheel * (v.a1 - v.a0) * 0.08)
      end
      result, claimed = action(next_view, w), true
    end
  end

  local cursor = drag.mode or hot
  if cursor then
    if cursor == "amp_top" or cursor == "amp_bottom" then
      if RESIZE_NS then reaper.ImGui_SetMouseCursor(ctx, RESIZE_NS) end
    elseif cursor == "time_left" or cursor == "time_right" or cursor == "middle_pan" then
      if RESIZE_EW then reaper.ImGui_SetMouseCursor(ctx, RESIZE_EW) end
    elseif cursor == "time_body" or cursor == "amp_body" or cursor == "ruler" then
      if RESIZE_ALL then reaper.ImGui_SetMouseCursor(ctx, RESIZE_ALL) end
    end
  end

  return result, claimed, drag.mode or hot
end

return navigation
