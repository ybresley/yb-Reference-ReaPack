local theme = require("ui.theme")
local filter = require("core.monitor_filter")
local band_icon = {}

function band_icon.paint(ctx, low, high, colour)
  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
  local s = theme.scale
  local start_x = (x0 + x1) * 0.5 - 9.5 * s
  local base = (y0 + y1) * 0.5 + 4.5 * s
  local width, height = 19 * s, 8 * s
  local left = start_x + filter.frequency_to_t(low) * width
  local right = start_x + filter.frequency_to_t(high) * width
  local rise_start = math.max(start_x, left - 2 * s)
  local fall_end = math.min(start_x + width, right + 2 * s)
  local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
  colour = theme.fade(colour, alpha)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)

  local function smoothstep(t)
    t = math.max(0, math.min(1, t))
    return t * t * (3 - 2 * t)
  end
  local function amount_at(x)
    local rise = low <= filter.MIN_HZ and 1
      or smoothstep((x - rise_start) / math.max(0.001, left - rise_start))
    local fall = high >= filter.MAX_HZ and 1
      or smoothstep((fall_end - x) / math.max(0.001, fall_end - right))
    return math.min(rise, fall)
  end

  -- Soft fill keeps each region readable at icon size. Fill each screen
  -- column once so translucent overlaps cannot create dark seams.
  for column = math.ceil(start_x), math.floor(start_x + width - 0.001) do
    local amount = amount_at(column + 0.5)
    if amount > 0 then
      reaper.ImGui_DrawList_AddRectFilled(dl, column, base - amount * height,
        column + 1, base, theme.fade(colour, 0.3))
    end
  end

  local px, py
  local steps = math.max(1, math.floor(width + 0.5))
  for i = 0, steps do
    local t = i / steps
    local cx = start_x + t * width
    local cy = base - amount_at(cx) * height
    if px then
      reaper.ImGui_DrawList_AddLine(dl, px, py, cx, cy, colour, s)
    end
    px, py = cx, cy
  end
  if low <= filter.MIN_HZ then
    reaper.ImGui_DrawList_AddLine(dl, start_x, base, start_x, base - height, colour, s)
  end
  if high >= filter.MAX_HZ then
    reaper.ImGui_DrawList_AddLine(dl, start_x + width, base,
      start_x + width, base - height, colour, s)
  end
  reaper.ImGui_DrawList_AddLine(dl, start_x, base, start_x + width, base,
    theme.fade(colour, 0.2), s)
end

return band_icon
