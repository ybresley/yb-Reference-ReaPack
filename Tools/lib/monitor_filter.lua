-- Owns the one yb-Reference JSFX instance in Reaper's global Monitoring FX
-- chain. Callers supply desired settings; this module owns discovery, identity,
-- health checks, the expiring controller lease, repair and clean shutdown.

local monitor_filter = {}

local R = reaper
local MONITOR_FX = 0x1000000
local FX_QUERY = "JS: yb-Reference Monitoring Filter"
local FX_ORIGINAL_NAME = "yb-Reference Monitoring Filter"
local FX_NAMES = {
  ["JS: yb-Reference Monitoring Filter"] = true,
  ["yb-Reference Monitoring Filter"] = true,
}
local EXT_SECTION = "yb-Reference"
local EXT_GUID = "monitor_filter_guid"
local EXT_SETTINGS = "monitor_filter_settings"

local PARAM = {
  protocol = 0,
  active = 1,
  mode = 2,
  low_hz = 3,
  high_hz = 4,
  slope = 5,
  heartbeat = 6,
}
local GMEM_NAME = "yb_reference_monitor_filter_v1"
local CONTROL = {
  protocol = 0,
  active = 1,
  mode = 2,
  low_hz = 3,
  high_hz = 4,
  slope = 5,
  heartbeat = 6,
  ack = 7,
  engaged = 8,
  revision = 9,
  response_sequence = 10,
}
local PROTOCOL = 6
local SPECTRUM = {
  fft_size = 16, smoothing = 17, epoch = 18, capture_state = 19, revision = 20,
  average_seconds = 21, history_epoch = 23,
  idle_seconds = 24, session = 25,
  magic = 32, protocol = 33, sequence = 34, sample_rate = 35, count = 36,
  peak = 38, frame_epoch = 39, fmin = 40, fmax = 41, frame_fft = 42,
  hop = 43, active = 44, frame_smoothing = 45, frame_revision = 46,
  current_sample_rate = 47, final = 48, average_ready = 49,
  history_samples = 51, frame_session = 52, data = 64, average_data = 576,
}
local SPECTRUM_MAGIC = 260826.1
local SPECTRUM_TIMEOUT = 1.0
local LEASE_INTERVAL = 0.20
local HEALTH_INTERVAL = 1.0
local ENGAGE_TIMEOUT = 0.75
local STABLE_SNAPSHOTS = 3
local MAX_SETTLE_FRAMES = 180

local S = {
  phase = "idle",
  message = "Setting up the Monitoring Filter…",
  frame = 0,
  stable_count = 0,
  last_signature = nil,
  stored_guid = nil,
  bound_guid = nil,
  slot = nil,
  next_lease = 0,
  next_health = 0,
  heartbeat = 0,
  control_revision = 0,
  response_sequence = nil,
  response_ack = nil,
  response_at = nil,
  response_needed = false,
  session = 0,
  last_settings = nil,
  last_applied_on = false,
  auto_insert = true,
  dev_sync_error = nil,
  control_ready = false,
  activation_started = nil,
  spectrum = { fft_size = 4096, smoothing_octaves = 1 / 12, epoch = 0,
    capture_state = 0, average_seconds = 0,
    history_epoch = 0, idle_seconds = 0 },
  spectrum_revision = 0,
  spectrum_dirty = true,
  spectrum_frame = nil,
  spectrum_staging = {},
  spectrum_average_staging = {},
  spectrum_last_arrival = nil,
  range_error = nil,
}

local function now()
  return R.time_precise and R.time_precise() or os.clock()
end

local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function current_master()
  local project = 0
  if R.EnumProjects then project = select(1, R.EnumProjects(-1, "")) or 0 end
  if not R.GetMasterTrack then return nil end
  return R.GetMasterTrack(project)
end

local function fx_name(master, fx)
  local ok, name = R.TrackFX_GetFXName(master, fx)
  if ok == false then return nil end
  return name
end

local function original_fx_name(master, fx)
  if not R.TrackFX_GetNamedConfigParm then return nil end
  local ok, name = R.TrackFX_GetNamedConfigParm(master, fx, "fx_name")
  if not ok then return nil end
  return name
end

