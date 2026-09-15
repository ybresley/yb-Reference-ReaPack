-- Pure layout policy for the Reference View control bar. The UI supplies live
-- measurements and scaled theme metrics; this module decides what fits and
-- returns the positions used by both measuring and drawing.

local layout = {}

local ARRANGEMENTS = {
  { count = true, trim = "fader" },
  { count = true, trim = "number" },
  { two_line = true, count = true, trim = "number" },
}

local function try_fit(arrangement, width, measured, metrics, cluster_w, floor_it)
  local ctrl = measured.ctrl
  local gap = measured.gap
  local count_on = arrangement.count and measured.count_w > 0
  local before_arrows = count_on
      and (metrics.PICK_COUNT_PAD + measured.count_w + metrics.PICK_COUNT_PAD)
    or gap
  local trim_w = (arrangement.trim == "fader" and metrics.SLIDER_W)
    or (arrangement.trim == "number" and measured.num_w)
    or nil

  local geometry = {
    ctrl = ctrl,
    gap = gap,
    gap_y = measured.gap_y,
    two_line = arrangement.two_line or false,
    count_w = count_on and measured.count_w or 0,
    trim_shown = arrangement.trim,
    trim_w = trim_w,
  }

  if arrangement.two_line then
    -- The first row gives the reference name every pixel before the fixed count
    -- and arrows. The second row keeps the transport group on the left and pins
    -- Loudness, trim, Library and Settings to the right.
    local slot_w = width - before_arrows - measured.arrows_w
    local group_w = ctrl + metrics.PICK_ARROW_GAP + ctrl
    if trim_w then group_w = group_w + gap + ctrl + gap + trim_w end
    local packed_x = ctrl + gap + cluster_w + gap
    if (slot_w < metrics.PICK_MIN_W or packed_x + group_w > width) and not floor_it then
      return nil
    end

    geometry.slot_x, geometry.slot_w = 0, math.max(0, slot_w)
    if count_on then
      geometry.count_x = geometry.slot_w + metrics.PICK_COUNT_PAD
      geometry.arrows_x = geometry.count_x + measured.count_w + metrics.PICK_COUNT_PAD
    else
      geometry.arrows_x = geometry.slot_w + gap
    end
    geometry.ctrl_y = ctrl + measured.gap_y
    geometry.latch_x = 0

    -- A dock can become narrower than the packed second row. Tighten every
    -- flexible gap evenly to 2 px before allowing the right edge to clip. The
    -- layout never removes a control or creates a third row.
    local tightened_gap = gap
    local deficit = (packed_x + group_w) - width
    local flexible_gap_count = measured.cluster_count + 3
    if deficit > 0 then
      tightened_gap = gap - math.min(gap - 2, deficit / flexible_gap_count)
    end
    geometry.cluster_gap = tightened_gap
    geometry.cluster_x = ctrl + tightened_gap
    local internal_cluster_gaps = measured.cluster_count - 1
    local x = math.max(width - group_w,
      geometry.cluster_x + cluster_w
        - internal_cluster_gaps * (gap - tightened_gap) + tightened_gap)
    if trim_w then
      geometry.target_x = x
      geometry.trim_x = geometry.target_x + ctrl + tightened_gap
      x = geometry.trim_x + trim_w + tightened_gap
    end
    geometry.library_x = x
    geometry.gear_x = geometry.library_x + ctrl + metrics.PICK_ARROW_GAP
    geometry.height = ctrl * 2 + measured.gap_y
    return geometry
  end

  -- On one row the name takes the available space up to its cap. Any room past
  -- that cap becomes the source-facts zone; it must not widen the name or move
  -- the fixed right-hand controls.
  local right_w = ctrl + gap + ctrl
  if trim_w then right_w = right_w + gap + ctrl + gap + trim_w end
  local slot_raw = width - (ctrl + gap + cluster_w + gap)
    - before_arrows - measured.arrows_w - gap - right_w
  if slot_raw < metrics.PICK_MIN_W and not floor_it then return nil end

  geometry.slot_w = math.max(0, math.min(slot_raw, metrics.PICK_MAX_W))
  geometry.ctrl_y = 0
  geometry.latch_x = 0
  geometry.cluster_gap = gap
  geometry.cluster_x = ctrl + gap
  geometry.slot_x = geometry.cluster_x + cluster_w + gap
  if count_on then
    geometry.count_x = geometry.slot_x + geometry.slot_w + metrics.PICK_COUNT_PAD
    geometry.arrows_x = geometry.count_x + measured.count_w + metrics.PICK_COUNT_PAD
  else
    geometry.arrows_x = geometry.slot_x + geometry.slot_w + gap
  end
  geometry.gear_x = width - ctrl
  geometry.library_x = geometry.gear_x - gap - ctrl
  if trim_w then
    geometry.trim_x = geometry.library_x - gap - trim_w
    geometry.target_x = geometry.trim_x - gap - ctrl
  end
  geometry.tech_x = geometry.arrows_x + measured.arrows_w + metrics.PICK_COUNT_PAD
  geometry.tech_max = (geometry.target_x or geometry.library_x) - gap - geometry.tech_x
  geometry.height = ctrl
  return geometry
end

function layout.geometry(width, measured, metrics)
  local cluster_w = measured.ctrl * measured.cluster_count
    + measured.gap * (measured.cluster_count - 1)

  -- Keep the full trim fader as long as it fits, then use its draggable number,
  -- then fold to two rows. Count width participates in every fit decision.
  for _, arrangement in ipairs(ARRANGEMENTS) do
    local geometry = try_fit(arrangement, width, measured, metrics, cluster_w, false)
    if geometry then return geometry end
  end

  return try_fit(ARRANGEMENTS[#ARRANGEMENTS], width, measured, metrics, cluster_w, true)
end

return layout
