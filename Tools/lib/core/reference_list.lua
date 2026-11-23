-- Which list the Reference card belongs to, and where the selected reference
-- sits in it. The card's dropdown switches between the Library's sounds and
-- this project's pinned references, and the card's arrows and count follow
-- that choice. The Library itself, docked or in its own window, always shows
-- the Library's sounds.
--
-- Pure Lua.
local list = {}

function list.docked(state)
  return state.browser_open == true and state.library_placement == "embedded"
end

-- "library" or "pinned": the list the card's dropdown shows.
function list.shown(state)
  return state.library_list == "pinned" and "pinned" or "library"
end

-- The Library's list is on screen, docked or in its own window.
function list.visible(state)
  return state.browser_open == true
end

-- "library" or "pinned": the list the card's arrows and count walk.
function list.source(state)
  return list.shown(state)
end

-- The Library sound a reference stands for: the sound a pin was made from
-- (`origin_of`, pin id -> Library sound id), or the id itself.
function list.library_id(id, origin_of)
  if id == nil then return nil end
  return origin_of and origin_of[id] or id
end

-- 1-based place of sound `id` in `sounds`, or nil.
function list.position(sounds, id)
  if id == nil then return nil end
  for i, sound in ipairs(sounds or {}) do
    if sound.id == id then return i end
  end
  return nil
end

-- The sound `delta` rows from `id`, wrapping at both ends like the pinned
-- list's arrows. From a sound that is not in the list, forward enters at the
-- top and back at the bottom. Returns the sound's id and its 0-based row, or
-- nil when there is nowhere else to go.
function list.step(sounds, id, delta)
  local n = sounds and #sounds or 0
  if n == 0 then return nil end
  local at = list.position(sounds, id)
  local to
  if at then
    to = (at - 1 + delta) % n + 1
    if to == at then return nil end
  else
    to = delta > 0 and 1 or n
  end
  return sounds[to].id, to - 1
end

return list
