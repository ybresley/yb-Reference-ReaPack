-- What the update feature tells the user right now: the newer version on offer,
-- a status line with its note, and the button that starts the update. Settings
-- → Updates and the update popup both read this, so the two always agree.
-- Pure: it reads the updater's view table (lib/updater.lua) and nothing else.
local update_status = {}

local UPDATE_TIP = "ReaPack installs the update. Close its report when it appears; "
  .. "yb-Reference will then reopen automatically."
local RETRY_TIP = "Close the ReaPack report first, then try the update again."

-- Fills `out` (reused by the caller, so drawing allocates nothing) with:
--   available   the version an update would install, or nil
--   status      a status line, or nil
--   note        a dimmer line under it, or nil
--   button      the start button's label, or nil when no update can start
--   button_tip  that button's tooltip
function update_status.describe(u, out)
  out.available, out.status, out.note, out.button, out.button_tip = nil, nil, nil, nil, nil
  if not u or not u.enabled then
    local reason = u and u.disabled_reason
    if reason == "repo_off" then
      out.status = "Paused. yb-Reference's repository is disabled in ReaPack."
      out.note = "Re-enable the repository under Extensions \u{2192} ReaPack \u{2192} Manage repositories, then reopen the tool."
    elseif reason == "noapi" then
      out.status = "Updates are unavailable because ReaPack isn't installed."
    else
      out.status = "Updates are unavailable because this copy wasn't installed through ReaPack."
    end
  elseif u.phase == "reopen" then
    out.status = "Update started."
    out.note = "Close the ReaPack report when it appears. yb-Reference will reopen automatically."
  elseif u.phase == "restarting" then
    out.status = "Update finished."
    out.note = "Reopening yb-Reference\u{2026}"
  elseif u.phase == "reopen_manual" then
    out.status = "Close the ReaPack report if it's still open, then close and reopen yb-Reference."
  elseif u.phase == "report_busy" then
    out.available = u.available
    out.status = "Close the open ReaPack report before starting this update."
    out.button, out.button_tip = "Try Again", RETRY_TIP
  elseif u.phase == "done" then
    out.status = "Updated. Close and reopen yb-Reference."
  else
    out.available = u.available
    if u.pinned then
      out.status = "Paused. This tool is pinned in ReaPack."
      out.note = "Right-click it in Extensions \u{2192} ReaPack \u{2192} Browse packages and untick \"Pin to current version\"."
    elseif out.available then
      out.button, out.button_tip = "Update Now", UPDATE_TIP
    end
    if u.phase == "failed_manual" then
      out.status = "The update couldn't be completed from here."
      out.note = "Run Extensions \u{2192} ReaPack \u{2192} Synchronize packages instead."
    end
  end
  return out
end

return update_status
