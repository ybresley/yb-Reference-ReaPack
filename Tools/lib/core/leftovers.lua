-- leftovers: what the Review Files panel says about audio files that sit in the
-- Library folder without being part of the Library. An add that stopped part-way
-- leaves them behind, and so does copying files into the folder by hand.
--
-- An entry is one such file:
--   { name = "Kick_2.wav",            -- the real filename on disk
--     size = bytes or nil,
--     duration = seconds or nil, channels = n or nil,
--     playable = true | false | nil,  -- nil until the file has been checked
--     match = nil
--       | { kind = "library", id = sound id, name = sound name }
--       | { kind = "deleted", name = sound name, date = "YYYY-MM-DD" or nil },
--     too_many_channels = true when it has more channels than can be played,
--     gone = true when the file left the folder after it was listed,
--     checked = true once everything above has been read }
--
-- Pure Lua. Reading the files is leftover_service's job.

local duration_text = require("core.duration_text")

local leftovers = {}

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

local function plural(n, one, many) return n == 1 and one or many end

-- "2026-09-04" reads as "4 Sep 2026". Anything else has no readable date.
function leftovers.date_text(iso)
  local y, m, d = tostring(iso or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  m = tonumber(m)
  if not y or not MONTHS[m] then return nil end
  return string.format("%d %s %s", tonumber(d), MONTHS[m], y)
end

-- Fresh entries for these filenames, sorted the way the panel lists them.
function leftovers.entries(names)
  local out = {}
  for i, name in ipairs(names or {}) do out[i] = { name = name } end
  table.sort(out, function(a, b)
    local la, lb = a.name:lower(), b.name:lower()
    if la ~= lb then return la < lb end
    return a.name < b.name
  end)
  return out
end

-- Why this file is worth a second look, as one word, or nil when nothing is
-- known. A file that has gone has nothing else to say; otherwise a matching
-- sound explains the file best, so it wins over a playback problem.
function leftovers.reason_kind(entry)
  if entry.gone then return "gone" end
  if entry.match then return entry.match.kind end
  if entry.playable == false then return "unplayable" end
  if entry.too_many_channels then return "channels" end
  return nil
end

function leftovers.reason_text(entry)
  local kind = leftovers.reason_kind(entry)
  if kind == "library" then
    return "Same audio as " .. entry.match.name
  elseif kind == "deleted" then
    local date = leftovers.date_text(entry.match.date)
    return "Same audio as " .. entry.match.name .. (date and (", deleted " .. date) or ", deleted")
  elseif kind == "unplayable" then
    return "Can't be played, may be incomplete"
  elseif kind == "channels" then
    return string.format("Has %d channels, more than yb-Reference supports", entry.channels or 0)
  elseif kind == "gone" then
    return "No longer in the Library folder"
  end
  return nil
end

-- One line under the heading when every file has the same reason, so it isn't
-- repeated on every row. Nil while any file is unchecked, or for a single file
-- (its row says it already).
function leftovers.summary(entries)
  local n = #entries
  if n < 2 then return nil end
  local kind, date
  for i, e in ipairs(entries) do
    if not e.checked then return nil end
    local k = leftovers.reason_kind(e)
    if k == nil then return nil end
    if i == 1 then
      kind = k
      date = k == "deleted" and e.match.date or nil
    elseif k ~= kind then
      return nil
    elseif k == "deleted" and e.match.date ~= date then
      date = nil
    end
  end
  if kind == "library" then
    return string.format("All %d have the same audio as sounds in your Library.", n)
  elseif kind == "deleted" then
    local when = leftovers.date_text(date)
    return string.format("All %d have the same audio as sounds you deleted%s.", n,
      when and (" on " .. when) or "")
  elseif kind == "unplayable" then
    return "None of these can be played. They may be incomplete."
  end
  -- Channel counts differ from file to file, so each row keeps its own; files
  -- that have gone are rare enough to name one by one.
  return nil
end

-- The length column, written the way the Library writes lengths. Empty while
-- the file is still being checked; a dash once it is known there is no length.
function leftovers.length_text(entry)
  if not entry.checked then return "" end
  if entry.gone or entry.playable == false or type(entry.duration) ~= "number" then return "\u{2014}" end
  return duration_text.format(entry.duration)
end

function leftovers.notice_text(n)
  if n == 1 then
    return "1 audio file in your Library folder isn't part of your Library. Your sounds aren't affected."
  end
  return string.format(
    "%d audio files in your Library folder aren't part of your Library. Your sounds aren't affected.", n)
end

-- The line under the Library facts in Settings, which reopens Review Files.
function leftovers.settings_text(n)
  return string.format("Also in the folder: %d audio %s not in your Library",
    n, plural(n, "file", "files"))
end

function leftovers.heading(n)
  return string.format("%d %s not in your Library", n, plural(n, "file", "files"))
end

-- What Add to Library did. `r` counts: added, duplicates (moved to the trash
-- because the Library already has that audio), unplayable and channels
-- (left where they are), failed (duplicates that couldn't be moved).
function leftovers.add_result(r)
  local parts = {}
  local added = r.added or 0
  if added > 0 then
    parts[#parts + 1] = string.format("Added %d %s to Uncategorised.", added, plural(added, "sound", "sounds"))
  end
  local dup = r.duplicates or 0
  if dup > 0 then
    parts[#parts + 1] = string.format("%d %s already in your Library, so %s to the trash folder.",
      dup, plural(dup, "file was a copy of a sound", "files were copies of sounds"),
      plural(dup, "it moved", "they moved"))
  end
  local unplayable = r.unplayable or 0
  if unplayable > 0 then
    parts[#parts + 1] = string.format("%d %s added because %s be played.", unplayable,
      plural(unplayable, "file wasn't", "files weren't"), plural(unplayable, "it can't", "they can't"))
  end
  local channels = r.channels or 0
  if channels > 0 then
    parts[#parts + 1] = string.format("%d %s added because %s more channels than yb-Reference supports.",
      channels, plural(channels, "file wasn't", "files weren't"), plural(channels, "it has", "they have"))
  end
  local failed = r.failed or 0
  if failed > 0 then
    parts[#parts + 1] = leftovers.move_failed_text(failed)
  end
  if #parts == 0 then return "Nothing was added." end
  return table.concat(parts, " ")
end

function leftovers.move_failed_text(n)
  return string.format("%d %s be moved to the trash folder, usually because another program has %s open.",
    n, plural(n, "file couldn't", "files couldn't"), plural(n, "it", "them"))
end

-- What Move to Trash did.
function leftovers.trash_result(moved, failed)
  local parts = {}
  if moved > 0 then
    parts[#parts + 1] = string.format("%d %s moved to the trash folder in your Library.",
      moved, plural(moved, "file", "files"))
  end
  if failed > 0 then parts[#parts + 1] = leftovers.move_failed_text(failed) end
  if #parts == 0 then return "Nothing was moved." end
  return table.concat(parts, " ")
end

return leftovers
