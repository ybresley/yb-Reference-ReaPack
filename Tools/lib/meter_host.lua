-- Owns the stereo analysis instance by persisted GUID and exact identity.

local host = {}
local install_crest = require("meter_installer").install
local meter_control = require("meter_control")
local recording_active = require("reaper_api").recording_active
local outline = require("core.surround_outline")
-- The physical meter uses exact 100 ms slices at these sample rates.
local SUPPORTED_RATES = {[44100]=true,[48000]=true,[88200]=true,[96000]=true,[176400]=true,[192000]=true}
local MONITOR_FX = 0x1000000
local EXT_SECTION = "yb-Reference"
local EXT_GUID = "meter_helper_guid_v1"
local EXT_ORIGINAL = "meter_helper_original_v1"
local CREST_IDENT = "yb-Reference/yb-Reference_Meter.jsfx"
-- A newly installed helper may not yet appear in REAPER's description cache.
local CREST_QUERY = "JS: " .. CREST_IDENT
local LEGACY_NATIVE_LABEL = "yb-Reference True Peak (session)"
local OLD_CREST_LABEL = "yb-Reference Meter (session)"
local CREST_LABEL = "yb-Reference Meter"
local HISTORY_BASE, HISTORY_ROWS, HISTORY_CAPACITY, HISTORY_STRIDE = 150000, 150032, 1000, 5
local CHANNEL_PACKET, CHANNEL_ROWS, CHANNEL_STRIDE = 156000, 156016, 9
-- Pair correlations sit inside the channel packet's seal. Helpers older than
-- this block never write it, and their tokens never match it.
local PAIR_PACKET, PAIR_VALUES = 156100, 156108
local CHANNEL_FIELDS = {'rms','peak','peak_age','live_peak','true_peak',
  'true_peak_age','live_true_peak','crest','field_rms'}
local STOPPED_MONITORING = "Monitor while stopped (output)"

local CREST_NAMES = {
  rms_l = "RMS Left (output)",
  rms_r = "RMS Right (output)",
  peak_l = "Peak Left (output)",
  peak_r = "Peak Right (output)",
  crest_l = "Crest Left (output)",
  crest_r = "Crest Right (output)",
  crest = "Crest Factor (output)",
  true_peak_l = "True Peak Left (output)",
  true_peak_r = "True Peak Right (output)",
  live_true_peak_l = "Live True Peak Left (output)",
  live_true_peak_r = "Live True Peak Right (output)",
  true_peak_age_l = "True Peak Age Left (output)",
  true_peak_age_r = "True Peak Age Right (output)",
  sequence = "Sequence (output)",
  capture_epoch = "Capture epoch (output)",
  tp_max = "True Peak Max (output)",
  live_peak_l = "Live Peak Left (output)",
  live_peak_r = "Live Peak Right (output)",
  lra = "LRA (output)",
  lra_low = "LRA low (output)",
  lra_high = "LRA high (output)",
  lra_valid = "LRA valid (output)",
  lra_seconds = "LRA seconds (output)",
  lra_revision = "LRA revision (output)",
  live_m = "Momentary L/R (output)",
  live_s = "Short-term L/R (output)",
  peak_age_l = "Peak Age Left (output)",
  peak_age_r = "Peak Age Right (output)",
  integrated = "Integrated L/R (output)",
  control_protocol = "Control protocol (output)",
  instance_token = "Instance token (output)",
  control_session = "Control session (output)",
}

local OUTPUT_NAMES = {}
local OLD_CREST_NAMES = {
  capture_mode = "Capture mode", reset_request = "Reset request",
  reset_policy = "Reset policy", loop_start = "Project loop start",
  loop_end = "Project loop end", loop_enabled = "Project loop enabled",
}
local PROTOCOL_ONE_NAMES = {}
for key, value in pairs(CREST_NAMES) do PROTOCOL_ONE_NAMES[key] = value end
for _, key in ipairs({ 'capture_mode', 'reset_request', 'reset_policy',
    'loop_start', 'loop_end', 'loop_enabled' }) do
  PROTOCOL_ONE_NAMES[key] = OLD_CREST_NAMES[key]
end
for key, value in pairs(CREST_NAMES) do
  if key ~= "control_protocol" and key ~= "instance_token" then
    OUTPUT_NAMES[key] = value
  end
  if key ~= "tp_max" and key ~= "control_protocol" and key ~= "instance_token"
      and key ~= "control_session" then
    OLD_CREST_NAMES[key] = value
  end
end

local function clean_name(name)
  return type(name) == "string" and name:gsub("^%-+", ""):lower() or ""
end

local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function pin_mask(value)
  if not finite(value) or value%1~=0 or value < -2147483648 or value > 4294967295 then return nil end
  -- REAPER exposes signed and unsigned halves of the same 32-bit mask.
  return value & 0xffffffff
end

-- Correlation for every channel pair, in the helper's (1,2), (1,3) ... order.
-- A silent pair is false. Returns nil when this helper does not publish pairs.
local function accept_pairs(header, values, channel_header, control, sequence)
  if not header or header.protocol ~= 1 or header.token ~= control.token
      or header.session ~= control.session or header.sequence ~= sequence
      or header.count ~= channel_header.count or #values ~= header.count * (header.count - 1) / 2 then
    return nil
  end
  local result = {}
  for index, value in ipairs(values) do
    result[index] = type(value) == 'number' and value >= -1.0001 and value <= 1.0001
      and math.max(-1, math.min(1, value)) or false
  end
  return result
end

local function valid_counter(value)
  return finite(value) and value >= 0 and value < 1000000000 and value % 1 == 0
end

local function expected_original(kind, original)
  if type(original) ~= "string" then return false end
  if kind == "native" then
    return original == "Loudness Meter Peak/RMS/LUFS (Cockos)"
      or original == "JS: Loudness Meter Peak/RMS/LUFS (Cockos)"
      or original == "Loudness Meter Peak/RMS/LUFS"
      or original == "JS: Loudness Meter Peak/RMS/LUFS"
      or original == "analysis/loudness_meter"
      or original == "JS: analysis/loudness_meter"
  end
  return original == "yb-Reference Meter"
    or original == "JS: yb-Reference Meter"
    or original == "yb-Reference Meter [yb-Reference/yb-Reference_Meter.jsfx]"
    or original == "JS: yb-Reference Meter [yb-Reference/yb-Reference_Meter.jsfx]"
    or original == "yb-Reference/yb-Reference_Meter.jsfx"
    or original == "JS: yb-Reference/yb-Reference_Meter.jsfx"
    or original == "yb-Reference/yb-Reference_Meter"
    or original == "JS: yb-Reference/yb-Reference_Meter"
