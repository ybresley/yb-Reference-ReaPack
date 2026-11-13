-- pins_service: the operations behind project pins — pinning a library sound into
-- the current project, unpinning, and adopting a pin into the library. Sits
-- between the pure core (core/pins decides records but can't see the filesystem
-- or the project) and the adapters (reaper_api copies files, project_state holds
-- the per-project storage). Like library_service, it never calls reaper.* or
-- ImGui directly, and it isn't drawn from — the entry script invokes it.
--
-- Pinning follows import's crash-safe order: copy the audio into References/
-- FIRST, write the pin record LAST — a crash in between leaves at worst an
-- orphan file beside the project. Unpinning removes ONLY the record, never the
-- audio: the copy stays in References/ as a harmless leftover. That is a safety
-- decision, not laziness — the pin data only reaches the .RPP when the user
-- saves, so a deleted file could be resurrected as a record by an unsaved
-- project ("close without saving" would bring the pin back with its audio gone),
-- and a second project saved beside the first can reference the same folder.
-- Records may come back from an old save; files, once destroyed, cannot.
--
-- Durability: storing project values does NOT mark the project as needing a save
-- (verified in Phase 4), so every DATA change here also marks the project dirty —
-- otherwise a pin made in an otherwise-untouched project would silently evaporate
-- at close. Selection memory alone deliberately doesn't (see remember_selected).

local pins       = require("core.pins")
local importer   = require("core.importer")
local analysis   = require("core.analysis")
local copies     = require("analysis_copies")
local library_service = require("library_service")
local save_retry = require("core.save_retry")
local reaper_api = require("reaper_api")
local project    = require("project_state")

local product_error = require("product_error")
local service = {}
-- A failed Save As must keep using the original audio even after a tab switch.
-- This lasts only for the open project; no absolute path enters its pin data.
local stalled_moves = setmetatable({}, { __mode = "k" })

