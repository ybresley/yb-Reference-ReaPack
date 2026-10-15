local fill = {}

local TILE_WIDTH = 64
local TILE_OVERLAP = 2

-- Clip adjoining contours at fixed screen columns. Their outer edges sit
-- beyond each clip, so the polygon's antialiased side cannot make a seam.
function fill.paint(polygon_draw, dl, points, used, scratch, capacity,
    left, right, top, bottom, colour, push_clip, pop_clip, paint_polygon)
  if used < 2 or right <= left or bottom <= top then return false end
  local painted = false
  local segment = 1
  local tile = math.floor(left / TILE_WIDTH) * TILE_WIDTH

  while tile < right do
    local clip_left, clip_right = math.max(left, tile), math.min(right, tile + TILE_WIDTH)
    local from, to = math.max(left, tile - TILE_OVERLAP),
      math.min(right, tile + TILE_WIDTH + TILE_OVERLAP)
    local count, clip_open, above = 0, false, false
    local highest,lowest=bottom,top

    local function curve_point(x, y)
      if count > 0 and scratch[count * 2 - 1] == x then return end
      local level = math.max(top, math.min(bottom, y))
      count = count + 1
      scratch[count * 2 - 1], scratch[count * 2] = x, level
      above = above or level < bottom
      highest,lowest=math.min(highest,level),math.max(lowest,level)
    end

    local function flush()
      if count > 1 then
        local first_x, first_y = scratch[1], scratch[2]
        local last_x, last_y = scratch[count * 2 - 1], scratch[count * 2]
        if last_x > first_x and above then
          if last_y < bottom then
            count = count + 1
            scratch[count * 2 - 1], scratch[count * 2] = last_x, bottom
          end
          if first_y < bottom then
            count = count + 1
            scratch[count * 2 - 1], scratch[count * 2] = first_x, bottom
          end
          if not clip_open then
            push_clip(dl, clip_left, top, clip_right, bottom, true)
            clip_open = true
          end
          scratch.resize(count * 2)
          if paint_polygon then
            paint_polygon(dl,scratch,first_x,last_x,highest,lowest)
          else
            polygon_draw(dl, scratch, colour)
          end
          scratch.resize(capacity)
          painted = true
        end
      end
      count = 0
      above = false
      highest,lowest=bottom,top
    end

    while segment < used - 1 and points[segment * 2 + 1] < from do
      segment = segment + 1
    end
    while segment > 1 and points[segment * 2 - 3] == points[segment * 2 - 1] do
      segment = segment - 1
    end
    local i = segment
    while i < used and points[i * 2 - 1] < to do
      local x0, y0 = points[i * 2 - 1], points[i * 2]
      local next_i = i + 1
      while next_i <= used and points[next_i * 2 - 1] == x0 do
        next_i = next_i + 1
      end
      if next_i <= used then
        local x1, y1 = points[next_i * 2 - 1], points[next_i * 2]
        local a, b = math.max(from, x0), math.min(to, x1)
        if b > a then
          local ya = y0 + (y1 - y0) * (a - x0) / (x1 - x0)
          local yb = y0 + (y1 - y0) * (b - x0) / (x1 - x0)
          if ya < bottom and yb < bottom then
            curve_point(a, ya)
            curve_point(b, yb)
          elseif ya < bottom then
            local cross = a + (bottom - ya) * (b - a) / (yb - ya)
            curve_point(a, ya)
            curve_point(cross, bottom)
            flush()
          elseif yb < bottom then
            local cross = a + (bottom - ya) * (b - a) / (yb - ya)
            curve_point(cross, bottom)
            curve_point(b, yb)
          else
            flush()
          end
        end
      end
      i = next_i
    end
    flush()
    if clip_open then pop_clip(dl) end
    tile = tile + TILE_WIDTH
  end
  return painted
end

return fill
