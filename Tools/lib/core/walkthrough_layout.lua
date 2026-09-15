-- Cards prefer a side of their subject and avoid other visible tool windows.
local layout = {}
local sides = { 'right', 'left', 'above', 'below' }

function layout.overlaps(x, y, w, h, rect)
  return x < rect.x2 and x + w > rect.x1
    and y < rect.y2 and y + h > rect.y1
end

function layout.place(subject, w, h, bounds, obstacles, gap, margin)
  for _, side in ipairs(sides) do
    -- Try every available area on this side before considering another side.
    for _, area in ipairs(bounds) do
      local min_x, min_y = area.x + margin, area.y + margin
      local max_x, max_y = area.x + area.w - margin - w, area.y + area.h - margin - h
      if max_x >= min_x and max_y >= min_y then
        local x, y
        if side == 'right' or side == 'left' then
          x = side == 'right' and subject.x2 + gap or subject.x1 - gap - w
          y = math.max(min_y, math.min(max_y, subject.y1))
        else
          x = math.max(min_x, math.min(max_x, subject.x2 - w))
          y = side == 'above' and subject.y1 - gap - h or subject.y2 + gap
        end
        local clear = x >= min_x and x <= max_x and y >= min_y and y <= max_y
        for _, obstacle in ipairs(obstacles or {}) do
          if layout.overlaps(x, y, w, h, obstacle) then clear = false; break end
        end
        if clear then return x, y end
      end
    end
  end
end

-- A changing target or closing panel must not make an established card jump.
-- New obstacles and screen limits still take priority over position retention.
function layout.stabilize(previous, step, x, y, w, h, area, obstacles, margin, anchor)
  if previous and previous.step == step then
    local px, py = previous.x, previous.y
    -- Follow the host's movement in either direction, even without a collision.
    -- Changing or closing a panel is not movement of that same host.
    if anchor and previous.anchor_id == anchor.id then
      px = px + anchor.x - previous.anchor_x
      py = py + anchor.y - previous.anchor_y
    end
    local clear = px >= area.x + margin and py >= area.y + margin
      and px + w <= area.x + area.w - margin
      and py + h <= area.y + area.h - margin
    for _, obstacle in ipairs(obstacles or {}) do
      if layout.overlaps(px, py, w, h, obstacle) then clear = false; break end
    end
    if clear then
      previous.x, previous.y = px, py
      if anchor then
        previous.anchor_id, previous.anchor_x, previous.anchor_y = anchor.id, anchor.x, anchor.y
      end
      return previous
    end
  end
  return { step = step, x = x, y = y, anchor_id = anchor and anchor.id,
    anchor_x = anchor and anchor.x, anchor_y = anchor and anchor.y }
end

return layout
