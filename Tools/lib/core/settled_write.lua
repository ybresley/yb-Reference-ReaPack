-- settled_write: writes a value once it has stopped changing.
--
-- A window being dragged reports a new position every frame. Saving each one to
-- REAPER's permanent settings would rewrite its settings file dozens of times a
-- second, so only the last value is written, a moment after the movement stops
-- or when the script closes.
--
-- The clock and the write are passed in; pure Lua.

local settled_write = {}
settled_write.__index = settled_write

function settled_write.new(delay, write)
  return setmetatable({ delay = delay, write = write }, settled_write)
end

-- Remember the newest value and restart the wait.
function settled_write:request(now, value)
  self.value, self.at, self.pending = value, now, true
end

-- Write if the value has been still for the whole delay. Call every frame.
function settled_write:tick(now)
  if self.pending and now - self.at >= self.delay then self:flush() end
end

-- Write now if anything is waiting (closing the script).
function settled_write:flush()
  if not self.pending then return end
  self.pending = false
  self.write(self.value)
end

return settled_write
