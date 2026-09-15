-- Paint-only motion for the selected Lucide controls. Coordinates use Lucide's
-- 24-unit view box; the theme supplies the final size and all state colours.
local theme = require("ui.theme")
local motion = require("core.ui_motion")
local loop = require("core.loop_icon")
local icons = require("ui.icons")
local shapes = require("ui.icon_shapes")

local icon_motion = {}
local tracker = motion.new(128)
local generation = theme.motion.generation
local modes = {
  library = "ICON_LIBRARY", settings = "ICON_SETTINGS", ear = "ICON_AUDITION",
  ["arrow-left-right"] = "ICON_SWAP",
  ["arrow-up-down"] = "ICON_SWAP", ["repeat"] = "ICON_LOOP", link = "ICON_LATCH",
  ["music-2"] = "ICON_PITCH", ["sliders-horizontal"] = "ICON_FILTER",
  target = "ICON_MORPH",
}
local morphs = { target = true }
local toggle_events = {
  library = true, settings = true, ear = true, ["repeat"] = true,
  link = true, ["music-2"] = true, ["sliders-horizontal"] = true,
}

function icon_motion.supports(name)
  return modes[name] ~= nil
end

local function ease_out(t)
  return 1 - (1 - t) ^ 3
end

local function ease_in_out(t)
  if t < 0.5 then return 4 * t ^ 3 end
  return 1 - (-2 * t + 2) ^ 3 / 2
end

local function ease_out_back(t)
  local overshoot = 1.2
  return 1 + (overshoot + 1) * (t - 1) ^ 3 + overshoot * (t - 1) ^ 2
end

local function line(dl, cx, cy, unit, x0, y0, x1, y1, colour)
  reaper.ImGui_DrawList_AddLine(dl, cx + (x0 - 12) * unit, cy + (y0 - 12) * unit,
    cx + (x1 - 12) * unit, cy + (y1 - 12) * unit, colour, 2 * unit)
end

local function circle(dl, cx, cy, unit, x, y, radius, colour, filled)
  x, y = cx + (x - 12) * unit, cy + (y - 12) * unit
  if filled then
    reaper.ImGui_DrawList_AddCircleFilled(dl, x, y, radius * unit, colour, 24)
  else
    reaper.ImGui_DrawList_AddCircle(dl, x, y, radius * unit, colour, 24, 2 * unit)
  end
end

local function outline(dl, cx, cy, unit, points, colour, angle, dx, dy)
  local sine, cosine = math.sin(angle or 0), math.cos(angle or 0)
  dx, dy = dx or 0, dy or 0
  for i = 1, #points, 2 do
    local x, y = points[i] - 12, points[i + 1] - 12
    reaper.ImGui_DrawList_PathLineTo(dl,
      cx + (x * cosine - y * sine + dx) * unit,
      cy + (x * sine + y * cosine + dy) * unit)
  end
  reaper.ImGui_DrawList_PathStroke(dl, colour, 0, 2 * unit)
end

local function swap_line(dl, cx, cy, unit, vertical, shift, colour, x0, y0, x1, y1)
  x0, x1 = x0 + shift, x1 + shift
  if vertical then x0, y0, x1, y1 = y0, x0, y1, x1 end
  line(dl, cx, cy, unit, x0, y0, x1, y1, colour)
end

local function paint_swap(dl, cx, cy, unit, colour, progress, vertical)
  local p = progress or 0
  local shift = p < 0.5 and p * 16 or (p - 1) * 16
  colour = theme.fade(colour, math.abs(p * 2 - 1))
  swap_line(dl, cx, cy, unit, vertical, -shift, colour, 8, 3, 4, 7)
  swap_line(dl, cx, cy, unit, vertical, -shift, colour, 4, 7, 8, 11)
  swap_line(dl, cx, cy, unit, vertical, -shift, colour, 4, 7, 20, 7)
  swap_line(dl, cx, cy, unit, vertical, shift, colour, 16, 13, 20, 17)
  swap_line(dl, cx, cy, unit, vertical, shift, colour, 20, 17, 16, 21)
  swap_line(dl, cx, cy, unit, vertical, shift, colour, 20, 17, 4, 17)
end

