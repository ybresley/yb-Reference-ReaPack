-- leftover_service: audio files in the Library folder that aren't part of the
-- Library. It works out what each one is, so the Review Files panel can say so,
-- and carries out the panel's two choices: add the files to the Library where
-- they already are, or move them to the trash folder.
--
-- Like library_service it sits between the pure core and reaper_api, and never
-- calls reaper.* or ImGui itself. Entries are the tables core.leftovers
-- describes.

local importer        = require("core.importer")
local store           = require("core.library_store")
local json            = require("vendor.json")
local trash           = require("core.trash")
local reaper_api      = require("reaper_api")
local library_service = require("library_service")

local service = {}

local function no_pause() end

local function read_note(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  local ok, note = pcall(json.decode, text or "")
  if ok and type(note) == "table" then return note end
  return nil
end

-- Group files by their size in bytes. Only files of the same size can hold the
-- same audio, so this keeps the full comparisons to the few that might match.
local function add_by_size(index, size, item)
  local list = index[size] or {}
  index[size] = list
  list[#list + 1] = item
end

-- Fill in each unchecked entry: its size, whether a Library sound or a deleted
-- sound in the trash has exactly the same audio, and whether it plays. `pause`
-- spreads the work across frames. Nothing on disk is changed.
function service.check(state, entries, pause)
  pause = pause or no_pause
  local dir = state.library_dir
  local trash_dir = reaper_api.join(dir, trash.DIR)

  local sounds = {}
  for i, s in ipairs(state.library.sounds) do
    if type(s.size_bytes) == "number" and type(s.filename) == "string" then
      add_by_size(sounds, s.size_bytes, s)
    end
    if i % 256 == 0 then pause() end
  end

  -- The trash is only listed when some file needs it.
  local trashed
  local function trash_by_size()
    if trashed then return trashed end
    trashed = {}
    for i, name in ipairs(reaper_api.list_files(trash_dir, pause)) do
      if reaper_api.is_audio_file(name) then
        local size = reaper_api.file_size(reaper_api.join(trash_dir, name))
        if size then add_by_size(trashed, size, name) end
      end
      if i % 32 == 0 then pause() end
    end
    return trashed
  end

  for _, e in ipairs(entries) do
    if not e.checked then
      local path = reaper_api.join(dir, e.name)
      e.size = reaper_api.file_size(path)
      -- Moved or deleted since the folder was listed: say so, rather than
      -- calling it a file that can't be played.
      e.gone = not e.size and not reaper_api.path_exists(path) or nil
      if e.size then
        for _, s in ipairs(sounds[e.size] or {}) do
          if s.filename:lower() ~= e.name:lower()
            and library_service.identical_files(path, reaper_api.join(dir, s.filename), pause) then
            e.match = { kind = "library", id = s.id, name = s.name }
            break
          end
        end
        if not e.match then
          for _, t in ipairs(trash_by_size()[e.size] or {}) do
            if library_service.identical_files(path, reaper_api.join(trash_dir, t), pause) then
              -- Only a note says which sound this was. Audio with no note,
              -- such as a file moved there from this panel, explains nothing.
              local note = read_note(reaper_api.join(trash_dir, trash.note_filename(t)))
              local sound = note and type(note.sound) == "table" and note.sound
              if sound and type(sound.name) == "string" then
                e.match = { kind = "deleted", name = sound.name,
                  date = type(note.deleted) == "string" and note.deleted or nil }
                break
              end
            end
          end
        end
      end
      local info = reaper_api.probe_audio(path)
      e.duration = info and info.duration or nil
      e.channels = info and info.channels or nil
      e.playable = info ~= nil and (info.channels or 0) >= 1
      e.too_many_channels = e.playable and info.channels > reaper_api.MAX_AUDIO_CHANNELS or nil
      e.checked = true
      pause()
    end
  end
  return entries
end

-- The check as a background job, stepped by the entry loop like an import. It
-- stops by itself when the Library changes under it.
function service.start_check(state, entries)
  local lib, dir = state.library, state.library_dir
  local thread = coroutine.create(function()
    service.check(state, entries, coroutine.yield)
  end)
  local job = {}
  function job:cancel()
    if self.done then return end
    coroutine.close(thread)
    self.done, self.cancelled = true, true
  end
  function job:step()
    if self.done then return true end
    if state.library ~= lib or state.library_dir ~= dir then
      self:cancel()
      return true
    end
    local ok, err = coroutine.resume(thread)
    if not ok then
      coroutine.close(thread)
      self.done, self.error = true, err
    elseif coroutine.status(thread) == "dead" then
      self.done = true
    end
    return self.done
  end
  return job
end

-- Move these entries' files into the trash folder under names nothing there is
-- using. No note is written: a note holds a sound's record, and these files
-- never had one. Returns the names moved and the ones that couldn't be, each
-- { name, why }.
--
-- A file a Library sound now uses is left alone, however old the panel's list:
-- moving it would leave that sound with no audio. So is a file that has already
-- gone, as there is nothing left to move.
function service.move_to_trash(state, entries)
  local dir = state.library_dir
  local known = {}
  for _, s in ipairs(state.library.sounds) do
    if s.filename then known[s.filename:lower()] = true end
  end
  local trash_dir = reaper_api.join(dir, trash.DIR)
  reaper_api.ensure_dir(trash_dir)
  local taken, take = library_service.trash_names(trash_dir)
  local moved, failed = {}, {}
  for _, e in ipairs(entries) do
    local path = reaper_api.join(dir, e.name)
    if not known[e.name:lower()] and reaper_api.path_exists(path) then
      local dest = importer.unique_filename(e.name, taken)
      take(dest)
      take(trash.note_filename(dest))
      local ok, why = reaper_api.move_file(path, reaper_api.join(trash_dir, dest))
      if ok then moved[#moved + 1] = e.name else failed[#failed + 1] = { name = e.name, why = why } end
    end
  end
  return moved, failed
end

-- Add the chosen files to the Library where they already are, as Uncategorised.
-- Nothing is copied. Each file is measured again now, because it may have
-- changed since it was checked:
--
--   * a file with exactly the same audio as a Library sound isn't added a second
--     time. It moves to the trash folder instead, as adding a duplicate does.
--     The audio is compared again here, not trusted from the check. The same
--     goes for two chosen files with the same audio: only the first is added.
--   * a file that can't be played, or has too many channels, stays where it is.
--
-- The Library is saved once. If that fails, the new records are taken out again
-- and nothing moves, so memory and disk still agree.
--
-- Returns { added = { record... }, duplicates, unplayable, channels,
-- failed = { { name, why } }, save_error = message or nil }.
function service.add(state, entries)
  local lib, dir = state.library, state.library_dir
  local result = { added = {}, duplicates = 0, unplayable = 0, channels = 0, failed = {} }

  local by_id, known = {}, {}
  for _, s in ipairs(lib.sounds) do
    by_id[s.id] = s
    if s.filename then known[s.filename:lower()] = true end
  end

  -- This add's own new sounds by size, so a second chosen file with the same
  -- audio is caught as a copy of the first.
  local added_by_size = {}
  local function is_copy(e, path, size)
    local s = e.match and e.match.kind == "library" and by_id[e.match.id]
    if s and s.filename and library_service.identical_files(path, reaper_api.join(dir, s.filename)) then
      return true
    end
    for _, other in ipairs(size and added_by_size[size] or {}) do
      if library_service.identical_files(path, reaper_api.join(dir, other)) then return true end
    end
    return false
  end

  local copies = {}
  for _, e in ipairs(entries) do
    local path = reaper_api.join(dir, e.name)
    local size = reaper_api.file_size(path)
    if known[e.name:lower()] or not reaper_api.path_exists(path) then
      -- Already part of the Library, or gone since the panel listed it.
    elseif is_copy(e, path, size) then
      copies[#copies + 1] = e
    else
      local info = reaper_api.probe_audio(path)
      if not info or info.channels < 1 then
        result.unplayable = result.unplayable + 1
      elseif info.channels > reaper_api.MAX_AUDIO_CHANNELS then
        result.channels = result.channels + 1
      else
        known[e.name:lower()] = true
        if size then add_by_size(added_by_size, size, e.name) end
        result.added[#result.added + 1] = importer.add_sound(lib, {
          filename = e.name, source_name = e.name, size_bytes = size,
          duration = info.duration, channels = info.channels,
        })
      end
    end
  end

  if #result.added > 0 then
    local saved, err = pcall(store.save, state.library_path, lib)
    if not saved then
      for i = #result.added, 1, -1 do trash.remove(lib, result.added[i].id) end
      result.added, result.save_error = {}, err
      return result
    end
  end

  local moved, failed = service.move_to_trash(state, copies)
  result.duplicates, result.failed = #moved, failed
  return result
end

return service
