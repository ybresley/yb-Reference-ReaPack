-- When the update popup appears. Pure: it reads the updater's view table
-- (lib/updater.lua), the user's two popup choices, and one session record.
--
-- The rules, from the user's side:
--   * The popup is decided once per session, when the first update check
--     finishes. A version found by a later daily check lights the Settings dot
--     only, and the popup waits for the next launch, so it never interrupts an
--     audition.
--   * It never offers a version the user skipped, or anything older than it.
--   * It never appears while the feature is unavailable, the tool is pinned in
--     ReaPack, or an update is already under way.
--   * It waits for another startup window (What's New, the walkthrough) to
--     close. Once shown, it stays until the user closes it.
--   * Turning the popup off while it is open does not close it.
local update_check = require("core.update_check")

local notice = {}

-- The newer version the popup may offer, or nil. `prefs` holds the user's
-- choices: `enabled` (false only when turned off) and `skipped` (a version).
function notice.offer(u, prefs)
  if not u or not u.enabled or u.pinned or u.phase ~= nil then return nil end
  local version = u.available
  if not version then return nil end
  if prefs and prefs.enabled == false then return nil end
  if prefs and prefs.skipped and update_check.compare(version, prefs.skipped) <= 0 then
    return nil
  end
  return version
end

function notice.new()
  return { decided = false, version = nil, shown = false, closed = false }
end

-- Whether to draw the popup this frame. `waiting` is true while another
-- startup window is open.
function notice.step(session, u, prefs, waiting)
  if not session.decided then
    if not u or (u.checks or 0) == 0 then return false end
    session.decided = true
    session.version = notice.offer(u, prefs)
  end
  if session.closed or not session.version or not u then return false end
  -- ReaPack is replacing this tool's files, and the tool restarts onto them.
  -- Settings stands down for the same reason.
  if u.phase == "reopen" or u.phase == "restarting" then return false end
  -- Installed some other way, such as through ReaPack itself: nothing to offer.
  if not u.available and not u.phase then return false end
  if not session.shown then
    if waiting then return false end
    session.shown = true
  end
  return true
end

-- Closed with ✕, Esc or Skip This Version: gone for the rest of the session.
function notice.close(session)
  session.closed = true
end

return notice
