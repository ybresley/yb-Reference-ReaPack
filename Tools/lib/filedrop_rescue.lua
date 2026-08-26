-- filedrop_rescue: remembers an OS file drag across the false "release" that
-- ReaImGui reports when the pointer crosses between two native windows. Pure
-- Lua: the caller supplies whether a payload exists and the real Windows mouse
-- button state, then asks once for the paths on a genuine physical release.

local rescue = {}
rescue.__index = rescue

local function copy_paths(paths)
  if type(paths) ~= "table" or #paths == 0 then return nil end
  local out = {}
  for i = 1, #paths do out[i] = paths[i] end
  return out
end

function rescue.new()
  return setmetatable({
    paths = nil,
    payload_active = false,
    left_down = false,
    active = false,
    released = false,
    claimed = false,
  }, rescue)
end

function rescue:needs_paths(payload_active)
  return payload_active == true and self.paths == nil
end

-- Start one UI frame. `left_down` is nil when the real Windows mouse state is
-- unavailable; in that case the rescue path stands down and normal ReaImGui
-- drag/drop continues unchanged.
function rescue:begin_frame(payload_active, left_down, paths)
  self.claimed = false
  self.released = false
  self.active = false

  if type(left_down) ~= "boolean" then
    self.paths = nil
    self.payload_active = payload_active == true
    self.left_down = false
    return false
  end

  local was_payload = self.payload_active
  local was_down = self.left_down

  if payload_active then
    self.paths = copy_paths(paths) or self.paths
  elseif left_down then
    -- The OS drag disappeared while the physical button stayed down. This is
    -- a cancellation or a gap before another DragEnter, never a completed drop.
    self.paths = nil
  end

  -- Require the OS payload to still belong to ReaImGui on the release frame.
  -- Without this guard, releasing over another application that happens to
  -- cover one of our remembered rectangles could import into the hidden panel.
  self.released = payload_active and was_payload and was_down and not left_down
    and self.paths ~= nil
  self.active = (payload_active and left_down and self.paths ~= nil)
    or self.released
  self.payload_active = payload_active == true
  self.left_down = left_down
  return self.active
end

function rescue:take_paths()
  if not self.released or self.claimed or not self.paths then return nil end
  self.claimed = true
  return copy_paths(self.paths)
end

function rescue:consume()
  self.claimed = true
end

function rescue:finish_frame()
  if self.released or (not self.payload_active and not self.left_down) then
    self.paths = nil
  end
  self.active = false
  self.released = false
  self.claimed = false
end

function rescue.inside(x, y, x0, y0, x1, y1)
  return type(x) == "number" and type(y) == "number"
    and x >= x0 and x < x1 and y >= y0 and y < y1
end

return rescue
