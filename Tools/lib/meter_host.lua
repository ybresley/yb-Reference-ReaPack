-- Owns the stereo analysis instance by persisted GUID and exact identity.

local host = {}
local install_crest = require("meter_installer").install
local meter_control = require("meter_control")
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

function host.new(R, options)
  R = R or reaper
  options = options or {}
  local self = { R = R, options = options, owned = {}, control = meter_control.new(R),
    reset_request = 0 }

  local function saved_identity()
    local guid = R.GetExtState(EXT_SECTION, EXT_GUID)
    local original = R.GetExtState(EXT_SECTION, EXT_ORIGINAL)
    if guid == "" and original == "" then return nil end
    if type(guid) ~= "string" or guid == "" or not expected_original("crest", original) then
      return false
    end
    return { guid = guid, original = original, label = CREST_LABEL }
  end

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

  function self:locate(snap, kind, allow_disabled, scanned)
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
    local original_ok, original = R.TrackFX_GetNamedConfigParm(snap.master, match.fx, "fx_name")
    local renamed_ok, renamed = R.TrackFX_GetNamedConfigParm(snap.master, match.fx, "renamed_name")
    if not original_ok or not renamed_ok or original ~= identity.original
      or renamed ~= identity.label then
      return nil, "changed"
    end
    if not allow_disabled then
      if R.TrackFX_GetOffline(snap.master, match.fx) then return nil, "offline" end
      if not R.TrackFX_GetEnabled(snap.master, match.fx) then return nil, "bypassed" end
    end
    return match
  end

  local function find_params(snap, fx, names)
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
    return found
  end

  local function validate_params(snap, entry)
    local params = find_params(snap, entry.fx, CREST_NAMES)
    if not params then return nil, "crest_parameters_missing" end
    local protocol = R.TrackFX_GetParam(snap.master, entry.fx, params.control_protocol)
    local token = R.TrackFX_GetParam(snap.master, entry.fx, params.instance_token)
    if protocol ~= 2 or not valid_counter(token) then
      return nil, "control_incompatible"
    end
    if token == 0 then return nil, "initializing" end
    return params, token
  end

  local function known_older_helper(snap, entry)
    -- Both shipped layouts have an exact signature. Unknown controls stay manual.
    local params = find_params(snap, entry.fx, PROTOCOL_ONE_NAMES)
    if params then
      if R.TrackFX_GetParam(snap.master, entry.fx,
          params.control_protocol) ~= 1 then return false end
      local token = R.TrackFX_GetParam(snap.master, entry.fx, params.instance_token)
      if not valid_counter(token) or token == 0 then return false end
    else
      params = find_params(snap, entry.fx, OLD_CREST_NAMES)
      if not params then return false end
    end
    local known = {}
    for _, param in pairs(params) do known[param] = true end
    if R.TrackFX_GetParamFromIdent then
      for _, ident in ipairs({ ":bypass", ":wet", ":delta" }) do
        local param = R.TrackFX_GetParamFromIdent(snap.master, entry.fx, ident)
        if type(param) == "number" and param >= 0 then known[param] = true end
      end
    end
    for param = 0, R.TrackFX_GetNumParams(snap.master, entry.fx) - 1 do
      if not known[param] then return false end
    end
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
    return ok and current == original and R.TrackFX_Delete(snap.master, match) == true
  end

  function self:add(slot)
    local kind = "crest"
    local snap = self:snapshot()
    if not snap then return false, "no_master" end
    local existing = {}
    for index = 0, snap.count - 1 do
      local old_guid = R.TrackFX_GetFXGUID(snap.master, MONITOR_FX + index)
      if old_guid then existing[old_guid] = true end
    end
    local label = CREST_LABEL
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
    local params, token = validate_params(latest, entry)
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
    if self.auto_upgrade_failed_reason and not saved_identity() then
      return false, self.auto_upgrade_failed_reason
    end
    if not reuse_only then
      if not self.options.crest_source then return false, "crest_source_unreadable" end
      local installer = self.options.install_crest or install_crest
      local ok, reason = installer(R, self.options.crest_source)
      if not ok then return false, reason end
    end
    local snap = self:snapshot()
    if not snap then return false, "no_master" end
    local available, lease_reason = self.control:available()
    if not available then return false, lease_reason end
    local saved = saved_identity()
    if saved == false then return false, "identity_failed" end
    if self.owned.crest and saved and self.owned.crest.guid ~= saved.guid then
      return false, "changed"
    end
    local meters, remembered, labels = 0, 0, 0
    for slot = 0, snap.count - 1 do
      local fx = MONITOR_FX + slot
      local original_ok, original = R.TrackFX_GetNamedConfigParm(snap.master, fx, "fx_name")
      local label_ok, label = R.TrackFX_GetNamedConfigParm(snap.master, fx, "renamed_name")
      local guid = R.TrackFX_GetFXGUID(snap.master, fx)
      if meter_present(snap, fx, original_ok, original) then meters = meters + 1 end
      if label_ok and (label == LEGACY_NATIVE_LABEL or label == OLD_CREST_LABEL
          or label == CREST_LABEL) then labels = labels + 1 end
      if saved and guid == saved.guid then remembered = remembered + 1 end
      if label_ok and (label == LEGACY_NATIVE_LABEL or label == OLD_CREST_LABEL) then
        return false, "existing_instance"
      end
    end
    if meters > 1 or remembered > 1 or labels > 1 then return false, "ambiguous" end
    if saved then
      if remembered == 0 then return false, "missing" end
      self.owned.crest = self.owned.crest or saved
      local entry, found_reason = self:locate(snap, "crest")
      if not entry then return false, found_reason end
      if entry.slot ~= 0 then return false, "moved" end
      local params, token = validate_params(snap, entry)
      if not params then
        self.owned.crest.initializing = token == "initializing" or nil
        if token == "initializing" then return false, token end
        if reuse_only or self.auto_upgrade_attempted or self.control_claimed
            or not known_older_helper(snap, entry) then return false, token end
        self.auto_upgrade_attempted = true
        local repaired, repair_reason = self:repair(true)
        if not repaired then
          self.auto_upgrade_failed_reason = repair_reason
          return false, repair_reason
        end
        local added, add_reason = self:add(0)
        if not added then
          if add_reason ~= "initializing" then self.auto_upgrade_failed_reason = add_reason end
          return false, add_reason
        end
        self.control_claimed = true
        local ready, ready_reason = self:operational(self:snapshot())
        return ready ~= nil, ready_reason
      end
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

  -- This is an explicit recovery path for leftovers after another app copy has
  -- closed. A session label alone never grants ownership to normal attach.
  function self:recover_leftovers()
    if next(self.owned) then return false, "existing_instance" end
    local available, lease_reason = self.control:available()
    if not available then return false, lease_reason end
    local saved = saved_identity()
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

    local planned, reason = candidates(initial)
    if not planned then return false, reason end
    local order = {}
    for kind, item in pairs(planned) do
      order[#order + 1] = { kind = kind, slot = item.slot }
    end
    if #order == 0 then self.configuration = nil; return true end
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

  function self:operational(snap)
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
      local params, token = validate_params(snap, crest)
      if not params then return nil, token end
      -- Only attach may acquire control after the instance becomes ready.
      return nil, "initializing"
    end
    if not self.owned.crest.params then return nil, "crest_parameters_missing" end
    local params = self.owned.crest.params
    if R.TrackFX_GetParam(snap.master, crest.fx, params.control_protocol) ~= 2
        or R.TrackFX_GetParam(snap.master, crest.fx, params.instance_token)
          ~= self.control.token then
      return nil, "control_incompatible"
    end
    return crest
  end

  function self:poll()
    local result = { status = "detached", ready = false }
    local snap = self:snapshot()
    if not snap then result.status = "no_master"; return result end
    result.project = snap.project
    result.playing = (R.GetPlayStateEx(snap.project) & 1) ~= 0
    result.position = R.GetPlayPositionEx(snap.project)
    local crest, reason = self:operational(snap)
    if not crest then result.status = reason; return result end
    local renewed, renew_reason = self.control:renew()
    if not renewed then result.status = renew_reason; return result end
    local params = self.owned.crest.params
    local coherent, readings, header = false, {}, nil
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
      if not valid_counter(readings.capture_epoch) then
        result.status = "capture_invalid"
        return result
      end
      local after = R.TrackFX_GetParam(snap.master, crest.fx, params.lra_revision)
      if finite(before) and before >= 0 and before % 2 == 0 and before == after
          and epoch == readings.capture_epoch
          and readings.control_session == self.control.session then
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
    if result.lra_valid == -1 then result.status = "lra_invalid"; return result end
    if not finite(result.lra_seconds) or result.lra_seconds < 0 then
      result.status = "lra_invalid"; return result
    end
    if result.lra_valid ~= 0 and result.lra_valid ~= 1 then
      result.status = "lra_invalid"; return result
    end
    if result.lra_valid == 1 and (not finite(result.lra_low)
        or not finite(result.lra_high) or not finite(result.lra)
        or result.lra_low > result.lra_high or result.lra < 0
        or math.abs(result.lra_high - result.lra_low - result.lra) > 1e-6) then
      result.status = "lra_invalid"; return result
    end
    -- Every reading comes from the same stereo capture and reset boundary.
    result.m, result.s, result.i = result.live_m, result.live_s, result.integrated
    result.history, result.m_max, result.s_max = history, header.m_max, header.s_max
    -- Silence is a valid meter reading. The session owns audio-arrival timing.
    result.ready = result.m ~= nil and result.s ~= nil and result.i ~= nil
      and result.tp_max ~= nil and result.rms_l ~= nil and result.rms_r ~= nil
      and result.sequence ~= nil
        and result.capture_epoch ~= nil and result.live_peak_l ~= nil
        and result.live_peak_r ~= nil and finite(result.peak_age_l)
        and result.peak_age_l >= 0 and finite(result.peak_age_r) and result.peak_age_r >= 0
        and result.true_peak_l ~= nil and result.true_peak_r ~= nil
        and result.live_true_peak_l ~= nil and result.live_true_peak_r ~= nil
        and finite(result.true_peak_age_l) and result.true_peak_age_l >= 0
        and finite(result.true_peak_age_r) and result.true_peak_age_r >= 0
    result.status = result.ready and "ready" or "waiting"
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
    if mode ~= 0 and mode ~= 1 and mode ~= 2 then return false, "capture_invalid" end
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
    self.reset_request = request
    if reset then
      self.pending_epoch = epoch
      self.header_pending_at = nil
    end
    return true
  end

  function self:configure(prefs, project)
    local policy = (prefs.auto_reset == 'On Play' and 1 or 0)
      | (prefs.seek_reset == 'Start New Run' and 2 or 0)
      | (prefs.loop_reset == 'Start New Run' and 4 or 0)
    local first, last = R.GetSet_LoopTimeRange2(project, false, true, 0, 0, false)
    local enabled = R.GetSetRepeatEx(project, -1) == 1 and 1 or 0
    local values = {reset_policy=policy,loop_start=first,loop_end=last,loop_enabled=enabled}
    local signature = string.format('%d:%.9f:%.9f:%d',policy,first,last,enabled)
    local snap = self:snapshot()
    if not snap then return false, 'no_master' end
    local crest, reason = self:operational(snap)
    if not crest then return false, reason or 'detached' end
    if self.configuration == signature then return true end
    local published, publish_reason = self.control:publish(values)
    if not published then return false, publish_reason end
    self.configuration=signature
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
    return closed, reason
  end

  -- Automatic repair is limited to a verified, enabled old helper in slot zero.
  -- Explicit repair retains its broader recovery behaviour.
  function self:repair(automatic)
    local available, lease_reason = self.control:available()
    if not available then return false, lease_reason end
    local saved = saved_identity()
    if saved == false then return false, "identity_failed" end
    if not saved then return self:close() end
    local snap = self:snapshot()
    if not snap then return false, "no_master" end
    self.owned.crest = saved
    local entry, reason = self:locate(snap, "crest", not automatic)
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
    if count > 1 or (not entry and count > 0) then return false, "ambiguous" end
    if automatic then
      local scanned = scan_owned(snap)
      if scanned.crest == false or scanned.meter_count ~= 1
          or scanned.known_labels ~= 1 or not known_older_helper(snap, entry) then
        return false, "ambiguous"
      end
    end
    local closed, close_reason = self.control:close()
    if not closed then return false, close_reason end
    self.control_claimed = nil
    if entry then
      local latest = self:snapshot()
      local current, current_reason
      if latest then current, current_reason = self:locate(latest, "crest", not automatic) end
      if not current then return false, current_reason or "no_master" end
      if automatic then
        local latest_saved = saved_identity()
        local scanned = scan_owned(latest)
        if not latest_saved or latest_saved == false
            or latest_saved.guid ~= saved.guid or latest_saved.original ~= saved.original then
          return false, "changed"
        end
        if current.slot ~= 0 then return false, "moved" end
        if scanned.crest == false or scanned.meter_count ~= 1
            or scanned.known_labels ~= 1 then return false, "ambiguous" end
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
    if not automatic then
      self.auto_upgrade_attempted = nil
      self.auto_upgrade_failed_reason = nil
    end
    return true
  end

  return self
end

return host
