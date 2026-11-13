-- Hold a Review Files action until SWS has let go of the files it moves (see
-- release_wait.lua). Nothing changes while it waits.
local holders = require("holders")
local api = require("reaper_api")
local release_wait = require("release_wait")

local wait = {}
local pending

local GAVE_UP = {
  add   = "The files weren't added because playback hasn't finished stopping. Try again.",
  trash = "The files weren't moved to the trash because playback hasn't finished stopping. Try again.",
}

-- Stop whatever the Review Files panel is playing.
function wait.stop_audition(state)
  if state.preview.slot == "leftover" then holders.stop_audio(state) end
end

-- kind is "add" or "trash"; names are the ticked files.
function wait.request(state, kind, names)
  if pending then return false, "The last Review Files action hasn't finished yet. Try again in a moment." end
  local paths = {}
  for i, name in ipairs(names or {}) do paths[i] = api.join(state.library_dir, name) end
  pending = { kind = kind, names = names or {}, paths = paths, dir = state.library_dir,
    deadline = release_wait.deadline() }
  wait.stop_audition(state)
  return true
end

-- Returns { kind, names } once every file is free, or nil and a message when the
-- wait ended without it. A request whose Library folder changed is cancelled:
-- its names would point at files in another folder.
function wait.tick(state)
  local job = pending
  if not job then return end
  if state.library_dir ~= job.dir then
    pending = nil
    return nil, "Review Files was cancelled because the Library changed."
  end
  -- A preview started during the wait must not reopen a file just before it moves.
  wait.stop_audition(state)
  local status = release_wait.check(job.paths, job.deadline)
  if status == "waiting" then return end
  pending = nil
  if status == "timeout" then return nil, GAVE_UP[job.kind] end
  return { kind = job.kind, names = job.names }
end

return wait
