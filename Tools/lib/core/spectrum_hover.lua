-- Delayed spectrum capture and its bounded peak markers.
-- The caller supplies already tilted display values, so this module stays
-- independent of the analyser and the interface scale.
local curve_shape = require('core.spectrum_curve')
local mathx = require('core.spectrum_math')
local hover = {}

local DWELL_SECONDS = 1.2
local ANCHOR_RADIUS = 5
local HOVER_SPEED_PIXELS_PER_SECOND = 120
local FADE_SECONDS = 0.18
local MAX_RENDER_GAP = 0.5
local PEAK_INTERVAL = 0.12
local MAX_PEAKS = 5
local MIN_SIGNAL_DB = -100
local PEAK_PROMINENCE_DB = 1
local RETAIN_PROMINENCE_DB = 0.5
local PEAK_LABEL_PIXELS = 72
local DISTINCT_PEAK_PIXELS = 48
local INCUMBENT_BONUS_DB = 6
local DOMINANCE_TOLERANCE_DB = 0.5
local CREST_VALLEY_DB = 1
local BASS_MIN_HZ, BASS_MAX_HZ = 20, 200

local LN2 = math.log(2)

local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function clear_list(list)
  for index = #list, 1, -1 do list[index] = nil end
end

local function clear_capture(state)
  -- Display remnants may outlive a normal fade, but never a discarded capture.
  state.generation = (state.generation or 0) + 1
  state.active = false
  state.pending = false
  state.opacity = 0
  state.count = 0
  clear_list(state.peaks)
  state.anchor_x, state.anchor_y, state.dwell_started = nil, nil, nil
  state.next_peak_at = nil
end

function hover.new()
  return {
    generation = 0,
    active = false,
    pending = false,
    opacity = 0,
    values = {},
    outline = {},
    count = 0,
    peaks = {},
    candidate_index = {},
    candidate_db = {},
    candidate_score = {},
    candidate_used = {},
    selected = {},
    selected_used = {},
    previous_index = {},
    ordered = {},
    identity_ready = false,
  }
end

function hover.reset(state)
  clear_capture(state)
  state.identity_ready = false
  state.last_now = nil
  state.source_key, state.epoch = nil, nil
  state.fmin, state.fmax, state.tilt, state.width = nil, nil, nil, nil
  state.mode = nil
  return state
end

function hover.highlight_amount(state)
  if state.pending then
    local started, now = state.dwell_started, state.last_now
    if finite(started) and finite(now) then
      local progress = math.min(1, math.max(0, (now - started) / DWELL_SECONDS))
      return progress * progress
    end
    return 0
  end
  if state.active then return 1 - state.opacity end
  return 0
end

local function valid_input(input, mode)
  if type(input) ~= "table" or not finite(input.now)
      or type(input.eligible) ~= "boolean"
      or not finite(input.count) or input.count < 1 or input.count > 512
      or input.count % 1 ~= 0 or type(input.values) ~= "table"
      or not finite(input.fmin) or input.fmin <= 0
      or not finite(input.fmax) or input.fmax <= input.fmin
      or not finite(input.tilt) or not finite(input.width) or input.width <= 0
      or (mode ~= "hold" and mode ~= "off") then
    return false
  end
  if input.eligible and (not finite(input.x) or not finite(input.y)) then return false end
  for index = 1, input.count do
    if not finite(input.values[index]) then return false end
  end
  return true
end

local function identity_changed(state, input, mode)
  return state.identity_ready and (
    state.source_key ~= input.source_key or state.epoch ~= input.epoch
    or state.count_identity ~= input.count
    or state.fmin ~= input.fmin or state.fmax ~= input.fmax
    or state.tilt ~= input.tilt or state.width ~= input.width
    or state.mode ~= mode)
end

local function remember_identity(state, input, mode)
  state.identity_ready = true
  state.source_key, state.epoch = input.source_key, input.epoch
  state.count_identity = input.count
  state.fmin, state.fmax = input.fmin, input.fmax
  state.tilt, state.width, state.mode = input.tilt, input.width, mode
end

local function strongest_value(values, count)
  local strongest = -math.huge
  for index = 1, count do strongest = math.max(strongest, values[index]) end
  return strongest
end

local function copy_values(state, input)
  for index = 1, input.count do
    state.values[index] = input.values[index]
  end
  state.count = input.count
end