end

local function saved_identity(R)
  local guid = R.GetExtState(EXT_SECTION, EXT_GUID)
  local original = R.GetExtState(EXT_SECTION, EXT_ORIGINAL)
  if guid == "" and original == "" then return nil end
  if type(guid) ~= "string" or guid == "" or not expected_original("crest", original) then
    return false
  end
  return { guid = guid, original = original, label = CREST_LABEL }
end

local function find_params(R, snap, fx, names, optional)
  local available = {}
  local count = R.TrackFX_GetNumParams(snap.master, fx)
  if type(count) ~= "number" then return nil end
  for param = 0, count - 1 do
    local ok, name = R.TrackFX_GetParamName(snap.master, fx, param)
    if ok then available[clean_name(name)] = param end
  end
  local found = {}
  for key, name in pairs(names) do
    found[key] = available[clean_name(name)]
    if found[key] == nil then return nil end
  end
  return found, optional and available[clean_name(optional)]
end

local function validate_params(R, snap, entry)
  local params, stopped = find_params(R, snap, entry.fx, CREST_NAMES, STOPPED_MONITORING)
  if not params then return nil, "crest_parameters_missing" end
  local protocol = R.TrackFX_GetParam(snap.master, entry.fx, params.control_protocol)
  local token = R.TrackFX_GetParam(snap.master, entry.fx, params.instance_token)
  if protocol ~= 4 or not valid_counter(token) then
    return nil, "control_incompatible"
  end
  if token == 0 then return nil, "initializing" end
  params.stopped_monitoring = stopped ~= nil and R.TrackFX_GetParam(snap.master, entry.fx, stopped) == 1
  return params, token
end

local function matches_identity(R, master, fx, identity, allow_renamed)
  local original_ok, original = R.TrackFX_GetNamedConfigParm(master, fx, "fx_name")
  local renamed_ok, renamed = R.TrackFX_GetNamedConfigParm(master, fx, "renamed_name")
  if not original_ok or not renamed_ok then return false end
  -- Reuse may honour a display-only rename once the saved original, installed
  -- file and current controls verify it. Repair keeps its separate name checks.
  local label_matches = renamed == identity.label or renamed == ""
  local reusable_name = false
  if allow_renamed and not label_matches and original == identity.original and type(renamed) == "string" then
    local identified, ident = R.TrackFX_GetNamedConfigParm(master, fx, "fx_ident")
    if identified and ident == CREST_IDENT then
      local params, reason = validate_params(R, {master=master}, {fx=fx})
      -- REAPER can expose the verified controls before audio assigns a token.
      reusable_name = params ~= nil or reason == "initializing"
    end
  end
  local exact = original == identity.original and (label_matches or reusable_name)
  return exact, original, renamed
end

function host.has_saved_front_meter(R, master)
  local identity = saved_identity(R)
  return identity and R.TrackFX_GetNamedConfigParm
    and R.TrackFX_GetFXGUID(master, MONITOR_FX) == identity.guid
    and matches_identity(R, master, MONITOR_FX, identity, true) or false
end

