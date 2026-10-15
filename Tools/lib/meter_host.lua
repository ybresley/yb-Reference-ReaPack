-- Owns the analysis instances inserted by this Reference View session.
-- GUID and instance name checks keep it away from the user's other Monitor FX.

local host = {}
local install_crest = require("meter_installer").install
local MONITOR_FX = 0x1000000
local NATIVE_QUERY = "JS: Loudness Meter Peak/RMS/LUFS"
-- A newly installed helper may not yet appear in REAPER's description cache.
local CREST_QUERY = "JS: yb-Reference/yb-Reference_Meter.jsfx"
local NATIVE_LABEL = "yb-Reference True Peak (session)"
local CREST_LABEL = "yb-Reference Meter (session)"

local NATIVE_NAMES = {
  peak_mode = "Peak",
  reset_on_play = "Reset on playback start",
  mono = "Force mono analysis",
  automation = "Output loudness values as automation",
  m = "LUFS-M (output)",
  s = "LUFS-S (output)",
  i = "LUFS-I (output)",
  tp_max = "Peak/True peak dB (output)",
  rms = "RMS-M (output)",
  native_lra = "LRA (output)",
}
local NATIVE_OUTPUT_NAMES = {
  m = NATIVE_NAMES.m,
  s = NATIVE_NAMES.s,
  i = NATIVE_NAMES.i,
  tp_max = NATIVE_NAMES.tp_max,
  rms = NATIVE_NAMES.rms,
  native_lra = NATIVE_NAMES.native_lra,
}
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
  capture_mode = "Capture mode",
  reset_request = "Reset request",
  reset_policy = "Reset policy",
  loop_start = "Project loop start",
  loop_end = "Project loop end",
  loop_enabled = "Project loop enabled",
}

local function clean_name(name)
  return type(name) == "string" and name:gsub("^%-+", ""):lower() or ""
end

local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge
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
    or original == "yb-Reference/yb-Reference_Meter.jsfx"
    or original == "JS: yb-Reference/yb-Reference_Meter.jsfx"
    or original == "yb-Reference/yb-Reference_Meter"
    or original == "JS: yb-Reference/yb-Reference_Meter"
end