local function update_values(state, input)
  for index = 1, input.count do
    -- Upward capture must be immediate or the live line can cross the hold.
    state.values[index] = math.max(state.values[index], input.values[index])
  end
end

local function smooth_values(state)
  curve_shape.smooth_outline(state.values, state.count, state.outline)
end

local function label_separation(count, bins_per_octave, width)
  local pixel_separation = count > 1
    and PEAK_LABEL_PIXELS * (count - 1) / width or count
  return math.max(bins_per_octave / 12, pixel_separation)
end

local function collect_candidates(state)
  local smooth, count = state.outline, state.count
  local octave_span = math.log(state.fmax / state.fmin) / LN2
  local bins_per_octave = count > 1 and (count - 1) / octave_span or 1
  local radius = math.max(2,
    label_separation(count, bins_per_octave, state.width))
  local candidate_count = 0
  local association = hover.label_association_distance(
    count, state.fmin, state.fmax, state.width)

  local index = 2
  while index <= count - 1 do
    local centre = smooth[index]
    local plateau_end = index
    while plateau_end < count and smooth[plateau_end + 1] == centre do
      plateau_end = plateau_end + 1
    end
    if centre > smooth[index - 1] and plateau_end < count
        and centre > smooth[plateau_end + 1] then
      local left_min, right_min = centre, centre
      for neighbour = math.max(1, math.ceil(index - radius)), index - 1 do
        left_min = math.min(left_min, smooth[neighbour])
      end
      for neighbour = plateau_end + 1,
          math.min(count, math.floor(plateau_end + radius)) do
        right_min = math.min(right_min, smooth[neighbour])
      end
      local prominence = centre - math.max(left_min, right_min)
      if prominence >= RETAIN_PROMINENCE_DB then
        local position = (index + plateau_end) * 0.5
        local db = curve_shape.sample_drawn(smooth, count, position, state.width)
        local qualifies = prominence >= PEAK_PROMINENCE_DB and db >= MIN_SIGNAL_DB
        -- Judge a new crest against its own surroundings, not louder distant
        -- regions. Retained tags tolerate a shallower crest to avoid flicker.
        if not qualifies and db >= MIN_SIGNAL_DB then
          for old = 1, state.previous_count do
            local previous = state.previous_index[old]
            if math.abs(position - previous) <= association
                and curve_shape.same_crest(smooth, count, previous, position) then
              qualifies = true
              break
            end
          end
        end
        if qualifies then
          candidate_count = candidate_count + 1
          state.candidate_index[candidate_count] = position
          state.candidate_db[candidate_count] = db
        end
      end
    end
    index = plateau_end + 1
  end
  return candidate_count, bins_per_octave
end

function hover.label_association_distance(count, fmin, fmax, width)
  local bins_per_octave = (count - 1) / (math.log(fmax / fmin) / LN2)
  return math.max(2, bins_per_octave / 12, PEAK_LABEL_PIXELS * 0.5 * (count - 1) / width)
end

local function higher_on_crest(state, candidate, direction, reach)
  local position = state.candidate_index[candidate]
  local level = state.candidate_db[candidate]
  local edge = math.max(1, math.min(state.count, position + direction * reach))
  local first = direction > 0 and math.floor(position) + 1 or math.ceil(position) - 1
  local last = direction > 0 and math.floor(edge) or math.ceil(edge)
  for neighbour = first, last, direction do
    local db = state.outline[neighbour]
    -- A meaningful dip separates peaks even when their labels compete for space.
    if db <= level - CREST_VALLEY_DB then return false end
    if db > level + DOMINANCE_TOLERANCE_DB then return true end
  end
  return curve_shape.sample_drawn(state.outline, state.count, edge, state.width)
    > level + DOMINANCE_TOLERANCE_DB
end

local function labels_compete(state, first, second, separation, distinct_separation)
  local a, b = state.candidate_index[first], state.candidate_index[second]
  local distance = math.abs(a - b)
  if distance >= separation then return false end
  if distance < distinct_separation then return true end
  local valley = math.min(state.candidate_db[first], state.candidate_db[second]) - CREST_VALLEY_DB
  for index = math.ceil(math.min(a, b)), math.floor(math.max(a, b)) do
    if state.outline[index] <= valley then return false end
  end
  return true
end

local function candidate_fits(state, candidate, selected_count, separation, distinct_separation)
  if state.candidate_used[candidate] then return false end
  for slot = 1, selected_count do
    if labels_compete(state, candidate, state.selected[slot], separation, distinct_separation) then
      return false
    end
  end
  return true
