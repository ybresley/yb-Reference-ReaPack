-- Meter controls share the filter's named memory because ReaScript has only one
-- current attachment. Its control and history regions are below Stereo packets.
local control = {}
local NAME, BASE, PROTOCOL = 'yb_reference_monitor_filter_v1', 140000, 2
local LEASE_SECONDS, COUNTER_LIMIT = 2, 1000000000
local SLOT = { protocol=0, active=1, session=2, heartbeat=3, token=4,
  revision=5, capture_mode=6, reset_request=7, reset_policy=8,
  loop_start=9, loop_end=10, loop_enabled=11, owner_time=12 }

local function finite(value)
  return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

local function counter(value)
  return finite(value) and value >= 0 and value < COUNTER_LIMIT and value % 1 == 0
end

function control.new(R)
  local self = {}
  local values
  local function connect()
    return R.gmem_attach and R.gmem_read and R.gmem_write and R.time_precise
      and R.gmem_attach(NAME) ~= false
  end
  local function read(key) return R.gmem_read(BASE + SLOT[key]) end
  local function write(key, value)
    R.gmem_write(BASE + SLOT[key], value)
    return read(key) == value
  end
  local function owns()
    return self.session and read('session') == self.session and read('token') == self.token
  end
  local function heartbeat()
    local previous, now = read('heartbeat'), R.time_precise()
    if not counter(previous) or not finite(now) then return false end
    return write('owner_time', now) and write('heartbeat', (previous + 1) % COUNTER_LIMIT)
  end
  local function fail()
    if owns() then write('active', 0) end
    return false, 'configuration_failed'
  end

  function self:available()
    if not connect() then return false, 'configuration_failed' end
    local session, stamp, now = read('session'), read('owner_time'), R.time_precise()
    if not counter(session) or not finite(stamp) or not finite(now) then
      return false, 'configuration_failed'
    end
    if owns() then return true end
    if session > 0 and stamp >= 0 and now - stamp < LEASE_SECONDS then
      return false, 'existing_instance'
    end
    return true
  end

  function self:claim(token)
    local ok, reason = self:available()
    if not ok then return false, reason end
    if not counter(token) or token == 0 then return false, 'configuration_failed' end
    if owns() then
      if self.token ~= token then return false, 'existing_instance' end
      return true
    end
    local previous = read('session')
    self.session, self.token = previous % (COUNTER_LIMIT - 1) + 1, token
    values = { capture_mode=2, reset_request=0, reset_policy=7,
      loop_start=0, loop_end=0, loop_enabled=0, active=false }
    -- No audio work begins until capture publishes the initial complete controls.
    if not write('active', 0) or not write('token', token)
      or not write('session', self.session) then return fail() end
    return self:publish({})
  end

  function self:publish(changes)
    if not connect() then return false, 'configuration_failed' end
    if not owns() then return false, 'existing_instance' end
    local next_values = {}
    for key, value in pairs(values) do next_values[key] = value end
    for key, value in pairs(changes) do
      if next_values[key] == nil then return false, 'configuration_failed' end
      next_values[key] = value
    end
    if type(next_values.active) ~= 'boolean'
      or not counter(next_values.capture_mode) or next_values.capture_mode > 2
      or not counter(next_values.reset_request)
      or not counter(next_values.reset_policy) or next_values.reset_policy > 7
      or not finite(next_values.loop_start) or next_values.loop_start < 0 or next_values.loop_start > 1e9
      or not finite(next_values.loop_end) or next_values.loop_end < 0 or next_values.loop_end > 1e9
      or (next_values.loop_enabled ~= 0 and next_values.loop_enabled ~= 1) then
      return false, 'configuration_failed'
    end
    local revision = read('revision')
    if not counter(revision) then return fail() end
    revision = (revision - revision % 2 + 2) % COUNTER_LIMIT
    if not write('revision', (revision + COUNTER_LIMIT - 1) % COUNTER_LIMIT)
      or not write('protocol', PROTOCOL) then return fail() end
    for key, value in pairs(next_values) do
      if key ~= 'active' and not write(key, value) then return fail() end
    end
    if not owns() then return false, 'existing_instance' end
    if not heartbeat() or not write('revision', revision)
      or not write('active', next_values.active and 1 or 0) then return fail() end
    if not owns() then return false, 'existing_instance' end
    values = next_values
    return true
  end

  function self:renew()
    if not connect() then return false, 'configuration_failed' end
    if not owns() then return false, 'existing_instance' end
    if not heartbeat() then return fail() end
    return true
  end

  function self:close()
    if not self.session then return true end
    if not connect() then return false, 'configuration_failed' end
    -- A timed-out window may finish after another window has taken ownership.
    if owns() then
      if not write('active', 0) or not write('owner_time', -1) then return fail() end
    end
    self.session, self.token, values = nil, nil, nil
    return true
  end

  return self
end

return control
