-- Reserve transport space before arranging the analysis panels.
local panels = {}

function panels.measure(width, height, bar_height, gap, scale, view, picture_min_width)
  width, height = math.max(0, width), math.max(0, height)
  scale = scale or 1
  local content_y = 0
  local available = math.max(0, height - content_y - bar_height - gap)
  local result = {bar_y = content_y + available + (available > 0 and gap or 0),
    content_y = content_y, content_h = available, mode = view or 'all'}
  local function rect(x, y, w, h) return {x = x, y = y, w = w, h = h} end
  if view == 'pictures' then
    result.pictures = rect(0, content_y, width, available)
  elseif view == 'meters' then
    result.meters = rect(0, content_y, width, available)
  elseif width >= 1000 * scale and available >= 200 * scale then
    local meter_width = math.min(640 * scale, math.floor((width - gap) * 0.45),
      math.max(320 * scale, width - gap - (picture_min_width or 608 * scale)))
    result.pictures = rect(0, content_y, width - gap - meter_width, available)
    result.meters = rect(width - meter_width, content_y, meter_width, available)
    result.mode = 'horizontal'
  elseif available >= 470 * scale then
    local meter_height = math.floor((available - gap) * 0.55)
    result.pictures = rect(0, content_y, width, available - gap - meter_height)
    result.meters = rect(0, content_y + available - meter_height, width, meter_height)
    result.mode = 'vertical'
  else
    -- Preserve legible meters in a small window; Settings keeps the other
    -- views accessible without shrinking every panel into an unreadable strip.
    result.meters = rect(0, content_y, width, available)
    result.mode = 'compact'
  end
  return result
end

return panels
