-- Loudness and channel bars grow from one lane width, so both groups scale
-- together. M, S and I share one bar width and even spacing; channel bars sit a
-- quarter of a bar apart. Each group stops growing once its bars reach
-- MAX_BAR; spare width then stays outside the groups instead of opening gaps.
local lanes = {}

lanes.MAX_BAR = 48
-- M, S and I bars stop thinning here; only the gaps between them shrink further.
lanes.MIN_BAR = 24
-- Axis gutter plus the padding on the group's other side: 32 + 3 + 8, or 8 + 35.
lanes.FRAME = 43
-- Readout pitch (unscaled): the width of '00.0' plus a hanging minus and 8 px of
-- clearance. The panel measures the real font; these values stand in without one.
lanes.DEFAULT_PITCHES = { [20] = 59, [18] = 54, [16] = 49, [14] = 44, [12] = 39 }
lanes.SIZES = { 20, 18, 16, 14, 12 }

-- The LRA bracket sits 9 px right of the I bar, and its text 5 px further on.
lanes.LRA_BRACKET, lanes.LRA_TEXT_GAP = 9, 5
-- Widest LRA text: '00.0' at 14 px in the release font. The panel measures the
-- real font; this value stands in without one.
lanes.LRA_TEXT = 28
-- The LRA text stops 6 px short of whatever follows it. L/R's grid starts 8 px
-- into its group.
local CLEAR, LR_PAD = 6, 8
local PAD, MIN_GAP = 8, 12

-- Slot order for the Loudness group. The LRA bracket keeps the I slot even when
-- the I bar itself is hidden.
function lanes.loudness_slots(prefs)
  prefs = prefs or {}
  local slots = {}
  if prefs.show_m ~= false then slots[#slots+1] = 'm' end
  if prefs.show_s ~= false then slots[#slots+1] = 's' end
  local lra = prefs.show_lra ~= false
  if prefs.show_i ~= false or lra then slots[#slots+1] = 'i' end
  return slots, lra
end

-- M, S and I bar width: half the lane, but never thinner than MIN_BAR while a
-- 12 px gap still fits between bars.
function lanes.bar(lane, s)
  local bar = math.max(lane/2, math.min(lanes.MIN_BAR*s, lane - MIN_GAP*s))
  return math.min(lanes.MAX_BAR*s, bar)
end

-- Extra room after the I slot so the LRA text clears the group's edge. `after`
-- is empty space past that edge the text may also use; `text` is its widest
-- line, unscaled.
function lanes.gutter(lane, s, slots, lra, after, text)
  if not lra or slots[#slots] ~= 'i' then return 0 end
  local reach = (lanes.LRA_BRACKET + lanes.LRA_TEXT_GAP + (text or lanes.LRA_TEXT) + CLEAR)*s
  return math.max(0, reach - (after or 0) - (lane - lanes.bar(lane, s))/2 - PAD*s)
end

function lanes.loudness_width(lane, s, prefs, after, text)
  local slots, lra = lanes.loudness_slots(prefs)
  return lanes.FRAME*s + #slots*lane + lanes.gutter(lane, s, slots, lra, after, text)
end

-- Channel bars sit a quarter of a bar apart, or further where two values such
-- as -12.3 need the room. A lane too narrow for its values compresses evenly.
function lanes.pitch(lane, readout_pitch)
  return math.max(lane*.625, math.min(lane, readout_pitch))
end

function lanes.channel_width(lane, s, count, readout_pitch)
  return lanes.FRAME*s + count*lanes.pitch(lane, readout_pitch)
end

-- Widest lane whose width(lane) fits. width() never shrinks as the lane grows.
function lanes.solve(width, available, highest)
  if width(highest) <= available then return highest end
  local low, high = 0, highest
  for _ = 1, 40 do
    local mid = (low+high)/2
    if width(mid) <= available then low = mid else high = mid end
  end
  return low
end

-- Plans one meter row. Values step down from 20 px only when the row cannot
-- give every bar a lane wide enough for them.
function lanes.plan(options)
  local s = options.scale or 1
  local count = options.channel_count or 2
  local pitches = options.readout_pitches or lanes.DEFAULT_PITCHES
  local text = options.lra_text_width
  -- With L/R straight after Loudness, the LRA text may run on through the gap
  -- and L/R's padding, stopping short of their grid.
  local after = (options.loudness and options.channels and options.lr_follows ~= false)
    and ((options.gap or 0) + LR_PAD*s) or 0
  local function readout_pitch(size)
    return (pitches[size] or lanes.DEFAULT_PITCHES[size])*s
  end
  local function row(lane, size)
    local total = 0
    if options.loudness then total = total + lanes.loudness_width(lane, s, options.prefs, after, text) end
    if options.channels then total = total + lanes.channel_width(lane, s, count, readout_pitch(size)) end
    if options.loudness and options.channels then total = total + (options.gap or 0) end
    return total
  end
  -- The narrowest lane that keeps values apart and M, S and I at full thickness.
  local function shortest(size)
    return math.max(readout_pitch(size), (lanes.MIN_BAR + MIN_GAP)*s)
  end
  local cap = 2*lanes.MAX_BAR*s
  local smallest = lanes.SIZES[#lanes.SIZES]
  local least = shortest(smallest)
  local plan = { cap_lane = cap, maximum = row(cap, lanes.SIZES[1]), minimum = row(least, smallest),
    after = after }
  -- Each group's width at the narrowest lane, for dividers and swapped groups.
  plan.loudness_minimum = lanes.loudness_width(least, s, options.prefs, after, text)
  plan.channel_minimum = lanes.channel_width(least, s, count, readout_pitch(smallest))
  -- Returns the shared lane and the value size for a row of this width.
  function plan.fit(available)
    local size = smallest
    for _, candidate in ipairs(lanes.SIZES) do
      if row(shortest(candidate), candidate) <= available then size = candidate; break end
    end
    local lane = lanes.solve(function(value) return row(value, size) end, available, cap)
    return lane, size
  end
  -- `contained`: the LRA label must fit inside the group, because L/R does not
  -- follow it directly in this arrangement.
  -- Largest value size, up to `largest`, whose neighbouring values stay apart on
  -- lanes this wide. Half a pixel absorbs the rounding of group widths.
  function plan.size_for(lane, largest)
    for _, size in ipairs(lanes.SIZES) do
      if size <= largest and readout_pitch(size) <= lane + .5*s then return size end
    end
    return smallest
  end
  function plan.loudness_width(lane, contained)
    return lanes.loudness_width(lane, s, options.prefs, not contained and after or 0, text)
  end
  function plan.channel_width(lane, size)
    return lanes.channel_width(lane, s, count, readout_pitch(size))
  end
  return plan
end

return lanes
