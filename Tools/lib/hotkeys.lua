-- REAPER shortcut integration for yb-Reference's companion actions.
--
-- REAPER remains the owner of shortcut storage, modifier handling, scope and
-- conflict resolution. This adapter registers the actions, reads their native
-- descriptions and opens REAPER's own assignment dialog. Companion actions only
-- leave short-lived messages for the currently open copy of this installation.

local hotkeys = {}

local MAIN_SECTION_ID = 0
local EXT_SECTION = "yb-Reference Hotkeys"
local LEASE_PREFIX = "lease_"
local QUEUE_PREFIX = "queue_"
local HEARTBEAT_TIMEOUT = 2.0
local MAX_QUEUE = 64


local COMMANDS = {
  -- Keep the original PlayPause filename so existing Play assignments survive
  -- the split. Its action is now the dedicated Play trigger.
  { id = "play", label = "Play", section = "Reference View",
    script = "yb-Reference_Hotkey_PlayPause.lua", intent = { type = "trigger_play", target = "main" } },
  { id = "pause", label = "Pause / Resume", section = "Reference View",
    script = "yb-Reference_Hotkey_PauseResume.lua", intent = { type = "toggle_pause", target = "main" } },
  { id = "latch", label = "Latch", section = "Reference View",
    -- Keep the 0.4.0 action path so existing Latch assignments remain attached.
    script = "yb-Reference_ToggleReferenceMode.lua", intent = { type = "toggle_reference" } },
  { id = "mono", label = "Mono", section = "Reference View",
    script = "yb-Reference_Hotkey_ToggleMono.lua", intent = { type = "toggle_mono" } },
  { id = "loop", label = "Loop", section = "Reference View",
    script = "yb-Reference_Hotkey_ToggleLoop.lua", intent = { type = "toggle_loop" } },
  { id = "next", label = "Next Pinned Reference", section = "Reference View",
    script = "yb-Reference_Hotkey_NextPinnedReference.lua", intent = { type = "step_reference", delta = 1 } },
  { id = "previous", label = "Previous Pinned Reference", section = "Reference View",
    script = "yb-Reference_Hotkey_PreviousPinnedReference.lua", intent = { type = "step_reference", delta = -1 } },
  { id = "filter_sub", label = "Sub", section = "Filter Bands",
    script = "yb-Reference_Hotkey_ToggleFilterSub.lua", intent = { type = "toggle_monitor_filter_preset", id = "sub" } },
  { id = "filter_bass", label = "Bass", section = "Filter Bands",
    script = "yb-Reference_Hotkey_ToggleFilterBass.lua", intent = { type = "toggle_monitor_filter_preset", id = "bass" } },
  { id = "filter_low_mid", label = "Low Mid", section = "Filter Bands",
    script = "yb-Reference_Hotkey_ToggleFilterLowMid.lua", intent = { type = "toggle_monitor_filter_preset", id = "low_mid" } },
  { id = "filter_mid", label = "Mid", section = "Filter Bands",
    script = "yb-Reference_Hotkey_ToggleFilterMid.lua", intent = { type = "toggle_monitor_filter_preset", id = "mid" } },
  { id = "filter_high", label = "High", section = "Filter Bands",
    script = "yb-Reference_Hotkey_ToggleFilterHigh.lua", intent = { type = "toggle_monitor_filter_preset", id = "high" } },
  { id = "library", label = "Open / Close Library", section = "Windows",
    script = "yb-Reference_Hotkey_ToggleLibrary.lua", intent = { type = "toggle_browser" } },
  { id = "settings", label = "Open / Close Settings", section = "Windows",
    script = "yb-Reference_Hotkey_ToggleSettings.lua", intent = { type = "toggle_settings" } },
}

local BY_ID = {}
for i = 1, #COMMANDS do BY_ID[COMMANDS[i].id] = COMMANDS[i] end

local state = {
  root = nil,
  identity = nil,
  key_suffix = nil,
  session = nil,
  section = nil,
  command_ids = {},
  available = false,
  error = nil,
}

local function now()
  return reaper.time_precise()
end

local function separator()
  return package.config:sub(1, 1)
end

local function clean_root(root)
  if type(root) ~= "string" or root == "" then return nil end
  local sep = separator()
  root = root:gsub("[/\\]", sep)
  local drive_root = sep == "\\" and root:match("^%a:\\$")
  if not drive_root then root = root:gsub("[/\\]+$", "") end
  return root
end

local function root_identity(root)
  root = clean_root(root)
  if not root then return nil end
  -- yb-Reference is Windows-only, so case and slash spelling do not identify a
  -- different installation.
  return root:lower()
end

local function identity_key(identity)
  local hash = 2166136261
  for i = 1, #identity do
    hash = ((hash ~ identity:byte(i)) * 16777619) & 0xffffffff
  end
  return string.format("%08x", hash)