end

local function is_bass_candidate(state, candidate)
  local hz = mathx.bin_frequency(state.candidate_index[candidate], state.count,
    state.fmin, state.fmax)
  return hz >= BASS_MIN_HZ and hz <= BASS_MAX_HZ
end

local function higher_competitor(state, best, candidate_count, selected_count,
    separation, distinct_separation, bass_only)
  -- Resolve competition only against peaks that can still be shown. Bass
  -- protection limits its replacement to another summit in the bass band.
  while true do
    local higher
    for candidate = 1, candidate_count do
      if candidate_fits(state, candidate, selected_count, separation, distinct_separation)
          and (not bass_only or is_bass_candidate(state, candidate))
          and labels_compete(state, candidate, best, separation, distinct_separation)
          and state.candidate_db[candidate] > state.candidate_db[best] + DOMINANCE_TOLERANCE_DB
          and (not higher or state.candidate_db[candidate] > state.candidate_db[higher]) then
        higher = candidate
      end
    end
    if not higher then return best end
    best = higher
  end
end

local function choose_candidates(state, candidate_count, bins_per_octave)
  local count = state.count
  local separation = label_separation(count, bins_per_octave, state.width)
  local distinct_separation = math.max(bins_per_octave / 12,
    DISTINCT_PEAK_PIXELS * (count - 1) / state.width)
  local association_distance = hover.label_association_distance(
    count, state.fmin, state.fmax, state.width)
  for index = 1, candidate_count do
    state.candidate_used[index] = higher_on_crest(state, index, -1, separation)
      or higher_on_crest(state, index, 1, separation)
    state.candidate_score[index] = state.candidate_db[index]
  end
  -- Nearby dominance is settled first. The bonus only steadies nearly equal summits.
  for old = 1, state.previous_count do
    local nearest, nearest_distance
    for candidate = 1, candidate_count do
      local distance = math.abs(state.candidate_index[candidate] - state.previous_index[old])
      if distance <= association_distance
          and curve_shape.same_crest(state.outline, count,
            state.previous_index[old], state.candidate_index[candidate])
          and (not nearest_distance or distance < nearest_distance) then
        nearest, nearest_distance = candidate, distance
      end
    end
    if nearest then
      state.candidate_score[nearest] = state.candidate_db[nearest] + INCUMBENT_BONUS_DB
    end
  end
  local selected_count = 0

  -- Keep one useful bass summit represented when louder distant peaks would
  -- otherwise take every slot. Qualification and nearby dominance still apply.
  local bass
  for candidate = 1, candidate_count do
    if not state.candidate_used[candidate] then
      if is_bass_candidate(state, candidate)
          and (not bass or state.candidate_score[candidate] > state.candidate_score[bass]) then
        bass = candidate
      end
    end
  end
  if bass then
    bass = higher_competitor(state, bass, candidate_count, selected_count,
      separation, distinct_separation, true)
    selected_count = 1
    state.selected[1] = bass
    state.candidate_used[bass] = true
  end

  while selected_count < MAX_PEAKS do
    local best
    for candidate = 1, candidate_count do
      if candidate_fits(state, candidate, selected_count, separation, distinct_separation) then
        local score = state.candidate_score[candidate]
        local best_score = best and state.candidate_score[best] or -math.huge
        if score > best_score then best = candidate end
      end
    end
    if not best then break end
    best = higher_competitor(state, best, candidate_count, selected_count,
      separation, distinct_separation, false)
    selected_count = selected_count + 1
    state.selected[selected_count] = best
    state.candidate_used[best] = true
  end
  return selected_count, association_distance
end