-- Every loaded pin set gets its own session number. Pin ids restart at "p1" in
-- every project, and REAPER may hand the same project pointer to a different
-- file opened into the same tab, so anything id-keyed that outlives a frame (a
-- label edit, a drag, the picker's preview) remembers this number rather than
-- the pointer. Save As keeps the number; another project, or the same file
-- reloaded with different pins, gets a new one.
local last_session = 0

-- How often refresh compares the stored pin text even when REAPER's change
-- counter hasn't moved, in seconds (see refresh).
local RECHECK_SECONDS = 1

local function empty_pins(proj, path)
  last_session = last_session + 1
  return {
    proj      = proj,                    -- which project this pin state belongs to
    session   = last_session,            -- identity for id-keyed work (see above)
    path      = path,                    -- its .RPP path ("" = never saved)
    dir       = project.refs_dir(path),  -- the References folder (nil until saved)
    data      = pins.new_state(),
    -- The stored pin text as last read or written. A project that still stores
    -- exactly this text is the one these records came from.
    text      = nil,
    change_count = nil,                  -- REAPER's change counter when `text` was checked
    checked_at = nil,                    -- the time `text` was last checked, in seconds
    by_origin = {},                      -- library sound id -> pin, for the list's markers
    origin_of = {},                      -- pin id -> library sound id, for "Show in library"
    markers_version = 0,                 -- bumped on every rebuild (see rebuild_markers)
    load_error = nil,
    load_newer = nil,                    -- the load error is newer-version data, not damage
  }
end

local DAMAGED = "This project's pinned references couldn't be read. Changes to pinned " ..
  "references are paused, and the saved data will not be overwritten. To discard the " ..
  "unreadable data, open the reference list and choose Start With No Pinned References."

local NEWER = "This project's pinned references were saved by a newer version of yb-Reference. " ..
  "Update yb-Reference to use them. Changes to pinned references are paused, and the saved " ..
  "data will not be overwritten."

-- The paused-data refusal, in one shape. `service.edit` asks it before every
-- change, but an operation that looks a pin UP first has to ask before it does:
-- unreadable data loads as an empty list, so the lookup would report a missing
-- pin and hide the real reason from the user.
local function damaged(state)
  if state.pins.relocation_error then return state.pins.relocation_error end
  if state.pins.load_newer then return NEWER end
  if state.pins.load_error then return DAMAGED end
  return nil
end

-- Whether pinning into this project could happen right now — the one check
-- shared by pinning a single sound and by importing a whole batch that will
-- all be pinned (import_and_pin, in the entry script). The batch case needs
-- the answer BEFORE it copies anything into the library: importing first and
-- discovering pinning is refused would strand sounds in the library with none
-- of them pinned, and retrying afterwards would just dedup to "already in
-- library" and never pin them. Returns the refusal message, or nil when
-- pinning is fine.
function service.can_pin(state)
  local ps = state.pins
  local refusal = damaged(state)
  if refusal then return refusal end
  if not ps.dir then
    return "Save the project first. Pinned references are stored in a References folder " ..
      "beside the project file."
  end
  return nil
end

-- Public: the entry script re-derives the markers itself after a library
-- switch (the pins didn't change, but the library they point into did).
--
-- `markers_version` counts the rebuilds. Every pin mutation goes through here,
-- so it's the one honest "the pinned set may have changed" signal — the entry
-- script watches it to re-sort a list that's currently ordered BY the pin
-- column, the same way a finished loudness measurement re-sorts a list ordered
-- by loudness.
function service.rebuild_markers(state)
  local by_origin = pins.markers(state.pins.data, state.library.sounds)
  -- The same map read the other way round, for "Show in library" on a pin's
  -- right-click menu. Built here rather than searched per frame, and from the
  -- SAME verified matches — so the menu item is offered exactly when the
  -- library table would show that sound's pin marker, never on a pin whose
  -- library twin can't be proven (a capture, or a teammate's pin).
  local origin_of = {}
  for sound_id, p in pairs(by_origin) do origin_of[p.id] = sound_id end
  state.pins.by_origin = by_origin
  state.pins.origin_of = origin_of
  state.pins.markers_version = (state.pins.markers_version or 0) + 1
end
local rebuild_markers = service.rebuild_markers

local function same_folder(a, b)
  if package.config:sub(1, 1) == "\\" then
    a, b = a:gsub("/", "\\"):lower(), b:gsub("/", "\\"):lower()
  end
  return a == b
end

local function missing_note(names)
  if #names == 0 then return nil end
  if #names == 1 then
    return string.format("\"%s\" has no audio in the original References folder, so it wasn't copied.",
      names[1])
  end
  return string.format("%d pinned references have no audio in the original References folder, " ..
    "so they weren't copied: \"%s\".", #names, table.concat(names, "\", \""))
end

local function assumed_note(names)
  if #names == 0 then return nil end
  if #names == 1 then
    return string.format("\"%s\" has no audio in the original References folder, so it now uses the file " ..
      "with the same name and size in the new one. Play it to check it's the right sound.", names[1])
  end
  return string.format("%d pinned references have no audio in the original References folder, so they now " ..
    "use the files with the same names and sizes in the new one: \"%s\". Play them to check they're the " ..
    "right sounds.", #names, table.concat(names, "\", \""))
end

local function join_messages(a, b)
  if a and b then return a .. " " .. b end
  return a or b
end

-- Whether this pin's audio is already in the new folder under its own name,
-- byte for byte. Opening an earlier Save As copy into this tab looks exactly
-- like Save As (same tab, same pin text), and that copy's References folder
-- already holds its audio. Copying again would rename its pin.
--
-- When the original file is gone there is nothing to compare, so the size the
-- pin recorded when it was made stands in for it, and the answer is "assumed"
-- rather than "same". Without this, a healthy copy opened into a tab whose own
-- audio is missing had its pin renamed to a file that doesn't exist. Equal
-- name and size don't prove equal audio, so an assumed match is always
-- reported for the user to check. An original that exists but can't be read is
-- no match: the copy that follows fails and the move stops visibly.
local function already_there(old_dir, new_dir, pin)
  local src = reaper_api.join(old_dir, pin.filename)
  local dest = reaper_api.join(new_dir, pin.filename)
  local size, dest_size = reaper_api.file_size(src), reaper_api.file_size(dest)
  if size then
    return dest_size == size and library_service.identical_files(src, dest) and "same" or nil
  end
  if not reaper_api.path_exists(src) and pin.size_bytes ~= nil and dest_size == pin.size_bytes then
    return "assumed"
  end
  return nil
end

-- Which pins are already there, whether all of them are, and the names of
-- those only assumed to be. Decided before anything is copied, so a pin can
-- never match a file this move has just written for another pin: two pins
-- sharing one file would fail the pin list's own load check.
local function pins_in_place(old_dir, new_dir, list)
  local in_place, all, assumed = {}, true, {}
  for i, pin in ipairs(list) do
    local match = already_there(old_dir, new_dir, pin)
    in_place[i] = match ~= nil
    all = all and in_place[i]
    if match == "assumed" then assumed[#assumed + 1] = pin.name end
  end
  return in_place, all, assumed
end

-- All copies must land before any pin changes its address. An existing name is
-- not proof of matching audio, even when its byte size matches the original.
-- Completed copies stay on disk after a refusal; deleting them could damage a
-- project saved by another process while this move was in progress.
--
-- A pin whose audio is already missing gets its own unused name in the new
-- folder and stays missing there, unless a file with its name and recorded
-- size is already in that folder. It then uses that file, and the user is told
-- to check it.
local function carry_files_forward(old_dir, fresh, original_text, retry)
  local data, plan, missing, assumed = fresh.data, {}, {}, {}
  local changed = retry == true
  local moving = not same_folder(old_dir, fresh.dir)
  if moving then
    local in_place, all
    in_place, all, assumed = pins_in_place(old_dir, fresh.dir, data.pins)
    -- When every pin is already there, nothing is copied and the project isn't
    -- marked changed: the user never caused a save. A retry still rewrites the
    -- stored text: an earlier refused write may have left it different from
    -- these records.
    if all and not retry then return true, assumed_note(assumed) end
    reaper_api.ensure_dir(fresh.dir)
    local taken, listed = {}, nil
    for _, name in ipairs(reaper_api.list_files(fresh.dir)) do taken[name:lower()] = true end
    for i, pin in ipairs(data.pins) do
      -- A pin already there keeps its name, even when another pin in the same
      -- set still needs copying.
      local name = pin.filename
      if not in_place[i] then
        name = importer.unique_filename(pin.filename, taken)
        taken[name:lower()] = true
        local src = reaper_api.join(old_dir, pin.filename)
        -- Audio absent from a reachable folder has nothing to copy. A file that
        -- is listed but can't be opened (locked, no permission), or a folder
        -- that can't be reached, must still stop the move: that audio exists.
        local absent = false
        if not reaper_api.path_exists(src) and reaper_api.directory_exists(old_dir) then
          if not listed then
            listed = {}
            for _, n in ipairs(reaper_api.list_files(old_dir)) do listed[n:lower()] = true end
          end
          absent = not listed[pin.filename:lower()]
        end
        if absent then
          missing[#missing + 1] = pin.name
        else
          local ok, err = reaper_api.copy_file(src, reaper_api.join(fresh.dir, name))
          if not ok then return false, err end
        end
      end
      plan[#plan + 1] = { pin = pin, before = pin.filename, after = name }
      changed = changed or name ~= pin.filename
    end
  end
  if not changed then return true, join_messages(missing_note(missing), assumed_note(assumed)) end
  for _, item in ipairs(plan) do item.pin.filename = item.after end
  local ok, saved = pcall(project.write_pins, fresh.proj, pins.encode(data))
  if not ok or not saved then
    for _, item in ipairs(plan) do item.pin.filename = item.before end
    -- Read-back failure may mean a partial write. Restore the exact previous
    -- text when possible; the session fallback remains necessary either way.
    pcall(project.write_pins, fresh.proj, original_text or pins.encode(data))
    return false, "The updated pinned references couldn't be saved in the project."
  end
  project.mark_dirty(fresh.proj)
  return true, join_messages("Pinned references are ready in this project's References folder. " ..
    "Save the project again to keep them.", join_messages(missing_note(missing), assumed_note(assumed)))
end

-- Bring state.pins in line with the project in front of the user. Called once per
-- frame (a few cheap calls and a compare when nothing changed): switching project
-- tabs, opening a project, reopening one, or Save As all land here. Returns nil
-- when nothing changed, else { selected = <pin id to restore, or nil>,
-- warning = <msg, or nil>, same_project = <true for Save As> }.
--
-- Reloading never loses anything: every pin mutation is written into the
-- project's storage immediately (see persist), so reading it back IS the latest.
--
-- Damaged pin data is reported and treated as read-only-empty rather than
-- blocking the tool: unlike the library (a user's whole collection), this is one
-- project's small list, and the last saved .RPP still holds the stored text.
-- Every mutation is refused until the user explicitly discards it (reset_pins).
function service.refresh(state)
  local proj, path = project.current()
  local ps = state.pins
  if ps and ps.proj == proj and ps.path == path then
    -- Same tab, same file. Reopening that file, or an undo, can still replace
    -- the stored pins without changing either, and the next edit would then
    -- write this stale list over them. The text is re-read when REAPER's change
    -- counter moves. Whether reopening a file moves that counter isn't
    -- verified, so the text is also re-read about once a second; never every
    -- frame.
    local count, now = project.change_count(proj), reaper_api.now()
    if count == ps.change_count and now - ps.checked_at < RECHECK_SECONDS then return nil end
    ps.change_count, ps.checked_at = count, now
    if project.read_pins(proj) == ps.text then return nil end
  end

  -- The same pointer under a new path is Save As only while the project still
  -- stores exactly the pin text this tool last read or wrote. Opening another
  -- file into the tab may keep the pointer, and that project's own pins must
  -- load as a different project: never inherit this one's audio, stall or list.
  local text = project.read_pins(proj)
  local same_project = ps ~= nil and ps.proj == proj and ps.path ~= path and ps.text == text
  local held = stalled_moves[proj]
  if held and (held.text ~= text or (not same_project and held.path ~= path)) then
    held = nil; stalled_moves[proj] = nil
  end
  local moved_from = held and held.dir
    or ((same_project and ps.dir and #ps.data.pins > 0) and ps.dir or nil)
  -- Pins that can't be read can't be moved either; Save As leaves their audio
  -- in the original folder, and the user is told so below.
  local left_in = same_project and ps.load_error and ps.dir or nil

  local fresh
  if same_project then
    -- Save As keeps this pin set and its records, rather than decoding a copy of
    -- the same text. The selection, playback, pauses, measurements, a trim still
    -- being dragged and the picker all stay attached, and a moved file is simply
    -- the same record under its new name.
    fresh = ps
    fresh.path, fresh.dir, fresh.relocation_error = path, project.refs_dir(path), nil
  else
    fresh = empty_pins(proj, path)
    if held then
      fresh.data = held.data
    elseif text then
      local ok, result = pcall(pins.decode, text)
      if ok then
        fresh.data = result
      elseif pins.saved_by_newer(text) then
        fresh.load_error, fresh.load_newer = NEWER, true
      else
        fresh.load_error = DAMAGED
      end
    end
  end

  local warning = nil
  if held and held.path == path then
    fresh.dir, fresh.relocation_error = held.dir, held.warning
    warning = held.warning
  elseif moved_from and fresh.dir and (held or not same_folder(moved_from, fresh.dir))
      and not fresh.load_error then
    local ok, message = carry_files_forward(moved_from, fresh, text, held ~= nil)
    if ok then
      stalled_moves[proj] = nil
      warning = message
    else
      warning = product_error.with_details(
        "Pinned references couldn't be moved to the project's new folder. They still use the original " ..
        "References folder in this session, and changes to pins are paused. Before closing yb-Reference, " ..
        "use Save As to save the project in its original folder or another folder, then save again. " ..
        "The saved project may otherwise open the wrong audio. Original References folder:\n" .. moved_from,
        message)
      fresh.dir, fresh.relocation_error = moved_from, warning
      stalled_moves[proj] = { path = path, dir = moved_from, data = fresh.data, warning = warning,
        text = project.read_pins(proj) }
    end
  elseif left_in and fresh.dir and not same_folder(left_in, fresh.dir)
      and reaper_api.directory_exists(left_in) then
    warning = string.format("This project's pinned references %s, so their audio wasn't copied to the " ..
      "References folder beside the new project file. Copy the files there to keep them with the " ..
      "project. Original References folder:\n%s",
      fresh.load_newer and "were saved by a newer version of yb-Reference" or "couldn't be read", left_in)
  end

  fresh.text = project.read_pins(proj)
  fresh.change_count = project.change_count(proj)
  fresh.checked_at = reaper_api.now()
  state.pins = fresh
  rebuild_markers(state)
  return { selected = fresh.data.selected, warning = warning, same_project = same_project }
end

-- Write the pin state into the project's storage (in memory at once; it reaches
-- the .RPP when the user saves the project), verified by read-back, and mark the
-- project as needing that save — without the mark, REAPER would never prompt for
-- it and the change would evaporate at close.
--
-- opts.quiet skips the dirty-mark (selection memory only — not worth a save
-- prompt of its own). opts.force allows the one deliberate overwrite of damaged
-- data (reset_pins); everything else is refused while a load error stands, so a
-- broken-but-recoverable stored text can't be clobbered by accident.
--
-- Private on purpose: a bare store is a store with no way back, and a caller who
-- forgets the way back leaves the user looking at a change the project never
-- took. Everything that alters the records goes through service.edit. Three
-- callers below deliberately don't — remember_selected, reset_pins and
-- save_pin_to_library's origin link — and each says why where it calls this;
-- that is the whole list.
local function persist(state, opts)
  opts = opts or {}
  local ps = state.pins
  if ps.relocation_error then return false end
  if ps.load_error and not opts.force then return false end
  local text = pins.encode(ps.data)
  if not project.write_pins(ps.proj, text) then return false end
  ps.text = text
  if not opts.quiet then project.mark_dirty(ps.proj) end
  return true
end

-- The one way to change pin data. Every operation does the same three things:
-- change the records, store them, and put the change BACK when storing is
-- refused — so what the user sees and what the project holds can never drift
-- apart. Writing that out per operation is exactly how the trim and start/end
-- commits ended up with no way back at all, so it lives here once.
--
-- `fn` makes the change and returns the closure that reverses it — or nil when
-- it changed nothing, in which case there is nothing to store and no save to ask
-- for. A second return value from `fn` is handed back to the caller.
--
-- Returns (true, value) on success. On failure (false, reason), where reason is
-- DAMAGED when the stored text may not be touched at all, and nil when the store
-- itself refused: only the caller knows what was being changed, so only the
-- caller can word that one.
function service.edit(state, fn)
  local refusal = damaged(state)
  if refusal then return false, refusal end
  local undo, value = fn()
  if not undo then return true end
  if not persist(state) then
    undo()
    return false, nil
  end
  return true, value
end
local edit = service.edit

-- Pinning that pauses between copy chunks must finish in the project it started
-- in, or not at all. Returns a function that answers whether the project in
-- front still has the same pin set, References folder, path and Library.
-- REAPER can open another file into the same tab under the same pointer, and
-- two never-pinned projects in one folder even share their empty pin text and
-- References folder, so only the path tells them apart.
function service.pin_target(state)
  local ps, library = state.pins, state.library
  local data, dir, path = ps.data, ps.dir, ps.path
  return function()
    return state.pins == ps and ps.data == data and ps.dir == dir and ps.path == path
      and state.library == library
  end
end

-- Whether a pin's References copy and a Library sound's file hold the same
-- audio, compared the way import compares files: the Library file goes in as
-- the existing copy, so both checks follow import's rule for a copy that can't
-- be read. With no References folder there is no copy to read and nothing
-- could be copied, so the name and size answer alone.
local function same_audio(state, pin, sound)
  if not state.pins.dir then return true end
  return library_service.same_content(reaper_api.join(state.pins.dir, pin.filename),
    reaper_api.join(state.library_dir, sound.filename), pin.size_bytes)
end

local function already_pinned(state, sound)
  return pins.already_pinned(state.pins.data, sound,
    function(p) return same_audio(state, p, sound) end)
end

-- Pin a library sound to the current project. Returns (true, message, pin_id) or
-- (false, message[, existing_pin_id when it was already pinned]).
function service.pin_sound(state, sound, copy_file)
  local ps = state.pins
  local same_target = service.pin_target(state)

  local refusal = service.can_pin(state)
  if refusal then return false, refusal end

  local existing = already_pinned(state, sound)
  if existing then
    return false, string.format("\"%s\" is already pinned to this project.", sound.name), existing.id
  end

  reaper_api.ensure_dir(ps.dir)

  -- Names already spoken for = pin records UNION the real folder listing, so a
  -- crash-orphaned copy (or anything else the user keeps there) is never
  -- overwritten — the same rule import applies to the library folder.
  local taken = pins.taken_filenames(ps.data)
  for _, name in ipairs(reaper_api.list_files(ps.dir)) do
    taken[name:lower()] = true
  end
  local dest_name = importer.unique_filename(sound.filename, taken)
  local src = reaper_api.join(state.library_dir, sound.filename)
  local dest = reaper_api.join(ps.dir, dest_name)

  local copied, cerr = (copy_file or reaper_api.copy_file)(src, dest)
  -- The injected copier may yield between chunks. Its completed audio remains
  -- harmless if another action changed the destination while it was working.
  if not same_target() then
    return false, "The sound wasn't pinned because the project or Library changed while its audio was being copied."
  end
  refusal = service.can_pin(state)
  if refusal then return false, refusal end
  existing = already_pinned(state, sound)
  if existing then
    return false, string.format("\"%s\" is already pinned to this project.", sound.name), existing.id
  end
  if not copied then
    return false, string.format("\"%s\" couldn't be pinned because its audio couldn't be copied " ..
      "to the project's References folder:\n\n%s",
      sound.name, tostring(cerr))
  end

  local opts = pins.snapshot(sound)
  opts.filename = dest_name

  local ok, record = edit(state, function()
    local added = pins.add(ps.data, opts)
    return function()
      -- The record couldn't be stored in the project, so it would not survive the
      -- session — take it back out and remove the copy, leaving things as they were.
      pins.remove(ps.data, added.id)
      os.remove(dest)
    end, added
  end)
  if not ok then
    return false, string.format("\"%s\" couldn't be pinned because the pinned reference " ..
      "couldn't be saved in your project.", sound.name)
  end

  copies.remember(state, sound, record)
  rebuild_markers(state)
  return true, string.format("\"%s\" is pinned to this project. Save the project to keep it.", sound.name),
    record.id
end

-- Pin several Library sounds as one background job, driven a step at a time by
-- the entry loop like an import. Each copy pauses between chunks, so a long file
-- never holds REAPER up, and the job stops as soon as the project, its pins or
-- the Library change underneath it. Every result is counted for one summary,
-- rather than each sound's message replacing the last.
--
-- `on_pinned(pin_id, added)` runs for a new pin (added = true) and for a sound
-- that was already pinned (added = false).
function service.start_pinning(state, sounds, on_pinned)
  local same_target = service.pin_target(state)
  local list = {}
  for i, sound in ipairs(sounds) do list[i] = sound end
  local job = { kind = "pin",
    summary = { total = #list, current = 0, pinned = 0, already = 0, errors = {}, last_message = nil } }
  local function copy(src, dest) return reaper_api.copy_file(src, dest, coroutine.yield) end
  local thread = coroutine.create(function()
    local sum = job.summary
    for i, sound in ipairs(list) do
      sum.current = i
      local ok, message, pin_id = service.pin_sound(state, sound, copy)
      sum.last_message = message
      if ok then
        sum.pinned = sum.pinned + 1
      elseif pin_id then
        sum.already = sum.already + 1
      else
        sum.errors[#sum.errors + 1] = message
      end
      if pin_id and on_pinned then on_pinned(pin_id, ok) end
      coroutine.yield()
    end
  end)
  -- Closing the coroutine also closes a suspended copy's files and removes its
  -- partial file.
  function job:cancel()
    if self.done then return end
    local ok, err = coroutine.close(thread)
    self.done, self.cancelled = true, true
    if not ok then self.error = err end
  end
  function job:step()
    if self.done then return true end
    if not same_target() or service.can_pin(state) then
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

-- Unpin: the record leaves the project; the References copy deliberately stays
-- (see the top of this file — an unsaved project can resurrect the record, and a
-- neighbouring project may reference the same folder; a leftover file is
-- harmless, a destroyed one is forever).
function service.unpin(state, pin_id)
  local ps = state.pins
  local refusal = damaged(state)
  if refusal then return false, refusal end
  local p = pins.find(ps.data, pin_id)
  if not p then return false, "That pin is no longer in this project." end

  local ok, reason = edit(state, function()
    local was_selected = ps.data.selected
    -- Also clears it as the remembered selection; `index` lets a failed store put
    -- everything back exactly as it was.
    local removed, index = pins.remove(ps.data, pin_id)
    return function()
      -- Couldn't store the removal: put the record back at the position it held
      -- (plus the remembered selection) so memory and the project agree — a
      -- refusal must not quietly reorder the sidebar.
      table.insert(ps.data.pins, index, removed)
      ps.data.selected = was_selected
    end
  end)
  if not ok then
    return false, reason or
      string.format("\"%s\" couldn't be unpinned because the change couldn't be saved in your project.", p.name)
  end
  copies.forget(state, function(id) return id == pin_id end)
  rebuild_markers(state)
  return true, string.format(
    "\"%s\" is unpinned. Save the project to keep this change. Its audio remains in the References folder.",
    p.name)
end

-- Set (or clear) a pin's job label. Like every other pin-data change: refused
-- while stored data is damaged, persisted + marks the project dirty on
-- success, rolled back on a failed store. Duplicate labels are allowed — a
-- label describes a job ("Fire"), not an identity.
function service.set_pin_label(state, pin_id, label)
  local ps = state.pins
  local refusal = damaged(state)
  if refusal then return false, refusal end
  local p = pins.find(ps.data, pin_id)
  if not p then return false, "That pin is no longer in this project." end

  local ok, reason = edit(state, function()
    local old = p.label
    pins.set_label(ps.data, pin_id, label)
    return function() p.label = old end
  end)
  if not ok then
    return false, reason or string.format("\"%s\"'s label couldn't be saved in your project.", p.name)
  end
  return true, p.label
    and string.format("\"%s\" labelled \"%s\".", p.name, p.label)
    or string.format("\"%s\"'s label cleared.", p.name)
end

-- Move a pin to another position in the stored order (the picker's edit mode).
-- The order is what the picker's arrows step through, so it's real project data:
-- refused while stored data is damaged, persisted + marks the project dirty on
-- success, and put back exactly where it was if the store fails.
function service.reorder_pin(state, pin_id, to_index)
  local ps = state.pins
  local refusal = damaged(state)
  if refusal then return false, refusal end
  local p = pins.find(ps.data, pin_id)
  if not p then return false, "That pin is no longer in this project." end

  local ok, reason = edit(state, function()
    local from = pins.reorder(ps.data, pin_id, to_index)
    if not from then return nil end -- already there: nothing to store, nothing to say
    return function() pins.reorder(ps.data, pin_id, from) end
  end)
  if not ok then
    return false, reason or
      string.format("\"%s\" couldn't be moved because the new order couldn't be saved in your project.", p.name)
  end
  return true
end

-- Adopt a pin into the library ("save to my library"). Dedup comes first, both
-- ways it can match: a verified origin (the id AND the content facts agree — an
-- id alone can collide with an unrelated sound in someone else's library), or
-- the library already holding the same content. Matching never copies anything;
-- the existing sound is simply pointed out. Returns (ok, message, sound_id,
-- added, unsaved) — `added` says a new record was created, so the caller can
-- refresh the view and the analysis queue, and `unsaved` that the Library file
-- doesn't have it yet.
--
-- `library_saves` is the caller's save tracker (core/save_retry). Saving through
-- it means a failed save is retried on its timer like any other Library change,
-- rather than waiting for a change the user may never make.
function service.save_pin_to_library(state, pin_id, library_saves)
  local ps = state.pins
  local lib = state.library
  local p = pins.find(ps.data, pin_id)
  if not p then return false, "That pin is no longer in this project." end

  local existing
  for _, s in ipairs(lib.sounds) do
    if pins.origin_match(p, s) then existing = s; break end
  end
  existing = existing or importer.find_duplicate(lib, p.source_name, p.size_bytes,
    function(s) return same_audio(state, p, s) end)
  if existing then
    -- Remember the link when it was found by content: the marker lights up and
    -- the next check answers instantly. Best-effort — the dedup answer stands
    -- even if the project won't store the updated link right now.
    if p.origin_id ~= existing.id then
      p.origin_id = existing.id
      persist(state)
    end
    rebuild_markers(state)
    return true, string.format("\"%s\" is already in your Library as \"%s\". Nothing was copied.",
      p.name, existing.name), existing.id, false
  end

  if not ps.dir then
    return false, "Save the project first. This pinned reference has no References folder " ..
      "to copy audio from."
  end

  local taken = importer.taken_filenames(lib)
  for _, name in ipairs(reaper_api.list_audio_files(state.library_dir)) do
    taken[name:lower()] = true
  end
  local dest_name = importer.unique_filename(p.filename, taken)
  local src = reaper_api.join(ps.dir, p.filename)
  local dest = reaper_api.join(state.library_dir, dest_name)

  local copied, cerr = reaper_api.copy_file(src, dest)
  if not copied then
    return false, string.format("\"%s\" couldn't be saved to your Library because its audio " ..
      "couldn't be copied:\n\n%s",
      p.name, tostring(cerr))
  end

  local record = importer.add_sound(lib, {
    filename    = dest_name,
    name        = p.name,
    note        = p.note,
    trim_db     = p.trim_db,
    duration    = p.duration,
    channels    = p.channels,
    source_name = p.source_name,
    size_bytes  = p.size_bytes,
  })
  -- The pin's measurements travel with it; only a completed measurement is worth
  -- carrying (pending/failed stays "pending" so the background analysis measures
  -- the new library copy itself). A pin measured under the old three-value
  -- scheme — "done" but with nothing in any of the newer fields — also lands as
  -- "pending": its numbers carry over for the meantime and the background
  -- analysis quietly brings the library copy up to the full six, the same deal
  -- the v2 -> v3 library migration gives existing sounds. (A truly silent pin
  -- gets one cheap pointless re-measure out of this; that beats a library
  -- record frozen at three values forever.)
  if p.analysis == "done" then
    for _, field in ipairs(analysis.FIELDS) do record[field] = p[field] end
    if p.lufs_s_max or p.peak or p.rms then record.analysis = "done" end
  end
  -- The start/end points travel exactly like the trim does.
  record.span_start, record.span_end = p.span_start, p.span_end

  local saved, serr = save_retry.try(library_saves)
  if not saved then
    -- Same stance as import: the sound is in the in-memory library and every
    -- retry writes the whole library again, so the tool keeps going. The pin is
    -- linked only once its Library record is safely on disk.
    local message = product_error.with_details(
      string.format("\"%s\" was added to your Library, but the Library file couldn't be saved. " ..
        "yb-Reference will keep trying to save it.", p.name), serr)
    return true, message, record.id, true, true
  end

  -- Link the pin to its new library sound (marker + instant dedup from now on).
  -- Best-effort like the content-match link above.
  p.origin_id = record.id
  persist(state)
  rebuild_markers(state)

  return true, string.format("\"%s\" saved to your Library.", p.name), record.id, true
end

-- Put a pin's live-edited fields back to what the project ACTUALLY stores.
-- Returns whether it could: a project whose pin text has gone missing (or turned
-- unreadable since it was loaded) can't answer, and the caller then says the
-- value is still adrift rather than claiming a rollback that never happened.
local function restore_stored(ps, pin, fields)
  local text = project.read_pins(ps.proj)
  if not text then return false end
  local ok, data = pcall(pins.decode, text)
  if not ok then return false end
  local kept = pins.find(data, pin.id)
  if not kept then return false end
  for _, f in ipairs(fields) do pin[f] = kept[f] end
  return true
end

local TRIM_FIELDS = { "trim_db" }
local SPAN_FIELDS = { "span_start", "span_end" }

-- Store a value the user has ALREADY heard. The trim fader and the start/end
-- handles move the sound live and only reach the project on release, so by the
-- time the commit arrives the change is in the record and there is no "value
-- before this call" to hand back — what the project holds is the value from
-- before the whole gesture, and re-reading it is the only honest way to recover
-- it. `refused` and `adrift` are the two truths a failure can have: the record
-- went back, or it couldn't be put back and still differs from the project.
local function commit_live_edit(state, pin, fields, refused, adrift)
  local restored = false
  local ok, reason = edit(state, function()
    return function() restored = restore_stored(state.pins, pin, fields) end
  end)
  if ok then return true end
  if reason then return false, reason end
  return false, restored and refused or adrift
end

-- Per-pin trim, mirroring the library sound flow: the audio follows the fader
-- live, the value reaches the project on release.
function service.commit_trim(state, pin)
  return commit_live_edit(state, pin, TRIM_FIELDS,
    "The trim couldn't be saved in your project. Its previous value was restored.",
    "The trim couldn't be saved in your project. The current value will reset to the " ..
      "previously saved value when the project changes or reopens.")
end

-- The start/end points, on the trim's exact save rhythm.
function service.commit_span(state, pin)
  return commit_live_edit(state, pin, SPAN_FIELDS,
    "The start and end points couldn't be saved in your project. Their previous values were restored.",
    "The start and end points couldn't be saved in your project. The current values will reset " ..
      "to the previously saved values when the project changes or reopens.")
end

-- Remember the last selected reference for this project. Only ever called with a
-- PIN id — a library id stored in a shared project would name a different sound
-- on a teammate's machine (see core/pins) — or nil, which clears the memory (the
-- user moved on to a library sound; restoring an older pin would be a lie).
-- Quiet: selection memory rides along with the user's own next save, it never
-- earns a save prompt of its own. Best-effort by design.
function service.remember_selected(state, pin_id)
  local ps = state.pins
  if ps.data.selected == pin_id then return end
  ps.data.selected = pin_id
  persist(state, { quiet = true })
end

-- The one deliberate escape from damaged pin data: the user chose to discard it.
-- Overwrites the stored text with a fresh empty state (the previous text remains
-- in the last saved .RPP until they save again — recoverable up to that point).
function service.reset_pins(state)
  local ps = state.pins
  if ps.relocation_error then return false, ps.relocation_error end
  -- Newer-version data is intact; only an update can read it, never a reset.
  if ps.load_newer then return false, ps.load_error end
  ps.data = pins.new_state()
  if not persist(state, { force = true }) then
    return false, "The damaged pinned-reference data couldn't be replaced. Nothing was changed."
  end
  ps.load_error = nil
  rebuild_markers(state)
  return true, "This project's pinned references were reset. Pinning works here again. " ..
    "Save the project to keep this change."
end

-- Land the result of a job that was requested for one particular pin. The
-- caller keeps the record itself with the job: checking that identity here
-- prevents a late result from changing a replacement that reused the same id.
-- A failed pass keeps the numbers already in the snapshot; it only records the
-- failed state so a later retry can be told apart from a pending first pass.
-- Failing again changes nothing, so it stores nothing: a pin whose audio is
-- missing must not ask for a save every time its project comes to the front.
function service.complete_analysis(state, expected_pin, results)
  local ps = state.pins
  local current = ps and pins.find(ps.data, expected_pin and expected_pin.id)
  if not current or current ~= expected_pin or not analysis.pin_needs(current) then return false, nil end

  local old = { analysis = current.analysis }
  for _, field in ipairs(analysis.FIELDS) do old[field] = current[field] end
  local ok, reason = service.edit(state, function()
    if not results and current.analysis == "failed" then return nil end
    if results then
      for _, field in ipairs(analysis.FIELDS) do current[field] = results[field] end
      current.analysis = "done"
    else
      current.analysis = "failed"
    end
    return function()
      current.analysis = old.analysis
      for _, field in ipairs(analysis.FIELDS) do current[field] = old[field] end
    end
  end)
  if not ok then
    return false, reason or "The pin's loudness result couldn't be saved in the project."
  end
  return true
end

return service