local slider_x, slider_y = {14, 8, 16}, {5, 12, 19}
local function paint_sliders(dl, cx, cy, unit, colour, progress)
  local t = progress and (progress < 0.5 and progress * 2 or (1 - progress) * 2) or 0
  local position = t * t * (3 - 2 * t)
  -- Lucide's rounded strokes apply equally to the rails and handles.
  local function stroke(x0, y0, x1, y1)
    line(dl, cx, cy, unit, x0, y0, x1, y1, colour)
    circle(dl, cx, cy, unit, x0, y0, 1, colour, true)
    circle(dl, cx, cy, unit, x1, y1, 1, colour, true)
  end
  for i = 1, 3 do
    local x = slider_x[i] + (12 - slider_x[i]) * 1.4 * position
    local y = slider_y[i]
    stroke(3, y, x - (i == 2 and 0 or 4), y)
    stroke(x + (i == 2 and 4 or 0), y, 21, y)
    stroke(x, y - 2, x, y + 2)
  end
end

local function audition_ellipse(dl, cx, cy, rx, ry, colour, thickness)
  for i = 0, 12 do
    local angle = -math.pi * 0.5 + math.pi * i / 12
    reaper.ImGui_DrawList_PathLineTo(dl,
      cx + math.cos(angle) * rx, cy + math.sin(angle) * ry)
  end
  reaper.ImGui_DrawList_PathStroke(dl, colour, 0, thickness)
end

-- CSS `ease-out` from the approved mockup. Keeping its actual curve matters here:
-- the waves spend longer approaching the ear than the app's usual cubic easing.
local function css_ease_out(t)
  local low, high = 0, 1
  for _ = 1, 8 do
    local u = (low + high) * 0.5
    local x = 3 * (1 - u) * u * u * 0.58 + u * u * u
    if x < t then low = u else high = u end
  end
  local u = (low + high) * 0.5
  return 3 * (1 - u) * u * u + u * u * u
end

local function audition_keyframe(progress, first_at, last_at, first, last)
  if progress <= first_at then return first end
  if progress >= last_at then return last end
  local t = css_ease_out((progress - first_at) / (last_at - first_at))
  return first + (last - first) * t
end

-- Opening the Library reads as a quick browse: the icon pulls slightly left,
-- settles from the right, and leaves one brief copy travelling ahead of it.
-- The real Lucide glyph stays in use, so the moving and resting icons match.
local function paint_library(ctx, font, dl, cx, cy, unit, colour, progress)
  local shift = 0
  if progress < 0.32 then
    shift = -2.7 * ease_out(progress / 0.32)
  elseif progress < 0.70 then
    shift = -2.7 + 4 * ease_in_out((progress - 0.32) / 0.38)
  else
    shift = 1.3 * (1 - ease_out((progress - 0.70) / 0.30))
  end

  if progress > 0.18 and progress < 1 then
    local ghost_progress = (progress - 0.18) / 0.82
    local ghost_shift = -2 + 10.1 * ease_out(ghost_progress)
    local ghost_alpha = math.sin(math.pi * ghost_progress) ^ 1.4 * 0.58
    local ghost_colour = theme.fade(colour, ghost_alpha)
    if not icons.paint_glyph(ctx, font, "library", cx + ghost_shift * unit, cy,
        ghost_colour, theme.metrics.ICON_FS) then
      icons.draw_folder(dl, cx + ghost_shift * unit, cy, ghost_colour)
    end
  end

  if not icons.paint_glyph(ctx, font, "library", cx + shift * unit, cy,
      colour, theme.metrics.ICON_FS) then
    icons.draw_folder(dl, cx + shift * unit, cy, colour)
  end
end