function host.new(R, options)
  R = R or reaper
  options = options or {}
  local self = { R = R, options = options, owned = {}, control = meter_control.new(R),
    reset_request = 0 }

  local function store_identity(identity)
    local prior_guid = R.GetExtState(EXT_SECTION, EXT_GUID)
    local prior_original = R.GetExtState(EXT_SECTION, EXT_ORIGINAL)
    local function write(key, value)
      R.SetExtState(EXT_SECTION, key, value, true)
      return R.GetExtState(EXT_SECTION, key) == value
    end
    local function failed()
      -- ExtState has no paired transaction; restore the previous pair if possible.
      write(EXT_ORIGINAL, prior_original)
      write(EXT_GUID, prior_guid)
      return false, "storage_failed"
    end
    if identity then
      if not write(EXT_ORIGINAL, identity.original) then return failed() end
      if not write(EXT_GUID, identity.guid) then return failed() end
    else
      if not write(EXT_GUID, "") then return failed() end
      if not write(EXT_ORIGINAL, "") then return failed() end
    end
    return true
  end

  function self:snapshot()
    local project = R.EnumProjects and select(1, R.EnumProjects(-1, "")) or 0
    local master = R.GetMasterTrack(project)
    if not master then return nil end
    local count = R.TrackFX_GetRecCount(master)
    if type(count) ~= "number" then return nil end
    return { project = project, master = master, count = count }
  end

  local function meter_present(snap, fx, original_ok, original)
    if original_ok and expected_original("crest", original) then return true end
    -- The installed filename still reveals a meter after its name check fails.
    -- This blocks extra insertions; it does not grant ownership or deletion.
    local ok, ident = R.TrackFX_GetNamedConfigParm(snap.master, fx, "fx_ident")
    return ok and ident == CREST_IDENT
  end

  local function scan_owned(snap)
    local found = { meter_count = 0, known_labels = 0 }
    local crest_guid = self.owned.crest and self.owned.crest.guid
    for slot = 0, snap.count - 1 do
      local guid = R.TrackFX_GetFXGUID(snap.master, MONITOR_FX + slot)
      local original_ok, original = R.TrackFX_GetNamedConfigParm(
        snap.master, MONITOR_FX + slot, "fx_name")
      local label_ok, label = R.TrackFX_GetNamedConfigParm(
        snap.master, MONITOR_FX + slot, "renamed_name")
      if meter_present(snap, MONITOR_FX + slot, original_ok, original) then
        found.meter_count = found.meter_count + 1
      end
      if label_ok and (label == CREST_LABEL or label == OLD_CREST_LABEL
          or label == LEGACY_NATIVE_LABEL) then
        found.known_labels = found.known_labels + 1
      end
      if crest_guid and guid == crest_guid then
        if found.crest ~= nil then
          found.crest = false
        else
          found.crest = { slot = slot, fx = MONITOR_FX + slot }
        end
      end
    end
    return found
  end

  function self:locate(snap, kind, allow_disabled, scanned, recover_name)
    local identity = self.owned[kind]
    if not identity then return nil, "detached" end
    local match
    if scanned then
      match = scanned[kind]
      if match == false then return nil, "ambiguous" end
    else
      for slot = 0, snap.count - 1 do
        local fx = MONITOR_FX + slot
        if R.TrackFX_GetFXGUID(snap.master, fx) == identity.guid then
          if match then return nil, "ambiguous" end
          match = { slot = slot, fx = fx }
        end
      end
    end
    if not match then return nil, "missing" end
    local exact, original, renamed = matches_identity(R, snap.master, match.fx, identity, recover_name == nil)
    if not exact then
      -- Only explicit repair can resolve a changed name. It still verifies
      -- the installed file and known controls before deleting the instance.
      if not recover_name or kind ~= "crest" or type(renamed) ~= "string"
          or not expected_original(kind, original) then
        return nil, "changed"
      end
      local ident_ok, ident = R.TrackFX_GetNamedConfigParm(snap.master, match.fx, "fx_ident")
      if not ident_ok or ident ~= CREST_IDENT then return nil, "changed" end
      match.identity_changed = true
    end
    match.original, match.label = original, renamed
    if not allow_disabled then
      if R.TrackFX_GetOffline(snap.master, match.fx) then return nil, "offline" end
      if not R.TrackFX_GetEnabled(snap.master, match.fx) then return nil, "bypassed" end
    end
    return match
  end

  local function known_older_helper(snap, entry)
    -- Each shipped layout has an exact signature. Unknown controls stay manual.
    local params = find_params(R, snap, entry.fx, PROTOCOL_ONE_NAMES)
    local waiting, stopped
    if params then
      local protocol = R.TrackFX_GetParam(snap.master, entry.fx, params.control_protocol)
      if protocol ~= 1 and protocol ~= 2 and protocol ~= 3 then return false end
      local token = R.TrackFX_GetParam(snap.master, entry.fx, params.instance_token)
      if not valid_counter(token) then return false end
      waiting = token == 0
      for param = 0, R.TrackFX_GetNumParams(snap.master, entry.fx) - 1 do
        local ok, name = R.TrackFX_GetParamName(snap.master, entry.fx, param)
        if ok and clean_name(name) == clean_name(STOPPED_MONITORING) then
          if protocol ~= 3 or stopped ~= nil or R.TrackFX_GetParam(snap.master, entry.fx, param) ~= 1 then
            return false
          end
          stopped = param
        end
      end
    else
      params = find_params(R, snap, entry.fx, OLD_CREST_NAMES)
      if not params then return false end
    end
    local known = {}
    for _, param in pairs(params) do known[param] = true end
    if stopped ~= nil then known[stopped] = true end
    if R.TrackFX_GetParamFromIdent then
      for _, ident in ipairs({ ":bypass", ":wet", ":delta" }) do
        local param = R.TrackFX_GetParamFromIdent(snap.master, entry.fx, ident)
        if type(param) == "number" and param >= 0 then known[param] = true end
      end
    end
    for param = 0, R.TrackFX_GetNumParams(snap.master, entry.fx) - 1 do
      if not known[param] then return false end
    end
    if waiting then return false, "initializing" end
    return true
  end

  local function remove_created(guid, original)
    local snap = self:snapshot()
    if not snap then return false end
    local match
    for slot = 0, snap.count - 1 do
      local fx = MONITOR_FX + slot
      if R.TrackFX_GetFXGUID(snap.master, fx) == guid then
        if match then return false end
        match = fx
      end
    end
    if not match then return false end
    local ok, current = R.TrackFX_GetNamedConfigParm(snap.master, match, "fx_name")
    return ok and current == original and not recording_active(R)
      and R.TrackFX_Delete(snap.master, match) == true
  end

  function self:add(slot)
    if recording_active(R) then return false, "recording" end
    local kind = "crest"
    local snap = self:snapshot()
    if not snap then return false, "no_master" end
    local existing = {}
    for index = 0, snap.count - 1 do
      local old_guid = R.TrackFX_GetFXGUID(snap.master, MONITOR_FX + index)
      if old_guid then existing[old_guid] = true end
    end
    local label = CREST_LABEL
    if recording_active(R) then return false, "recording" end
    local position = R.TrackFX_AddByName(snap.master, CREST_QUERY, true, -1000 - slot)
    if type(position) ~= "number" or position < 0 then
      return false, "crest_insert_failed"
    end
    -- REAPER documents a chain slot; accept a monitor-tagged index as well.
    if position >= MONITOR_FX then position = position - MONITOR_FX end
    -- The chain may move during insertion. Acquire the new instance by its returned slot.
    snap = self:snapshot()
    if not snap then return false, "no_master" end
    if position >= snap.count then return false, "identity_failed" end
    local fx = MONITOR_FX + position
    local guid = R.TrackFX_GetFXGUID(snap.master, fx)
    local original_ok, original = R.TrackFX_GetNamedConfigParm(snap.master, fx, "fx_name")
    if not guid or existing[guid] or not original_ok
      or not expected_original(kind, original) then
      return false, "identity_failed"
    end
    if R.TrackFX_SetNamedConfigParm(snap.master, fx, "renamed_name", label) ~= true then
      remove_created(guid, original)
      return false, "rename_failed"
    end
    self.owned[kind] = { guid = guid, original = original, label = label }
    local latest = self:snapshot()
    local entry, reason = latest and self:locate(latest, kind)
    if not entry then
      self.owned[kind] = nil
      remove_created(guid, original)
      return false, reason or "no_master"
    end
    local params, token = validate_params(R, latest, entry)
    -- REAPER can expose the sliders before the audio callback assigns a token.
    -- Remember only the exact instance we inserted; never claim token zero.
    if not params and token == "initializing" then
      local stored, store_reason = store_identity(self.owned[kind])
      if stored then
        self.owned[kind].initializing = true
        return false, "initializing"
      end
      self.owned[kind] = nil
      remove_created(guid, original)
      return false, store_reason
    end
    if not params then
      self.owned[kind] = nil
      remove_created(guid, original)
      return false, token
    end
    local claimed, claim_reason = self.control:claim(token)
    if not claimed then
      self.control:close()
      self.owned[kind] = nil
      remove_created(guid, original)
      return false, claim_reason
    end
    local stored, store_reason = store_identity(self.owned[kind])
    if not stored then
      self.control:close()
      self.owned[kind] = nil
      remove_created(guid, original)
      return false, store_reason
    end
    self.owned[kind].params = params
    self.pending_epoch = nil
    self.history_cursor, self.header_pending_at = nil, nil
    return true
  end

  function self:attach(reuse_only)
    reuse_only = reuse_only or self.restored_install
    if self.auto_upgrade_failed_reason and not saved_identity(R) then
      return false, self.auto_upgrade_failed_reason
    end
    if not reuse_only and recording_active(R) then
      -- A recording may use the loaded helper, but must not install or replace it.
      local ready, reason = self:attach(true)
      if ready or reason == "initializing" then return ready, reason end
      if reason == "missing" or reason == "crest_parameters_missing" or reason == "control_incompatible" then
        return false, "recording"
      end
      return false, reason
    end
    if not reuse_only then
      if not self.options.crest_source then return false, "crest_source_unreadable" end
      local installer = self.options.install_crest or install_crest
      local ok, reason, restored = installer(R, self.options.crest_source)
      if not ok then
        if not restored then return false, reason end
        -- A verified rollback permits reuse of the same compatible instance.
        -- Never replace or install an effect from this recovery path.
        local ready, reuse_reason = self:attach(true)
        if ready or reuse_reason == "initializing" then
          self.restored_install = true
          return ready, reuse_reason
        end
        return false, reason
      end
    end
    local snap = self:snapshot()
    if not snap then return false, "no_master" end
    local available, lease_reason = self.control:available()
    if not available then return false, lease_reason end
    local saved = saved_identity(R)
    if saved == false then return false, "identity_failed" end
    if self.owned.crest and saved and self.owned.crest.guid ~= saved.guid then
      return false, "changed"
    end
    local meters, remembered, labels = 0, 0, 0
    local candidate
    for slot = 0, snap.count - 1 do
      local fx = MONITOR_FX + slot
      local original_ok, original = R.TrackFX_GetNamedConfigParm(snap.master, fx, "fx_name")
      local label_ok, label = R.TrackFX_GetNamedConfigParm(snap.master, fx, "renamed_name")
      local guid = R.TrackFX_GetFXGUID(snap.master, fx)
      if meter_present(snap, fx, original_ok, original) then
        meters = meters + 1
        local ident_ok, ident = R.TrackFX_GetNamedConfigParm(snap.master, fx, "fx_ident")
        if original_ok and expected_original("crest", original) and ident_ok
            and ident == CREST_IDENT and label_ok and (label == "" or label == CREST_LABEL)
            and type(guid) == "string" and guid ~= "" then
          candidate = { guid = guid, original = original, tagged = label == CREST_LABEL }
        end
      end
      if label_ok and (label == LEGACY_NATIVE_LABEL or label == OLD_CREST_LABEL
          or label == CREST_LABEL) then labels = labels + 1 end
      if saved and guid == saved.guid then remembered = remembered + 1 end
      if label_ok and (label == LEGACY_NATIVE_LABEL or label == OLD_CREST_LABEL) then
        -- A saved current meter can use any display name, including an old
        -- session label. That label cannot identify an unsaved legacy effect.
        if not (saved and guid == saved.guid
            and matches_identity(R, snap.master, fx, saved, true)) then
          return false, "existing_instance"
        end
      end
    end
    if meters > 1 or remembered > 1 or labels > 1 then return false, "ambiguous" end
    -- The tag is lost at every REAPER restart, and the saved identity can be lost
    -- too. One meter loaded from yb-Reference's own installed file, with no other
    -- window holding the controls (checked above), is this app's: take it back
    -- as it is instead of refusing it. Nothing in Monitor FX changes.
    local adopting = not saved and not reuse_only and meters == 1 and candidate
      and labels == (candidate.tagged and 1 or 0)
    if adopting then
      local identity = { guid = candidate.guid, original = candidate.original, label = CREST_LABEL }
      local stored, store_reason = store_identity(identity)
      if not stored then return false, store_reason end
      saved, remembered = identity, 1
    end
    if saved then
      if remembered == 0 then return false, "missing" end
      self.owned.crest = self.owned.crest or saved
      local entry, found_reason = self:locate(snap, "crest")
      if not entry then return false, found_reason end
      if entry.slot ~= 0 then return false, "moved" end
      local params, token = validate_params(R, snap, entry)
      if not params then
        self.owned.crest.initializing = token == "initializing" or nil
        if token == "initializing" then return false, token end
        local older, older_reason = known_older_helper(snap, entry)
        if older_reason == "initializing" then return false, older_reason end
        if adopting or reuse_only or self.auto_upgrade_attempted or self.control_claimed
            or not older then return false, token end
        if recording_active(R) then return false, "recording" end
        self.auto_upgrade_attempted = true
        local repaired, repair_reason = self:repair(true)
        if not repaired then
          if repair_reason == "recording" then self.auto_upgrade_attempted = nil
          else self.auto_upgrade_failed_reason = repair_reason end
          return false, repair_reason
        end
        local added, add_reason = self:add(0)
        if not added then
          if add_reason ~= "initializing" and add_reason ~= "recording" then self.auto_upgrade_failed_reason = add_reason end
          return false, add_reason
        end
        self.control_claimed = true
        local ready, ready_reason = self:operational(self:snapshot())
        return ready ~= nil, ready_reason
      end
      if not params then return false, token end
      self.owned.crest.params = params
      if not self.control_claimed then
        local claimed, claim_reason = self.control:claim(token)
        if not claimed then return false, claim_reason end
        self.control_claimed = true
        self.history_cursor, self.header_pending_at = nil, nil
      end
      self.owned.crest.initializing = nil
    else
      if reuse_only then return false, "missing" end
      -- A meter that could not be taken back above cannot be verified as ours.
      if meters > labels then return false, "unknown_meter" end
      if meters > 0 or labels > 0 then return false, "existing_instance" end
      local added, add_reason = self:add(0)
      if not added then return false, add_reason end
      self.control_claimed = true
    end
    local ready, reason = self:operational(self:snapshot())
    return ready ~= nil, reason
  end

  -- A delayed master or control connection may retry a saved helper without any
  -- installer, insertion, deletion, or replacement of Monitor FX.
  function self:retry_attach()
    return self:attach(true)
  end

  -- Taking the meter offline and back online reloads it with a new token.
  -- Claim that token again only for the exact saved instance, still first in
  -- the chain and on the current protocol. The lease check still refuses a
  -- meter that another live yb-Reference window has taken over.
  function self:reclaim()
    if not self.control_claimed or not self.owned.crest then return false, "detached" end
    local snap = self:snapshot()
    if not snap then return false, "no_master" end
    local entry, reason = self:locate(snap, "crest")
    if not entry then return false, reason end
    if entry.slot ~= 0 then return false, "moved" end
    local params, token = validate_params(R, snap, entry)
    if not params then return false, token end
    if token == self.control.token then return false, "control_incompatible" end
    local available, lease_reason = self.control:available()
    if not available then return false, lease_reason end
    local closed, close_reason = self.control:close()
    if not closed then return false, close_reason end
    local claimed, claim_reason = self.control:claim(token)
    if not claimed then return false, claim_reason end
    self.owned.crest.params = params
    self.configuration = nil
    self.pending_epoch = nil
    self.history_cursor, self.header_pending_at = nil, nil
    return true
  end

  function self:supports_stopped_monitoring()
    local owned = self.owned.crest
    return owned ~= nil and owned.params ~= nil and owned.params.stopped_monitoring
  end

  function self:hold_capture(park_audio)
    if not park_audio or self.capture_parked then return self.control:renew() end
    -- A route under verification must not add unverified audio to this run.
    -- Keep the saved effect and the controller lease in place.
    local ok, reason = self.control:publish({active=false})
    if ok then self.capture_parked = true end
    return ok, reason
  end

  -- This is an explicit recovery path for leftovers after another app copy has
  -- closed. A session label alone never grants ownership to normal attach.
  function self:recover_leftovers()
    if next(self.owned) then return false, "existing_instance" end
    local available, lease_reason = self.control:available()
    if not available then return false, lease_reason end
    local saved = saved_identity(R)
    if saved == false then return false, "identity_failed" end
    local initial = self:snapshot()
    if not initial then return false, "no_master" end

    local function candidates(snap)
      local found, guids = {}, {}
      for slot = 0, snap.count - 1 do
        local fx = MONITOR_FX + slot
        local guid = R.TrackFX_GetFXGUID(snap.master, fx)
        if type(guid) ~= "string" or guid == "" or guids[guid] then
          return nil, "ambiguous"
        end
        guids[guid] = true
        local label_ok, label = R.TrackFX_GetNamedConfigParm(snap.master, fx, "renamed_name")
        local kind = label_ok and (label == LEGACY_NATIVE_LABEL and "native"
          or label == OLD_CREST_LABEL and "crest"
          or label == CREST_LABEL and "persistent")
        if kind then
          if found[kind] then return nil, "ambiguous" end
          local original_ok, original = R.TrackFX_GetNamedConfigParm(snap.master, fx, "fx_name")
          if not original_ok or not expected_original(kind == "persistent" and "crest" or kind, original) then
            return nil, "identity_failed"
          end
          if kind == "persistent" and saved
              and (guid ~= saved.guid or original ~= saved.original) then
            return nil, "identity_failed"
          end
          found[kind] = { guid = guid, original = original, label = label, slot = slot }
        end
      end
      return found
    end

    -- Recovery deletes labelled leftovers only. An untagged meter left behind is
    -- taken back by the next attach when it can be verified, and reported there
    -- when it cannot.
    local planned, reason = candidates(initial)
    if not planned then return false, reason end
    local order = {}
    for kind, item in pairs(planned) do
      order[#order + 1] = { kind = kind, slot = item.slot }
    end
    if #order == 0 then
      self.configuration = nil
      return true
    end
    table.sort(order, function(a, b) return a.slot > b.slot end)

    for _, item in ipairs(order) do
      local snap = self:snapshot()
      if not snap or snap.project ~= initial.project or snap.master ~= initial.master then
        return false, "changed"
      end
      local current, current_reason = candidates(snap)
      if not current then return false, current_reason end
      for kind, expected in pairs(planned) do
        local actual = current[kind]
        if not actual or actual.guid ~= expected.guid or actual.original ~= expected.original
            or actual.label ~= expected.label then
          return false, "changed"
        end
      end
      for kind in pairs(current) do
        if not planned[kind] then return false, "ambiguous" end
      end
      local target = current[item.kind]
      if recording_active(R) then return false, "recording" end
      if R.TrackFX_Delete(snap.master, MONITOR_FX + target.slot) ~= true then
        return false, "delete_failed"
      end
      if saved and target.guid == saved.guid then
        local cleared, clear_reason = store_identity(nil)
        if not cleared then return false, clear_reason end
        saved = nil
      end
      planned[item.kind] = nil
    end
    self.configuration = nil
    return true
  end

  local function read_outputs(snap, entry, params, names, result)
    for key in pairs(names) do
      if params[key] ~= nil then
        local value = R.TrackFX_GetParam(snap.master, entry.fx, params[key])
        result[key] = finite(value) and value or nil
      end
    end
  end

  local function analysis_inputs(snap, entry, profile)
    local count = profile and profile.count or 2
    if type(R.TrackFX_GetPinMappings) ~= "function" then
      return false, "input_mapping_unverified"
    end
    -- Pin mappings are effective masks. Include channels 65–128 so an extra
    -- summed input cannot hide outside the helper's configured channel count.
    for channel = 1, count do
      local pin = (profile and profile.outputs and profile.outputs[channel] or channel) - 1
      local low, high = R.TrackFX_GetPinMappings(snap.master, entry.fx, 0, pin)
      local upper_low, upper_high = R.TrackFX_GetPinMappings(
        snap.master, entry.fx, 0, pin + 0x1000000)
      low,high,upper_low,upper_high=pin_mask(low),pin_mask(high),pin_mask(upper_low),pin_mask(upper_high)
      if low == nil or high == nil or upper_low == nil or upper_high == nil then
        return false, "input_mapping_unverified"
      end
      local masks = {0, 0, 0, 0}
      masks[math.floor(pin / 32) + 1] = 1 << (pin % 32)
      if low ~= masks[1] or high ~= masks[2]
          or upper_low ~= masks[3] or upper_high ~= masks[4] then
        return false, "input_mapping_changed"
      end
    end
    return true
  end

  function self:operational(snap, profile)
    if type(profile)=="number" then profile={count=profile} end
    if not snap then return nil, "no_master" end
    if not self.owned.crest then return nil, "detached" end
    local scanned = scan_owned(snap)
    if scanned.meter_count > 1 or scanned.known_labels > 1 then
      return nil, "ambiguous"
    end
    local crest, reason = self:locate(snap, "crest", false, scanned)
    if not crest then return nil, reason end
    if crest.slot ~= 0 then return nil, "moved" end
    if self.owned.crest.initializing then
      local params, token = validate_params(R, snap, crest)
      if not params then return nil, token end
      -- Only attach may acquire control after the instance becomes ready.
      return nil, "initializing"
    end
    if not self.owned.crest.params then return nil, "crest_parameters_missing" end
    local params = self.owned.crest.params
    if R.TrackFX_GetParam(snap.master, crest.fx, params.control_protocol) ~= 4
        or R.TrackFX_GetParam(snap.master, crest.fx, params.instance_token)
          ~= self.control.token then
      return nil, "control_incompatible"
    end
    local inputs_ok, input_reason = analysis_inputs(snap, crest,
      profile or self.channel_profile)
    if not inputs_ok then
      if input_reason=='input_mapping_changed' or input_reason=='input_mapping_unverified' then
        self.input_mapping_blocked = true
      end
      return nil, input_reason
    end
    if self.input_mapping_blocked then
      local epoch = R.TrackFX_GetParam(snap.master, crest.fx, params.capture_epoch)
      if not valid_counter(epoch) then return nil, "capture_invalid" end
      local request = (self.reset_request + 1) % 1000000000
      -- Keep the current capture mode, but discard measurements accumulated
      -- while the speaker assignments could not be trusted.
      local published, publish_reason = self.control:publish({reset_request = request})
      if not published then return nil, publish_reason end
      self.reset_request, self.pending_epoch = request, epoch
      self.history_cursor, self.header_pending_at = nil, nil
      self.input_mapping_blocked = nil
    end
    return crest
  end

  function self:poll()
    local result = { status = "detached", ready = false }
    local snap = self:snapshot()
    if not snap then result.status = "no_master"; return result end
    result.project = snap.project
    result.playing = (R.GetPlayStateEx(snap.project) & 5) ~= 0
    result.position = R.GetPlayPositionEx(snap.project)
    local crest, reason = self:operational(snap)
    if not crest then result.status = reason; return result end
    local renewed, renew_reason = self.control:renew()
    if not renewed then result.status = renew_reason; return result end
    local params = self.owned.crest.params
    local coherent, readings, header, channel_header, channels = false, {}, nil, nil, nil
    local pair_header, pair_values
    for _ = 1, 3 do
      local before = R.TrackFX_GetParam(snap.master, crest.fx, params.lra_revision)
      local epoch = R.TrackFX_GetParam(snap.master, crest.fx, params.capture_epoch)
      if not valid_counter(epoch) then result.status = "capture_invalid"; return result end
      read_outputs(snap, crest, params, OUTPUT_NAMES, readings)
      header = {
        protocol = R.gmem_read(HISTORY_BASE),
        token = R.gmem_read(HISTORY_BASE + 1),
        session = R.gmem_read(HISTORY_BASE + 2),
        epoch = R.gmem_read(HISTORY_BASE + 3),
        latest = R.gmem_read(HISTORY_BASE + 4),
        m_max = R.gmem_read(HISTORY_BASE + 5),
        s_max = R.gmem_read(HISTORY_BASE + 6),
        capacity = R.gmem_read(HISTORY_BASE + 7),
      }
      channel_header = {
        protocol=R.gmem_read(CHANNEL_PACKET), token=R.gmem_read(CHANNEL_PACKET+1),
        session=R.gmem_read(CHANNEL_PACKET+2), epoch=R.gmem_read(CHANNEL_PACKET+3),
        sequence=R.gmem_read(CHANNEL_PACKET+4), count=R.gmem_read(CHANNEL_PACKET+5),
        known=R.gmem_read(CHANNEL_PACKET+6), revision=R.gmem_read(CHANNEL_PACKET+7),
        seal=R.gmem_read(CHANNEL_PACKET+8), inputs=R.gmem_read(CHANNEL_PACKET+9),
      }
      channels = {}
      if valid_counter(channel_header.count) and channel_header.count>=1 and channel_header.count<=8 then
        for channel=1,channel_header.count do
          local row=CHANNEL_ROWS+(channel-1)*CHANNEL_STRIDE
          local values={}
          for offset,field in ipairs(CHANNEL_FIELDS) do values[field]=R.gmem_read(row+offset-1) end
          channels[channel]=values
        end
      end
      pair_header={protocol=R.gmem_read(PAIR_PACKET), token=R.gmem_read(PAIR_PACKET+1),
        session=R.gmem_read(PAIR_PACKET+2), sequence=R.gmem_read(PAIR_PACKET+3),
        count=R.gmem_read(PAIR_PACKET+4)}
      pair_values={}
      if pair_header.protocol==1 and pair_header.count==channel_header.count
          and valid_counter(pair_header.count) and pair_header.count>=1 and pair_header.count<=8 then
        for index=1,pair_header.count*(pair_header.count-1)/2 do
          pair_values[index]=R.gmem_read(PAIR_VALUES+index-1)
        end
      end
      if not valid_counter(readings.capture_epoch) then
        result.status = "capture_invalid"
        return result
      end
      local after = R.TrackFX_GetParam(snap.master, crest.fx, params.lra_revision)
      if finite(before) and before >= 0 and before % 2 == 0 and before == after
          and epoch == readings.capture_epoch
          and readings.control_session == self.control.session
          and valid_counter(channel_header.seal) and channel_header.seal%2==0
          and channel_header.seal==R.gmem_read(CHANNEL_PACKET+8) then
        coherent = true
        break
      end
    end
    if not coherent then
      -- A publication crossed this poll, or it still belongs to a prior launch.
      result.status = "waiting"
      result.pending_publication = true
      return result
    end
    local expected_count=self.channel_profile and self.channel_profile.count or 2
    local expected_known=(not self.channel_profile or self.channel_profile.known~=false) and 1 or 0
    if channel_header.protocol~=4 or channel_header.token~=self.control.token
      or channel_header.session~=self.control.session
      or channel_header.epoch~=readings.capture_epoch
      or channel_header.sequence~=readings.sequence
      or channel_header.count~=expected_count or channel_header.known~=expected_known
      or channel_header.revision~=(self.layout_revision or 0) then
      local now=R.time_precise()
      self.channel_pending_at=self.channel_pending_at or now
      if now-self.channel_pending_at>=1.5 then result.status='capture_invalid'
      else result.status,result.pending_publication='waiting',true end
      return result
    end
    self.channel_pending_at=nil
    if not finite(channel_header.inputs) or channel_header.inputs%1~=0
      or channel_header.inputs<(self.channel_profile and self.channel_profile.max_output or channel_header.count) then
      result.status='channels_unavailable'
      return result
    end
    for _,channel in ipairs(channels) do
      for _,field in ipairs(CHANNEL_FIELDS) do
        if not finite(channel[field]) then result.status='capture_invalid'; return result end
      end
      if channel.peak_age<0 or channel.true_peak_age<0 then
        result.status='capture_invalid'; return result
      end
    end
    if self.pending_epoch ~= nil then
      if readings.capture_epoch == self.pending_epoch then
        result.status = "waiting"
        result.pending_publication = true
        return result
      end
      self.pending_epoch = nil
    end
    if header.protocol ~= 2 or header.token ~= self.control.token
        or header.session ~= self.control.session
        or header.epoch ~= readings.capture_epoch then
      local now = R.time_precise()
      self.header_pending_at = self.header_pending_at or now
      if now - self.header_pending_at >= 1.5 then
        result.status = 'capture_invalid'
      else
        result.status, result.pending_publication = 'waiting', true
      end
      return result
    end
    self.header_pending_at = nil
    if not valid_counter(header.latest) or header.capacity ~= HISTORY_CAPACITY
        or not finite(header.m_max) or not finite(header.s_max) then
      result.status = 'capture_invalid'
      return result
    end
    local cursor = self.history_cursor
    if not cursor or cursor.token ~= header.token or cursor.session ~= header.session
        or cursor.epoch ~= header.epoch then
      cursor = { token=header.token, session=header.session, epoch=header.epoch, sequence=0 }
    end
    local first = math.max(cursor.sequence + 1, header.latest - HISTORY_CAPACITY + 1)
    local history = {}
    for sequence = first, header.latest do
      local row = HISTORY_ROWS + ((sequence - 1) % HISTORY_CAPACITY) * HISTORY_STRIDE
      local seal = R.gmem_read(row)
      if seal ~= sequence then
        result.status, result.pending_publication = 'waiting', true
        return result
      end
      local point = {
        t = R.gmem_read(row + 1), m = R.gmem_read(row + 2),
        s = R.gmem_read(row + 3), i = R.gmem_read(row + 4),
      }
      if R.gmem_read(row) ~= sequence then
        result.status, result.pending_publication = 'waiting', true
        return result
      end
      if not finite(point.t) or point.t < 0 or not finite(point.m)
          or not finite(point.s) or not finite(point.i) then
        result.status = 'capture_invalid'
        return result
      end
      history[#history + 1] = point
    end
    if R.gmem_read(HISTORY_BASE) ~= header.protocol
        or R.gmem_read(HISTORY_BASE + 1) ~= header.token
        or R.gmem_read(HISTORY_BASE + 2) ~= header.session
        or R.gmem_read(HISTORY_BASE + 3) ~= header.epoch then
      result.status, result.pending_publication = 'waiting', true
      return result
    end
    for key, value in pairs(readings) do result[key] = value end
    result.channels=channels
    result.correlations=accept_pairs(pair_header,pair_values,channel_header,self.control,readings.sequence)
    local basic_only = result.lra_valid == -2
    result.sample_rate_supported, result.true_peak_available = not basic_only, not basic_only
    result.loudness_available=channel_header.known==1 and not basic_only
    if basic_only then
      local known, rate
      if R.GetAudioDeviceInfo then known, rate = R.GetAudioDeviceInfo("SRATE") end
      rate = tonumber(rate)
      if not (known and finite(rate) and rate > 0 and not SUPPORTED_RATES[rate]) then
        result.status = "lra_invalid"; return result
      end
    end
    if not basic_only and (not finite(result.lra_seconds) or result.lra_seconds < 0) then
      result.status = "lra_invalid"; return result
    end
    if not basic_only and result.lra_valid ~= 0 and result.lra_valid ~= 1 then
      result.status = "lra_invalid"; return result
    end
    if result.lra_valid == 1 and (not finite(result.lra_low)
        or not finite(result.lra_high) or not finite(result.lra)
        or result.lra_low > result.lra_high or result.lra < 0
        or math.abs(result.lra_high - result.lra_low - result.lra) > 1e-6) then
      result.status = "lra_invalid"; return result
    end
    -- All channel readings and loudness share one capture and reset boundary.
    result.m, result.s, result.i = result.live_m, result.live_s, result.integrated
    result.history, result.m_max, result.s_max = history, header.m_max, header.s_max
    if not result.loudness_available then
      result.m,result.s,result.i=nil,nil,nil
      result.history,result.m_max,result.s_max={},nil,nil
    end
    if basic_only then
      -- Unsupported calculations are distinct from a damaged audio packet.
      -- Raw RMS already waits for its complete 400 ms window in the helper.
      result.lra_seconds,result.lra,result.lra_low,result.lra_high=nil,nil,nil,nil
      result.tp_max,result.crest,result.crest_l,result.crest_r=nil,nil,nil,nil
      for _,side in ipairs({'l','r'}) do
        result['true_peak_'..side],result['live_true_peak_'..side],result['true_peak_age_'..side]=nil,nil,nil
      end
      for _,channel in ipairs(channels) do
        channel.true_peak,channel.live_true_peak,channel.true_peak_age,channel.crest=nil,nil,nil,nil
      end
    end
    -- Silence is a valid meter reading. The session owns audio-arrival timing.
    result.ready = (not result.loudness_available or (result.m ~= nil and result.s ~= nil and result.i ~= nil))
      and (basic_only or result.tp_max ~= nil) and finite(result.rms_l) and finite(result.rms_r)
      and finite(result.peak_l) and finite(result.peak_r)
      and result.sequence ~= nil
        and result.capture_epoch ~= nil and result.live_peak_l ~= nil
        and result.live_peak_r ~= nil and finite(result.peak_age_l)
        and result.peak_age_l >= 0 and finite(result.peak_age_r) and result.peak_age_r >= 0
        and (basic_only or (result.true_peak_l ~= nil and result.true_peak_r ~= nil
        and result.live_true_peak_l ~= nil and result.live_true_peak_r ~= nil
        and finite(result.true_peak_age_l) and result.true_peak_age_l >= 0
        and finite(result.true_peak_age_r) and result.true_peak_age_r >= 0))
    result.status = result.ready and "ready" or "capture_invalid"
    if result.ready then
      cursor.sequence = header.latest
      self.history_cursor = cursor
    end
    return result
  end

  function self:capture(mode, reset)
    local snap = self:snapshot()
    if not snap then return false, "no_master" end
    local crest, reason = self:operational(snap)
    if not crest then return false, reason or "detached" end
    if mode ~= 0 and mode ~= 1 and mode ~= 2 and not (mode == 3 and self:supports_stopped_monitoring()) then
      return false, "capture_invalid"
    end
    local epoch
    local request = self.reset_request
    if reset then
      epoch = R.TrackFX_GetParam(snap.master, crest.fx, self.owned.crest.params.capture_epoch)
      if not valid_counter(epoch) then return false, "capture_invalid" end
      request = (request + 1) % 1000000000
    end
    local published, publish_reason = self.control:publish({
      active = true, capture_mode = mode, reset_request = request,
    })
    if not published then return false, publish_reason end
    self.capture_parked = nil
    self.reset_request = request
    if reset then
      self.pending_epoch = epoch
      self.header_pending_at = nil
    end
    return true
  end

  function self:configure(prefs, project, profile)
    local policy = (prefs.auto_reset == 'On Play' and 1 or 0)
      | (prefs.seek_reset == 'Start New Run' and 2 or 0)
      | (prefs.loop_reset == 'Start New Run' and 4 or 0)
    local first, last = R.GetSet_LoopTimeRange2(project, false, true, 0, 0, false)
    local enabled = R.GetSetRepeatEx(project, -1) == 1 and 1 or 0
    local values = {reset_policy=policy,loop_start=first,loop_end=last,loop_enabled=enabled}
    profile=profile or {count=2,known=true,weights={1,1},signature='stereo'}
    local count=profile.count
    if type(count)~='number' or count%1~=0 or count<1 or count>8 then return false,'configuration_failed' end
    if profile.outputs~=nil and type(profile.outputs)~="table" then return false,"configuration_failed" end
    local weights=profile.weights or {}
    local outputs, selected, max_output = {}, {}, 0
    for channel=1,count do
      local output=profile.outputs==nil and channel or profile.outputs[channel]
      if not finite(output) or output%1~=0 or output<1 or output>128 or selected[output] then
        return false,'configuration_failed'
      end
      outputs[channel],selected[output]=output,true
      max_output=math.max(max_output,output)
    end
    local profile_signature=tostring(count)..':'..tostring(profile.known~=false)..':'..tostring(profile.signature or '')
    for channel=1,8 do
      local weight=(channel<=count and profile.known~=false) and weights[channel] or 0
      if weight~=0 and weight~=1 and weight~=1.41 then return false,'configuration_failed' end
      values['weight_'..channel]=weight
      values['output_'..channel]=outputs[channel] or channel
      profile_signature=profile_signature..':'..tostring(outputs[channel] or channel)
      profile_signature=profile_signature..':'..tostring(weight)
    end
    values.pair_mask=outline.neighbour_mask(profile)
    profile_signature=profile_signature..':'..tostring(values.pair_mask)
    local layout_changed=self.profile_signature~=profile_signature
    local revision=self.layout_revision or 0
    if layout_changed then revision=(revision+1)%1000000000 end
    values.channel_count,values.layout_known,values.layout_revision=count,profile.known~=false and 1 or 0,revision
    local signature=string.format('%d:%.9f:%.9f:%d:',policy,first,last,enabled)..profile_signature
    local snap = self:snapshot()
    if not snap then return false, 'no_master' end
    local crest, reason = self:operational(snap, {count=count,outputs=outputs})
    if not crest then return false, reason or 'detached' end
    if self.configuration == signature then return true end
    local published, publish_reason = self.control:publish(values)
    if not published then return false, publish_reason end
    self.configuration=signature
    local accepted = {}
    for key,value in pairs(profile) do accepted[key]=value end
    accepted.outputs,accepted.max_output=outputs,max_output
    self.channel_profile,self.profile_signature,self.layout_revision=accepted,profile_signature,revision
    return true
  end

  function self:close()
    local closed, reason = self.control:close()
    self.configuration = nil
    self.control_claimed = nil
    self.owned = {}
    self.pending_epoch = nil
    self.history_cursor = nil
    self.header_pending_at = nil
    self.reset_request = 0
    self.capture_parked = nil
    self.input_mapping_blocked = nil
    return closed, reason
  end

  -- Automatic repair is limited to a verified, enabled old helper in slot zero.
  -- Explicit repair retains its broader recovery behaviour.
  function self:repair(automatic)
    local available, lease_reason = self.control:available()
    if not available then return false, lease_reason end
    local saved = saved_identity(R)
    if saved == false then return false, "identity_failed" end
    if not saved then return self:close() end
    local snap = self:snapshot()
    if not snap then return false, "no_master" end
    self.owned.crest = saved
    local function locate_repair(current_snap)
      local found, found_reason = self:locate(current_snap, "crest", not automatic, nil, not automatic)
      if found and (found.identity_changed or found.label == "") then
        -- The missing label alone does not justify changing Monitor FX.
        local ident_ok, ident = R.TrackFX_GetNamedConfigParm(current_snap.master, found.fx, "fx_ident")
        if not ident_ok or ident ~= CREST_IDENT or (not validate_params(R, current_snap, found)
            and not known_older_helper(current_snap, found)) then
          return nil, "changed"
        end
      end
      return found, found_reason
    end
    local entry, reason = locate_repair(snap)
    if not entry and reason ~= "missing" then return false, reason end
    if automatic and (not entry or entry.slot ~= 0) then
      return false, entry and "moved" or "missing"
    end
    local count = 0
    for slot = 0, snap.count - 1 do
      local fx = MONITOR_FX + slot
      local ok, original = R.TrackFX_GetNamedConfigParm(snap.master, fx, "fx_name")
      local label_ok, label = R.TrackFX_GetNamedConfigParm(snap.master, fx, "renamed_name")
      if meter_present(snap, fx, ok, original) then count = count + 1 end
      if label_ok and (label == LEGACY_NATIVE_LABEL or label == OLD_CREST_LABEL) then
        return false, "existing_instance"
      end
    end
    if count > 1 then return false, "ambiguous" end
    if entry then
      local scanned = scan_owned(snap)
      local expected_labels = entry.label == CREST_LABEL and 1 or 0
      if scanned.known_labels ~= expected_labels then return false, "ambiguous" end
      if automatic and (scanned.crest == false or scanned.meter_count ~= 1
          or not known_older_helper(snap, entry)) then
        return false, "ambiguous"
      end
    end
    local closed, close_reason = self.control:close()
    if not closed then return false, close_reason end
    self.control_claimed = nil
    if entry then
      local latest = self:snapshot()
      local current, current_reason
      if latest then current, current_reason = locate_repair(latest) end
      if not current then return false, current_reason or "no_master" end
      local latest_saved = saved_identity(R)
      if latest.project ~= snap.project or latest.master ~= snap.master
          or not latest_saved or latest_saved == false
          or latest_saved.guid ~= saved.guid or latest_saved.original ~= saved.original
          or current.original ~= entry.original or current.label ~= entry.label then
        return false, "changed"
      end
      local scanned = scan_owned(latest)
      local expected_labels = current.label == CREST_LABEL and 1 or 0
      if scanned.crest == false or scanned.meter_count ~= 1
          or scanned.known_labels ~= expected_labels then
        return false, "ambiguous"
      end
      local still_available, available_reason = self.control:available()
      if not still_available then return false, available_reason end
      if recording_active(R) then return false, "recording" end
      if automatic then
        if current.slot ~= 0 then return false, "moved" end
        if not known_older_helper(latest, current) then return false, "changed" end
      end
      if R.TrackFX_Delete(latest.master, current.fx) ~= true then
        return false, "delete_failed"
      end
    end
    local forgotten, forget_reason = store_identity(nil)
    if not forgotten then return false, forget_reason end
    self.owned = {}
    self.pending_epoch = nil
    self.history_cursor, self.header_pending_at = nil, nil
    self.configuration = nil
    self.reset_request = 0
    self.input_mapping_blocked = nil
    if not automatic then
      self.auto_upgrade_attempted = nil
      self.auto_upgrade_failed_reason = nil
    end
    return true
  end

  return self
end

return host
