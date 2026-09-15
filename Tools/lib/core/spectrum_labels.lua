-- Stable lifecycle and motion for the spectrum's bounded peak labels.
local labels = {}
local curve = require("core.spectrum_curve")

local CONFIRM_SECONDS = 0.30
local GRACE_SECONDS = 0.20
local FADE_IN_SECONDS = 0.15
local FADE_OUT_SECONDS = 0.30
local MOTION_SECONDS = 0.06
local MAX_RENDER_GAP = 0.5
local MAX_PEAKS = 5
local MAX_TRACKS = 10

local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function clear_list(list)
  for index = #list, 1, -1 do list[index] = nil end
end

function labels.new()
  return { items = {}, _next_id = 0, _incoming = {}, _placeable = {}, _used = {} }
end

function labels.reset(state)
  state.items = state.items or {}
  clear_list(state.items)
  state.last_now = nil
  return state
end

local function empty_track(item)
  item._occupied = false
  item._confirmed = false
  item._pending_started = nil
  item._last_seen = nil
  item._fade_started = nil
  item._fade_from = nil
  item._fade_in_started = nil
  item._fade_in_from = nil
  item._was_missing = false
  item.index = nil
  item.target_index = nil
  item.opacity = 0
  item.matched = false
  item.ready = false
end

local function begin_track(state, item, peak_index, now)
  state._next_id = (state._next_id or 0) + 1
  item.id = state._next_id
  item._occupied = true
  item._associated = true
  item._confirmed = false
  item._pending_started = now
  item._last_seen = now
  item._fade_started = nil
  item._fade_from = nil
  item._fade_in_started = nil
  item._fade_in_from = nil
  item._was_missing = false
  item.index = peak_index
  item.target_index = peak_index
  item.opacity = 0
  item.matched = true
  item.ready = false
end

local function choose_slot(state)
  for _, item in ipairs(state.items) do
    if not item._occupied then return item end
  end
  if #state.items < MAX_TRACKS then
    local item = {}
    state.items[#state.items + 1] = item
    return item
  end
  -- Reusing a visible entry would cut its fade short. Wait if all are busy.
  for _, item in ipairs(state.items) do
    if not item._associated and item.opacity <= 0 then return item end
  end
  return nil
end

local function collect_peaks(state, peaks)
  local incoming, placeable = state._incoming, state._placeable
  local count = 0
  if type(peaks) ~= "table" then return 0 end
  for index = 1, math.min(#peaks, MAX_PEAKS) do
    local peak = peaks[index]
    local peak_index = type(peak) == "table" and peak.index or nil
    if finite(peak_index) then
      count = count + 1
      incoming[count] = peak_index
      placeable[count] = peak.placeable ~= false
    end
  end
  for index = count + 1, #incoming do
    incoming[index], placeable[index] = nil, nil
  end
  return count
end

local function associate(state, incoming_count, distance, outline, count)
  local incoming, used = state._incoming, state._used
  for peak = 1, incoming_count do used[peak] = false end
  for _ = 1, incoming_count do
    local best_peak, best_item, best_distance
    for peak = 1, incoming_count do
      if not used[peak] then
        for _, item in ipairs(state.items) do
          if item._occupied and not item._associated and finite(item.target_index) then
            local separation = math.abs(incoming[peak] - item.target_index)
            if separation <= distance
                and curve.same_crest(outline, count, item.target_index, incoming[peak])
                and curve.same_crest(outline, count, item.index, incoming[peak])
                and (not best_distance or separation < best_distance) then
              best_peak, best_item, best_distance = peak, item, separation
            end
          end
        end
      end
    end
    if not best_item then break end
    best_item._associated = true
    best_item.matched = state._placeable[best_peak]
    best_item.target_index = incoming[best_peak]
    if best_item.matched then
      best_item._last_seen = state.last_now
      best_item._fade_started = nil
      best_item._fade_from = nil
    end
    used[best_peak] = true
  end
end

local function advance_matched(item, now, dt, outline, count, width)
  if not item._confirmed then
    if now - item._pending_started >= CONFIRM_SECONDS then
      item._confirmed = true
      item.ready = true
      item._fade_in_started = item._pending_started + CONFIRM_SECONDS
      item._fade_in_from = 0
    end
  end

  if item._confirmed then
    item.ready = true
    if item._was_missing then
      item._fade_in_started = now
      item._fade_in_from = item.opacity
    end
    local progress = math.max(0, now - item._fade_in_started) / FADE_IN_SECONDS
    item.opacity = math.min(1,
      item._fade_in_from + (1 - item._fade_in_from) * progress)
  end

  if dt > 0 and item.index ~= item.target_index then
    local amount = 1 - math.exp(-dt / MOTION_SECONDS)
    local proposed = item.index + (item.target_index - item.index) * amount
    local from_height = curve.sample_drawn(outline, count, item.index, width)
    local proposed_height = curve.sample_drawn(outline, count, proposed, width)
    local target_height = curve.sample_drawn(outline, count, item.target_index, width)
    if proposed_height < target_height - 0.5
        or proposed_height < from_height - 0.15 then
      item.index = item.target_index
    else
      item.index = proposed
    end
  end
  item._was_missing = false
end

local function advance_missing(item, now, active, retained)
  if not item._confirmed then
    empty_track(item)
    return
  end

  item._was_missing = true
  item.ready = true
  local fade_at = active and item._last_seen + GRACE_SECONDS or now
  if not item._fade_started then
    if active and now <= fade_at then return end
    item._fade_started = fade_at
    item._fade_from = item.opacity
  end
  local progress = math.max(0, now - item._fade_started) / FADE_OUT_SECONDS
  item.opacity = item._fade_from * math.max(0, 1 - progress)
  -- A blocked label can become invisible without forgetting a crest that is
  -- still selected. It can fade back in as soon as there is room again.
  if item.opacity <= 0 and not retained then empty_track(item) end
end

function labels.update(state, peaks, now, active, association_distance, outline, count, width)
  state.items = state.items or {}
  state._next_id = state._next_id or 0
  state._incoming = state._incoming or {}
  state._placeable = state._placeable or {}
  state._used = state._used or {}
  if not finite(now) then return labels.reset(state) end
  if state.last_now ~= nil
      and (now < state.last_now or now - state.last_now > MAX_RENDER_GAP) then
    labels.reset(state)
  end
  local dt = state.last_now and now - state.last_now or 0
  state.last_now = now

  for _, item in ipairs(state.items) do
    item.matched = false
    item._associated = false
  end
  if active == true then
    local incoming_count = collect_peaks(state, peaks)
    local distance = finite(association_distance)
      and math.max(0, association_distance) or 0
    associate(state, incoming_count, distance, outline, count)
    for peak = 1, incoming_count do
      if not state._used[peak] and state._placeable[peak] then
        local item = choose_slot(state)
        if item then begin_track(state, item, state._incoming[peak], now) end
      end
    end
  end

  for _, item in ipairs(state.items) do
    if item._occupied then
      if item.matched then
        advance_matched(item, now, dt, outline, count, width)
      else
        advance_missing(item, now, active == true,
          active == true and item._associated)
      end
    end
  end
  return state
end

return labels
