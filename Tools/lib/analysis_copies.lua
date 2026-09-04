-- analysis_copies: the short-lived bridge between a library sound and the pin
-- made from it.  A successful pin copy gives us two files that can share an
-- analysis result, but only while both records and both files remain the ones
-- we observed at copy time.
--
-- Links live in state.analysis_copies for this Lua session only.  Context
-- snapshots are kept here, rather than in state, so this feature can never add
-- data to library or project persistence.

local analysis   = require("core.analysis")
local reaper_api = require("reaper_api")

local copies = {}

-- One weak entry per state lets several tests (or future instances) use the
-- module without retaining an old state.  `links` is also tracked so a table
-- supplied from outside the module is treated as untrusted session data.
local contexts = setmetatable({}, { __mode = "k" })

local function pins_parts(state)
  local ps = state and state.pins
  return ps, ps and ps.dir, ps and ps.data
end

local function same_context(context, state)
  local ps, pins_dir, pins_data = pins_parts(state)
  return context.library == state.library
    and context.library_dir == state.library_dir
    and context.pins == ps
    and context.pins_dir == pins_dir
    and context.pins_data == pins_data
end

local function snapshot(state)
  local ps, pins_dir, pins_data = pins_parts(state)
  return {
    library = state.library,
    library_dir = state.library_dir,
    pins = ps,
    pins_dir = pins_dir,
    pins_data = pins_data,
  }
end

local function fresh_links(state, context)
  -- Replacing the list makes context invalidation O(1), which matters because
  -- sync runs once per scheduler update and deliberately performs no disk I/O.
  state.analysis_copies = {}
  context.links = state.analysis_copies
end

local function prepare(state)
  if type(state) ~= "table" then return nil end

  local context = contexts[state]
  if not context then
    context = snapshot(state)
    contexts[state] = context
    -- A state can have come from code that copied or restored a table.  Only
    -- links created through this module in this Lua session are trustworthy.
    fresh_links(state, context)
  elseif state.analysis_copies ~= context.links then
    -- Keep the session-only promise even if a caller replaces the list.
    fresh_links(state, context)
  elseif not same_context(context, state) then
    fresh_links(state, context)
    context = snapshot(state)
    context.links = state.analysis_copies
    contexts[state] = context
  end
  return context
end

local function valid_path(dir, filename)
  if type(dir) ~= "string" or type(filename) ~= "string" then return nil end
  return reaper_api.join(dir, filename)
end

local function remove_for_ids(links, sound_id, pin_id)
  for i = #links, 1, -1 do
    local link = links[i]
    if link.sound_id == sound_id or link.pin_id == pin_id then
      table.remove(links, i)
    end
  end
end

-- Record a copied pair after the caller has copied the audio and persisted the
-- pin. Returns true when a safe link was recorded, false when either record is
-- ineligible, either path is unavailable, or the two files do not have the
-- same non-nil size.
function copies.remember(state, sound, pin)
  local context = prepare(state)
  if not context or type(sound) ~= "table" or type(pin) ~= "table"
    or sound.id == nil or pin.id == nil
    or not analysis.needs(sound) or not analysis.pin_needs(pin) then
    return false
  end

  local sound_path = valid_path(state.library_dir, sound.filename)
  local pin_path = valid_path(state.pins and state.pins.dir, pin.filename)
  if not sound_path or not pin_path then return false end

  local sound_size = reaper_api.file_size(sound_path)
  local pin_size = reaper_api.file_size(pin_path)
  if sound_size == nil or pin_size == nil or sound_size ~= pin_size then
    -- A prior link for either identity cannot be trusted after this failed
    -- observation, even if the caller is retrying the copy operation.
    remove_for_ids(state.analysis_copies, sound.id, pin.id)
    return false
  end

  -- There is one current pin for a library sound.  Replacing an old link keeps
  -- repeated successful calls bounded and ensures an id is never paired twice.
  remove_for_ids(state.analysis_copies, sound.id, pin.id)
  state.analysis_copies[#state.analysis_copies + 1] = {
    sound_id = sound.id,
    pin_id = pin.id,
    -- The references make an id collision after a project/library reload
    -- unambiguously stale. They are session-only, just like the rest of link.
    sound_record = sound,
    pin_record = pin,
    sound_path = sound_path,
    pin_path = pin_path,
    size = sound_size,
  }
  return true
end

-- Drop links when their library/project context changes. Returns true when the
-- context changed (or an untrusted list was discarded), false when it was
-- already current. No file sizes or other disk state are read here.
function copies.sync(state)
  if type(state) ~= "table" then return false end
  local context = contexts[state]
  if not context then
    prepare(state)
    return true
  end
  if state.analysis_copies ~= context.links or not same_context(context, state) then
    prepare(state)
    return true
  end
  return false
end

local function current_path(path, record)
  if type(path) ~= "function" then return nil end
  return path(record)
end

-- Consume the link for a completed record. Returns its current counterpart only
-- when both records, paths, and files still match the captured pair and the
-- counterpart still needs analysis; otherwise returns nil. The matching link is
-- consumed on every attempted take so a failed or stale completion cannot be
-- retried against a changed file.
function copies.take_peer(state, record, find, path)
  local context = prepare(state)
  if not context or type(record) ~= "table" or type(find) ~= "function" then return nil end

  local links = state.analysis_copies
  local index, link, peer_id, record_path, peer_path
  for i = #links, 1, -1 do
    local candidate = links[i]
    if candidate.sound_id == record.id then
      index, link, peer_id = i, candidate, candidate.pin_id
      record_path, peer_path = candidate.sound_path, candidate.pin_path
      break
    elseif candidate.pin_id == record.id then
      index, link, peer_id = i, candidate, candidate.sound_id
      record_path, peer_path = candidate.pin_path, candidate.sound_path
      break
    end
  end
  if not link then return nil end
  table.remove(links, index)

  local ps = state.pins
  if not ps or ps.load_error then return nil end

  local current = find(record.id)
  local peer = find(peer_id)
  local expected_current = record.id == link.sound_id and link.sound_record or link.pin_record
  local expected_peer = record.id == link.sound_id and link.pin_record or link.sound_record
  if current ~= record or current ~= expected_current or peer ~= expected_peer then return nil end

  -- The invariant is deliberately about the exact captured paths and sizes.
  -- It assumes neither file is rewritten between remember and this call;
  -- matching sizes are an inexpensive guard, not proof that the contents match.
  if current_path(path, record) ~= record_path or current_path(path, peer) ~= peer_path then
    return nil
  end
  local current_size = reaper_api.file_size(record_path)
  local peer_size = reaper_api.file_size(peer_path)
  if current_size ~= link.size or peer_size ~= link.size then return nil end

  local peer_is_pin = peer_id == link.pin_id
  if peer_is_pin then
    if not analysis.pin_needs(peer) then return nil end
  elseif not analysis.needs(peer) then
    return nil
  end
  return peer
end

-- Forget every pair touched by a holder release or successful unpin. Returns
-- the number of links removed.
function copies.forget(state, matches)
  local context = prepare(state)
  if not context or type(matches) ~= "function" then return 0 end
  local removed = 0
  for i = #state.analysis_copies, 1, -1 do
    local link = state.analysis_copies[i]
    if matches(link.sound_id) or matches(link.pin_id) then
      table.remove(state.analysis_copies, i)
      removed = removed + 1
    end
  end
  return removed
end

return copies
