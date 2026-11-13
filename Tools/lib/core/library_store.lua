-- Library persistence: turn the in-memory library table into JSON on disk and
-- back, safely.
--
-- Pure Lua plus the standard io/os library only (no reaper.*, no ImGui) so it
-- runs under Busted. The parent folder must already exist — creating the library
-- folder is the reaper layer's job (RecursiveCreateDirectory); this module only
-- reads and writes files inside it.
--
-- Files beside library.json that this module owns:
--   library.json.tmp / .bak  the two halves of a save in progress (see save).
--   library.prev.json        the library as it was before the latest save. Lua
--                            cannot force a save onto the disk, so after a power
--                            cut the newest file can read back empty; this copy
--                            is what the user can fall back on.
--   library.v<N>.json        written once, before a load upgrades a version N
--                            file, so going back to an older yb-Reference still
--                            has a file it can open.
-- Recovery and the "is a library here?" checks look only at library.json, .tmp
-- and .bak, never at the two kept copies: a kept copy is for the user to choose,
-- not something to restore silently.

local json = require("vendor.json")
local schema = require("core.schema")

local store = {}

-- Start of the error a load raises when an upgrade could not be saved. The file
-- itself is fine; something (a sync tool, a lock) stopped the write.
local NOT_SAVED = "the upgraded library couldn't be saved: "

-- Encode a library table to a JSON string. Pure.
function store.encode(data)
  return json.encode(data)
end

-- Decode a JSON string into a validated, migrated library table. Pure.
-- Raises a clear error on broken JSON or a non-library shape rather than
-- returning half-parsed data (fail loud — never silently wipe a bad file).
-- Returns the data, whether it changed and needs saving, and the version the
-- text was stored at.
function store.decode(text)
  if type(text) ~= "string" or text == "" then
    error("library file is empty")
  end
  local ok, result = pcall(json.decode, text)
  if not ok then
    error("library file is not valid JSON: " .. tostring(result))
  end
  if type(result) ~= "table" then
    error("library file doesn't contain a library (file is corrupt)")
  end
  local stored_version = result.version
  local data = schema.migrate(result)
  local repaired = schema.clear_missing_categories(data)
  return data, repaired or stored_version ~= data.version, stored_version
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

-- Does a library file exist at this path?
function store.exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

-- Is SOMETHING at this path, even if it can't be opened right now (an exclusive
-- lock by a backup or sync tool)? Renaming a name to itself only succeeds when a
-- real entry is there. The distinction matters exactly once, at startup: only a
-- path that is truly EMPTY may become a fresh library. Treating a locked library
-- as missing would create an empty one in memory — and the first save after the
-- lock clears would then replace the user's real library with that emptiness.
function store.present(path)
  if store.exists(path) then return true end
  return os.rename(path, path) == true
end

-- "library.json" -> "library<suffix>.json"; any other name gets the suffix.
local function beside(path, suffix)
  local stem = path:match("^(.*)%.json$")
  if stem then return stem .. suffix .. ".json" end
  return path .. suffix
end

-- Where the library from before the latest save is kept.
function store.previous_path(path)
  return beside(path, ".prev")
end

-- Where a version N library is kept before a load upgrades it.
function store.version_path(path, version)
  return beside(path, ".v" .. tostring(version))
end

-- Write `text` to "<path>.tmp" completely, or raise having removed the partial
-- file. Checking the CLOSE matters as much as the write: close is when buffered
-- bytes actually reach the disk, so that's where a full disk surfaces. Nothing
-- existing is touched here, so a failure always leaves the old file intact.
local function write_temp(path, text, what)
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "wb")
  if not f then
    error("could not open temp file for writing: " .. tostring(err))
  end
  local wrote, werr = f:write(text)
  if not wrote then
    f:close()
    os.remove(tmp)
    error("could not write " .. what .. ": " .. tostring(werr))
  end
  local closed, cerr = f:close()
  if not closed then
    os.remove(tmp)
    error("could not finish writing " .. what .. " (disk full?): " .. tostring(cerr))
  end
  return tmp
end

-- After a completed swap the .bak holds the previous library. Keep it as the
-- previous copy rather than deleting it. A leftover .bak is never kept: recover
-- would promote it whenever library.json goes missing, including when the user
-- moved the file away on purpose. If the copy can't be kept, the .bak goes, as
-- it always has.
local function keep_previous(path)
  local bak = path .. ".bak"
  if not store.exists(bak) then return end
  local prev = store.previous_path(path)
  os.remove(prev)
  if not os.rename(bak, prev) then os.remove(bak) end
end

-- Swap `text` into place atomically: fully write a temp file, then swap it into
-- place, so a crash mid-write can never leave a half-written file.
--
-- Windows caveat: os.rename won't overwrite an existing file, so we move the
-- current file aside to a .bak first, then rename the temp into place, then deal
-- with the backup. If the swap fails partway, the old file is restored here; if
-- REAPER is killed mid-swap (old file already moved to .bak, new file not yet in
-- place), store.recover() rescues it on next startup.
local function swap_in(path, text, what, keep)
  local tmp = write_temp(path, text, what)
  local bak = path .. ".bak"
  if store.exists(path) then
    os.remove(bak) -- clear any stale backup from a previous interrupted save
    local ok = os.rename(path, bak)
    if not ok then
      os.remove(tmp)
      error("could not back up existing " .. what .. " before saving")
    end
  end

  local ok, rerr = os.rename(tmp, path)
  if not ok then
    -- Swap failed: put the old file back so the on-disk file stays intact.
    if store.exists(bak) then os.rename(bak, path) end
    os.remove(tmp)
    error("could not save " .. what .. ": " .. tostring(rerr))
  end

  if keep then keep_previous(path) else os.remove(bak) end
