-- The picker borrows the one preview engine without selecting a reference.
-- Interrupted Reference View/Library positions remain parked until the user
-- explicitly resumes them.
local pins = require("core.pins")
local holders = require("holders")

local picker_preview = {}

function picker_preview.stop(state)
  if state.preview.slot == "picker" then holders.stop_audio(state) end
  holders.clear_pause(state, "picker")
end

-- Called with this frame's actual popup owner, independently of UI actions.
-- A close, edit mode, hidden window or project switch must always release audio.
-- The owner is the pin set's session, not the project pointer: REAPER may keep
-- the pointer while another file opens into the same tab.
function picker_preview.set_context(state, owner)
  local ps = state.pins
  if not ps or ps.load_error or owner ~= ps.session then owner = nil end
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
local function start(state, sound, owner, play, missing)
  local ps = state.pins
  if owner == nil or owner ~= state.picker_preview_owner
    or not ps or owner ~= ps.session then return false end
  if state.drag then return false end
  if state.picker_preview_blocked or state.reference.active then
    return false, "Reference mode is playing. Stop the Reaper timeline to preview here."
  end
  if not sound then return false, missing end

  -- Preserve the actual sounding reference, even if a quiet left-click has
  -- selected another row since playback started. Selection itself stays intact.
  local live = state.preview
  if live.playing and live.slot ~= "picker" then
    holders.pause_playback(state, live.slot, live.sound_id)
  end
  -- Picker rows are one-shot triggers. A repeated click starts the row again;
  -- the popup never owns a pause/resume gesture.
  holders.clear_pause(state, "picker")
  if not play(sound, nil, "picker") then return false, state.status end
  return true
end

-- A pinned reference, by id.
function picker_preview.play(state, id, owner, play)
  local ps = state.pins
  -- A damaged pin collection plays nothing from it. Library sounds below do
  -- not depend on the pins, so they still play.
  if ps and ps.load_error then return false end
  return start(state, ps and ps.data and pins.find(ps.data, id) or nil, owner, play,
    "That reference is no longer pinned to this project.")
end

-- A Library sound from the dropdown's Library list. `sound` is its record, or
-- nil when it is gone.
function picker_preview.play_sound(state, sound, owner, play)
  return start(state, sound, owner, play, "That sound is no longer in your Library.")
end

return picker_preview
