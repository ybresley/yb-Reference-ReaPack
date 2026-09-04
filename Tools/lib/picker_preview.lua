-- The picker borrows the one preview engine without selecting a reference.
-- Only its pause belongs to the popup; interrupted Reference View/Library positions
-- remain parked until the user explicitly resumes them.
local pins = require("core.pins")
local holders = require("holders")

local picker_preview = {}

function picker_preview.stop(state)
  if state.preview.slot == "picker" then holders.stop_audio(state) end
  holders.clear_pause(state, "picker")
end

-- Called with this frame's actual popup owner, independently of UI actions.
-- A close, edit mode, hidden window or project switch must always release audio.
function picker_preview.set_context(state, owner)
  local ps = state.pins
  if not ps or ps.load_error or owner ~= ps.proj then owner = nil end
  if owner == nil or owner ~= state.picker_preview_owner then
    picker_preview.stop(state)
  end
  state.picker_preview_owner = owner
end

-- Transport ownership wins before drawing or handling any picker click.
function picker_preview.set_reference_running(state, running)
  state.picker_preview_blocked = running == true
  if running then picker_preview.stop(state) end
end

-- `play` is the entry script's normal playback path, including routing, gain,
-- spans and error reporting. This module never opens another audio player.
function picker_preview.play(state, id, owner, restart, play)
  local ps = state.pins
  if owner == nil or owner ~= state.picker_preview_owner
    or not ps or owner ~= ps.proj or ps.load_error then return false end
  if state.drag then return false end
  if state.picker_preview_blocked or state.reference.active then
    return false, "Reference mode is playing. Stop the Reaper timeline to preview here."
  end
  local sound = pins.find(ps.data, id)
  if not sound then return false, "That reference is no longer pinned to this project." end

  local live = state.preview
  if not restart and live.playing and live.slot == "picker" and live.sound_id == id then
    holders.pause_playback(state, "picker", id)
    return true
  end

  -- Preserve the actual sounding reference, even if a quiet left-click has
  -- selected another row since playback started. Selection itself stays intact.
  if live.playing and live.slot ~= "picker" then
    holders.pause_playback(state, live.slot, live.sound_id)
  end
  local parked = not restart and holders.paused_on(state, "picker", id)
  local from = parked and parked.at or nil
  holders.clear_pause(state, "picker")
  if not play(sound, from, "picker") then return false, state.status end
  return true
end

return picker_preview
