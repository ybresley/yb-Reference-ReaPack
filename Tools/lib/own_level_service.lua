-- Measures the user's own project audio and keeps the lock's target. The
-- lock is temporary: it sets the level a reference plays at and never writes
-- a trim. core/own_level.lua owns the numbers; this module owns the REAPER
-- side: the dry run of the time selection and the listening pass through the
-- live meter.
--
-- Nothing here adds a track, an effect or a send. The dry run is REAPER's own
-- read-only action, and listening reads the meter that is already running.

local own_level = require("core.own_level")
local match = require("core.match")
local status_message = require("core.status_message")
local reaper_api = require("reaper_api")
local metering = require("metering")
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

-- One update. Returns true when the level the selected reference plays at
-- changed while it stayed selected (the lock went on or off, its target moved,
-- or a measurement arrived), so the caller can make the audible level follow.
-- A newly selected reference starts at its level without this.
function service.tick(state)
  local ol = state.own_level
  if not ol then return false end
  -- A measurement and its lock belong to the project they were made in. In
  -- another project they would play that project's references at a level
  -- measured somewhere else.
  local ps = state.pins
  -- pins_service gives every loaded pin set a new session number: another
  -- project, or the same one reloaded (an undo included), whose pin ids start
  -- again. Save As keeps the number, so it keeps the measurement too.
  local project_key = ps and ps.session or nil
  if ol.project_key ~= nil and ol.project_key ~= project_key then
    ol.measurement, ol.lock, ol.listening = nil, false, nil
    -- Pin ids start again in the new pin set, so an old choice could name
    -- another project's pin.
    ol.chosen = {}
    if ol.target and ol.target.kind == "own" then ol.target = nil end
  end
  ol.project_key = project_key
  tick_listening(state)
  local selected = state.selected
  local id = selected and selected.id or nil
  local level = selected and own_level.playing_trim(ol, selected) or nil
  local changed = level ~= nil and ol.playing_id == id and ol.playing_level ~= level
  ol.playing_id, ol.playing_level = id, level
  return changed
end

-- Lock every reference to `target`, or unlock. While the lock is on, each
-- reference with a stored reading in the target's unit plays at the target's
-- level (own_level.playing_trim). A target that cannot
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
end

-- The user normalized the selected reference to a target. That target is
-- the one the lock uses from now on. `sound_id` is the selected reference's
-- id, a pin or a Library sound, and remembers which target it was set to.
function service.choose_target(state, target, sound_id)
  local ol = state.own_level
  ol.target = target
  if sound_id then ol.chosen[sound_id] = target end
end

-- The user set this sound's trim by hand, so no target names it any more.
function service.forget_choice(state, sound_id)
  if sound_id then state.own_level.chosen[sound_id] = nil end
end

-- Pinning or unpinning hands a reference to a new id with the same trim, so
-- the target it was set to stays lit.
function service.carry_choice(state, from_id, to_id)
  local chosen = state.own_level.chosen
  if from_id and to_id and chosen[from_id] then chosen[to_id] = chosen[from_id] end
end

-- Another Library folder numbers its sounds from s1 again, so a choice kept
-- for an old Library id would name a different sound. `matches` picks the ids
-- to drop.
function service.forget_choices(state, matches)
  local chosen = state.own_level.chosen
  for id in pairs(chosen) do
    if matches(id) then chosen[id] = nil end
  end
end

-- May this trim edit go ahead? While the lock is on, the lock sets the level
-- and a trim moved by hand would sit apart from it unnoticed, so only
-- normalizing to a target (`from_target`) still saves a trim. Every control
-- that edits the trim shows this state itself; this is the last line.
function service.accepts_trim(state, from_target)
  local ol = state.own_level
  return from_target == true or not (ol and ol.lock)
end

function service.set_unit(state, unit)
  if own_level.is_unit(unit) then state.own_level.unit = unit end
end

return service
