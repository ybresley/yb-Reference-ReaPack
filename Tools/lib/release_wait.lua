-- Waiting for SWS to let go of files before they are moved. Stopping a preview
-- only asks SWS to release its file; SWS finishes on its own timer, and Windows
-- won't move a file that is still open. Delete (library_delete.lua) and Review
-- Files (leftover_wait.lua) both wait here, and nothing changes while they do.
local preview = require("preview")
local api = require("reaper_api")

local release_wait = {}

local TIMEOUT = 2 -- failure limit only; completion follows SWS handle validity

-- The deadline for a wait that starts now.
function release_wait.deadline()
  return api.now() + TIMEOUT
end

-- "ready" once none of these files is still being let go of, "waiting" until
-- the deadline, then "timeout".
function release_wait.check(paths, deadline)
  for _, path in ipairs(paths) do
    if preview.releasing(path) then
      return api.now() >= deadline and "timeout" or "waiting"
    end
  end
  return "ready"
end

return release_wait
