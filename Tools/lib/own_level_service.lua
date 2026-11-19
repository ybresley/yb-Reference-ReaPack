-- Measures the user's own project audio and keeps the trims of a locked
-- target in force. core/own_level.lua owns the numbers; this module owns
-- the REAPER side: the dry run of the time selection, the listening pass
-- through the live meter, and storing locked trims in the project.
--
-- Nothing here adds a track, an effect or a send. The dry run is REAPER's own
-- read-only action, and listening reads the meter that is already running.

local own_level = require("core.own_level")
local match = require("core.match")
local status_message = require("core.status_message")
local reaper_api = require("reaper_api")
local metering = require("metering")
local pins_service = require("pins_service")
local loudness = require("loudness")

local service = {}

local SELECTION_PROBLEMS = {
  no_selection = "Make a time selection in your project first.",
  recording = "Stop recording before measuring.",
  failed = "Reaper couldn't measure the time selection.",
}

local function announce(state, measurement)
  local unit = state.own_level.unit
  local value = measurement[unit]
  if value then
    status_message.info(state, string.format("Reaper Measurement: %.1f %s.", value, match.label(unit)))
  else
    status_message.info(state, "Reaper Measurement updated.")
  end
end

-- Measure the master mix inside the time selection without playback. REAPER
-- processes the selection before this returns, so a long or heavy selection
-- holds the interface for that time.
function service.measure_selection(state)
  local ol = state.own_level
  ol.listening = nil
  local stats, reason = reaper_api.measure_time_selection()
  if not stats then
    status_message.problem(state, SELECTION_PROBLEMS[reason] or SELECTION_PROBLEMS.failed)
    return false
  end
  local measurement = own_level.parse_render_stats(stats)
  if not measurement then
    status_message.problem(state, "The time selection has no measurable audio.")
    return false
  end
  ol.measurement = measurement
  announce(state, measurement)
  return true
end

local ITEM_PROBLEMS = {
  none = "Select an item in your project first.",
  no_audio = "The selected item has no audio to measure.",
  several = "Select one item, or one folder item.",
  recording = "Stop recording before measuring.",
  failed = "Reaper couldn't measure the selected item.",
}

-- Measure the selected item, or a folder item's whole folder, without
-- playback. Like the time selection, REAPER does the work before this
-- returns. A folder is always measured through its effects: its sound only
-- exists as the folder track's sum.
function service.measure_item(state)
  local ol = state.own_level
  ol.listening = nil
  local items, handles = reaper_api.selected_items_for_measure()
  local target, reason = own_level.item_target(items)
  if not target then
    status_message.problem(state, ITEM_PROBLEMS[reason])
    return false
  end

  if reaper_api.recording_active() then
    status_message.problem(state, ITEM_PROBLEMS.recording)
    return false
  end

  local measurement
  local item = handles[target.index]
  if target.kind == "folder" then
    local stats = reaper_api.measure_folder(item, target.start, target.finish)
    if not stats then
      status_message.problem(state, ITEM_PROBLEMS.failed)
      return false
    end
    measurement = own_level.parse_render_stats(stats, "folder")
  elseif ol.item_sound == "raw" then
    local src, from, to = reaper_api.item_source_range(item)
    local readings = src and loudness.measure_range(src, from, to)
    if not readings then
      status_message.problem(state, ITEM_PROBLEMS.failed)
      return false
    end
    measurement = own_level.from_readings(readings, "item_raw")
  else
    local stats = reaper_api.measure_selected_item()
    if not stats then
      status_message.problem(state, ITEM_PROBLEMS.failed)
      return false
    end
    measurement = own_level.parse_render_stats(stats, "item")
  end

  if not measurement then
    status_message.problem(state, ITEM_PROBLEMS.no_audio)
    return false
  end
  ol.measurement = measurement
  announce(state, measurement)
  return true
end

function service.set_item_sound(state, value)
  if not own_level.is_item_sound(value) then return end
  state.own_level.item_sound = value
  reaper_api.set_item_sound(value)
end

-- Arm or cancel a listening pass. The pass itself runs in service.tick.
function service.toggle_listening(state)
  local ol = state.own_level
  if ol.listening then
    ol.listening = nil
    return
  end
  local model = state.metering
  if not model or not model.attached then
    status_message.problem(state, "The Loudness meter isn't running, so playback can't be measured.")
    return
  end
  ol.listening = "waiting"
end