local function keep_stable_order(state, selected_count, association_distance)
  local old_count = #state.peaks
  for index = 1, selected_count do state.selected_used[index] = false end
  local ordered_count = 0

  for old = 1, old_count do
    local best_slot, best_distance
    for slot = 1, selected_count do
      if not state.selected_used[slot] then
        local candidate = state.selected[slot]
        local distance = math.abs(state.candidate_index[candidate]
          - state.previous_index[old])
        if distance <= association_distance
            and curve_shape.same_crest(state.outline, state.count,
              state.previous_index[old], state.candidate_index[candidate])
            and (not best_distance or distance < best_distance) then
          best_slot, best_distance = slot, distance
        end
      end
    end
    if best_slot then
      ordered_count = ordered_count + 1
      state.ordered[ordered_count] = state.selected[best_slot]
      state.selected_used[best_slot] = true
    end
  end
  for slot = 1, selected_count do
    if not state.selected_used[slot] then
      ordered_count = ordered_count + 1
      state.ordered[ordered_count] = state.selected[slot]
    end
  end

  for slot = 1, ordered_count do
    local peak = state.peaks[slot]
    if not peak then peak = {}; state.peaks[slot] = peak end
    peak.index = state.candidate_index[state.ordered[slot]]
    peak.db = curve_shape.sample_drawn(state.outline, state.count, peak.index, state.width)
  end
  for slot = #state.peaks, ordered_count + 1, -1 do state.peaks[slot] = nil end
end

local function detect_peaks(state)
  if state.count < 3 then clear_list(state.peaks); return end
  state.previous_count = #state.peaks
  for index = 1, state.previous_count do
    state.previous_index[index] = state.peaks[index].index
  end
  local candidate_count, bins_per_octave = collect_candidates(state)
  local selected_count, association_distance = choose_candidates(
    state, candidate_count, bins_per_octave)
  keep_stable_order(state, selected_count, association_distance)
end

local function update_peak_levels(state)
  for index = 1, #state.peaks do
    local peak = state.peaks[index]
    peak.db = curve_shape.sample_drawn(state.outline, state.count, peak.index, state.width)
  end
end

local function fade_capture(state, input, dt)
  state.opacity = math.max(0, state.opacity - math.max(0, dt) / FADE_SECONDS)
  if state.opacity == 0 then
    state.count = 0
    clear_list(state.peaks)
  elseif state.count > 0 then
    -- A still-visible outline must cover fresh peaks during its exit fade too.
    update_values(state, input)
    smooth_values(state)
    update_peak_levels(state)
  end
end

function hover.update(state, input)
  state.pending = false
  local mode = type(input) == "table" and (input.mode or "hold") or "hold"
  if not valid_input(input, mode) then return hover.reset(state) end

  local now = input.now
  local time_broken = state.last_now ~= nil
    and (now < state.last_now or now - state.last_now > MAX_RENDER_GAP)
  if time_broken or identity_changed(state, input, mode) then
    hover.reset(state)
  end
  remember_identity(state, input, mode)
  local dt = state.last_now and now - state.last_now or 0
  state.last_now = now

  if mode == "off" or strongest_value(input.values, input.count) <= MIN_SIGNAL_DB then
    clear_capture(state)
    return state
  end

  if not input.eligible then
    state.anchor_x, state.anchor_y, state.dwell_started = nil, nil, nil
    if state.active then state.active = false end
    fade_capture(state, input, dt)
    return state
  end

  if not state.active then
    state.pending = true
    if not state.anchor_x then
      state.anchor_x, state.anchor_y = input.x, input.y
      state.dwell_started = now
    else
      local dx, dy = input.x - state.anchor_x, input.y - state.anchor_y
      local distance = math.sqrt(dx * dx + dy * dy)
      local travel = HOVER_SPEED_PIXELS_PER_SECOND * math.max(0, dt)
      -- Let the anchor follow a slow scan, with a little slack for hand jitter.
      -- Sustained faster travel outruns it and restarts the waiting period.
      if distance > travel + ANCHOR_RADIUS then
        state.anchor_x, state.anchor_y = input.x, input.y
        state.dwell_started = now
      elseif distance <= travel then
        state.anchor_x, state.anchor_y = input.x, input.y
      elseif distance > 0 then
        state.anchor_x = state.anchor_x + dx * travel / distance
        state.anchor_y = state.anchor_y + dy * travel / distance
      end
    end
    if now - state.dwell_started >= DWELL_SECONDS then
      state.active = true
      state.pending = false
      copy_values(state, input)
      smooth_values(state)
      detect_peaks(state)
      state.next_peak_at = now + PEAK_INTERVAL
    else
      fade_capture(state, input, dt)
    end
    return state
  end

  state.opacity = math.min(1, state.opacity + math.max(0, dt) / FADE_SECONDS)
  update_values(state, input)
  smooth_values(state)
  if not state.next_peak_at or now >= state.next_peak_at then
    detect_peaks(state)
    state.next_peak_at = now + PEAK_INTERVAL
  else
    update_peak_levels(state)
  end
  return state
end

return hover
