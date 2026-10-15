local arcs = {}
local PI, TAU = math.pi, 2 * math.pi

function arcs.new()
  return {angles = {}, starts = {}, ends = {}, count = 0}
end

-- Clipping occupies short sections of the full-scale border. Merge only
-- overlapping marker widths, keeping gaps where no clipping was captured.
function arcs.build(output, pixels, radius, marker_radius, extra_x, extra_y)
  local angles, count = output.angles, 0
  local step, cols = pixels.dot_size, pixels.cols
  for i = 1, pixels.clip_count do
    local cell = pixels.clip_cells[i]
    local x = (cell % cols + 0.5) * step - radius
    local y = math.max(0, radius - (cell // cols + 0.5) * step)
    count = count + 1
    angles[count] = TAU - math.atan(y, x)
  end
  if extra_x and extra_y then
    count = count + 1
    angles[count] = TAU - math.atan(math.max(0, extra_y), extra_x)
  end
  for i = #angles, count + 1, -1 do angles[i] = nil end
  table.sort(angles)
  local half_width = marker_radius / radius
  local spans = 0
  for i = 1, count do
    local first = math.max(PI, angles[i] - half_width)
    local last = math.min(TAU, angles[i] + half_width)
    if spans > 0 and first <= output.ends[spans] then
      output.ends[spans] = math.max(output.ends[spans], last)
    else
      spans = spans + 1
      output.starts[spans], output.ends[spans] = first, last
    end
  end
  for i = output.count, spans + 1, -1 do
    output.starts[i], output.ends[i] = nil, nil
  end
  output.count = spans
  return output
end

return arcs
