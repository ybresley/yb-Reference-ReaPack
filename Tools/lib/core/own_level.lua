-- own_level: the loudness of the user's own project audio (the Reaper
-- Measurement), and the lock that holds every pinned reference at the target
-- the user chose last.
--
-- Pure Lua. No reaper.*, no ImGui, no disk access. The two ways of measuring
-- (REAPER's dry run of the time selection, and listening through the live
-- meter) both land here as one record in the stored-measurement vocabulary of
-- core/analysis.lua, so core/match.lua's arithmetic applies unchanged: the
-- trim is the user's reading minus the reference's stored reading.

local analysis = require("core.analysis")
local match = require("core.match")

local own_level = {}

-- The readings a comparison can use, in the order the menu cycles them. Peak
-- readings are left out: matching peaks does not make two sounds equally loud.
own_level.UNITS = { "lufs_m_max", "lufs_s_max", "lufs_i" }
own_level.DEFAULT_UNIT = "lufs_m_max"

-- What Measure Item hears from a single item: "fx" is the item through its
-- take FX, track FX and fader, as REAPER renders it; "raw" is the source
-- audio the item plays, before anything in the project touches it.
own_level.ITEM_SOUNDS = { "fx", "raw" }
own_level.DEFAULT_ITEM_SOUND = "fx"

function own_level.is_item_sound(value)
  return value == "fx" or value == "raw"
end