end

-- Save a library. The data is checked first with the same rules a load applies,
-- so a record that could not be opened again is refused now, while the change
-- is still in memory, instead of stopping the next launch. The library as it was
-- before this save is kept as the previous copy.
function store.save(path, data)
  schema.validate(data)
  swap_in(path, store.encode(data), "library", true)
end

-- Save any other small JSON record (feedback drafts and receipts) with the same
-- atomic swap and crash recovery as the library, without the library checks or
-- the previous copy.
function store.save_record(path, data)
  swap_in(path, store.encode(data), "record", false)
end

-- Keep the file exactly as it was before an upgrade, once per old version. An
-- existing copy is the original and is never replaced.
local function keep_version_copy(path, text, version)
  local copy = store.version_path(path, version)
  if store.present(copy) then return end
  local tmp = write_temp(copy, text, "the copy of the older library")
  local ok, err = os.rename(tmp, copy)
  if not ok then
    os.remove(tmp)
    error("could not keep a copy of the older library: " .. tostring(err))
  end
end

-- Load a library from disk. A successful migration or repair is saved
-- immediately so the on-disk file and the in-memory shape cannot drift apart or
-- repeat repairs on every launch. An upgrade first keeps the old file as
-- library.v<N>.json. Atomic save keeps the previous file intact if persistence
-- fails. Returns the current table, or raises if the file is missing, corrupt,
-- or the changed file cannot be saved. The caller decides whether "missing"
-- means a new library may be created.
function store.load(path)
  local text = read_file(path)
  if text == nil then
    error("library file not found: " .. tostring(path))
  end
  local data, changed, stored_version = store.decode(text)
  if changed then
    local ok, err = pcall(function()
      if stored_version ~= data.version then keep_version_copy(path, text, stored_version) end
      store.save(path, data)
    end)
    -- A real upgrade must reach the disk before the old shape is forgotten. A
    -- repair alone is already applied in memory and rides along with the next save.
    if not ok and stored_version ~= data.version then error(NOT_SAVED .. tostring(err), 0) end
  end
  return data
end

-- Sort a load failure into what the user can do about it:
--   "newer"     a newer yb-Reference saved the file; update to open it.
--   "unusable_names" the Library holds file names this computer can't use.
--   "not_saved" the file is fine, but its upgrade couldn't be saved; retry.
--   "damaged"   anything else: the file can't be read as a library.
function store.failure_kind(err)
  local text = tostring(err)
  if text:find("written by a newer version", 1, true) then return "newer" end
  if text:find(NOT_SAVED, 1, true) then return "not_saved" end
  if text:find(schema.UNUSABLE_NAME_TEXT, 1, true) then return "unusable_names" end
  return "damaged"
end

-- Write a standalone JSON file (today: a trash note) the same careful way — temp
-- file first, then swap — so a crash can't leave half a record behind.
--
-- No .bak dance, unlike the library: there is no previous version of this file
-- worth rescuing, and the caller writes it BEFORE destroying anything.
function store.write_json(path, data)
  local tmp = write_temp(path, store.encode(data), "record")
  os.remove(path) -- Windows: os.rename won't overwrite (no-op if absent)
  local ok, rerr = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    error("could not save record: " .. tostring(rerr))
  end
end

-- Was this temp file written to the end? A save closes the .tmp before it
-- touches anything else, so a .tmp that parses as a JSON object is complete.
-- One that doesn't (cut short, or zeros after a power cut) is not.
local function complete_json(path)
  local text = read_file(path)
  if not text or text == "" then return false end
  local ok, result = pcall(json.decode, text)
  return ok and type(result) == "table"
end

-- Repair the aftermath of a save that a crash interrupted mid-swap. Call once at
-- startup, before deciding whether a library exists.
--
--   * Main file gone but a .bak present  -> we crashed after moving the old file
--     aside but before the new one landed. The .tmp, if it is complete, is that
--     newer save; promote it and keep the .bak as the previous copy. Otherwise the
--     .bak is the last complete file; promote it back. (Without this, startup
--     would see no file, create an empty library, and the next save would delete
--     the .bak — silent data loss.)
--   * Any other leftover .tmp  -> an interrupted write; it is incomplete, drop it.
--
-- Only the library keeps its older copy as a previous copy. Pass `false` as
-- `keep_previous_copy` for small records, which would otherwise leave a stray
-- .prev.json holding their contents.
function store.recover(path, keep_previous_copy)
  local bak, tmp = path .. ".bak", path .. ".tmp"
  if not store.exists(path) and store.exists(bak) then
    -- Raise if the promotion doesn't take. Carrying on would be silent data loss of
    -- the worst kind: the caller sees no library, creates an empty one, and saving
    -- THAT deletes the .bak this backup rescue exists to protect. Better to stop and
    -- let the user move the file back by hand.
    if store.exists(tmp) and complete_json(tmp) and os.rename(tmp, path) then
      if keep_previous_copy ~= false then keep_previous(path) else os.remove(bak) end
      return
    end
    local ok, err = os.rename(bak, path)
    if not ok then
      error("could not restore the library from its backup (" .. bak .. "): " .. tostring(err))
    end
  end
  os.remove(tmp) -- no-op if absent
end

return store