-- This follows the approved 42 px mockup in button-relative coordinates. Its
-- waves are elliptical, share one delayed inward movement, and keep their
-- separate silhouettes until they disappear inside the ear.
local function paint_audition(ctx, font, dl, cx, cy, button_size, colour, wave_base, progress)
  local total_time = 0.585
  local elapsed = progress * total_time
  local ear_progress = math.min(elapsed / 0.56, 1)
  local wave_progress = math.max(0, math.min((elapsed - 0.025) / 0.56, 1))
  local scale = button_size / 42

  local travel = audition_keyframe(wave_progress, 0.08, 1, -3.6, 7.2)
  local wave_scale = audition_keyframe(wave_progress, 0.08, 1, 1.08, 0.62)
  local wave_alpha
  if wave_progress <= 0.08 then
    wave_alpha = 0
  elseif wave_progress <= 0.22 then
    wave_alpha = audition_keyframe(wave_progress, 0.08, 0.22, 0, 0.95)
  elseif wave_progress <= 0.72 then
    wave_alpha = audition_keyframe(wave_progress, 0.22, 0.72, 0.95, 0.9)
  else
    wave_alpha = audition_keyframe(wave_progress, 0.72, 1, 0.9, 0)
  end

  local wave_colour = theme.fade(wave_base, wave_alpha)
  local thickness = math.max(1.1 * theme.scale, 1.5 * scale)
  audition_ellipse(dl, cx + (-14.5 + travel) * scale, cy,
    3.5 * wave_scale * scale, 8 * wave_scale * scale, wave_colour, thickness)
  audition_ellipse(dl, cx + (-11.5 + travel) * scale, cy,
    3.5 * wave_scale * scale, 4.5 * wave_scale * scale, wave_colour, thickness)

  local response
  if ear_progress <= 0.38 then
    response = audition_keyframe(ear_progress, 0, 0.38, 1, 1.08)
  elseif ear_progress <= 0.72 then
    response = audition_keyframe(ear_progress, 0.38, 0.72, 1.08, 0.98)
  else
    response = audition_keyframe(ear_progress, 0.72, 1, 0.98, 1)
  end
  icons.paint_glyph(ctx, font, "ear", cx, cy, colour, theme.metrics.ICON_FS * response)
end

-- Pitch needs whole-icon travel to remain legible at 14 px. The note jumps one
-- clear step, rocks with the movement, and leaves two brief notehead echoes on
-- the ascent. It returns to the ordinary Lucide outline when the motion ends.
local function paint_pitch(dl, cx, cy, unit, colour, progress)
  local lift, angle = 0, 0
  if progress then
    lift = -6.5 * math.sin(math.pi * progress)
    angle = math.rad(11) * math.sin(math.pi * 2 * progress) * (1 - progress)

    local echo = math.sin(math.pi * progress) ^ 1.5
    if echo > 0.02 then
      circle(dl, cx, cy, unit, 6.5, 19 + lift * 0.5, 2.4,
        theme.fade(colour, echo * 0.42))
      circle(dl, cx, cy, unit, 4.5, 20.5 + lift * 0.18, 1.7,
        theme.fade(colour, echo * 0.24))
    end
  end

  local sine, cosine = math.sin(angle), math.cos(angle)
  local function point(x, y)
    x, y = x - 12, y - 12
    return cx + (x * cosine - y * sine) * unit,
      cy + (x * sine + y * cosine + lift) * unit
  end

  local hx, hy = point(8, 18)
  reaper.ImGui_DrawList_AddCircle(dl, hx, hy, 4 * unit, colour, 24, 2 * unit)
  local x0, y0 = point(12, 18)
  local x1, y1 = point(12, 2)
  reaper.ImGui_DrawList_AddLine(dl, x0, y0, x1, y1, colour, 2 * unit)
  x0, y0 = point(12, 2)
  x1, y1 = point(19, 6)
  reaper.ImGui_DrawList_AddLine(dl, x0, y0, x1, y1, colour, 2 * unit)
end

local function paint_loop(dl, cx, cy, unit, colour, progress)
  for arrow = 1, 2 do
    for i = 0, loop.SEGMENTS do
      local x, y = loop.sample(progress or 0, arrow, i / loop.SEGMENTS)
      reaper.ImGui_DrawList_PathLineTo(dl, cx + (x - 12) * unit, cy + (y - 12) * unit)
    end
    reaper.ImGui_DrawList_PathStroke(dl, colour, 0, 2 * unit)
    local x, y, angle = loop.head(progress or 0, arrow)
    local sine, cosine = math.sin(angle), math.cos(angle)
    line(dl, cx, cy, unit, x - 4 * cosine + 4 * sine,
      y - 4 * sine - 4 * cosine, x, y, colour)
    line(dl, cx, cy, unit, x, y, x - 4 * cosine - 4 * sine,
      y - 4 * sine + 4 * cosine, colour)
  end
end