function host.new(R, options)
  R = R or reaper
  options = options or {}
  local self = { R = R, options = options, owned = {} }

  function self:snapshot()
    local project = R.EnumProjects and select(1, R.EnumProjects(-1, "")) or 0
    local master = R.GetMasterTrack(project)
    if not master then return nil end
    local count = R.TrackFX_GetRecCount(master)
    if type(count) ~= "number" then return nil end
    return { project = project, master = master, count = count }
  end

  local function scan_owned(snap)
    local found = {}
    local native_guid = self.owned.native and self.owned.native.guid
    local crest_guid = self.owned.crest and self.owned.crest.guid
    for slot = 0, snap.count - 1 do
      local guid = R.TrackFX_GetFXGUID(snap.master, MONITOR_FX + slot)
      if native_guid and guid == native_guid then
        if found.native ~= nil then
          found.native = false
        else
          found.native = { slot = slot, fx = MONITOR_FX + slot }
        end
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

  local function find_params(snap, fx, names, optional)
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
      if found[key] == nil and not (optional and optional[key]) then return nil end
    end
    return found
  end

  function self:add(kind, slot)
    local snap = self:snapshot()
    if not snap then return false, "no_master" end
    local existing = {}
    for index = 0, snap.count - 1 do
      local old_guid = R.TrackFX_GetFXGUID(snap.master, MONITOR_FX + index)
      if old_guid then existing[old_guid] = true end
    end
    local native = kind == "native"
    local query = native and NATIVE_QUERY or CREST_QUERY
    local label = native and NATIVE_LABEL or CREST_LABEL
    local position = R.TrackFX_AddByName(snap.master, query, true, -1000 - slot)
    if type(position) ~= "number" or position < 0 then
      return false, native and "insert_failed" or "crest_insert_failed"
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
    self.owned[kind] = { guid = guid, original = original, label = label }
    if R.TrackFX_SetNamedConfigParm(snap.master, fx, "renamed_name", label) ~= true then
      -- This is only the just-created instance; a failed rename cannot claim it.
      for index = 0, snap.count - 1 do
        local candidate = MONITOR_FX + index
        if R.TrackFX_GetFXGUID(snap.master, candidate) == guid then
          local ok, name = R.TrackFX_GetNamedConfigParm(snap.master, candidate, "fx_name")
          if ok and name == original then R.TrackFX_Delete(snap.master, candidate) end
          break
        end
      end
      self.owned[kind] = nil
      return false, "rename_failed"
    end
    local entry, reason = self:locate(self:snapshot(), kind)
    if not entry then return false, reason end
    local params = find_params(snap, entry.fx, native and NATIVE_NAMES or CREST_NAMES,
      native and { native_lra = true } or nil)
    if not params then return false, native and "parameters_missing" or "crest_parameters_missing" end
    self.owned[kind].params = params
    if native then
      self.owned.native.reset_on_play = 1
      local settings = {
        { params.peak_mode, 1 }, -- Cockos choice 1 is true peak.
        { params.reset_on_play, 1 }, -- Cockos resets before processing the first playback block.
        { params.mono, 0 }, -- Mono analysis subtracts 3 dB from the output readouts.
        { params.automation, 0 }, -- Reading the meter must not write envelopes.
      }
      for _, setting in ipairs(settings) do
        if R.TrackFX_SetParam(snap.master, entry.fx, setting[1], setting[2]) ~= true then
          return false, "configuration_failed"
        end
        local value = R.TrackFX_GetParam(snap.master, entry.fx, setting[1])
        if value ~= setting[2] then return false, "configuration_failed" end
      end
    end
    return true
  end

  function self:attach()
    if self.options.crest_source then
      local installer = self.options.install_crest or install_crest
      local ok, reason = installer(R, self.options.crest_source)
      if not ok then return false, reason end
    end
    local snap = self:snapshot()
    if not snap then return false, "no_master" end
    -- A surviving session belongs to an uncertain owner. Never stack another
    -- analyser on top of it or adopt it solely by name.
    for slot = 0, snap.count - 1 do
      local fx = MONITOR_FX + slot
      local ok, label = R.TrackFX_GetNamedConfigParm(snap.master, fx, "renamed_name")
      if ok and (label == NATIVE_LABEL or label == CREST_LABEL) then
        local kind = label == NATIVE_LABEL and "native" or "crest"
        if not self.owned[kind] or R.TrackFX_GetFXGUID(snap.master, fx) ~= self.owned[kind].guid then
          return false, "existing_instance"
        end
      end
    end
    for _, kind in ipairs({ "native", "crest" }) do
      if self.owned[kind] then
        local entry, reason = self:locate(snap, kind)
        if not entry then return false, reason end
      end
    end
    if not self.owned.native then
      local ok, reason = self:add("native", 0)
      if not ok then self:close(); return false, reason end
    end
    if self.options.crest_source and not self.owned.crest then
      local ok, reason = self:add("crest", 1)
      if not ok then self:close(); return false, reason end
    end
    local ready, _, reason = self:operational(self:snapshot())
    return ready ~= nil, reason
  end

  -- This is an explicit recovery path for leftovers after another app copy has
  -- closed. A session label alone never grants ownership to normal attach.
  function self:recover_leftovers()
    if next(self.owned) then return false, "existing_instance" end
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
        local kind = label_ok and (label == NATIVE_LABEL and "native"
          or label == CREST_LABEL and "crest")
        if kind then
          if found[kind] then return nil, "ambiguous" end
          local original_ok, original = R.TrackFX_GetNamedConfigParm(snap.master, fx, "fx_name")
          if not original_ok or not expected_original(kind, original) then
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

  local function native_settings_ok(snap, entry, params)
    return R.TrackFX_GetParam(snap.master, entry.fx, params.peak_mode) == 1
      and R.TrackFX_GetParam(snap.master, entry.fx, params.reset_on_play) == self.owned.native.reset_on_play
      and R.TrackFX_GetParam(snap.master, entry.fx, params.mono) == 0
      and R.TrackFX_GetParam(snap.master, entry.fx, params.automation) == 0
  end

  function self:operational(snap)
    if not self.owned.native then return nil, nil, "detached" end
    local scanned = scan_owned(snap)
    local native, reason = self:locate(snap, "native", false, scanned)
    if not native then return nil, nil, reason end
    if native.slot ~= 0 then return nil, nil, "moved" end
    if not self.owned.native.params then return nil, nil, "parameters_missing" end
    if not native_settings_ok(snap, native, self.owned.native.params) then
      return nil, nil, "configuration_changed"
    end
    if not self.options.crest_source then return native, nil end
    local crest, crest_reason = self:locate(snap, "crest", false, scanned)
    if not crest then return nil, nil, "crest_" .. crest_reason end
    if crest.slot ~= 1 then return nil, nil, "crest_moved" end
    if not self.owned.crest.params then return nil, nil, "crest_parameters_missing" end
    return native, crest
  end

  function self:poll()
    local result = { status = "detached", ready = false }
    local snap = self:snapshot()
    if not snap then result.status = "no_master"; return result end
    result.project = snap.project
    result.playing = (R.GetPlayStateEx(snap.project) & 1) ~= 0
    result.position = R.GetPlayPositionEx(snap.project)
    local native, crest, reason = self:operational(snap)
    if not native then result.status = reason; return result end
    read_outputs(snap, native, self.owned.native.params, NATIVE_OUTPUT_NAMES, result)
    if crest then
      local params = self.owned.crest.params
      local coherent = false
      for _ = 1, 3 do
        local before = R.TrackFX_GetParam(snap.master, crest.fx, params.lra_revision)
        local epoch = R.TrackFX_GetParam(snap.master, crest.fx, params.capture_epoch)
        read_outputs(snap, crest, params, CREST_NAMES, result)
        local after = R.TrackFX_GetParam(snap.master, crest.fx, params.lra_revision)
        if finite(before) and before >= 0 and before % 2 == 0 and before == after
            and epoch == result.capture_epoch then
          coherent = true
          break
        end
      end
      if not coherent then
        -- A publication crossed this poll. Wait for a complete pair of endpoints.
        result.status = "waiting"
        result.pending_publication = true
        return result
      end
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
      -- M/S share the stereo helper's weighting and arrive while their windows fill.
      result.m, result.s, result.i = result.live_m, result.live_s, result.integrated
    end
    -- Silence is a valid meter reading. The session owns audio-arrival timing.
    result.ready = result.m ~= nil and result.s ~= nil and result.i ~= nil
      and result.tp_max ~= nil and result.rms ~= nil
      and (not self.options.crest_source or (result.sequence ~= nil
        and result.capture_epoch ~= nil and result.live_peak_l ~= nil
        and result.live_peak_r ~= nil and finite(result.peak_age_l)
        and result.peak_age_l >= 0 and finite(result.peak_age_r) and result.peak_age_r >= 0
        and result.true_peak_l ~= nil and result.true_peak_r ~= nil
        and result.live_true_peak_l ~= nil and result.live_true_peak_r ~= nil
        and finite(result.true_peak_age_l) and result.true_peak_age_l >= 0
        and finite(result.true_peak_age_r) and result.true_peak_age_r >= 0))
    result.status = result.ready and "ready" or "waiting"
    return result
  end

  function self:capture(mode, reset)
    local snap = self:snapshot()
    if not snap then return false, "no_master" end
    local _, crest, reason = self:operational(snap)
    if not crest then return false, reason or "detached" end
    local params = self.owned.crest.params
    if mode ~= 0 and mode ~= 1 and mode ~= 2 then return false, "capture_invalid" end
    if reset then
      local request = (R.TrackFX_GetParam(snap.master, crest.fx, params.reset_request) + 1) % 1000000000
      if R.TrackFX_SetParam(snap.master, crest.fx, params.reset_request, request) ~= true then
        return false, "configuration_failed"
      end
    end
    if R.TrackFX_SetParam(snap.master, crest.fx, params.capture_mode, mode) ~= true then
      return false, "configuration_failed"
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
    if self.configuration == signature then return true end
    local snap = self:snapshot()
    if not snap then return false, 'no_master' end
    local native, crest, reason = self:operational(snap)
    if not crest then return false, reason or 'detached' end
    for key,value in pairs(values) do
      if R.TrackFX_SetParam(snap.master,crest.fx,self.owned.crest.params[key],value) ~= true then
        return false, 'configuration_failed'
      end
    end
    if R.TrackFX_SetParam(snap.master,native.fx,self.owned.native.params.reset_on_play,
        prefs.auto_reset == 'On Play' and 1 or 0) ~= true then return false,'configuration_failed' end
    self.owned.native.reset_on_play = prefs.auto_reset == 'On Play' and 1 or 0
    self.configuration=signature
    return true
  end

  function self:reset_true_peak()
    local snap=self:snapshot()
    if not snap then return false,'no_master' end
    local native,_,reason=self:operational(snap)
    if not native then return false,reason end
    if R.TrackFX_Delete(snap.master,native.fx) ~= true then return false,'delete_failed' end
    self.owned.native=nil
    self.configuration=nil
    return self:add('native',native.slot)
  end

  function self:show_native()
    local snap = self:snapshot()
    if not snap then return false, "no_master" end
    local entry, reason = self:locate(snap, "native")
    if not entry then return false, reason end
    R.TrackFX_Show(snap.master, entry.fx, 3)
    return true
  end

  function self:close()
    self.configuration = nil
    local snap = self:snapshot()
    if not snap then return false, "no_master" end
    local entries = {}
    for kind in pairs(self.owned) do
      local entry, reason = self:locate(snap, kind, true)
      if entry then entries[#entries + 1] = { kind = kind, entry = entry }
      elseif reason == "missing" then self.owned[kind] = nil
      else return false, reason end
    end
    table.sort(entries, function(a, b) return a.entry.slot > b.entry.slot end)
    for _, item in ipairs(entries) do
      -- Reacquire before each deletion, since the preceding deletion shifts slots.
      snap = self:snapshot()
      local entry, reason = self:locate(snap, item.kind, true)
      if not entry then return false, reason end
      if R.TrackFX_Delete(snap.master, entry.fx) ~= true then return false, "delete_failed" end
      self.owned[item.kind] = nil
    end
    return true
  end

  function self:reset()
    self.configuration = nil
    local snap = self:snapshot()
    if not snap then return false, "no_master" end
    local operational, _, reason = self:operational(snap)
    if not operational then return false, reason end
    local positions = {}
    for kind in pairs(self.owned) do
      local entry, reason = self:locate(snap, kind)
      if not entry then return false, reason end
      positions[#positions + 1] = { kind = kind, slot = entry.slot }
    end
    if #positions == 0 then return false, "detached" end
    table.sort(positions, function(a, b) return a.slot > b.slot end)
    for _, item in ipairs(positions) do
      snap = self:snapshot()
      local entry, reason = self:locate(snap, item.kind)
      if not entry then return false, reason end
      if R.TrackFX_Delete(snap.master, entry.fx) ~= true then return false, "delete_failed" end
      self.owned[item.kind] = nil
    end
    table.sort(positions, function(a, b) return a.slot < b.slot end)
    for _, item in ipairs(positions) do
      local ok, reason = self:add(item.kind, item.slot)
      if not ok then self:close(); return false, reason end
    end
    return true
  end

  return self
end

return host