local function snapshot()
  local master = current_master()
  if not master then return nil end
  local count = R.TrackFX_GetRecCount(master)
  if type(count) ~= "number" then return nil end
  local entries, signature = {}, { tostring(count) }
  for slot = 0, count - 1 do
    local fx = MONITOR_FX + slot
    local entry = {
      slot = slot,
      fx = fx,
      guid = R.TrackFX_GetFXGUID(master, fx),
      name = fx_name(master, fx),
      original_name = original_fx_name(master, fx),
      enabled = R.TrackFX_GetEnabled(master, fx),
      offline = R.TrackFX_GetOffline(master, fx),
    }
    entries[#entries + 1] = entry
    signature[#signature + 1] = table.concat({
      tostring(entry.guid), tostring(entry.name), tostring(entry.original_name),
      entry.enabled and "1" or "0", entry.offline and "1" or "0",
    }, ":")
  end
  return { master = master, entries = entries, signature = table.concat(signature, "|") }
end

local function exact_matches(snap)
  local matches = {}
  for _, entry in ipairs(snap.entries) do
    if entry.original_name == FX_ORIGINAL_NAME or FX_NAMES[entry.name] then
      matches[#matches + 1] = entry
    end
  end
  return matches
end

local function find_guid(snap, guid)
  if not guid or guid == "" then return nil end
  for _, entry in ipairs(snap.entries) do
    if entry.guid == guid then return entry end
  end
  return nil
end

local function store_guid(guid)
  S.stored_guid = guid
  if guid and guid ~= "" then
    R.SetExtState(EXT_SECTION, EXT_GUID, guid, true)
  end
end

local function max_filter_hz()
  local sample_rate = S.control_ready and R.gmem_read(SPECTRUM.current_sample_rate)
  if type(sample_rate) == "number" and sample_rate == sample_rate and sample_rate > 0 then
    return math.min(20000, math.floor(sample_rate * 0.49))
  end
  return 20000
end

local function view()
  local available = S.phase == "ready"
  return {
    phase = S.phase,
    message = S.message,
    available = available,
    audible = available and S.last_applied_on == true,
    can_restore = S.phase == "missing" or S.phase == "error"
      or S.phase == "incompatible",
    max_filter_hz = max_filter_hz(),
    range_error = S.range_error,
  }
end

local function set_phase(phase, message)
  S.phase, S.message = phase, message
  if phase ~= "ready" then
    if S.control_ready then
      R.gmem_write(CONTROL.active, 0)
      R.gmem_write(SPECTRUM.capture_state, 0)
    end
    S.last_applied_on = false
    S.activation_started = nil
    S.next_health = now() + HEALTH_INTERVAL
    S.spectrum_frame, S.spectrum_last_arrival = nil, nil
    S.spectrum_dirty = true
  end
end

local function control_write(index, value, tolerance)
  if not S.control_ready then return false end
  R.gmem_write(index, value)
  local actual = R.gmem_read(index)
  return type(actual) == "number" and actual == actual
    and math.abs(actual - value) <= (tolerance or 0.001)
end

local function write_heartbeat()
  S.heartbeat = (S.heartbeat + 1) % 1000000
  return control_write(CONTROL.heartbeat, S.heartbeat)
end

local function publish_spectrum()
  if not S.spectrum_dirty then return true end
  -- Odd/even publication keeps an audio block from accepting a mixed config.
  local revision = S.spectrum_revision + 2
  if not control_write(SPECTRUM.revision, revision - 1) then return false end
  for _, value in ipairs({
    { SPECTRUM.fft_size, S.spectrum.fft_size },
    { SPECTRUM.smoothing, S.spectrum.smoothing_octaves },
    { SPECTRUM.epoch, S.spectrum.epoch },
    { SPECTRUM.capture_state, S.spectrum.capture_state },
    { SPECTRUM.average_seconds, S.spectrum.average_seconds },
    { SPECTRUM.history_epoch, S.spectrum.history_epoch },
    { SPECTRUM.idle_seconds, S.spectrum.idle_seconds },
    { SPECTRUM.session, S.session },
  }) do
    if not control_write(value[1], value[2]) then return false end
  end
  if not control_write(SPECTRUM.revision, revision) then return false end
  S.spectrum_revision, S.spectrum_dirty = revision, false
  return true
end

local function dry_entry(_, _)
  if not S.control_ready then return end
  control_write(CONTROL.active, 0)
  write_heartbeat()
end

local function compatible(master, entry)
  if not R.TrackFX_GetNumParams or R.TrackFX_GetNumParams(master, entry.fx) < 7 then
    return false
  end
  local value = R.TrackFX_GetParam(master, entry.fx, PARAM.protocol)
  return math.abs((tonumber(value) or 0) - PROTOCOL) < 0.001
end

local function refresh_owned_helper(allow_incompatible)
  local snap = snapshot()
  if not snap or not S.bound_guid or S.bound_guid ~= S.stored_guid then
    return false, false
  end

  local matches = exact_matches(snap)
  local entry = find_guid(snap, S.bound_guid)
  if #matches ~= 1 or not entry or matches[1].guid ~= entry.guid
      or (not allow_incompatible and not compatible(snap.master, entry)) then
    return false, false
  end

  -- Restore is the user's explicit repair action. Only the exact compatible
  -- instance we already own may be replaced; every other Monitor FX is left alone.
  if not R.TrackFX_Delete then return true, false end
  dry_entry(snap, entry)
  if R.TrackFX_Delete(snap.master, entry.fx) ~= true then return true, false end

  S.stored_guid, S.bound_guid, S.slot = nil, nil, nil
  S.last_settings, S.last_applied_on = nil, false
  S.activation_started = nil
  return true, true
end

local function bind(snap, entry)
  if not compatible(snap.master, entry) then
    dry_entry(snap, entry)
    S.bound_guid, S.slot = entry.guid, entry.slot
    if entry.original_name == FX_ORIGINAL_NAME or FX_NAMES[entry.name] then
      store_guid(entry.guid)
    end
    set_phase("incompatible",
      "The helper doesn't match this yb-Reference version. Choose Update Helper to reload it.")
    return false
  end
  store_guid(entry.guid)
  if entry.offline then
    S.bound_guid, S.slot = entry.guid, entry.slot
    set_phase("offline", "The Monitoring Filter is offline in Reaper. Bring it online in Monitor FX to use filtering.")
    return false
  end
  if not entry.enabled then
    S.bound_guid, S.slot = entry.guid, entry.slot
    set_phase("bypassed", "The Monitoring Filter is bypassed in Reaper. Enable it in Monitor FX to use filtering.")
    return false
  end

  S.bound_guid, S.slot = entry.guid, entry.slot
  set_phase("ready", "Full-range monitoring. The filter applies to timeline and reference audio.")
  S.response_sequence = R.gmem_read(CONTROL.response_sequence)
  S.response_ack, S.response_at = nil, now()
  S.response_needed = false
  S.next_lease, S.next_health = 0, now() + HEALTH_INTERVAL
  S.last_settings = nil
  return true
end

local function insert_helper(snap)
  local position = R.TrackFX_AddByName(snap.master, FX_QUERY, true, -1000)
  S.auto_insert = false
  S.stable_count, S.last_signature = 0, nil
  if type(position) ~= "number" or position < 0 then
    set_phase("missing",
      "The helper couldn't be added to Monitor FX. Reinstall yb-Reference through ReaPack, then add the helper again.")
    return false
  end
  set_phase("settling", "Confirming the Monitoring Filter…")
  return true
end

local function resolve(snap, allow_insert)
  local matches = exact_matches(snap)
  local owned = find_guid(snap, S.stored_guid)
  local helper_count = #matches
  local owned_has_exact_name = owned and (owned.original_name == FX_ORIGINAL_NAME
    or FX_NAMES[owned.name])
  if owned and not owned_has_exact_name then helper_count = helper_count + 1 end
  if helper_count > 1 then
    if owned and compatible(snap.master, owned) then dry_entry(snap, owned) end
    S.bound_guid, S.slot = owned and owned.guid or nil, owned and owned.slot or nil
    set_phase("duplicate",
      "More than one yb-Reference Monitoring Filter is installed. Remove the extra copies from Reaper's Monitor FX chain.")
    return false
  end

  local entry = owned
  if not entry and #matches == 1 then entry = matches[1] end
  if entry then return bind(snap, entry) end

  S.bound_guid, S.slot = nil, nil
  if allow_insert then return insert_helper(snap) end
  set_phase("missing",
    "The helper is missing from Monitor FX. Choose Add Helper to add it back.")
  return false
end

local function settings_key(settings)
  return table.concat({
    settings.on and "1" or "0",
    tostring(settings.low_hz), tostring(settings.high_hz),
    tostring(settings.slope),
  }, "|")
end

local SLOPE_INDEX = { [12] = 0, [24] = 1, [36] = 2, [48] = 3 }

local function verified_owned_entry(snap)
  local at_slot = S.slot and snap.entries[S.slot + 1] or nil
  if at_slot and at_slot.guid == S.bound_guid then return at_slot end
  return find_guid(snap, S.bound_guid)
end

local function write_settings(snap, entry, settings)
  local slope = SLOPE_INDEX[settings.slope]
  if slope == nil then return false end
  local live_update = settings.on and S.last_applied_on

  -- Initial activation starts dry and enables only after the complete shape is
  -- published. Live edits keep the filter engaged so the audio thread can
  -- crossfade internally instead of exposing a full-range block.
  if not live_update and not control_write(CONTROL.active, 0) then return false end
  local revision = S.control_revision + 2
  if not control_write(CONTROL.revision, revision - 1) then return false end
  local writes = {
    { CONTROL.protocol, PROTOCOL, 0.001 },
    -- Slot 2 stays fixed to Band for compatibility with installed helpers.
    { CONTROL.mode, 1, 0.001 },
    { CONTROL.slope, slope, 0.001 },
  }
  for _, write in ipairs(writes) do
    if not control_write(write[1], write[2], write[3]) then
      return false
    end
  end
  local current_high = tonumber(R.gmem_read(CONTROL.high_hz))
  local boundaries = settings.low_hz > (current_high or settings.high_hz)
    and {
      { CONTROL.high_hz, settings.high_hz, 0.001 },
      { CONTROL.low_hz, settings.low_hz, 0.001 },
    }
    or {
      { CONTROL.low_hz, settings.low_hz, 0.001 },
      { CONTROL.high_hz, settings.high_hz, 0.001 },
    }
  for _, write in ipairs(boundaries) do
    if not control_write(write[1], write[2], write[3]) then return false end
  end
  if not publish_spectrum() then return false end
  if not write_heartbeat() then return false end
  if settings.on and not live_update
      and not control_write(CONTROL.active, 1) then
    return false
  end
  if not control_write(CONTROL.revision, revision) then return false end
  S.control_revision = revision
  S.slot = entry.slot
  S.last_settings = settings_key(settings)
  S.last_applied_on = live_update
  S.activation_started = settings.on and not live_update and (S.activation_started or now()) or nil
  S.message = settings.on and (live_update
      and "Filtering timeline and reference audio."
      or "Confirming the Monitoring Filter…")
    or "Full-range monitoring. The filter applies to timeline and reference audio."
  return true
end

-- A returned heartbeat alone can remain in shared memory after audio stops.
-- Require a new, complete audio response, including progress accepting controls.
local function response_tick(settings)
  local needed = settings.on or S.spectrum.capture_state ~= 0
  if not needed then
    S.response_needed, S.last_applied_on = false, false
    return
  end
  if not S.response_needed then
    S.response_at, S.response_needed = now(), true
  end
  local sequence = R.gmem_read(CONTROL.response_sequence)
  local ack = R.gmem_read(CONTROL.ack)
  local engaged = R.gmem_read(CONTROL.engaged)
  local complete = finite(sequence) and sequence > 0 and sequence % 2 == 0
    and sequence == R.gmem_read(CONTROL.response_sequence)
    and finite(ack) and ack >= 0 and (engaged == 0 or engaged == 1)
  if complete and sequence ~= S.response_sequence then
    S.response_sequence = sequence
    if ack == S.heartbeat or ack ~= S.response_ack then
      S.response_ack, S.response_at = ack, now()
      S.last_applied_on = settings.on and engaged == 1
      if settings.on and engaged == 0 then
        S.activation_started = S.activation_started or now()
      end
      if S.activation_started and ack == S.heartbeat and engaged == 1 then
        S.activation_started = nil
        S.message = "Filtering timeline and reference audio."
      end
    end
  end
  local deadline = S.activation_started or S.response_at
  if deadline and now() - deadline >= ENGAGE_TIMEOUT then
    control_write(CONTROL.active, 0)
    set_phase("error",
      "The helper stopped responding. Choose Restore Helper to reconnect it.")
  end
end

local function health_tick(settings, force_write)
  local snap = snapshot()
  if not snap then
    set_phase("settling", "Waiting for Reaper's current Monitor FX chain…")
    return
  end

  local matches = exact_matches(snap)
  if #matches > 1
    or (#matches == 1 and matches[1].guid ~= S.bound_guid) then
    resolve(snap, false)
    return
  end
  local entry = verified_owned_entry(snap)
  if not entry then resolve(snap, false); return end
  if entry.offline or not entry.enabled or not compatible(snap.master, entry) then
    bind(snap, entry)
    return
  end

  -- A matching installed effect is not evidence of recovery from a response
  -- failure. Keep Restore available until its explicit repair path runs.
  if S.phase == "error" then return end
  if S.phase ~= "ready" then bind(snap, entry) end
  local low, high = tonumber(settings.low_hz), tonumber(settings.high_hz)
  local limit = max_filter_hz()
  if settings.on and (not low or not high or low ~= low or high ~= high
      or low < 10 or high < low + 1 or high > limit) then
    control_write(CONTROL.active, 0)
    S.last_applied_on, S.activation_started, S.last_settings = false, nil, nil
    S.range_error = "This range isn't available at the current sample rate. High must be above Low and no higher than "
      .. tostring(limit) .. " Hz."
    -- Keep analysis alive while the rejected listening range remains dry.
    if not publish_spectrum() or not write_heartbeat() then
      set_phase("error", "The helper stopped responding. Choose Restore Helper to reconnect it.")
      return
    end
    S.next_lease, S.next_health = now() + LEASE_INTERVAL, now() + HEALTH_INTERVAL
    return
  end
  local t = now()
  local key = settings_key(settings)
  if force_write or key ~= S.last_settings or S.spectrum_dirty then
    if not write_settings(snap, entry, settings) then
      control_write(CONTROL.active, 0)
      set_phase("error", "The helper stopped responding. Choose Restore Helper to reconnect it.")
      return
    end
    S.next_lease = t + LEASE_INTERVAL
  elseif t >= S.next_lease then
    if not write_heartbeat() then
      set_phase("error", "The helper stopped responding. Choose Restore Helper to reconnect it.")
      return
    end
    S.next_lease = t + LEASE_INTERVAL
  end
  -- Automatic dry fallback must not acknowledge its own warning. Only a
  -- supported listening choice or an explicit Full choice clears the notice.
  if settings.on then S.range_error = nil end
  S.next_health = t + HEALTH_INTERVAL
end

function monitor_filter.dismiss_range_error()
  S.range_error = nil
end

local function read_file(path)
  local file = path and io.open(path, "rb")
  if not file then return nil end
  local data = file:read("a")
  file:close()
  return data
end

local function sync_dev_helper(source_path)
  local source = read_file(source_path)
  if not source then return "The development Monitoring Filter file is missing." end
  local sep = package.config:sub(1, 1)
  local effects = R.GetResourcePath() .. sep .. "Effects"
  local destination = effects .. sep .. "yb-Reference Monitoring Filter.jsfx"
  if read_file(destination) == source then return nil end
  if R.RecursiveCreateDirectory then R.RecursiveCreateDirectory(effects, 0) end
  local file, err = io.open(destination, "wb")
  if not file then return tostring(err or "The Reaper Effects folder isn't writable.") end
  local ok, write_err = file:write(source)
  file:close()
  if not ok then return tostring(write_err or "The Monitoring Filter file couldn't be written.") end
  return nil
end

local function initialise_control_session()
  -- An installed helper can miss every startup write between audio blocks.
  -- Continue its message numbering instead of relying on it observing zero.
  local previous_revision = R.gmem_read(CONTROL.revision)
  S.control_revision = finite(previous_revision) and previous_revision >= 0
    and previous_revision % 1 == 0 and previous_revision - previous_revision % 2 or 0
  local previous_session = R.gmem_read(SPECTRUM.session)
  S.session = finite(previous_session) and previous_session >= 0
    and previous_session % 1 == 0 and previous_session % 1000000000 + 1 or 1
  local previous_heartbeat = R.gmem_read(CONTROL.heartbeat)
  S.heartbeat = finite(previous_heartbeat) and previous_heartbeat % 1000000 or 0
  control_write(CONTROL.active, 0)
  control_write(SPECTRUM.capture_state, 0)
  control_write(SPECTRUM.revision, 0)
  -- A prior controller's frame must never appear as a fresh startup capture.
  R.gmem_write(SPECTRUM.sequence, 0)
  write_heartbeat()
end

function monitor_filter.init(opts)
  opts = opts or {}
  S.phase = "settling"
  S.message = "Setting up the Monitoring Filter…"
  S.frame, S.stable_count = 0, 0
  S.last_signature = nil
  S.stored_guid = R.GetExtState(EXT_SECTION, EXT_GUID)
  if S.stored_guid == "" then S.stored_guid = nil end
  S.bound_guid, S.slot = nil, nil
  S.next_lease, S.next_health = 0, 0
  S.last_settings, S.last_applied_on = nil, false
  S.activation_started = nil
  S.range_error = nil
  S.response_sequence, S.response_ack, S.response_at = nil, nil, nil
  S.response_needed = false
  S.spectrum = { fft_size = 4096, smoothing_octaves = 1 / 12, epoch = 0,
    capture_state = 0, average_seconds = 0,
    history_epoch = 0, idle_seconds = 0 }
  S.spectrum_revision, S.spectrum_dirty = 0, true
  S.spectrum_frame, S.spectrum_last_arrival = nil, nil
  S.spectrum_staging = {}
  S.spectrum_average_staging = {}
  -- The saved GUID distinguishes an earlier setup from a genuinely new one.
  -- If its helper is now absent, wait for the user's explicit recovery click.
  S.auto_insert = S.stored_guid == nil
  S.control_ready = R.gmem_attach ~= nil and R.gmem_read ~= nil
    and R.gmem_write ~= nil and R.gmem_attach(GMEM_NAME) ~= false
  if S.control_ready then
    initialise_control_session()
  end
  S.dev_sync_error = opts.dev_copy and sync_dev_helper(opts.source_path) or nil
  if not S.control_ready then
    set_phase("error", "The Monitoring Filter control channel isn't available in this Reaper version.")
  elseif S.dev_sync_error then
    set_phase("error", "The development Monitoring Filter couldn't be installed: " .. S.dev_sync_error)
  end
end

function monitor_filter.tick(settings)
  if S.dev_sync_error or not S.control_ready then return view() end
  S.frame = S.frame + 1

  -- Full must cancel even an activation that has not yet been acknowledged.
  if not settings.on and S.activation_started then
    control_write(CONTROL.active, 0)
    S.activation_started, S.last_applied_on, S.last_settings = nil, false, nil
  end

  if S.phase == "ready" then
    response_tick(settings)
    if S.phase ~= "ready" then return view() end
  end

  if S.phase == "settling" then
    local snap = snapshot()
    if not snap then
      S.message = "Waiting for Reaper's current Monitor FX chain…"
      return view()
    end
    if snap.signature == S.last_signature then
      S.stable_count = S.stable_count + 1
    else
      S.last_signature, S.stable_count = snap.signature, 1
    end
    if S.stable_count >= STABLE_SNAPSHOTS or S.frame >= MAX_SETTLE_FRAMES then
      local resolved = resolve(snap, S.auto_insert)
      if resolved and S.phase == "ready" then health_tick(settings, true) end
    end
    return view()
  end

  local t = now()
  if S.phase == "ready" then
    if t >= S.next_health then
      health_tick(settings, false)
    elseif t >= S.next_lease or settings_key(settings) ~= S.last_settings or S.spectrum_dirty then
      health_tick(settings, false)
    end
  elseif t >= S.next_health then
    -- A manual enable/online change or removal of an extra copy repairs itself.
    -- A truly missing helper is only inserted by restore(), never by this scan.
    health_tick(settings, false)
  end
  return view()
end

function monitor_filter.restore()
  if S.phase ~= "missing" and S.phase ~= "error"
      and S.phase ~= "incompatible" then return false end
  if S.phase == "incompatible" then
    local attempted, refreshed = refresh_owned_helper(true)
    if not attempted or not refreshed then
      set_phase("error",
        "The helper couldn't be reloaded. Remove yb-Reference Monitoring Filter from Monitor FX, then choose Add Helper.")
      return false
    end
  elseif S.phase == "error" then
    local attempted, refreshed = refresh_owned_helper(false)
    if attempted and not refreshed then
      set_phase("error",
        "The helper couldn't be refreshed. Remove yb-Reference Monitoring Filter from Monitor FX, then choose Add Helper.")
      return false
    end
  end
  S.phase = "settling"
  S.message = "Restoring the Monitoring Filter…"
  S.frame, S.stable_count = 0, 0
  S.last_signature = nil
  S.auto_insert = true
  S.dev_sync_error = nil
  if not S.control_ready and R.gmem_attach and R.gmem_read and R.gmem_write then
    S.control_ready = R.gmem_attach(GMEM_NAME) ~= false
    if S.control_ready then initialise_control_session() end
  end
  if not S.control_ready then
    set_phase("error", "The Monitoring Filter control channel isn't available in this Reaper version.")
    return false
  end
  return true
end

local function encoded_history_seconds(value, fallback)
  if value == nil then return fallback end
  if value == math.huge or value == "infinite" then return -1 end
  value = tonumber(value)
  if value == 0 or value == 1 or value == 3 or value == -1 then return value end
  return nil
end

function monitor_filter.configure_spectrum(config)
  config = config or {}
  local fft = tonumber(config.fft_size) or S.spectrum.fft_size
  local smoothing = tonumber(config.smoothing_octaves) or S.spectrum.smoothing_octaves
  local epoch = tonumber(config.epoch) or S.spectrum.epoch
  local capture_state = config.capture_state == nil and S.spectrum.capture_state
    or tonumber(config.capture_state)
  local average_seconds = encoded_history_seconds(
    config.average_seconds, S.spectrum.average_seconds)
  local history_epoch = config.history_epoch == nil and S.spectrum.history_epoch
    or tonumber(config.history_epoch)
  local idle_seconds = config.idle_seconds == nil and S.spectrum.idle_seconds
    or tonumber(config.idle_seconds)
  if (fft ~= 2048 and fft ~= 4096 and fft ~= 8192)
      or (smoothing ~= 0 and smoothing ~= 1 / 24 and smoothing ~= 1 / 12 and smoothing ~= 1 / 6)
      or epoch ~= epoch or epoch < 0 or epoch > 1000000000 or epoch % 1 ~= 0
      or capture_state == nil or capture_state < 0 or capture_state > 2
      or capture_state % 1 ~= 0 or average_seconds == nil
      or history_epoch == nil or history_epoch ~= history_epoch or history_epoch < 0
      or history_epoch > 1000000000 or history_epoch % 1 ~= 0
      or not finite(idle_seconds) or idle_seconds < 0 or idle_seconds > 1000000000 then
    return false
  end
  if fft ~= S.spectrum.fft_size or smoothing ~= S.spectrum.smoothing_octaves
      or epoch ~= S.spectrum.epoch or capture_state ~= S.spectrum.capture_state
      or average_seconds ~= S.spectrum.average_seconds
      or history_epoch ~= S.spectrum.history_epoch
      or idle_seconds ~= S.spectrum.idle_seconds then
    S.spectrum = { fft_size = fft, smoothing_octaves = smoothing, epoch = epoch,
      capture_state = capture_state, average_seconds = average_seconds,
      history_epoch = history_epoch,
      idle_seconds = idle_seconds }
    S.spectrum_dirty = true
  end
  return true
end

-- Preview startup uses this narrow path to arm capture before audio begins.
-- It publishes only the analyser transaction and never touches filter controls.
function monitor_filter.publish_spectrum_now()
  if not S.control_ready then return false end
  return publish_spectrum()
end

-- Only an explicit recovery click may undo bypass/offline. Reacquire the
-- exact owned instance around host writes because its chain position can move.
function monitor_filter.enable()
  if S.phase ~= "bypassed" and S.phase ~= "offline" then return false end
  S.auto_insert = false
  local function reacquire()
    local snap = snapshot()
    if not snap then
      set_phase("settling", "Waiting for Reaper's Monitor FX chain…")
      return nil
    end
    local matches = exact_matches(snap)
    local entry = verified_owned_entry(snap)
    if not entry or #matches ~= 1 or matches[1].guid ~= entry.guid
        or S.bound_guid ~= S.stored_guid or not compatible(snap.master, entry) then
      resolve(snap, false)
      return nil
    end
    return snap, entry
  end
  local snap, entry = reacquire()
  if not snap then return false end
  if not R.TrackFX_SetEnabled or (entry.offline and not R.TrackFX_SetOffline) then
    set_phase("error", "The helper couldn't be enabled. Enable yb-Reference Monitoring Filter in Monitor FX.")
    return false
  end
  if not control_write(CONTROL.active, 0) then
    set_phase("error", "The helper couldn't be enabled safely. Choose Restore Helper to reconnect it.")
    return false
  end
  S.activation_started, S.last_applied_on, S.last_settings = nil, false, nil
  if entry.offline then
    R.TrackFX_SetOffline(snap.master, entry.fx, false)
    snap, entry = reacquire()
    if not snap then return false end
    if entry.offline then bind(snap, entry); return false end
  end
  if not entry.enabled then
    R.TrackFX_SetEnabled(snap.master, entry.fx, true)
    snap, entry = reacquire()
    if not snap then return false end
  end
  return bind(snap, entry)
end

-- Returned tables are read-only to callers and reused on later frames. A
-- rejected snapshot never replaces the last complete set of measurements.
function monitor_filter.read_spectrum(time)
  if not S.control_ready or S.phase ~= "ready" then return nil, "unavailable" end
  if S.spectrum_dirty then return nil, "waiting" end
  local t = finite(time) and time or now()
  local sequence = R.gmem_read(SPECTRUM.sequence)
  if not finite(sequence) or sequence <= 0 or sequence % 2 ~= 0 then
    return nil, "waiting"
  end
  if R.gmem_read(SPECTRUM.magic) ~= SPECTRUM_MAGIC
      or R.gmem_read(SPECTRUM.protocol) ~= PROTOCOL then return nil, "invalid" end
  if S.spectrum_frame and sequence == S.spectrum_frame.sequence then
    if S.spectrum_frame.revision ~= S.spectrum_revision then return nil, "waiting" end
    if S.spectrum_frame.final then return S.spectrum_frame end
    if R.gmem_read(SPECTRUM.active) ~= 1 then return nil, "stale" end
    if t - S.spectrum_last_arrival > SPECTRUM_TIMEOUT then return nil, "stale" end
    return S.spectrum_frame
  end
  local count = R.gmem_read(SPECTRUM.count)
  local sample_rate = R.gmem_read(SPECTRUM.sample_rate)
  local fmin, fmax = R.gmem_read(SPECTRUM.fmin), R.gmem_read(SPECTRUM.fmax)
  local fft, hop = R.gmem_read(SPECTRUM.frame_fft), R.gmem_read(SPECTRUM.hop)
  local peak = R.gmem_read(SPECTRUM.peak)
  local epoch = R.gmem_read(SPECTRUM.frame_epoch)
  local frame_revision = R.gmem_read(SPECTRUM.frame_revision)
  local final = R.gmem_read(SPECTRUM.final)
  local average_ready = R.gmem_read(SPECTRUM.average_ready)
  local history_samples = R.gmem_read(SPECTRUM.history_samples)
  if R.gmem_read(SPECTRUM.frame_session) ~= S.session
      or epoch ~= S.spectrum.epoch or fft ~= S.spectrum.fft_size
      or frame_revision ~= S.spectrum_revision
      or math.abs(R.gmem_read(SPECTRUM.frame_smoothing) - S.spectrum.smoothing_octaves) > 0.000001 then
    return nil, "waiting"
  end
  if count ~= 512 or not finite(sample_rate) or sample_rate < 1000 or sample_rate > 768000
      or fmin ~= 10 or not finite(fmax) or fmax <= fmin or fmax > math.min(22050, sample_rate * 0.5)
      or not finite(hop) or hop < fft / 4 or not finite(peak)
      or (final ~= 0 and final ~= 1) or (average_ready ~= 0 and average_ready ~= 1)
      or not finite(history_samples)
      or history_samples < 0 or history_samples % 1 ~= 0 then return nil, "invalid" end
  if final ~= 1 and R.gmem_read(SPECTRUM.active) ~= 1 then return nil, "stale" end
  local raw = S.spectrum_staging
  local average = S.spectrum_average_staging
  for i = 1, count do
    local value = R.gmem_read(SPECTRUM.data + i - 1)
    local average_value = R.gmem_read(SPECTRUM.average_data + i - 1)
    if not finite(value) or value < -180 or value > 36
        or not finite(average_value) or average_value < -180 or average_value > 36 then
      return nil, "invalid"
    end
    raw[i] = value
    average[i] = average_value
  end
  if R.gmem_read(SPECTRUM.sequence) ~= sequence then return nil, "waiting" end
  local frame = S.spectrum_frame or {}
  S.spectrum_staging = frame.raw or {}
  S.spectrum_average_staging = frame.average or {}
  frame.raw, frame.average = raw, average
  frame.count, frame.sequence, frame.publication_id = count, sequence, sequence / 2
  frame.sample_rate, frame.fmin, frame.fmax = sample_rate, fmin, fmax
  frame.fft_size, frame.hop_size, frame.peak_db, frame.epoch = fft, hop, peak, epoch
  frame.revision, frame.final = frame_revision, final == 1
  frame.average_ready = average_ready == 1
  frame.history_samples = history_samples
  S.spectrum_frame, S.spectrum_last_arrival = frame, t
  return frame
end

function monitor_filter.shutdown()
  -- The master can disappear during shutdown; the shared dry command does not
  -- require a surviving track pointer or an FX-chain snapshot.
  if S.control_ready then
    control_write(CONTROL.active, 0)
    control_write(SPECTRUM.capture_state, 0)
  end
  local snap = snapshot()
  if not snap then return end
  local entry = verified_owned_entry(snap) or find_guid(snap, S.stored_guid)
  dry_entry(snap, entry)
  S.last_applied_on = false
end

function monitor_filter.get_saved_settings()
  local value = R.GetExtState(EXT_SECTION, EXT_SETTINGS)
  return value ~= "" and value or nil
end

function monitor_filter.save_settings(value)
  if type(value) ~= "string" then return end
  R.SetExtState(EXT_SECTION, EXT_SETTINGS, value, true)
end

monitor_filter._constants = {
  monitor_fx = MONITOR_FX,
  fx_name = FX_QUERY,
  params = PARAM,
  control = CONTROL,
  gmem_name = GMEM_NAME,
  protocol = PROTOCOL,
  spectrum = SPECTRUM,
}

return monitor_filter
