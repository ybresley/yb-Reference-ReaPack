-- library_service: the operations that change the library AND touch the disk —
-- importing files, sweeping for orphans. It sits between the pure core (which
-- decides names/records but can't see the filesystem) and reaper_api (which does
-- the copying/probing). It calls those two plus the store; it never calls reaper.*
-- or ImGui directly, and it isn't drawn from — the entry script invokes it in
-- response to a UI action.

local importer   = require("core.importer")
local categories = require("core.categories")
local store      = require("core.library_store")
local trash      = require("core.trash")
local reaper_api = require("reaper_api")

local product_error = require("product_error")
local service = {}

-- How much of each end of a file the duplicate check compares.
local SAMPLE_BYTES = 64 * 1024
local COMPARE_CHUNK = 1024 * 1024

local function read_ends(path, size)
  local f = io.open(path, "rb")
  if not f then return nil end
  local head = f:read(SAMPLE_BYTES) or ""
  local tail = ""
  if size > SAMPLE_BYTES then
    f:seek("set", math.max(SAMPLE_BYTES, size - SAMPLE_BYTES))
    tail = f:read(SAMPLE_BYTES) or ""
  end
  f:close()
  return head, tail
end

-- Are two files of `size` bytes the same audio? Compares the first and last
-- 64 KB, which covers the header and both ends of the sound: cheap, and enough
-- to tell apart two different exports that share a name and a size. `b` is the
-- Library's copy. When it is missing or unreadable the answer is no, so adding
-- the original again can restore it. When only `a` can't be read the answer is
-- yes: nothing can be copied from it, so a second copy would be pointless.
function service.same_content(a, b, size)
  if type(size) ~= "number" then return true end
  local b_head, b_tail = read_ends(b, size)
  if not b_head then return false end
  local a_head, a_tail = read_ends(a, size)
  if not a_head then return true end
  return a_head == b_head and a_tail == b_tail
end

-- Whether two files hold exactly the same bytes, read in full. For a match
-- that decides which file is used: two different sounds of the same length
-- that both start and end in silence pass the sampled check above. A file
-- that can't be read is no match. `pause`, when given, runs after each chunk
-- so a long comparison can be spread across frames.
--
-- Each chunk opens and closes its file again, so nothing is held open while the
-- comparison waits for the next frame: Windows won't move or delete an open
-- file, and a cancelled comparison would otherwise leave both files open until
-- Lua happened to collect them.
local function chunk_at(path, offset)
  local f <close> = io.open(path, "rb")
  if not f or not f:seek("set", offset) then return nil, false end
  return f:read(COMPARE_CHUNK), true
end

function service.identical_files(a, b, pause)
  local offset = 0
  while true do
    local ca, read_a = chunk_at(a, offset)
    local cb, read_b = chunk_at(b, offset)
    if not (read_a and read_b) or ca ~= cb then return false end
    if ca == nil then return true end
    offset = offset + #ca
    if pause then pause() end
  end
end