end

local function lease_key(suffix)
  return LEASE_PREFIX .. suffix
end

local function queue_key(suffix)
  return QUEUE_PREFIX .. suffix
end

local function encode_lease(identity, session, heartbeat)
  return table.concat({ identity, session, string.format("%.17g", heartbeat) }, "\t")
end

local function decode_lease(value)
  if type(value) ~= "string" or value == "" then return nil end
  local identity, session, heartbeat = value:match("^([^\t]+)\t([^\t]+)\t([^\t]+)$")
  heartbeat = tonumber(heartbeat)
  if not identity or not session or not heartbeat then return nil end
  return { identity = identity, session = session, heartbeat = heartbeat }
end

local function decode_queue(value)
  if type(value) ~= "string" or value == "" then return nil, {} end
  local fields = {}
  for field in value:gmatch("[^\t]+") do fields[#fields + 1] = field end
  if #fields == 0 then return nil, {} end
  local session = fields[1]
  table.remove(fields, 1)
  return session, fields
end

local function encode_queue(session, ids)
  if #ids == 0 then return "" end
  return session .. "\t" .. table.concat(ids, "\t")
end

local function get_ext(key)
  return reaper.GetExtState(EXT_SECTION, key)
end

local function set_ext(key, value)
  reaper.SetExtState(EXT_SECTION, key, value, false)
end

local function delete_ext(key)
  reaper.DeleteExtState(EXT_SECTION, key, false)
end

local function own_lease()
  if not state.session then return nil end
  local lease = decode_lease(get_ext(lease_key(state.key_suffix)))
  if not lease or lease.identity ~= state.identity or lease.session ~= state.session then
    return nil
  end
  return lease
end

local function touch_lease()
  if not own_lease() then return false end
  set_ext(lease_key(state.key_suffix), encode_lease(state.identity, state.session, now()))
  return true
end

local function copy_intent(intent)
  local result = {}
  for key, value in pairs(intent) do result[key] = value end
  return result
end

local function native_api_available()
  local required = {
    "AddRemoveReaScript", "SectionFromUniqueID", "CountActionShortcuts",
    "GetActionShortcutDesc", "DoActionShortcutDialog", "DeleteActionShortcut",
    "GetMainHwnd",
  }
  for i = 1, #required do
    if type(reaper[required[i]]) ~= "function" then return false end
  end
  return true
end

local function read_shortcuts(command_id)
  local shortcuts = {}
  local count = reaper.CountActionShortcuts(state.section, command_id)
  for index = 0, count - 1 do
    local ok, description = reaper.GetActionShortcutDesc(state.section, command_id, index)
    if not ok then error("Reaper did not return a counted shortcut") end
    shortcuts[#shortcuts + 1] = { index = index, description = description }
  end
  return shortcuts
end

local function make_snapshot()
  local snapshot = { commands = {}, available = state.available, error = state.error }
  for i = 1, #COMMANDS do
    local definition = COMMANDS[i]
    local item = {
      id = definition.id,
      label = definition.label,
      section = definition.section,
      shortcuts = {},
    }
    local command_id = state.command_ids[definition.id]
    if state.available and command_id then
      local ok, shortcuts = pcall(read_shortcuts, command_id)
      if ok then
        item.shortcuts = shortcuts
      else
        snapshot.available = false
        snapshot.error = "Reaper couldn't read the current shortcuts."
      end
    end
    snapshot.commands[#snapshot.commands + 1] = item
  end
  return snapshot
end

local function current_description(command_id, index)
  if type(index) ~= "number" or index < 0 or index % 1 ~= 0 then return nil end
  local count = reaper.CountActionShortcuts(state.section, command_id)
  if index >= count then return nil end
  local ok, description = reaper.GetActionShortcutDesc(state.section, command_id, index)
  if not ok then return nil end
  return description
end

local function mutation_target(id, index, expected_description, allow_add)
  if not state.available then
    return nil, nil, state.error or "Hotkeys aren't available."
  end
  local definition = BY_ID[id]
  local command_id = definition and state.command_ids[id]
  if not command_id then return nil, nil, "That hotkey action is not available." end

  if allow_add and (index == nil or index == -1) then return command_id, -1 end
  local ok, description = pcall(current_description, command_id, index)
  if not ok or description == nil or description ~= expected_description then
    return nil, nil, "That shortcut changed in Reaper. Refresh and try again."
  end
  return command_id, index
end

function hotkeys.start(root)
  state.root = clean_root(root)
  state.identity = root_identity(root)
  state.key_suffix = state.identity and identity_key(state.identity) or nil
  state.session = nil
  state.section = nil
  state.command_ids = {}
  state.available = false
  state.error = nil

  if not state.root or not state.identity then
    state.error = "Hotkeys couldn't find this yb-Reference installation."
    return make_snapshot()
  end
  if type(reaper.GetExtState) ~= "function" or type(reaper.SetExtState) ~= "function"
      or type(reaper.DeleteExtState) ~= "function" or type(reaper.time_precise) ~= "function" then
    state.error = "Hotkeys aren't supported by this Reaper version."
    return make_snapshot()
  end

  local stamp = string.format("%.17g", now())
  local unique = tostring({}):gsub("[^%w]", "")
  state.session = stamp .. "_" .. unique
  set_ext(lease_key(state.key_suffix), encode_lease(state.identity, state.session, now()))
  delete_ext(queue_key(state.key_suffix))

  if not native_api_available() then
    state.error = "Shortcut editing isn't supported by this Reaper version."
    return make_snapshot()
  end

  local ok, section = pcall(reaper.SectionFromUniqueID, MAIN_SECTION_ID)
  if not ok or not section then
    state.error = "Reaper's Main shortcut section isn't available."
    return make_snapshot()
  end
  state.section = section

  for i = 1, #COMMANDS do
    local definition = COMMANDS[i]
    local path = state.root .. separator() .. definition.script
    local registered, command_id = pcall(
      reaper.AddRemoveReaScript, true, MAIN_SECTION_ID, path, true)
    if not registered or type(command_id) ~= "number" or command_id == 0 then
      state.error = "Reaper couldn't register the yb-Reference hotkey actions."
      return make_snapshot()
    end
    state.command_ids[definition.id] = command_id
  end

  state.available = true
  return make_snapshot()
end

function hotkeys.refresh()
  if not state.session then return make_snapshot() end
  return make_snapshot()
end

function hotkeys.tick()
  if not own_lease() then return {} end
  touch_lease()

  local key = queue_key(state.key_suffix)
  local queued_session, ids = decode_queue(get_ext(key))
  if queued_session ~= state.session then
    if queued_session then delete_ext(key) end
    return {}
  end
  delete_ext(key)

  local intents = {}
  for i = 1, #ids do
    local definition = BY_ID[ids[i]]
    if definition then intents[#intents + 1] = copy_intent(definition.intent) end
  end
  return intents
end

function hotkeys.stop()
  if not state.session then return end
  if own_lease() then
    local queued_session = decode_queue(get_ext(queue_key(state.key_suffix)))
    if queued_session == state.session then delete_ext(queue_key(state.key_suffix)) end
    delete_ext(lease_key(state.key_suffix))
  end
  state.session = nil
end

function hotkeys.edit(id, index, expected_description)
  local command_id, shortcut_index, err =
    mutation_target(id, index, expected_description, true)
  if not command_id then return make_snapshot(), err end

  local ok = pcall(reaper.DoActionShortcutDialog,
    reaper.GetMainHwnd(), state.section, command_id, shortcut_index)
  -- The native dialog blocks this script. A matching session is still ours, so
  -- renew it immediately when the dialog closes before another action can run.
  touch_lease()
  if not ok then
    return make_snapshot(), "Reaper couldn't open the shortcut dialog."
  end
  return make_snapshot(), nil
end

function hotkeys.remove(id, index, expected_description)
  local command_id, shortcut_index, err =
    mutation_target(id, index, expected_description, false)
  if not command_id then return make_snapshot(), err end

  local ok, removed = pcall(reaper.DeleteActionShortcut,
    state.section, command_id, shortcut_index)
  if not ok or removed == false then
    return make_snapshot(), "Reaper couldn't remove that shortcut."
  end
  return make_snapshot(), nil
end

function hotkeys.send(root, id)
  if not BY_ID[id] then return false, "unknown hotkey action" end
  local identity = root_identity(root)
  if not identity then return false, "invalid installation path" end
  if type(reaper.GetExtState) ~= "function" or type(reaper.SetExtState) ~= "function"
      or type(reaper.time_precise) ~= "function" then
    return false, "hotkeys unavailable"
  end

  local suffix = identity_key(identity)
  local lease = decode_lease(reaper.GetExtState(EXT_SECTION, lease_key(suffix)))
  local current_time = now()
  if not lease or lease.identity ~= identity or current_time < lease.heartbeat
      or current_time - lease.heartbeat > HEARTBEAT_TIMEOUT then
    return false, "yb-Reference is not open"
  end

  local key = queue_key(suffix)
  local queued_session, ids = decode_queue(reaper.GetExtState(EXT_SECTION, key))
  if queued_session ~= lease.session then ids = {} end
  if #ids >= MAX_QUEUE then return false, "hotkey queue is full" end
  ids[#ids + 1] = id
  local value = encode_queue(lease.session, ids)
  reaper.SetExtState(EXT_SECTION, key, value, false)
  if reaper.GetExtState(EXT_SECTION, key) ~= value then
    return false, "hotkey request could not be queued"
  end
  return true
end

return hotkeys