-- Only the project's own playback counts: a playing reference, or Reference
-- mode holding the project silent, is not the user's sound.
local function hearing_project(state)
  local model = state.metering
  return model ~= nil and model.attached == true and model.playing == true
    and model.capture_mode == 0
    and not (state.preview and state.preview.playing)
    and not (state.reference and state.reference.latched)
end

local function tick_listening(state)
  local ol = state.own_level
  if not ol.listening then return end
  local hearing = hearing_project(state)
  if ol.listening == "waiting" then
    if hearing then
      -- A fresh run, so audio from before this pass is not part of the reading.
      if metering.reset(state) then
        ol.listening = "measuring"
      else
        ol.listening = nil
        status_message.problem(state, "The Loudness meter couldn't start a new measurement.")
      end
    end
  elseif not hearing then
    ol.listening = nil
    -- Only a plain stop of the project ends a pass with a reading. Once a
    -- reference plays, Reference mode starts or the meter goes away, the
    -- shared meter may already hold audio that is not the project's.
    local model = state.metering
    if not (model and model.attached) or (state.preview and state.preview.playing)
        or (state.reference and state.reference.latched) then
      status_message.problem(state,
        "The measurement was interrupted. Play your project and measure again.")
      return
    end
    local measurement = own_level.from_meter(model)
    if measurement then
      ol.measurement = measurement
      announce(state, measurement)
    else
      status_message.problem(state, "Playback stopped before anything could be measured.")
    end
  end
end

-- Write the trims the lock still owes, as one stored project change with a
-- way back. Returns whether the selected reference's trim changed.
local function tick_lock(state)
  local ol = state.own_level
  if not ol.lock then return false end
  local list = state.pins and state.pins.data and state.pins.data.pins
  local pending = own_level.pending_lock_trims(ol, list)
  if #pending == 0 then return false end
  local ok, reason = pins_service.edit(state, function()
    local before = {}
    for i, entry in ipairs(pending) do
      before[i] = entry.pin.trim_db
      entry.pin.trim_db = entry.trim
    end
    return function()
      for i, entry in ipairs(pending) do entry.pin.trim_db = before[i] end
    end
  end)
  if not ok then
    -- A refused store would be retried on every update; stop instead and say so.
    ol.lock = false
    status_message.problem(state, reason
      or "The pinned references' trims couldn't be saved in your project. The lock was turned off.")
    return false
  end
  local selected = state.selected
  if not selected then return false end
  for _, entry in ipairs(pending) do
    if entry.pin == selected then return true end
    if entry.pin.id == selected.id then
      selected.trim_db = entry.trim
      return true
    end
  end
  return false
end

-- One update. Returns true when the selected reference's trim changed, so the
-- caller can make the audible level follow.
function service.tick(state)
  local ol = state.own_level
  if not ol then return false end
  -- A measurement and its lock belong to the project they were made in. In
  -- another project they would rewrite that project's pin trims to a level
  -- measured somewhere else.
  local ps = state.pins
  -- pins_service gives every loaded pin set a new session number: another
  -- project, or the same one reloaded (an undo included), whose pin ids start
  -- again. Save As keeps the number, so it keeps the measurement too.
  local project_key = ps and ps.session or nil
  if ol.project_key ~= nil and ol.project_key ~= project_key then
    ol.measurement, ol.lock, ol.listening, ol.released = nil, false, nil, {}
    if ol.target and ol.target.kind == "own" then ol.target = nil end
  end
  ol.project_key = project_key
  tick_listening(state)
  return tick_lock(state)
end

-- Lock every pinned reference to `target`, or unlock. A target that cannot
-- give a trim (nothing measured, no usable number) leaves the lock as it was.
function service.set_lock(state, on, target)
  local ol = state.own_level
  if on == true then
    if not own_level.usable_target(ol, target) then
      status_message.problem(state, "Choose a target first.")
      return
    end
    ol.target = target
  end
  ol.lock = on == true
  ol.released = {}
end

-- The user normalized the selected reference to a target. That target is what
-- the lock holds from now on, and the selected pin is part of the lock again.
function service.choose_target(state, target, pin_id)
  local ol = state.own_level
  ol.target = target
  if pin_id then ol.released[pin_id] = nil end
end

function service.set_unit(state, unit)
  if own_level.is_unit(unit) then state.own_level.unit = unit end
end

-- The user moved a locked pin's trim by hand: it keeps that trim.
function service.release(state, pin_id)
  local ol = state.own_level
  if ol.lock and pin_id then ol.released[pin_id] = true end
end

return service