-- Paint a resolved pose without reading a clock or retaining control state. This
-- keeps non-live surfaces such as release demonstrations on their own timeline
-- while sharing the exact outlines and motion poses used by real controls.
function icon_motion.paint_pose(ctx, font, name, cx, cy, colour,
    position, progress, size, item_size)
  if not modes[name] then return false end
  position = position or 0
  -- Keep the established font glyph at rest; only the click needs its outline.
  if (name == "settings" or name == "library" or name == "ear") and not progress then
    return false
  end
  local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
  colour = theme.fade(colour, alpha)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local unit = (size or theme.metrics.ICON_FS) / 24
  if name == "library" then
    paint_library(ctx, font, dl, cx, cy, unit, colour, progress)
  elseif name == "ear" then
    paint_audition(ctx, font, dl, cx, cy, item_size or theme.metrics.ICON_FS,
      colour, theme.fade(theme.tokens.ACCENT, alpha), progress)
  elseif name == "settings" then
    local angle = progress and ease_in_out(progress) * math.pi / 3 or 0
    outline(dl, cx, cy, unit, shapes.gear[1], colour, angle)
    circle(dl, cx, cy, unit, 12, 12, 3, colour)
  elseif name == "link" then
    local gap = 0
    if progress then
      -- Begin at the resting outline, pull the halves apart, then run the
      -- established crossover join. This avoids a one-frame jump to full width.
      local opening = 0.20
      if progress < opening then
        gap = 3.4 * ease_out(progress / opening)
      else
        gap = 3.4 * (1 - ease_out_back((progress - opening) / (1 - opening)))
      end
    end
    outline(dl, cx, cy, unit, shapes.link[1], colour, 0, gap, -gap)
    outline(dl, cx, cy, unit, shapes.link[2], colour, 0, -gap, gap)
  elseif name == "music-2" then
    paint_pitch(dl, cx, cy, unit, colour, progress)
  elseif name == "target" then
    circle(dl, cx, cy, unit, 12, 12, 10, colour)
    circle(dl, cx, cy, unit, 12, 12, 6 - 2 * position, colour)
    if position < 1 then circle(dl, cx, cy, unit, 12, 12, 2 + 2 * position,
      theme.fade(colour, 1 - position ^ 8)) end
  elseif name == "sliders-horizontal" then
    paint_sliders(dl, cx, cy, unit, colour, progress)
  elseif name == "repeat" then
    paint_loop(dl, cx, cy, unit, colour, progress)
  else
    paint_swap(dl, cx, cy, unit, colour, progress, name == "arrow-up-down")
  end
  return true
end

-- Position and input are explicit so delayed paint passes never read another
-- control's last-item state. `on` means the real toggle/panel state, not colour.
function icon_motion.paint(ctx, id, name, cx, cy, colour, on, clicked, enabled, size, font, item_size)
  local mode = modes[name]
  if not mode then return false end
  enabled = enabled ~= false
  on, clicked = on == true, enabled and clicked == true
  if generation ~= theme.motion.generation then
    tracker, generation = motion.new(128), theme.motion.generation
  end
  local position, progress = on and 1 or 0, nil
  if enabled and theme.motion.enabled and reaper.ImGui_GetTime and reaper.ImGui_GetFrameCount then
    local now, frame = reaper.ImGui_GetTime(ctx), reaper.ImGui_GetFrameCount(ctx)
    local duration = theme.motion[mode]
    if morphs[name] then
      position = motion.icon_value(tracker, id, on, clicked, now, frame, duration)
    elseif toggle_events[name] then
      progress = motion.toggle_event(tracker, id, on, clicked, now, frame, duration)
    else
      progress = motion.icon_event(tracker, id, clicked, now, frame, duration)
    end
  else
    -- Disabled or hidden controls cannot retain a transition for a later frame.
    if tracker.entries[id] then tracker.entries[id], tracker.count = nil, tracker.count - 1 end
    if clicked then position = 1 - position end
  end
  return icon_motion.paint_pose(ctx, font, name, cx, cy, colour,
    position, progress, size, item_size)
end

function icon_motion.paint_item(ctx, id, name, colour, on, clicked, enabled, font)
  if not modes[name] then return false end
  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
  return icon_motion.paint(ctx, id, name, (x0 + x1) * 0.5, (y0 + y1) * 0.5,
    colour, on, clicked, enabled, nil, font, math.min(x1 - x0, y1 - y0))
end

return icon_motion