local function is_real_number(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- REAPER reports silence as a very low floor rather than leaving the field
-- out. A reading that low is not a level anything can be matched to.
local SILENCE_FLOOR = -100

local function reading(v)
  v = tonumber(v)
  if not is_real_number(v) or v <= SILENCE_FLOOR then return nil end
  return v
end

-- `item_sound` is the remembered Measure Item choice; anything that is not
-- one falls back to the default.
function own_level.new(item_sound)
  return {
    measurement = nil,
    unit = own_level.DEFAULT_UNIT,
    lock = false,
    -- The target the user chose last, which is the level the lock plays every
    -- reference at:
    -- { kind = "own" } for the Reaper Measurement, or
    -- { kind = "fixed", unit = ..., value = ... } for a preset or custom target.
    target = nil,
    -- The target each sound was last normalized to this session, by sound id.
    -- Two targets can give the same trim, so the trim alone cannot say which
    -- one the user picked. A trim set by hand forgets the choice.
    chosen = {},
    listening = nil, -- nil | "waiting" | "measuring"
    item_sound = own_level.is_item_sound(item_sound) and item_sound or own_level.DEFAULT_ITEM_SOUND,
  }
end

function own_level.is_unit(unit)
  for _, u in ipairs(own_level.UNITS) do
    if u == unit then return true end
  end
  return false
end

-- REAPER's render statistics text for one dry run, for example
--   FILE:untitled;LENGTH:0:20.000;PEAK:-19.9;LUFSMMAX:-19.9;LUFSSMAX:-19.9;LUFSI:-20.0;LRA:0.0
-- A dry run of the master mix, one item or one track reports one file. If
-- more are ever listed, only the first is read. `method` names how the
-- reading was taken (default "selection"). Returns nil when no loudness
-- reading could be found.
function own_level.parse_render_stats(text, method)
  if type(text) ~= "string" or text == "" then return nil end
  local fields, files = {}, 0
  for entry in text:gmatch("[^;]+") do
    local key, value = entry:match("^%s*(%u+):(.*)$")
    if key == "FILE" then
      files = files + 1
      if files > 1 then break end
    elseif key and fields[key] == nil then
      fields[key] = value
    end
  end
  local result = {
    lufs_i = reading(fields.LUFSI),
    lufs_m_max = reading(fields.LUFSMMAX),
    lufs_s_max = reading(fields.LUFSSMAX),
    method = method or "selection",
  }
  if not (result.lufs_i or result.lufs_m_max or result.lufs_s_max) then return nil end
  return result
end

-- Readings measured from a file, as { lufs_i, lufs_m_max, lufs_s_max,
-- channels? }. A mono file is counted as heard from both speakers, like the
-- references it is compared with. Returns nil when none of them is a level.
function own_level.from_readings(values, method)
  if type(values) ~= "table" then return nil end
  local result = {
    lufs_i = reading(analysis.heard(values, "lufs_i")),
    lufs_m_max = reading(analysis.heard(values, "lufs_m_max")),
    lufs_s_max = reading(analysis.heard(values, "lufs_s_max")),
    method = method,
  }
  if not (result.lufs_i or result.lufs_m_max or result.lufs_s_max) then return nil end
  return result
end

-- Decide what Measure Item measures from the selected items. Each entry is
--   { track = <key>, ancestors = { <track key>, ... }, folder = <bool>,
--     start = <seconds>, finish = <seconds>, has_take = <bool> }
-- where `folder` says the item's track is a folder parent.
--
-- Returns one of:
--   { kind = "item", index = i }                       one item with a take
--   { kind = "folder", index = i, start = s, finish = f }
--     a folder item (with or without its children selected), measured as
--     the folder track's sum over the selection's whole span
-- or nil and a reason: "none", "no_audio" or "several".
--
-- A folder item is recognised by its place, not by any tool's markings: one
-- selected item on a folder track whose folder holds every other selected
-- item. That is how folder-item tools such as NVK's select a group.
function own_level.item_target(items)
  if type(items) ~= "table" or #items == 0 then return nil, "none" end
  if #items == 1 then
    local item = items[1]
    if item.has_take then return { kind = "item", index = 1 } end
    if item.folder then
      return { kind = "folder", index = 1, start = item.start, finish = item.finish }
    end
    return nil, "no_audio"
  end

  local function holds(track, other)
    for _, key in ipairs(other.ancestors or {}) do
      if key == track then return true end
    end
    return false
  end

  local parent
  for i, candidate in ipairs(items) do
    if candidate.folder then
      local all = true
      for j, other in ipairs(items) do
        if j ~= i and not holds(candidate.track, other) then all = false break end
      end
      if all then parent = i break end
    end
  end
  if not parent then return nil, "several" end

  local start, finish = math.huge, -math.huge
  for _, item in ipairs(items) do
    start = math.min(start, item.start)
    finish = math.max(finish, item.finish)
  end
  return { kind = "folder", index = parent, start = start, finish = finish }
end

-- What the live meter gathered over one listening pass: its run maxima and
-- its integrated reading. Returns nil when it heard nothing measurable.
function own_level.from_meter(model)
  if type(model) ~= "table" then return nil end
  local result = {
    lufs_i = reading(model.values and model.values.i),
    lufs_m_max = reading(model.m_max),
    lufs_s_max = reading(model.s_max),
    method = "playback",
  }
  if not (result.lufs_i or result.lufs_m_max or result.lufs_s_max) then return nil end
  return result
end

-- The trim that brings `pin` to the user's own level in `unit`. Same returns
-- as match.trim_for, plus (nil, "no_measurement") before anything is measured.
function own_level.trim_for(pin, measurement, unit)
  local target = measurement and measurement[unit]
  if not is_real_number(target) then return nil, "no_measurement" end
  return match.trim_for(pin, unit, target)
end

-- The trim that brings `pin` to the lock's target. Same returns as
-- match.trim_for, plus (nil, "no_target") before a target is chosen.
function own_level.target_trim(state, pin)
  local target = state and state.target
  if type(target) ~= "table" then return nil, "no_target" end
  if target.kind == "own" then
    return own_level.trim_for(pin, state.measurement, state.unit)
  end
  return match.trim_for(pin, target.unit, target.value)
end

-- Can a lock use this target right now? A Reaper Measurement
-- target needs a reading in the chosen unit; a fixed target always can.
function own_level.usable_target(state, target)
  if not state or type(target) ~= "table" then return false end
  if target.kind == "own" then
    return state.measurement ~= nil and is_real_number(state.measurement[state.unit])
  end
  return match.is_unit(target.unit) and is_real_number(target.value)
end

-- Does the lock hold this reference, a pin or a Library sound? Not without
-- a lock, a target, or a stored reading in the target's unit.
function own_level.holds_sound(state, sound)
  if not state or not state.lock or type(sound) ~= "table" then return false end
  return own_level.target_trim(state, sound) ~= nil
end

-- The level a reference plays at, in dB: the lock's trim while the lock holds
-- it, otherwise its own saved trim. The lock is temporary. It changes what is
-- heard and shown and never a saved trim, so unlocking returns every reference
-- to its own trim with nothing to restore. The second return is "range" when
-- the trim's limit kept a held reference short of the target.
function own_level.playing_trim(state, sound)
  if type(sound) ~= "table" then return 0 end
  if state and state.lock then
    local trim, limited = own_level.target_trim(state, sound)
    if trim then return trim, limited end
  end
  return sound.trim_db or 0
end

-- The target in words, for a tooltip: "-16 LUFS-M", or "Reaper Measurement".
-- nil without a target.
function own_level.target_label(target)
  if type(target) ~= "table" then return nil end
  if target.kind == "own" then return "Reaper Measurement" end
  if not match.is_unit(target.unit) or not is_real_number(target.value) then return nil end
  return string.format("%g %s", target.value, match.label(target.unit))
end

-- Is `target` (which may be nil) this one? `kind` is "own", or "fixed" with a
-- unit and value. Plain arguments, so the menu can ask every frame without
-- building a table per row.
function own_level.is_target(target, kind, unit, value)
  if type(target) ~= "table" or target.kind ~= kind then return false end
  return kind == "own" or (target.unit == unit and target.value == value)
end

-- The target this sound is set to: the lock's target while the lock holds it,
-- else the one the user last normalized it to this session. nil when neither.
-- `sound` is the reference's record, a pin or a Library sound.
function own_level.chosen_target(state, sound)
  if not state or type(sound) ~= "table" or sound.id == nil then return nil end
  if own_level.holds_sound(state, sound) then return state.target end
  return state.chosen and state.chosen[sound.id] or nil
end

return own_level
