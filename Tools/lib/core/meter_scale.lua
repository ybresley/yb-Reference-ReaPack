-- Fixed dB landmarks expand the upper range without moving with the signal.
local scale = {}
scale.breaks = { -36, -24, -12 }

local function height(value)
  if value < -36 then return .12 + (value + 36) * .01 end
  if value < -24 then return .32 + (value + 24) * (.20 / 12) end
  if value < -12 then return .64 + (value + 12) * (.32 / 12) end
  return 1 + value * (.36 / 12)
end

-- Bars stop at the scale limits; history keeps off-screen points so clipping
-- preserves crossings instead of turning them into flat lines on the axes.
function scale.y(value, bottom, top, low, high, unclipped)
  value = value or low
  if not unclipped then value = math.max(low, math.min(high, value)) end
  local floor = height(low)
  return bottom - (height(value) - floor) / (height(high) - floor) * (bottom - top)
end

-- K-system displays retain their calibrated, evenly spaced dB divisions.
function scale.linear_y(value, bottom, top, low, high, unclipped)
  value = value or low
  if not unclipped then value = math.max(low, math.min(high, value)) end
  return bottom - (value - low) / (high - low) * (bottom - top)
end

function scale.ticks(top, bottom, low, step, ui_scale, high, map, labels)
  high, map = high or 0, map or scale.y
  labels = labels or {}
  local text_height = labels.height or 11 * ui_scale
  local gap = math.max(10 * ui_scale, text_height)
  local last_y = bottom - text_height/2 - 2 * ui_scale
  if last_y < top then return {} end
  -- Only half the centred text box extends towards the unlabelled bottom edge.
  local anchors = {{value=high, y=top}, {y=last_y+gap}}
  local priority = labels.priority
  if priority and priority >= low and priority <= high then
    local y = map(priority, bottom, top, low, high)
    if y <= last_y then
      if y - top < gap then table.remove(anchors, 1) end
      table.insert(anchors, #anchors, {value=priority, y=y})
    end
  end
  local candidates = {}
  -- Whole-dB alternatives can fit around an off-grid target where 3 dB marks
  -- cannot. Prefer the usual divisions whenever they fit the same label count.
  local candidate_step = step==3 and priority and 1 or step
  for value = high, low, -candidate_step do
    local y = map(value, bottom, top, low, high)
    local division = (high-value)/step
    candidates[#candidates + 1] = {value=value, y=y,
      fine=math.abs(division-math.floor(division+.5))<1e-9 and 0 or 1}
  end
  -- Maximise the readable labels before balancing their gaps. Placing a middle
  -- label first can otherwise block two labels that would fit on either side.
  local result = {}
  local function fill(a, b)
    if b-a < 2*gap-1e-9 then return end
    local nodes = {{y=a, count=0, fine=0, cost=0}}
    for _, candidate in ipairs(candidates) do
      if candidate.y-a >= gap-1e-9 and b-candidate.y >= gap-1e-9 then
        nodes[#nodes+1] = {value=candidate.value, y=candidate.y, penalty=candidate.fine}
      end
    end
    nodes[#nodes+1] = {y=b, penalty=0}
    for j=2,#nodes do
      local next_node=nodes[j]
      for i=1,j-1 do
        local previous=nodes[i]
        local distance=next_node.y-previous.y
        if previous.count and distance>=gap-1e-9 then
          local count=previous.count+(next_node.value and 1 or 0)
          local fine=previous.fine+next_node.penalty
          local cost=previous.cost+distance*distance
          if not next_node.count or count>next_node.count
            or count==next_node.count and (fine<next_node.fine
              or fine==next_node.fine and cost<next_node.cost) then
            next_node.count,next_node.fine,next_node.cost,next_node.previous=count,fine,cost,i
          end
        end
      end
    end
    local path,index={},nodes[#nodes].previous
    while index and index>1 do
      path[#path+1]=nodes[index].value
      index=nodes[index].previous
    end
    for i=#path,1,-1 do result[#result+1]=path[i] end
  end
  for i = 1, #anchors - 1 do
    result[#result + 1] = anchors[i].value
    fill(anchors[i].y, anchors[i+1].y)
  end
  return result
end

-- Target scales follow EBU Tech 3341's +9 / +18 spans. Expanded keeps the
-- fixed upper-range emphasis; changing the reading unit never moves a bar.
function scale.loudness(opts)
  if opts.loudness_scale == 'Target +9' then
    return opts.target - 18, opts.target + 9, scale.linear_y
  elseif opts.loudness_scale == 'Target +18' then
    return opts.target - 36, opts.target + 18, scale.linear_y
  end
  return opts.range, 0, scale.y
end

function scale.reading(value, opts)
  if value == nil or value <= -99 then return value end
  return opts.readings == 'Relative' and value - opts.target or value
end

function scale.unit(opts)
  return opts.readings == 'Relative' and 'LU' or 'LUFS'
end

return scale
