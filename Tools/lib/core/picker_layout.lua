local picker_layout = {}

local function clamp(value, low, high)
  if value < low then return low end
  if value > high then return high end
  return value
end

-- Place a popup around an anchor without allowing it to leave the usable work area.
-- The caller supplies coordinates in one shared space, including negative monitor
-- origins.  The minimum height is honoured whenever either side has room for it.
function picker_layout.place(anchor, work, width, height, min_height, gap, margin)
  -- A very small work area cannot afford the nominal margin on both sides.
  -- Reduce it independently so the result is still contained on each axis.
  local work_width = math.max(0, work.right - work.left)
  local work_height = math.max(0, work.bottom - work.top)
  local requested_margin = math.max(0, margin)
  local margin_x = work_width >= requested_margin * 2 and requested_margin or 0
  local margin_y = work_height >= requested_margin * 2 and requested_margin or 0
  local left = work.left + margin_x
  local top = work.top + margin_y
  local right = work.right - margin_x
  local bottom = work.bottom - margin_y
  local usable_width = right - left
  local usable_height = bottom - top

  local popup_width = math.min(width, usable_width)
  local popup_height = math.min(height, usable_height)
  local x = clamp(anchor.left, left, right - popup_width)

  local function result(y)
    return {
      x = x,
      y = clamp(y, top, bottom - popup_height),
      w = popup_width,
      h = popup_height,
    }
  end

  local below_y = anchor.bottom + gap
  local below_space = bottom - below_y
  local above_space = anchor.top - gap - top

  if below_space >= height then
    return result(below_y)
  end
  if above_space >= height then
    return result(anchor.top - gap - popup_height)
  end

  -- If one side can hold the useful minimum, use the side with more room and
  -- shorten only as much as necessary.  This keeps the popup near its anchor.
  local side, space
  if math.max(above_space, below_space) >= min_height then
    if below_space >= above_space then
      side, space = "below", below_space
    else
      side, space = "above", above_space
    end
    popup_height = math.min(height, usable_height, math.max(0, space))
    if side == "below" then
      return result(below_y)
    end
    return result(anchor.top - gap - popup_height)
  end

  -- Neither side can provide the minimum.  Start on the roomier side, then
  -- clamp the requested popup into the work area; overlap is unavoidable here.
  local y
  if below_space >= above_space then
    y = below_y
  else
    y = anchor.top - gap - popup_height
  end
  return result(y)
end

return picker_layout
