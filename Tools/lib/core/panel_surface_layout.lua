-- Display rectangles can differ from the frames used by panel dividers.
local surfaces = {}

local function shares_left_edge(a, b)
  local tolerance = .01
  return math.abs(a.x-b.x) <= tolerance
    and (a.y+a.h <= b.y+tolerance or b.y+b.h <= a.y+tolerance)
end

function surfaces.measure(panels, meter_left_inset, ruler_height, minimum_picture_height)
  local meter
  for _, pane in ipairs(panels) do
    if pane.id == 'loudness' then meter = pane; break end
  end
  local result = {}
  for _, pane in ipairs(panels) do
    local inset = meter and pane ~= meter and shares_left_edge(pane, meter)
      and math.max(0, math.min(math.max(0, pane.w-1), meter_left_inset or 0)) or 0
    local footer = math.max(0, ruler_height or 0)
    -- Panels ending on the same row share one ruler decision, including a
    -- tall panel beside a shorter bottom row.
    for _, neighbour in ipairs(panels) do
      if math.abs(pane.y+pane.h-neighbour.y-neighbour.h) <= .01
          and neighbour.h-footer < (minimum_picture_height or 0) then
        footer = 0
        break
      end
    end
    result[pane.id] = {
      x=pane.x+inset, y=pane.y, w=pane.w-inset, h=pane.h,
      footer_height=footer,
    }
  end
  return result
end

return surfaces