-- Import a list of source paths into the library, filing them under an optional
-- category. Follows the crash-safe order: for each file, copy it
-- in FIRST, then save its record immediately. A crash
-- mid-import leaves at worst orphan files (harmless, sweep-detectable), never a
-- record pointing at a file that isn't there.
--
-- Returns a summary { added, ignored, duplicates={}, skipped={}, errors={} } so the caller
-- can tell the user what happened without this layer touching the UI.
function service.import_files(state, paths, category, options)
  options = options or {}
  local pause = options.pause or function() end
  local lib = state.library

  -- Names already in use = existing records UNION the real files on disk. The
  -- disk half matters: an orphan left by a past crash has no record, and we must
  -- never overwrite it when choosing a collision-free name.
  local taken, duplicates = {}, {}
  local function index_sound(s)
    if s.filename then taken[importer.name_key(s.filename)] = true end
    if s.source_name and s.size_bytes then
      local sizes = duplicates[s.source_name] or {}
      duplicates[s.source_name] = sizes
      local same = sizes[s.size_bytes] or {}
      sizes[s.size_bytes] = same
      same[#same + 1] = s
    end
  end
  -- A matching name and size is only a candidate: fixed-length exports from two
  -- packs often share both. The audio itself decides.
  local function find_duplicate(src, source_name, size)
    local same = duplicates[source_name] and duplicates[source_name][size]
    for _, s in ipairs(same or {}) do
      if service.same_content(src, reaper_api.join(state.library_dir, s.filename), size) then
        return s
      end
    end
    return nil
  end
  local indexed_count, indexed_seq
  local function rebuild_index()
    repeat
      indexed_count, indexed_seq = #lib.sounds, lib.seq.sound
      duplicates = {}
      for i, s in ipairs(lib.sounds) do
        index_sound(s)
        if i % 256 == 0 then pause() end
      end
    until indexed_count == #lib.sounds and indexed_seq == lib.seq.sound
  end
  rebuild_index()
  for _, name in ipairs(reaper_api.list_audio_files(state.library_dir, pause)) do
    taken[importer.name_key(name)] = true
  end

  local summary = options.summary or { added = 0, ignored = 0, duplicates = {}, skipped = {}, errors = {} }
  summary.ignored = summary.ignored or 0
  summary.total = #paths

  for i, src in ipairs(paths) do
    summary.current, summary.total = i, #paths
    pause()
    if indexed_count ~= #lib.sounds or indexed_seq ~= lib.seq.sound then rebuild_index() end
    local source_name = importer.basename(src)
    if not reaper_api.is_audio_file(source_name) then
      summary.ignored = summary.ignored + 1
    else
      local size = reaper_api.file_size(src)
      local duplicate = find_duplicate(src, source_name, size)
      if duplicate then
        summary.duplicates[#summary.duplicates + 1] = source_name
        if options.on_sound then options.on_sound(duplicate) end
      else
        local info = reaper_api.probe_audio(src)
        if not info or info.channels < 1 then
          summary.errors[#summary.errors + 1] = source_name .. ": couldn't be read as audio."
        elseif info.channels > reaper_api.MAX_AUDIO_CHANNELS then
          summary.skipped[#summary.skipped + 1] = source_name ..
            string.format(": has %d channels. yb-Reference supports up to %d.",
              info.channels, reaper_api.MAX_AUDIO_CHANNELS)
        else
          local dest_name = importer.unique_filename(source_name, taken)
          local dest_path = reaper_api.join(state.library_dir, dest_name)
          local ok, err = reaper_api.copy_file(src, dest_path, pause)
          -- The size was read before copying, and the copy runs to whatever end
          -- the file has by then. A file still being rendered or synced would
          -- be stored with the wrong size, duration and channels, or cut short.
          if ok and size and reaper_api.file_size(dest_path) ~= size then
            os.remove(dest_path) -- the copy this import just made, nothing else
            ok, err = false, "changed while it was being added. Add it again once it has finished saving."
          end
          if not ok then
            summary.errors[#summary.errors + 1] = source_name .. ": " .. tostring(err)
          else
            taken[importer.name_key(dest_name)] = true
            local sound = importer.add_sound(lib, {
              filename    = dest_name,
              source_name = source_name,
              size_bytes  = size,
              duration    = info.duration,
              channels    = info.channels,
              category    = category and categories.get(lib, category) and category or nil,
            })
            summary.added = summary.added + 1
            index_sound(sound)
            indexed_count, indexed_seq = indexed_count + 1, indexed_seq + 1
            -- Each completed file survives cancellation of the remaining batch.
            store.save(state.library_path, lib)
            if options.on_sound then options.on_sound(sound) end
          end
        end
      end
    end
  end

  return summary
end

-- The entry loop resumes at most one bounded copy/index step per frame. Closing
-- the coroutine also closes any suspended copy's file handles and partial file.
function service.start_import(state, paths, category, options)
  options = options or {}
  local job = { summary = { added = 0, ignored = 0, total = #paths, duplicates = {}, skipped = {}, errors = {} } }
  local lib, dir = state.library, state.library_dir
  local owned_paths = {}
  for i, path in ipairs(paths) do owned_paths[i] = path end
  local thread = coroutine.create(function()
    return service.import_files(state, owned_paths, category, {
      pause = coroutine.yield, summary = job.summary, on_sound = options.on_sound,
    })
  end)
  function job:cancel()
    if self.done then return end
    local ok, err = coroutine.close(thread)
    self.done, self.cancelled = true, true
    if not ok then self.error = err end
  end
  function job:step()
    if self.done then return true end
    if state.library ~= lib or state.library_dir ~= dir
      or (options.valid and not options.valid()) then
      self:cancel()
      return true
    end
    local ok, result = coroutine.resume(thread)
    if not ok then
      coroutine.close(thread)
      self.done, self.error = true, result
    elseif coroutine.status(thread) == "dead" then
      self.done = true
    end
    return self.done
  end
  return job
end

--------------------------------------------------------------- deleting

-- The names the trash folder is already using, for importer.unique_filename, and
-- `take(name)` to claim another. EVERY file counts, not just the audio: a note
-- whose audio never arrived (a sound whose file had already vanished, or a
-- delete stopped part-way) is still the only surviving record of that sound,
-- and overwriting it would destroy exactly what the trash is for. A note also
-- claims the audio name it describes. Windows filenames don't care about case;
-- nor may we.
function service.trash_names(trash_dir)
  local taken = {}
  local function take(name)
    local key = importer.name_key(name)
    taken[key] = true
    local speaks_for = key:match("^(.+)%.json$")
    if speaks_for then taken[speaks_for] = true end
  end
  for _, name in ipairs(reaper_api.list_files(trash_dir)) do take(name) end
  return taken, take
end

-- Delete sounds: each one's audio AND a note holding its full record move into the
-- trash folder inside the library, so putting one back brings back the name,
-- filing, note, trim and measurements — not just the file.
--
-- THE ORDER IS THE MIRROR OF IMPORT'S, and it matters just as much. The note is
-- written FIRST, before anything is destroyed, because the whole promise of the
-- feature is that the record survives: audio sitting in the trash with nothing
-- describing it is the one outcome that can't be undone. The costs of stopping
-- part-way, in order:
--
--   after the note, before the move — a stray note beside a sound that is still
--     in the library. Harmless: nothing reads the trash folder on its own.
--   after the move, before the save — the audio is in the trash while the record
--     still lists it. The save failing puts every moved file back; one that can't
--     go back reads as "file missing" until it is fixed. Every piece of it is
--     still on disk and nothing has been lost.
--
-- One user action is one save: the folders are listed once, every file is moved,
-- every record is removed, and then the Library is saved once. Saving the whole
-- Library per sound froze REAPER for seconds when deleting hundreds.
--
-- Returns { deleted = { record... }, refused = { { id, name, why, audio_gone } },
-- save_error = message or nil }. `audio_gone` marks a sound that is still listed
-- although its audio is in the trash. Never raises: every way this can fail is
-- something the user needs told, not a script crash.
function service.delete_sounds(state, ids)
  local lib = state.library
  local result = { deleted = {}, refused = {} }
  local function refuse(id, name, why, audio_gone)
    result.refused[#result.refused + 1] =
      { id = id, name = name or "That sound", why = why, audio_gone = audio_gone }
  end

  local by_id = {}
  for _, s in ipairs(lib.sounds) do by_id[s.id] = s end

  local trash_dir = reaper_api.join(state.library_dir, trash.DIR)
  reaper_api.ensure_dir(trash_dir)

  local taken, take = service.trash_names(trash_dir)

  -- Whether a sound's audio is there is read from the folder LISTING, not by
  -- trying to open the file: something else holding the file open would make it
  -- unopenable while it is very much still there, and calling that "already gone"
  -- would drop the record and leave the audio behind as an orphan.
  local present = {}
  for _, name in ipairs(reaper_api.list_files(state.library_dir)) do
    present[name:lower()] = true
  end

  local moved, seen = {}, {}
  for _, id in ipairs(ids or {}) do
    local record = not seen[id] and by_id[id]
    if not seen[id] and not record then
      refuse(id, nil, "That sound is no longer in your Library.")
    end
    seen[id] = true

    -- A stored filename is only ever a plain name inside the library folder. One
    -- carrying a path (from a hand-edited or damaged library file) would send the
    -- move somewhere else entirely, so refuse rather than touch an unrelated file.
    if record and not importer.is_stored_filename(record.filename) then
      refuse(id, record.name, string.format(
        "\"%s\" couldn't be deleted because its stored file name is invalid. It must be a plain name " ..
        "inside your Library folder. Nothing was changed.", record.name))
      record = nil
    end

    if record then
      local trashed_name = importer.unique_filename(record.filename, taken)
      local note_path    = reaper_api.join(trash_dir, trash.note_filename(trashed_name))
      local audio_src    = reaper_api.join(state.library_dir, record.filename)
      local audio_dest   = reaper_api.join(trash_dir, trashed_name)
      take(trashed_name)
      take(trash.note_filename(trashed_name))

      -- A record whose audio has already vanished still deletes — there is simply
      -- nothing to move, and leaving the row behind would help nobody. The note
      -- says so rather than naming a file that won't be beside it.
      local has_audio = present[record.filename:lower()] == true

      -- The chosen name cleared the listing-based check above, so anything ALREADY
      -- at either path is a collision that check cannot see: a name Windows folds
      -- to the same file (its Unicode case rules go beyond this tool's). Writing
      -- the note would replace the only record of an earlier trashed sound — the
      -- exact loss the taken-name set exists to prevent — so refuse before
      -- touching anything.
      if reaper_api.path_exists(note_path) or reaper_api.path_exists(audio_dest) then
        refuse(id, record.name, string.format(
          "\"%s\" couldn't be deleted because the trash folder already contains a file " ..
          "with the same name (%s). Rename the sound's file and try again. Nothing was changed.",
          record.name, trashed_name))
      else
        local wrote, werr = pcall(store.write_json, note_path,
          trash.note(lib, record, { filename = has_audio and trashed_name or nil }))
        local ok = wrote
        if not wrote then
          refuse(id, record.name, product_error.with_details(
            string.format("\"%s\" wasn't deleted because its details couldn't be written to the trash folder.",
              record.name), werr))
        elseif has_audio then
          local done, merr = reaper_api.move_file(audio_src, audio_dest)
          if not done then
            ok = false
            os.remove(note_path) -- abandon cleanly — nothing has been destroyed yet
            refuse(id, record.name, string.format(
              "\"%s\" wasn't deleted because its audio couldn't be moved to the trash folder.\n\n%s",
              record.name, tostring(merr)))
          end
        end
        if ok then
          moved[#moved + 1] = { record = record, has_audio = has_audio,
            note_path = note_path, audio_src = audio_src, audio_dest = audio_dest }
        end
      end
    end
  end
  if #moved == 0 then return result end

  for _, item in ipairs(moved) do
    item.removed, item.index = trash.remove(lib, item.record.id)
  end
  local saved, serr = pcall(store.save, state.library_path, lib)
  if saved then
    for _, item in ipairs(moved) do result.deleted[#result.deleted + 1] = item.record end
    return result
  end

  -- The Library didn't save, so none of these deletions happened. Put the records
  -- back where they were (last removed, first restored), then bring each file
  -- back out of the trash. Its note goes only once the audio is back; a sound
  -- whose audio can't come back keeps its note beside the audio and stays listed,
  -- visibly missing, which beats memory and disk quietly disagreeing.
  for i = #moved, 1, -1 do trash.restore(lib, moved[i].removed, moved[i].index) end
  local stranded = 0
  for _, item in ipairs(moved) do
    local name = item.record.name
    local back = not item.has_audio or reaper_api.move_file(item.audio_dest, item.audio_src)
    if back then os.remove(item.note_path) else stranded = stranded + 1 end
    local why = back
      and string.format("\"%s\" couldn't be deleted because the Library file wouldn't save. " ..
        "Nothing was changed.", name)
      or string.format("\"%s\" couldn't be deleted because the Library file wouldn't save. " ..
        "It's still listed, but its audio couldn't be moved back from the \"%s\" folder inside " ..
        "your Library, so it will appear missing.", name, trash.DIR)
    refuse(item.record.id, name, product_error.with_details(why, serr), not back)
  end
  result.save_error = product_error.with_details(
    "No sounds were deleted because the Library file wouldn't save. " .. (stranded == 0
      and "Nothing was changed."
      or string.format("%d of them %s still listed but will appear missing, because %s audio " ..
        "couldn't be moved back from the \"%s\" folder inside your Library.",
        stranded, stranded == 1 and "is" or "are", stranded == 1 and "its" or "their", trash.DIR)),
    serr)
  return result
end

-- One sound, for callers with a single id. Returns true, or false + the reason +
-- whether its audio is already in the trash.
function service.delete_sound(state, id)
  local result = service.delete_sounds(state, { id })
  if result.deleted[1] then return true end
  local refused = result.refused[1]
  return false, refused.why, refused.audio_gone
end

-- Compare the library folder against the records, both ways round, in one scan:
--
--   orphans — audio files no record points at (the residue of an interrupted
--             import, or files copied in by hand), by their real filenames.
--             The Review Files panel offers to add them or move them to the trash.
--   missing — records whose audio file is no longer there (deleted or moved
--             outside the tool). These matter more: the sound still looks normal
--             in the list, but nothing will play and no waveform will draw, so it
--             has to be said out loud rather than discovered by clicking.
--
-- Neither is written into the library. A file that vanished may well come back
-- (an unplugged drive, a sync still running), and marking the record would make a
-- temporary absence permanent.
function service.check_files(state)
  local known, on_disk = {}, {}
  for _, s in ipairs(state.library.sounds) do
    if s.filename then known[s.filename:lower()] = true end
  end
  for _, name in ipairs(reaper_api.list_audio_files(state.library_dir)) do
    on_disk[name:lower()] = name
  end

  local orphans, missing = {}, {}
  for key, name in pairs(on_disk) do
    if not known[key] then orphans[#orphans + 1] = name end
  end
  for _, s in ipairs(state.library.sounds) do
    if s.filename and not on_disk[s.filename:lower()] then missing[#missing + 1] = s end
  end
  return orphans, missing
end

return service
