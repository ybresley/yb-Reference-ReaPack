local core = require('core.stereo')

local raster = {}
local MAX_COLUMNS = 2048
local MAX_DRAW_CELLS = 120000
local REBUILD_POINTS_PER_FRAME = 16384
local RESIZE_SETTLE_SECONDS = 0.1
local TRACE_CELLS_PER_CAPTURE = 4096

local function finite(value)
  return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

local function clear_clips(cache)
  for i = 1, cache.clip_count do
    local cell = cache.clip_cells[i]
    cache.clip_seen[cell], cache.clip_cells[i] = nil, nil
  end
  cache.clip_count = 0
end

local function clear_slot(slot)
  for i = 1, slot.clip_count do
    local cell = slot.clip_cells[i]
    slot.clip_seen[cell], slot.clip_cells[i] = nil, nil
  end
  slot.clip_count = 0
  slot.capture_id, slot.at, slot.source_clip_count = nil, nil, nil
end

local function remove_occupied(cache, cell)
  local position = cache.positions[cell]
  if not position then return end
  local last = cache.occupied[#cache.occupied]
  cache.occupied[position] = last
  cache.positions[last] = position
  cache.occupied[#cache.occupied] = nil
  cache.positions[cell], cache.latest[cell] = nil, nil
  cache.sample_times[cell] = nil
  cache.sample_x[cell], cache.sample_y[cell] = nil, nil
  cache.levels[cell] = nil
end

local function clear_history(cache)
  for i = 1, #cache.cells do cache.cells[i] = nil end
  for i = 1, #cache.occupied do
    local cell = cache.occupied[i]
    cache.positions[cell], cache.latest[cell] = nil, nil
    cache.sample_times[cell] = nil
    cache.sample_x[cell], cache.sample_y[cell] = nil, nil
    cache.levels[cell], cache.occupied[i] = nil, nil
  end
  for _, slot in pairs(cache.projected) do clear_slot(slot) end
  for id in pairs(cache.capture_times) do cache.capture_times[id] = nil end
  cache.count = 0
  cache.last_capture_id = nil
  cache.rebuild_queue, cache.rebuild_cursor = nil, nil
  cache.needs_reveal = nil
end

-- A fixed mask chooses at most 120,000 possible plot cells. It is independent
-- of occupancy and age, so no captured dot disappears when a newer packet
-- arrives. Ordinary-sized plots use every pixel.
local function configure_mask(cache, radius, polar, step, cols)
  local total = 0
  for gy = 0, cols - 1 do
    local y0, y1 = gy * step - radius, (gy + 1) * step - radius
    local distance = y1 < 0 and -y1 or (y0 > 0 and y0 or 0)
    local span
    if polar then
      if y0 <= 0 and distance <= radius then
        span = math.sqrt(math.max(0, radius * radius - distance * distance))
      end
    elseif distance <= radius then
      span = radius - distance
    end
    local left, right
    if span then
      -- Extra edge cells cover floor-rounding at the plot boundary.
      left = math.max(0, math.floor((radius - span) / step) - 1)
      right = math.min(cols - 1, math.floor((radius + span) / step) + 1)
      if right < left then left, right = nil, nil end
    end
    cache.mask_left[gy], cache.mask_right[gy] = left, right
    cache.mask_prefix[gy] = total
    if left then total = total + right - left + 1 end
  end
  cache.mask_total = total
  if total > MAX_DRAW_CELLS then
    local half = 1
    while half * half < total do half = half * 2 end
    cache.mask_half = half
    cache.mask_decisions = {}
  else
    cache.mask_half, cache.mask_decisions = nil, nil
  end
end

-- Four Feistel rounds scramble row-major positions without repeating one or
-- favouring any row. Cycle-walking restricts the permutation to the plot area.
local function permute(value, half)
  local left, right = value // half, value % half
  local mask = half - 1
  for round = 1, 4 do
    local mixed = (right * 0x9E3779B1 + round * 0x85EBCA6B) & 0xFFFFFFFF
    mixed = ((mixed ~ (mixed >> 16)) * 0x7FEB352D) & 0xFFFFFFFF
    mixed = ((mixed ~ (mixed >> 15)) * 0x846CA68B) & 0xFFFFFFFF
    mixed = mixed ~ (mixed >> 16)
    left, right = right, (left ~ mixed) & mask
  end
  return left * half + right
end

local function selected(cache, cell)
  if not cache.mask_half then return true end
  local saved = cache.mask_decisions[cell]
  if saved ~= nil then return saved end
  local gx, gy = cell % cache.cols, math.floor(cell / cache.cols)
  local left, right = cache.mask_left[gy], cache.mask_right[gy]
  if not left or gx < left or gx > right then return false end
  local rank = cache.mask_prefix[gy] + gx - left
  local mapped = rank
  repeat mapped = permute(mapped, cache.mask_half)
  until mapped < cache.mask_total
  local keep = mapped < MAX_DRAW_CELLS
  cache.mask_decisions[cell] = keep
  return keep
end

local function cell_at(px, py, radius, gain, step, cols)
  if not finite(px) or not finite(py) then return end
  local gx = math.floor((radius + px * radius * gain) / step)
  local gy = math.floor((radius - py * radius * gain) / step)
  if gx >= 0 and gx < cols and gy >= 0 and gy < cols then
    return gy * cols + gx
  end
end

local function project_clips(cache, slot, layer)
  for i = 1, slot.clip_count do
    local cell = slot.clip_cells[i]
    slot.clip_seen[cell], slot.clip_cells[i] = nil, nil
  end
  slot.clip_count = 0
  local xs = cache.polar and layer.polar_x or layer.lissajous_x
  local ys = cache.polar and layer.polar_y or layer.lissajous_y
  for i = 1, math.min(layer.clip_count or 0, core.MAX_POINTS) do
    local point = layer.clip_indices[i]
    local cell = point and cell_at(xs[point], ys[point],
      cache.radius, 1, cache.dot_size, cache.cols)
    if cell and not slot.clip_seen[cell] then
      slot.clip_count = slot.clip_count + 1
      slot.clip_cells[slot.clip_count] = cell
      slot.clip_seen[cell] = true
    end
  end
  slot.source_clip_count = layer.clip_count
end

local function slot_for(cache, index)
  local slot = cache.projected[index]
  if not slot then
    slot = {clip_count = 0, clip_cells = {}, clip_seen = {}}
    cache.projected[index] = slot
  end
  return slot
end

local function project(cache, index, layer)
  local slot = slot_for(cache, index)
  clear_slot(slot)
  local xs = cache.polar and layer.polar_x or layer.lissajous_x
  local ys = cache.polar and layer.polar_y or layer.lissajous_y
  local gain = layer.display_gain or 1
  cache.capture_times[layer.capture_id] = layer.at
  local interval = finite(layer.sample_rate) and layer.sample_rate > 0
    and 1 / layer.sample_rate or 0
  local function store(px, py, at)
    local cell = cell_at(px, py, cache.radius, 1, cache.dot_size, cache.cols)
    if cell and selected(cache, cell) then
      if not cache.latest[cell] then
        cache.occupied[#cache.occupied + 1] = cell
        cache.positions[cell] = #cache.occupied
      end
      local previous = cache.latest[cell]
      -- The packet timestamp belongs to its last sample. Keep the actual
      -- newest hit, including repeated visits within this same packet.
      local previous_at = previous and cache.capture_times[previous]
        and cache.sample_times[cell]
      if not previous_at or at > previous_at
          or (at == previous_at and layer.capture_id > previous) then
        cache.latest[cell] = layer.capture_id
        cache.sample_times[cell] = at
        cache.sample_x[cell], cache.sample_y[cell] = px, py
      end
    end
  end
  local count = math.min(layer.count, core.MAX_POINTS)
  for i = 1, count do
    if finite(xs[i]) and finite(ys[i]) then
      store(xs[i] * gain, ys[i] * gain, layer.at - (layer.count - i) * interval)
    end
  end
  if cache.trace then
    local remaining = TRACE_CELLS_PER_CAPTURE
    -- Join only adjacent samples from one capture. A finite budget favours
    -- recent complete segments; every real sample remains present as a dot.
    for i = count, 2, -1 do
      if finite(xs[i - 1]) and finite(ys[i - 1]) and finite(xs[i]) and finite(ys[i]) then
        local x1, y1, x2, y2 = xs[i - 1] * gain, ys[i - 1] * gain,
          xs[i] * gain, ys[i] * gain
        local steps = math.ceil(math.max(math.abs(x2 - x1), math.abs(y2 - y1))
          * cache.radius / cache.dot_size)
        if steps > remaining then break end
        remaining = remaining - steps
        for j = 1, steps - 1 do
          local t = j / steps
          store(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t,
            layer.at - (layer.count - (i - 1 + t)) * interval)
        end
        if remaining <= 0 then break end
      end
    end
  end
  slot.capture_id, slot.at = layer.capture_id, layer.at
  project_clips(cache, slot, layer)
  cache.last_capture_id = math.max(cache.last_capture_id or 0, layer.capture_id)
end

local function remove_slot(cache, slot)
  cache.capture_times[slot.capture_id] = nil
  clear_slot(slot)
end

local function valid_layer(layer)
  return layer and finite(layer.count) and layer.count > 0
    and finite(layer.capture_id) and finite(layer.at)
end

local function begin_rebuild(cache, model, radius, polar, step, cols)
  clear_history(cache)
  clear_clips(cache)
  cache.radius, cache.polar, cache.dot_size, cache.cols =
    radius, polar, step, cols
  cache.source_key, cache.epoch, cache.session =
    model.source_key, model.epoch, model.session
  configure_mask(cache, radius, polar, step, cols)
  local queue = {}
  for age_order = 0, core.MAX_LAYERS - 1 do
    local index = (model.head - age_order - 1) % core.MAX_LAYERS + 1
    local layer = model.layers[index]
    if valid_layer(layer) then
      if age_order == 0 then
        project(cache, index, layer)
      else
        queue[#queue + 1] = {index = index, id = layer.capture_id}
      end
    end
  end
  cache.rebuild_queue = queue
  cache.rebuild_cursor = 1
end

local function continue_rebuild(cache, model)
  local queue = cache.rebuild_queue
  if not queue then return end
  local cursor = cache.rebuild_cursor
  local points = 0
  while cursor <= #queue do
    local entry = queue[cursor]
    local layer = model.layers[entry.index]
    local cost = valid_layer(layer) and math.min(layer.count, core.MAX_POINTS) or 0
    if cache.trace and cost > 0 then cost = cost + TRACE_CELLS_PER_CAPTURE end
    if points > 0 and points + cost > REBUILD_POINTS_PER_FRAME then break end
    if valid_layer(layer) and layer.capture_id == entry.id then
      local slot = cache.projected[entry.index]
      if not slot or slot.capture_id ~= entry.id then
        project(cache, entry.index, layer)
        points = points + cost
      end
    end
    cursor = cursor + 1
  end
  if cursor > #queue then
    cache.rebuild_queue, cache.rebuild_cursor = nil, nil
  else
    cache.rebuild_cursor = cursor
  end
end

local function update_map(cache, model, now)
  local removed_visible = false
  local oldest_survivor
  for index = 1, core.MAX_LAYERS do
    local layer = model.layers[index]
    if valid_layer(layer) then
      oldest_survivor = math.min(oldest_survivor or layer.at, layer.at)
    end
  end
  for index = 1, core.MAX_LAYERS do
    local slot = cache.projected[index]
    if slot and slot.capture_id then
      local layer = model.layers[index]
      if not valid_layer(layer) or layer.capture_id ~= slot.capture_id then
        if oldest_survivor and slot.at >= oldest_survivor
            and core.opacity({count = 1, at = slot.at}, now)
              > core.VISIBLE_OPACITY then
          removed_visible = true
        end
        remove_slot(cache, slot)
      end
    end
  end
  local previous_id = cache.last_capture_id
  local incoming = {}
  for age_order = 1, core.MAX_LAYERS do
    local index = (model.head + age_order - 1) % core.MAX_LAYERS + 1
    local layer = model.layers[index]
    if valid_layer(layer) and (not previous_id
        or layer.capture_id > previous_id) then
      incoming[#incoming + 1] = {index = index, id = layer.capture_id}
    end
  end
  if #incoming > 0 then
    table.sort(incoming, function(a, b) return a.id > b.id end)
    local newest = incoming[1]
    project(cache, newest.index, model.layers[newest.index])
    if #incoming > 1 then
      local queue = {}
      local seen = {[newest.id] = true}
      for i = 2, #incoming do
        local entry = incoming[i]
        queue[#queue + 1], seen[entry.id] = entry, true
      end
      local old = cache.rebuild_queue
      if old then
        for i = cache.rebuild_cursor, #old do
          local entry = old[i]
          local layer = model.layers[entry.index]
          if valid_layer(layer) and layer.capture_id == entry.id
              and not seen[entry.id] then
            queue[#queue + 1], seen[entry.id] = entry, true
          end
        end
      end
      cache.rebuild_queue, cache.rebuild_cursor = queue, 1
    end
  end
  return removed_visible
end

local function refresh_output(cache, model, now)
  clear_clips(cache)
  local captures = {}
  for index = 1, core.MAX_LAYERS do
    local layer = model.layers[index]
    if valid_layer(layer) then
      captures[layer.capture_id] = true
      local slot = cache.projected[index]
      if slot and slot.capture_id == layer.capture_id then
        if slot.source_clip_count ~= layer.clip_count then
          project_clips(cache, slot, layer)
        end
        if core.clip_visible(layer, now, cache.preferences) then
          for i = 1, slot.clip_count do
            local cell = slot.clip_cells[i]
            if not cache.clip_seen[cell] then
              cache.clip_count = cache.clip_count + 1
              cache.clip_cells[cache.clip_count] = cell
              cache.clip_seen[cell] = true
            end
          end
        end
      end
    end
  end
  if cache.preferences and cache.preferences.show_clipping
      and cache.preferences.clip_hold == 0 and model.held_clips then
    local held = model.held_clips[cache.polar and 'polar_sample' or 'lissajous']
    for _, clip in pairs(held or {}) do
      local cell = cell_at(clip.x, clip.y, cache.radius, 1, cache.dot_size, cache.cols)
      if cell and not cache.clip_seen[cell] then
        cache.clip_count = cache.clip_count + 1
        cache.clip_cells[cache.clip_count], cache.clip_seen[cell] = cell, true
      end
    end
  end
  local previous_count, visible_count, i = cache.count, 0, 1
  local fade_curve = core.fade_curve(cache.view_prefs)
  while i <= #cache.occupied do
    local cell = cache.occupied[i]
    local opacity = captures[cache.latest[cell]]
      and core.opacity_at(cache.sample_times[cell], now, nil, fade_curve) or 0
    if opacity > core.VISIBLE_OPACITY then
      cache.levels[cell] = opacity
      visible_count = visible_count + 1
      cache.cells[visible_count] = cell
      i = i + 1
    elseif captures[cache.latest[cell]] and now - cache.sample_times[cell] < 6 then
      -- Keep hidden history available when a brightness or trail slider moves.
      cache.levels[cell] = nil
      i = i + 1
    else
      remove_occupied(cache, cell)
    end
  end
  for index = visible_count + 1, previous_count do cache.cells[index] = nil end
  cache.count = visible_count
end

function raster.new()
  local occupied = {}
  return {count = 0, cells = {}, levels = {},
    occupied = occupied, positions = {}, latest = {}, capture_times = {}, sample_times = {},
    sample_x = {}, sample_y = {},
    projected = {}, clip_count = 0, clip_cells = {}, clip_seen = {},
    mask_left = {}, mask_right = {}, mask_prefix = {},
    cols = 0, dot_size = 1}
end

function raster.shift_time(cache, elapsed)
  if not cache or not finite(elapsed) or elapsed <= 0 then return end
  for id, at in pairs(cache.capture_times) do cache.capture_times[id] = at + elapsed end
  for cell, at in pairs(cache.sample_times) do cache.sample_times[cell] = at + elapsed end
  for _, slot in pairs(cache.projected) do
    if slot.at then slot.at = slot.at + elapsed end
  end
  raster.shift_time(cache.pending, elapsed)
end

local map_fields = {
  'count', 'cells', 'levels', 'occupied', 'positions', 'latest',
  'capture_times', 'sample_times', 'sample_x', 'sample_y',
  'projected', 'clip_count', 'clip_cells', 'clip_seen',
  'mask_left', 'mask_right', 'mask_prefix', 'mask_total', 'mask_half',
  'mask_decisions', 'cols', 'dot_size', 'radius', 'polar',
  'source_key', 'epoch', 'session', 'last_capture_id',
  'rebuild_queue', 'rebuild_cursor', 'needs_reveal',
  'preferences', 'view_prefs', 'trace',
}

local function adopt(cache, completed)
  for _, name in ipairs(map_fields) do cache[name] = completed[name] end
  cache.pending, cache.resize_request, cache.preview = nil, nil, nil
end

-- Reproject actual hit positions while the full history rebuilds. Enlarging
-- rounded old pixel positions would create regularly spaced empty rows and
-- columns. Shrinking can merge hits; keep the brightest without adding light.
local function scaled_preview(cache, radius, step, cols)
  local preview = cache.preview
  if not preview then
    preview = {cells = {}, levels = {}, clip_cells = {}, clip_seen = {}}
    cache.preview = preview
  end
  for i = 1, #preview.cells do
    local cell = preview.cells[i]
    preview.levels[cell], preview.cells[i] = nil, nil
  end
  for i = 1, #preview.clip_cells do
    local cell = preview.clip_cells[i]
    preview.clip_seen[cell], preview.clip_cells[i] = nil, nil
  end
  local factor = cache.dot_size * radius / (cache.radius * step)
  for i = 1, cache.count do
    local cell = cache.cells[i]
    local destination = cell_at(cache.sample_x[cell], cache.sample_y[cell],
      radius, 1, step, cols)
    if destination then
      local opacity = cache.levels[cell]
      if not preview.levels[destination] then
        preview.cells[#preview.cells + 1] = destination
        preview.levels[destination] = opacity
      elseif opacity > preview.levels[destination] then
        preview.levels[destination] = opacity
      end
    end
  end
  for i = 1, cache.clip_count do
    local cell = cache.clip_cells[i]
    local gx = math.floor(cell % cache.cols * factor)
    local gy = math.floor(cell // cache.cols * factor)
    if gx < cols and gy < cols then
      local destination = gy * cols + gx
      if not preview.clip_seen[destination] then
        preview.clip_cells[#preview.clip_cells + 1] = destination
        preview.clip_seen[destination] = true
      end
    end
  end
  preview.count, preview.clip_count = #preview.cells, #preview.clip_cells
  preview.radius, preview.dot_size, preview.cols = radius, step, cols
  return preview
end

-- cells are zero-based grid IDs. levels[n] is the newest visible hit's
-- opacity; overlapping older hits never add brightness. Clipping bypasses
-- the blue spatial mask and remains at raw full-scale positions.
function raster.build(cache, model, radius, polar, dot_size, now, preferences)
  if not model or type(model.layers) ~= 'table'
      or model.status == 'invalid' or model.status == 'unavailable'
      or not finite(radius) or radius <= 0
      or not finite(dot_size) or dot_size <= 0 then
    clear_history(cache)
    clear_clips(cache)
    cache.pending, cache.resize_request = nil, nil
    cache.cols = 0
    return cache
  end
  local extent = radius * 2
  if not finite(extent) then
    clear_history(cache)
    clear_clips(cache)
    cache.pending, cache.resize_request = nil, nil
    cache.cols = 0
    return cache
  end
  local step = math.max(1, math.floor(dot_size + 0.5),
    math.ceil(extent / (MAX_COLUMNS - 1)))
  local cols = math.floor(extent / step) + 1
  now = finite(now) and now or (finite(model.now) and model.now or 0)
  -- Freeze stops dot ageing, but resizing must still settle in real time.
  local resize_now = math.max(now, finite(model.now) and model.now or now)
  polar = polar == true
  local view_prefs = preferences and preferences.views
    and preferences.views[polar and 'polar_sample' or 'lissajous']
  local trace = not polar and view_prefs and view_prefs.trace == 'lines' or false
  local head = model.head
  if not finite(head) or head % 1 ~= 0 or head < 1
      or head > core.MAX_LAYERS or not model.layers[head]
      or not finite(model.layers[head].count)
      or model.layers[head].count <= 0 then
    clear_history(cache)
    clear_clips(cache)
    cache.pending, cache.resize_request = nil, nil
    cache.cols, cache.dot_size = cols, step
    return cache
  end

  local different_view = cache.polar ~= polar
    or cache.source_key ~= model.source_key or cache.epoch ~= model.epoch
    or cache.session ~= model.session or not cache.radius
    or cache.trace ~= trace
  cache.preferences, cache.view_prefs = preferences, view_prefs
  if cache.pending then
    cache.pending.preferences, cache.pending.view_prefs = preferences, view_prefs
  end
  local function new_configured()
    local value = raster.new()
    value.preferences, value.view_prefs, value.trace = preferences, view_prefs, trace
    return value
  end
  local removed_visible = false
  if different_view then
    local fresh = new_configured()
    begin_rebuild(fresh, model, radius, polar, step, cols)
    adopt(cache, fresh)
  else
    removed_visible = update_map(cache, model, now)
    if removed_visible then cache.needs_reveal = true end
  end
  continue_rebuild(cache, model)
  refresh_output(cache, model, now)

  local size_changed = cache.radius ~= radius
    or cache.dot_size ~= step or cache.cols ~= cols
  if not size_changed then
    cache.resize_request = nil
    if cache.pending and (cache.pending.radius ~= radius
        or cache.pending.dot_size ~= step
        or cache.pending.cols ~= cols) then
      cache.pending = nil
    end
    if cache.needs_reveal and not cache.pending
        and not cache.rebuild_queue then
      cache.pending = new_configured()
      begin_rebuild(cache.pending, model, radius, polar, step, cols)
    end
    if cache.pending then
      if update_map(cache.pending, model, now) then
        cache.pending.needs_reveal = true
      end
      continue_rebuild(cache.pending, model)
      if not cache.pending.rebuild_queue then
        if cache.pending.needs_reveal then
          cache.pending = nil
        else
          refresh_output(cache.pending, model, now)
          adopt(cache, cache.pending)
        end
      end
    end
    return cache
  end

  local request = cache.resize_request
  if not request or request.radius ~= radius or request.step ~= step
      or request.cols ~= cols then
    cache.pending = nil
    request = {radius = radius, step = step, cols = cols, since = resize_now}
    cache.resize_request = request
  end
  if resize_now - request.since >= RESIZE_SETTLE_SECONDS then
    if not cache.pending then
      cache.pending = new_configured()
      begin_rebuild(cache.pending, model, radius, polar, step, cols)
    else
      if update_map(cache.pending, model, now) then
        cache.pending.needs_reveal = true
      end
    end
    continue_rebuild(cache.pending, model)
    if not cache.pending.rebuild_queue then
      if cache.pending.needs_reveal then
        cache.pending = nil
      else
        refresh_output(cache.pending, model, now)
        adopt(cache, cache.pending)
        return cache
      end
    end
  end
  return scaled_preview(cache, radius, step, cols)
end

raster.MAX_COLUMNS = MAX_COLUMNS
raster.MAX_DRAW_CELLS = MAX_DRAW_CELLS
raster.REBUILD_POINTS_PER_FRAME = REBUILD_POINTS_PER_FRAME

return raster
