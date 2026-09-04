-- Owns the destination of each measurement. A local id is not sufficient when
-- projects and libraries can change while a file is being measured.
local analysis = require("core.analysis")
local loudness = require("loudness")
local pins_service = require("pins_service")
local copies = require("analysis_copies")
local api = require("reaper_api")

local service = {}
local target
local pin_context, pin_version
local pin_queue, attempted = {}, {}
local progress_at, progress_state

-- One queue has one display destination. A later add moves its feedback to the
-- view the user just acted in, without restarting any measurement.
function service.set_progress_view(state, view)
  assert(view == "main" or view == "browse", "Unknown measurement progress view")
  state.analysis_progress_view = view
  if state.analysis_progress then state.analysis_progress.view = view end
end

local function is_pin(id)
  return type(id) == "string" and id:sub(1, 1) == "p"
end

local function valid(state, callbacks, job)
  if callbacks.find(job.record.id) ~= job.record then return false end
  if job.record.filename ~= job.filename or callbacks.path(job.record) ~= job.path then
    return false
  end
  return job.pin and state.pins == job.owner and not state.pins.load_error
    or not job.pin and state.library == job.owner
end

local function finish(state, callbacks, job, result)
  if not valid(state, callbacks, job) then return end
  if job.pin then
    local ok, message = pins_service.complete_analysis(state, job.record, result)
    if message then state.status = message end
    if ok and not result then
      state.status = string.format('"%s" couldn\'t be measured. Reopen the project or yb-Reference to retry.',
        job.record.name)
    end
    return ok
  elseif analysis.needs(job.record) then
    if result then analysis.apply(job.record, result) else analysis.mark_failed(job.record) end
    local saved = callbacks.save_library()
    if state.sort.col == "loud" then callbacks.refresh_view() end
    return saved
  end
end

-- Keep progress separate from action/errors. Count a newly copied pair once
-- while it can share a job; this is remaining work, not an ETA or percentage.
local function progress(state, paused, force)
  if not target and #pin_queue == 0 and #state.analysis_queue == 0 then
    state.analysis_progress = nil
    state.analysis_progress_view = nil
    return
  end
  local now = api.now()
  if progress_state ~= state then progress_state, progress_at = state, nil end
  if not force and progress_at and now - progress_at < 1 then return end
  progress_at = now
  -- Index queued ids once, then visit each record once. Repeated find(id) calls
  -- here would make a large import's status update quadratic in Library size.
  local queued, waiting, remaining = {}, {}, 0
  local name = target and target.record.name
  for _, id in ipairs(pin_queue) do queued[id] = "pin" end
  for _, id in ipairs(state.analysis_queue) do queued[id] = "library" end
  if target then queued[target.record.id] = "active" end
  for _, record in ipairs(state.library.sounds) do
    if queued[record.id] and analysis.needs(record) then
      waiting[record], remaining = true, remaining + 1
      name = name or record.name
    end
  end
  for _, record in ipairs(state.pins and state.pins.data.pins or {}) do
    if queued[record.id] and analysis.pin_needs(record)
      and not (queued[record.id] == "pin" and attempted[record]) then
      waiting[record], remaining = true, remaining + 1
      name = name or record.name
    end
  end
  -- No file reads for display. The real sharing check still verifies both files
  -- on completion; a rejected link can increase the displayed remaining work.
  for _, pair in ipairs(state.analysis_copies or {}) do
    if waiting[pair.sound_record] and waiting[pair.pin_record] then remaining = remaining - 1 end
  end
  state.analysis_progress = remaining > 0 and { paused = not not paused,
    remaining = remaining, name = name, view = state.analysis_progress_view or "main" } or nil
end

local function complete(state, callbacks, job, result)
  if not valid(state, callbacks, job) then return end
  local peer = copies.take_peer(state, job.record, callbacks.find, callbacks.path)
  -- Size catches truncation/replacement, not same-size edits. Keep the whole-file
  -- engine and its existing rounding; never publish a detected stale result.
  if job.size == nil or api.file_size(job.path) ~= job.size then
    if finish(state, callbacks, job, nil) then
      state.status = string.format('"%s" changed or became unavailable while measuring. Reopen yb-Reference to retry.',
        job.record.name)
    end
    return
  end
  finish(state, callbacks, job, result)
  if result and peer then
    local pin = is_pin(peer.id)
    if pin then attempted[peer] = true end
    finish(state, callbacks, { record = peer, pin = pin,
      owner = pin and state.pins or state.library, filename = peer.filename,
      path = callbacks.path(peer) }, result)
  end
end

-- Priority applies between files; an in-flight Library measurement keeps its
-- progress. Only copies made in this session can share a completed result.
function service.advance(state, callbacks)
  if copies.sync(state) then progress_at = nil end
  if not loudness.available() then state.analysis_progress = nil; return end
  if target and (loudness.current() ~= target.record.id or not valid(state, callbacks, target)) then
    -- A cancellation may already have released the source through holders.lua.
    if loudness.current() == target.record.id then loudness.cancel() end
    copies.forget(state, function(id) return id == target.record.id end)
    target = nil
  end
  local ps = state.pins
  if ps ~= pin_context then
    pin_context, pin_version, attempted = ps, nil, setmetatable({}, { __mode = "k" })
    pin_queue = {}
  end
  if ps and ps.markers_version ~= pin_version then
    pin_version = ps.markers_version
    pin_queue = not ps.load_error and ps.dir
      and analysis.pin_queue(ps.data, loudness.current(), attempted) or {}
  end

  local paused = api.recording_active()
  if paused then
    progress(state, true, not state.analysis_progress or not state.analysis_progress.paused)
    return
  end

  local id, result = loudness.advance()
  if id and target then
    local completed = target
    target = nil
    if id == completed.record.id then complete(state, callbacks, completed, result) end
  end
  progress(state, false, id ~= nil or (state.analysis_progress and state.analysis_progress.paused))
  if loudness.current() then return end

  -- One candidate per frame also bounds a queue full of removed or broken files.
  local queued_pin = table.remove(pin_queue, 1)
  local next_id = queued_pin or table.remove(state.analysis_queue, 1)
  if not next_id then
    state.analysis_progress, state.analysis_progress_view = nil, nil
    return
  end
  local record = callbacks.find(next_id)
  local pin = is_pin(next_id)
  if queued_pin and attempted[record] then return end
  if not record or not (pin and analysis.pin_needs(record) or not pin and analysis.needs(record)) then
    return
  end
  if pin and (not ps or ps.load_error or not ps.dir) then return end
  local job = { record = record, pin = pin, owner = pin and ps or state.library,
    filename = record.filename, path = callbacks.path(record) }
  job.size = api.file_size(job.path)
  if pin then attempted[record] = true end
  if job.size == nil or not loudness.request(next_id, job.path) then
    copies.take_peer(state, record, callbacks.find, callbacks.path)
    finish(state, callbacks, job, nil)
  else
    target = job
  end
  -- The source opens here, but its first whole-file pass is on the next update.
  -- The UI can paint this sound's progress panel before that pass blocks it.
  progress(state, false, true)
end

return service
