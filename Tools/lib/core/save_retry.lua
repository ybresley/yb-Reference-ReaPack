-- save_retry: remembers that the Library in memory holds changes its file
-- doesn't, and when to try saving them again.
--
-- A failed save (a sync tool's brief lock, a full disk) keeps the change in
-- memory. Waiting for the user's next change to retry loses it if they close
-- the window first, so the save is retried on a timer, and closing makes one
-- last attempt. That attempt retries a save that already failed; it is not
-- exit-time saving.
--
-- Pure Lua: the caller passes in the save function and the clock.

local save_retry = {}

-- `save()` raises on failure. `now()` returns seconds.
function save_retry.new(save, now, interval)
  return { save = save, now = now, interval = interval or 10, unsaved = false, retry_at = 0 }
end

-- Something outside `try` failed to save; retry after the usual interval.
function save_retry.mark_unsaved(r)
  r.unsaved, r.retry_at = true, r.now() + r.interval
end

-- Save now. Returns true, or false and the error.
function save_retry.try(r)
  local ok, err = pcall(r.save)
  if ok then r.unsaved = false else save_retry.mark_unsaved(r) end
  return ok, err
end

-- Is a retry waiting and due?
function save_retry.due(r)
  return r.unsaved and r.now() >= r.retry_at
end

-- The last attempt before closing. Returns true when nothing is left unsaved,
-- or false and the error when the changes could not be kept. Runs at most once
-- per unsaved episode, so two exit paths never warn twice.
function save_retry.closing(r)
  if not r.unsaved then return true end
  local ok, err = save_retry.try(r)
  r.unsaved = false
  return ok, err
end

return save_retry
