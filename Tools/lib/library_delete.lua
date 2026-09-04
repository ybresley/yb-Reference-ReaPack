-- Wait for SWS to release preview files before the existing Library deletion
-- operation runs. No files or records change while waiting. Captured records and
-- their Library must still match, so a delayed click cannot affect another sound.
local preview = require("preview")
local holders = require("holders")
local api = require("reaper_api")

local deletion = {}
local pending
local TIMEOUT = 2 -- failure limit only; completion follows SWS handle validity

local function stop_requested_preview(state, job)
  if job.ids[state.preview.sound_id] then holders.stop_audio(state) end
end

function deletion.request(state, ids)
  if pending then return false, "A deletion is already in progress." end
  local records, wanted = {}, {}
  for _, id in ipairs(ids or {}) do wanted[id] = true end
  for _, record in ipairs(state.library.sounds) do
    if wanted[record.id] then
      records[#records + 1] = { record = record, filename = record.filename,
        path = api.join(state.library_dir, record.filename) }
    end
  end
  if #records == 0 then return false, "Those sounds are no longer in your Library." end
  pending = { library = state.library, dir = state.library_dir,
    records = records, ids = wanted, deadline = api.now() + TIMEOUT }
  stop_requested_preview(state, pending)
  return true
end

-- Returns ready ids or an error. The caller performs the existing deletion and
-- reports its result. Cancelled/expired requests never carry into a later frame.
function deletion.tick(state)
  local job = pending
  if not job then return end
  if state.library ~= job.library or state.library_dir ~= job.dir then
    pending = nil
    return nil, "Deletion was cancelled because the Library changed."
  end
  local present = {}
  for _, record in ipairs(state.library.sounds) do
    if job.ids[record.id] then present[record] = true end
  end
  for _, item in ipairs(job.records) do
    if not present[item.record] or item.record.filename ~= item.filename then
      pending = nil
      return nil, "Deletion was cancelled because the selected sounds changed."
    end
  end

  -- A new audition during the wait must not reopen a file just before moving it.
  stop_requested_preview(state, job)
  for _, item in ipairs(job.records) do
    if preview.releasing(item.path) then
      if api.now() >= job.deadline then
        pending = nil
        return nil, "The sounds weren't deleted because playback hasn't finished stopping. Try again."
      end
      return
    end
  end
  pending = nil
  local ids = {}
  for _, item in ipairs(job.records) do ids[#ids + 1] = item.record.id end
  return ids
end

return deletion
