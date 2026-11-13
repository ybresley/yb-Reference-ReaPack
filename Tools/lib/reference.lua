-- reference: the reference-mode adapter (a sibling of reaper_api/preview — one of
-- the few modules allowed to call reaper.*). It owns the crash-safe "latch": while
-- ON, the project's master is muted so pressing play in REAPER auditions the chosen
-- reference sound instead of the project. The preview playback itself is driven by
-- the entry script (it owns the single preview and the one defer loop); this module
-- owns only the safety machinery, so a crash can never leave a master silently muted.
--
-- THE ONE INVARIANT: a master we muted is never left muted without a way to undo it.
-- Everything below exists to keep that true. Three ideas carry it:
--
-- 1. TWO RECORDS, each good at a different job, both written BEFORE the mute lands:
--    * A marker inside the project (project ExtState) holding the prior mute value.
--      This is the authoritative record. It travels WITH the project — through "Save
--      As", through a rename, and it works for a never-saved project — because it is
--      stored in the same place as the mute itself. If the mute survived, the marker
--      survived; if the marker is gone, the mute went with it. A file path can't do
--      this: renaming the project would strand it. Because the two are saved
--      together, a valid marker found in any open project is honoured as soon as
--      that project is seen, whether or not the journal still names it: a file
--      saved during a latch keeps its mute after a normal un-latch, and a journal
--      entry for a later latch of the same file never reached that file.
--    * A queue on disk (the journal) saying which obligations are outstanding,
--      plus each project's path. Needed because a project that isn't open can't be
--      scanned for markers. One active latch may hand over to another project while
--      any closed projects wait safely in this queue.
--    NOT ExtState for the disk note: persistent ExtState is only flushed on a clean
--    REAPER exit, so it would not survive the crash it exists to recover from.
--
-- 2. AN OBLIGATION IS ONLY FORGOTTEN ONCE IT IS PROVABLY DISCHARGED. Every restore is
--    read back to confirm it took, and the note is deleted last (and verified gone).
--    If a project is closed we KEEP its entry and recover it when it reopens. A real
--    write/restore failure still blocks new latches; a routine queued recovery does
--    not. Losing an entry is the only truly unrecoverable outcome, so we never remove
--    one on a guess.
--
-- 3. RESTORE-IF-UNCHANGED, always: if the user unmuted the master by hand, that is
--    their call and we leave it alone.
--
-- Why muting the master gives a clean A/B: the preview routes to a hardware output
-- (through Monitor FX), NOT through the master track, so muting the master silences
-- the PROJECT while the reference preview stays audible.
--
-- Known limitation (documented, not an oversight): if two copies of yb-Reference run
-- at once, each sees the other's live marker as a stranded one and restores it. The
-- latch then stops working in the first window (its marker is gone, so it lets go
-- and settles its own entry), which is visible rather than dangerous: the master
-- ends up unmuted, never stranded. REAPER's own "script already running" prompt and
-- the Dev Hub's one-copy rule make this rare, so it isn't worth an ownership lease
-- and the staleness bugs that come with one.

local reference = {}

local SEP = package.config:sub(1, 1)

local JOURNAL = reaper.GetResourcePath() .. SEP .. "yb-Reference_ref_journal.txt"
local JOURNAL_TMP = JOURNAL .. ".tmp"
local JOURNAL_BAK = JOURNAL .. ".bak"

-- The marker lives in the project's own ExtState, so it is saved into the .rpp
-- alongside the mute it describes.
local PROJ_SECTION = "yb-Reference"
local PROJ_KEY     = "ref_recovery"

-- Live latch state. At most one OPEN project drives reference playback. Closed
-- owners leave this slot and keep only their journal entry, so another project
-- can latch without overwriting their recovery.
-- `old_paths` holds the files the live latch was saved under before a Save As.
local latch = {
  on = false, proj = nil, path = "", prev_mute = nil, token = nil,
  preview_allowed = false, old_paths = {},
}

-- The last verified journal contents. Every active or queued obligation is one
-- entry. The file is loaded during startup recovery before latching is possible.
local journal_entries = {}
local journal_loaded = false
-- True while journal_entries holds a link to another file that the journal on
-- disk lacks because saving it failed. The recovery sweep retries the save.
local journal_dirty = false

-- Set only for a genuine safety failure: unreadable journal, refused restore, or
-- journal rewrite that could not be verified. A normally closed project is queued,
-- not pending, and does not block another project's latch.
local pending = nil

--------------------------------------------------------------- projects

-- REAPER lets the user switch project tabs at any moment, so "the master track" is an
-- ambiguous thing to hold on to. We pin the project we latched and only ever act on
-- THAT one; using whichever project happens to be in front would unmute the wrong
-- project and leave the latched one muted for good.
local function current_project()
  local proj, path = reaper.EnumProjects(-1)
  return proj, path or ""
end

-- A stored project pointer goes stale if the user closes that tab, and touching freed
-- memory is a crash — so every later use is validated first.
local function project_alive(proj)
  if not proj then return false end
  return reaper.ValidatePtr2(0, proj, "ReaProject*")
end

local function path_for_project(wanted)
  local i = 0
  while true do
    local proj, path = reaper.EnumProjects(i)
    if not proj then return nil end
    if proj == wanted then return path or "" end
    i = i + 1
  end
end

local function project_name(path)
  if not path or path == "" then return "Unsaved project" end
  local name = path:match("([^/\\]+)$") or path
  return (name:gsub("%.[Rr][Pp][Pp]$", ""))
end

local function get_master_mute(proj)
  return reaper.GetMediaTrackInfo_Value(reaper.GetMasterTrack(proj), "B_MUTE")
end

-- Set the mute and READ IT BACK. A write we merely asked for isn't proof: if it
-- silently didn't take and we deleted the recovery note on that assumption, the mute
-- would be stranded with nothing left to fix it.
local function set_master_mute(proj, v)
  local master = reaper.GetMasterTrack(proj)
  reaper.SetMediaTrackInfo_Value(master, "B_MUTE", v)
  if get_master_mute(proj) == v then return true end

  -- Some REAPER setups can reject the raw track-property write. Retry only that
  -- failed path through REAPER's dedicated mute command, isolated from track
  -- grouping and selection ganging, then verify the result exactly as before.
  if reaper.SetTrackUIMute then reaper.SetTrackUIMute(master, v, 3) end
  return get_master_mute(proj) == v
end

--------------------------------------------------------------- the project marker

-- Write the marker and READ IT BACK, for the same reason every mute write is read
-- back: this is the AUTHORITATIVE record, and a write we merely asked for is not
-- proof. If the marker never landed and we muted anyway, a later recovery would find
-- the note's project open but carrying no marker, conclude it had reloaded clean,
-- delete the note and walk away — leaving the master muted with nothing left to
-- describe it. That is the one unrecoverable outcome.
local function marker_write(proj, token, prev_mute)
  local value = ("%s|%d"):format(token, prev_mute)
  reaper.SetProjExtState(proj, PROJ_SECTION, PROJ_KEY, value)
  local _, got = reaper.GetProjExtState(proj, PROJ_SECTION, PROJ_KEY)
  return got == value
end

local function marker_read(proj)
  local _, v = reaper.GetProjExtState(proj, PROJ_SECTION, PROJ_KEY)
  if not v or v == "" then return nil, "absent" end
  local token, prev = v:match("^([^|]*)|(%d+)$")
  prev = tonumber(prev)
  if not token or token == "" or (prev ~= 0 and prev ~= 1) then
    return nil, "damaged"
  end
  return { token = token, prev = prev }, "valid"
end

-- Clear the marker and confirm it is gone — same reasoning as verifying the note's
-- deletion. A marker left behind describes a mute we have already put back, so a
-- later startup would "restore" it over whatever the user has deliberately chosen
-- since (deliberately muting their own master, say).
local function marker_clear(proj)
  reaper.SetProjExtState(proj, PROJ_SECTION, PROJ_KEY, "")
  local _, state = marker_read(proj)
  return state == "absent"
end

--------------------------------------------------------------- journal

-- Version 1 was one key=value record. Version 2 keeps several tab-separated
-- entries in the SAME permanent file. Windows project paths cannot contain tabs
-- or newlines, so the format is reversible without escaping and an old journal
-- can be loaded and rewritten as v2 the first time another project is added.
--
-- Version 3 adds `also` lines: other files a held entry is known to have
-- reached, such as the old name of a project saved under a new one. They keep
-- that link after the tab carrying the marker closes. Version 3 is written only
-- while some entry has such a line, so an older copy of the tool reading it
-- reports a damaged journal rather than quietly losing the link.
local function journal_parse(txt)
  if type(txt) ~= "string" then return nil, "unreadable" end

  local version = txt:match("^version=([23])\r?\n")
  if version then
    local entries, by_token = {}, {}
    for line in txt:gmatch("[^\r\n]+") do
      if line ~= "version=" .. version then
        local prev, token, project = line:match("^entry=([01])\t([^\t]+)\t(.*)$")
        local also_token, also_path = nil, nil
        if not token and version == "3" then
          also_token, also_path = line:match("^also=([^\t]+)\t(.+)$")
        end
        if token then
          if by_token[token] then return nil, "damaged" end
          local e = { prev = tonumber(prev), token = token, project = project, also = {} }
          by_token[token] = e
          entries[#entries + 1] = e
        elseif also_token and by_token[also_token] then
          table.insert(by_token[also_token].also, also_path)
        else
          return nil, "damaged"
        end
      end
    end
    return entries
  end

  local set = tonumber(txt:match("set_mute=(%d+)"))
  local prev = tonumber(txt:match("prev_mute=(%d+)"))
  local token = txt:match("token=([^\r\n]*)")
  local project = txt:match("project=([^\r\n]*)") or ""
  if set ~= 1 or (prev ~= 0 and prev ~= 1) or not token or token == "" then
    return nil, "damaged"
  end
  return { { prev = prev, token = token, project = project, also = {} } }
end

local function journal_encode(entries)
  local out, version = {}, "2"
  for i = 1, #entries do
    local e = entries[i]
    if (e.prev ~= 0 and e.prev ~= 1) or type(e.token) ~= "string" or e.token == ""
      or e.token:find("[\t\r\n]") or type(e.project) ~= "string"
      or e.project:find("[\t\r\n]") then
      return nil
    end
    out[#out + 1] = ("entry=%d\t%s\t%s\n"):format(e.prev, e.token, e.project)
    for _, p in ipairs(e.also or {}) do
      if type(p) ~= "string" or p == "" or p:find("[\t\r\n]") then return nil end
      out[#out + 1] = ("also=%s\t%s\n"):format(e.token, p)
      version = "3"
    end
  end
  return "version=" .. version .. "\n" .. table.concat(out)
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local txt = f:read("*a")
  f:close()
  return type(txt) == "string" and txt or ""
end

local function file_exists(path)
  local f = io.open(path, "r")
  if not f then return false end
  f:close()
  return true
end

-- If REAPER died during the Windows remove-then-rename swap, the old complete
-- journal is in .bak and the new complete journal is still in .tmp. No mute can
-- land until a save returns, so restoring .bak is the only safe interpretation.
local function journal_load()
  local txt = read_file(JOURNAL)
  if txt ~= nil then
    local entries, err = journal_parse(txt)
    if not entries then return nil, err end
    os.remove(JOURNAL_TMP)
    os.remove(JOURNAL_BAK)
    return entries
  end

  local bak = read_file(JOURNAL_BAK)
  if bak ~= nil then
    local entries, err = journal_parse(bak)
    if not entries then return nil, err end
    os.remove(JOURNAL_TMP)
    if not os.rename(JOURNAL_BAK, JOURNAL) then return nil, "repair failed" end
    if read_file(JOURNAL) ~= bak then return nil, "repair failed" end
    return entries
  end

  os.remove(JOURNAL_TMP)
  return {}
end

local function ensure_journal_loaded()
  if journal_loaded then return true end
  local entries, err = journal_load()
  if not entries then
    pending = "Reference mode can't check its recovery journal (" .. JOURNAL ..
      "). Check the master track in any project that may be muted, then email " ..
      "yoni.ybtools@gmail.com before deleting the journal."
    return false, err
  end
  journal_entries, journal_loaded, journal_dirty = entries, true, false
  return true
end

-- Atomically replace the whole queue. On Windows the existing file must move
-- aside first. The new file is read back before the backup is discarded.
local function journal_save(entries)
  if #entries == 0 then
    os.remove(JOURNAL_TMP)
    os.remove(JOURNAL)
    os.remove(JOURNAL_BAK)
    if file_exists(JOURNAL) or file_exists(JOURNAL_BAK) then return false end
    journal_entries, journal_dirty = {}, false
    return true
  end

  local encoded = journal_encode(entries)
  if not encoded then return false end
  local f = io.open(JOURNAL_TMP, "w")
  if not f then return false end
  local written = f:write(encoded)
  local closed = f:close()
  if not written or not closed or read_file(JOURNAL_TMP) ~= encoded then
    os.remove(JOURNAL_TMP)
    return false
  end

  os.remove(JOURNAL_BAK)
  if file_exists(JOURNAL_BAK) then os.remove(JOURNAL_TMP); return false end

  local had_main = file_exists(JOURNAL)
  if had_main and not os.rename(JOURNAL, JOURNAL_BAK) then
    os.remove(JOURNAL_TMP)
    return false
  end
  if not os.rename(JOURNAL_TMP, JOURNAL) or read_file(JOURNAL) ~= encoded then
    os.remove(JOURNAL)
    if had_main then os.rename(JOURNAL_BAK, JOURNAL) end
    os.remove(JOURNAL_TMP)
    return false
  end

  os.remove(JOURNAL_BAK)
  journal_entries, journal_dirty = entries, false
  return true
end

local function journal_add(entry)
  if not ensure_journal_loaded() then return false end
  local next_entries = {}
  for i = 1, #journal_entries do
    local e = journal_entries[i]
    if e.token == entry.token then return false end
    next_entries[#next_entries + 1] = e
  end
  next_entries[#next_entries + 1] = entry
  return journal_save(next_entries)
end

local function journal_remove(token)
  if not ensure_journal_loaded() then return false end
  local next_entries, found = {}, false
  for i = 1, #journal_entries do
    local e = journal_entries[i]
    if e.token == token then found = true else next_entries[#next_entries + 1] = e end
  end
  return not found or journal_save(next_entries)
end

local function journal_update_path(token, path)
  if not ensure_journal_loaded() then return false end
  local next_entries, found, changed = {}, false, false
  for i = 1, #journal_entries do
    local e = journal_entries[i]
    if e.token == token then
      found = true
      if e.project ~= path then
        e = { prev = e.prev, token = e.token, project = path, also = e.also }
        changed = true
      end
    end
    next_entries[#next_entries + 1] = e
  end
  return found and (not changed or journal_save(next_entries))
end

--------------------------------------------------------------- latch

-- A valid pointer is not enough ownership proof: REAPER may replace a tab and
-- later present the same pointer value for a different project. The marker token
-- is the identity that was written before the mute. Without our token, the latched
-- project is gone from this tab: another project took the pointer, or the same
-- file was reopened into it with no marker or an older one. Its entry then waits
-- in the queue, where the recovery sweep judges the reopened copy; a muted master
-- without a marker stays a visible failure there. Only an unreadable marker on
-- the same path is an error here, because nothing can say what it described.
local function live_owner_state(proj, old_path, token)
  if not project_alive(proj) then return "gone" end
  local path = path_for_project(proj)
  if path == nil then return "gone" end
  local marker, marker_state = marker_read(proj)
  if marker and marker.token == token then return "owned", path end
  if path ~= old_path or marker_state ~= "damaged" then return "gone", path end
  return "marker_error", path, marker_state
end

-- One wording for damaged markers a journal entry may describe, whether the
-- latch finds one as it lets go or a sweep finds it on a later frame. The same
-- text lets the app's one-alert-per-message rule show it once.
local function damaged_marker_message(names)
  if #names == 1 then
    return "Reference mode found a damaged recovery marker inside " .. names[1] ..
      ". Its journal entry was kept. Keep the project open, check its master track, then email " ..
      "yoni.ybtools@gmail.com."
  end
  return "Reference mode found damaged recovery markers in " .. #names .. " open projects. " ..
    "Their journal entries were kept. Keep the projects open, check their master tracks, then " ..
    "email yoni.ybtools@gmail.com."
end

-- Shared with the sweep for the same reason: un-latching and the next frame's
-- retry must say the same thing.
local MARKER_NOT_CLEARED = "Reference mode restored a project's master track to its previous mute state, " ..
  "but couldn't clear its recovery marker. Save the project or restart Reaper to retry recovery cleanup."

-- The recovery sweep, defined below. Latch off calls it too.
local recover_entries

-- Whether a tab other than proj has the file at path open.
-- Whether another open tab may carry this latch's mute: a tab of the same
-- file, or a tab of any file whose marker names this latch, such as the old
-- file after Save As.
local function shares_latch(proj, path, token)
  local i = 0
  while true do
    local p, p_path = reaper.EnumProjects(i)
    if not p then return false end
    if p ~= proj then
      if path ~= "" and (p_path or "") == path then return true end
      local m = marker_read(p)
      if m and m.token == token then return true end
    end
    i = i + 1
  end
end

-- Open tabs of a file the latch was saved under before Save As that may still
-- carry its mute: muted without a marker, or holding a damaged one. Neither
-- their file name nor their marker ties them to the latch, so only the latch
-- remembers them.
local function unsettled_old_tabs(proj, old_paths, prev)
  local found, i = {}, 0
  while true do
    local p, p_path = reaper.EnumProjects(i)
    if not p then return found end
    p_path = p_path or ""
    if p ~= proj and old_paths[p_path] then
      local _, state = marker_read(p)
      if state == "damaged" or (state == "absent" and prev == 0 and get_master_mute(p) == 1) then
        found[#found + 1] = p_path
      end
    end
    i = i + 1
  end
end

-- Save files into an entry as `also` links, so the recovery sweep judges
-- their tabs. The links stay in memory if the save fails, and the sweep
-- retries it.
local function journal_link(token, paths)
  if not ensure_journal_loaded() then return false end
  for i, e in ipairs(journal_entries) do
    if e.token == token then
      local also, known, grew = {}, { [e.project] = true }, false
      for _, p in ipairs(e.also or {}) do also[#also + 1], known[p] = p, true end
      for _, p in ipairs(paths) do
        if p ~= "" and not known[p] then
          known[p] = true
          also[#also + 1] = p
          grew = true
        end
      end
      if not grew then return true end
      journal_entries[i] = { prev = e.prev, token = e.token, project = e.project, also = also }
      journal_dirty = true
      return journal_save(journal_entries)
    end
  end
  return false
end

local function clear_live_latch()
  latch.on, latch.proj, latch.path, latch.prev_mute, latch.token,
    latch.preview_allowed, latch.old_paths = false, nil, "", nil, nil, false, {}
end

function reference.is_latched() return latch.on end

-- The outstanding-obligation message, or nil when everything is settled.
function reference.pending() return pending end

local token_seq = 0
local function new_token()
  local token, used
  repeat
    token_seq = token_seq + 1
    token = ("%d-%d-%d"):format(
      os.time(), math.floor(reaper.time_precise() * 1000) % 1000000, token_seq)
    used = false
    for i = 1, #journal_entries do
      if journal_entries[i].token == token then used = true; break end
    end
  until not used
  return token
end

-- Latch ON: silence the project. Returns (false, reason) having changed NOTHING if the
-- records can't be laid down first, or if a genuine recovery error is outstanding.
-- Routine closed-project obligations remain in the queue and do not block this latch.
-- Silencing happens here, never at play-detection, so no blip of project audio can
-- leak out before the mute lands.
function reference.latch_on()
  -- A reopened queued project must be restored before a new marker can replace
  -- its old one. In the normal app loop refresh already ran this frame; keeping
  -- it here makes the safety interface correct for cleanup/tests too.
  reference.refresh()
  if pending then return false, pending end
  local proj, path = current_project()
  if not proj then return false, "Reference mode couldn't find the current project." end

  if latch.on and latch.proj == proj then return true end
  if latch.on then
    local ok = reference.latch_off()
    if not ok then return false, pending end
  end

  -- A marker already sitting in this project is a survivor: the project was saved
  -- while latched and reopened later. The open-project sweep in refresh (run just
  -- above) normally restores and clears it as soon as the project opens; this is
  -- the fallback for any marker it has not settled. That marker's prior value is
  -- the truth about this master — the CURRENT mute is our own residue, and
  -- recording it as "prior" would restore the mute on un-latch and strand the
  -- master muted with both records gone. Adopting the surviving value makes
  -- pressing REF the rescue.
  --
  -- Adopted ONLY while the residue is still in place (master still muted). If the
  -- master is unmuted, the user already resolved the crash by hand, and their
  -- latest choice — not the marker's memory of an older one — is what un-latch must
  -- restore. The stale marker is then simply replaced by the new latch's own.
  local survivor, survivor_state = marker_read(proj)
  if survivor_state == "damaged" then
    pending = "Reference mode found a damaged recovery marker inside " ..
      project_name(path) .. ". Check its master track, then email yoni.ybtools@gmail.com " ..
      "before turning on Reference mode."
    return false, pending
  end
  local current = get_master_mute(proj)
  local adopting_survivor = survivor ~= nil and current == 1
  local prev = adopting_survivor and survivor.prev or current
  -- The surviving marker is already the authoritative record for this mute.
  -- Reuse it until the missing disk journal has been restored: replacing it
  -- first would destroy the last recovery record if that journal write failed.
  local token = adopting_survivor and survivor.token or new_token()

  -- Both records exist BEFORE any new mute, and both are verified. If we die
  -- between them they describe a mute that never happened, and restore-if-unchanged
  -- correctly does nothing. The adoption path is the exception only in timing:
  -- its verified marker already owns the crash-residue mute, so this call restores
  -- the missing journal without replacing that last surviving record.
  if not adopting_survivor and not marker_write(proj, token, prev) then
    return false, "Reference mode couldn't start because it couldn't save a recovery marker " ..
      "in your project. Your project was not changed."
  end
  local entry = { prev = prev, token = token, project = path }
  if not journal_add(entry) then
    -- A newly written marker describes a mute that never happened and must go.
    -- An adopted marker describes the mute already in front of us and is the
    -- only remaining recovery record, so leave it exactly as it was.
    if not adopting_survivor then marker_clear(proj) end
    return false, "Reference mode couldn't start because it couldn't save its recovery journal. " ..
      "Your project was not changed."
  end

  if not set_master_mute(proj, 1) then
    marker_clear(proj)
    -- Only THIS entry describes the mute that never landed. Other closed
    -- projects' recovery entries stay untouched.
    if not journal_remove(token) then
      pending = "Reference mode couldn't mute the project's master track. Your project was not changed, " ..
        "but its recovery journal entry couldn't be removed (" .. JOURNAL .. "). Reopen " ..
        "yb-Reference to retry. Email yoni.ybtools@gmail.com before deleting the journal manually."
      return false, pending
    end
    return false, "Reference mode couldn't mute the project's master track. Your project was not changed. " ..
      "Try the Latch button again. If it still fails, send feedback from Settings."
  end

  latch.on, latch.proj, latch.path, latch.prev_mute, latch.token, latch.old_paths =
    true, proj, path, prev, token, {}
  -- Latching is an explicit request: if this project's transport is already
  -- rolling, the reference may start immediately. Leaving the project later
  -- disarms this until the user returns and stops/starts its transport.
  latch.preview_allowed = true
  return true
end

-- Latch OFF: put the master back the way we found it, then forget the obligation —
-- but only once it is provably discharged. Returns true when fully settled.
function reference.latch_off()
  if not latch.on then return true end
  local proj, path, prev, token = latch.proj, latch.path, latch.prev_mute, latch.token
  local old_paths = latch.old_paths
  local owner_state = live_owner_state(proj, path, token)
  clear_live_latch()

  -- A tab of a file this latch was saved under before Save As may still be
  -- muted with its marker lost or damaged. The entry links that file, so the
  -- sweep judges its tabs from now on.
  local stale = unsettled_old_tabs(proj, old_paths, prev)
  if #stale > 0 then journal_link(token, stale) end

  -- The project we muted has been closed or replaced in its tab. If it was saved
  -- while latched, that mute is in the file and outlives us, so the note MUST stay —
  -- dropping it here is what would strand the user's master for good.
  if owner_state == "gone" then
    -- The entry was written before the mute and is already in the queue. This
    -- is routine recovery, not an error, so another project may latch now.
    return true, "queued", project_name(path)
  end

  if owner_state == "marker_error" then
    pending = damaged_marker_message({ project_name(path) })
    return false, pending
  end

  -- Restore-if-unchanged: only put our value back if the master still holds the mute
  -- we set. If the user unmuted it by hand, that's theirs to keep.
  if get_master_mute(proj) == 1 and not set_master_mute(proj, prev) then
    pending = "Reference mode couldn't restore the master track's previous mute state. The master " ..
      "track is still muted. Unmute it manually or reopen the project so yb-Reference can try again."
    return false
  end

  -- Both records have to be provably gone before the obligation is forgotten — the
  -- note is kept either way, so the next run retries the cleanup.
  if not marker_clear(proj) then
    pending = MARKER_NOT_CLEARED
    return false
  end
  -- Another tab may have been opened from a save made while latched, so it
  -- carries this mute too: a tab of this file, whose marker may since be gone
  -- or damaged, or the old file after Save As. The sweep judges every tab,
  -- and it runs now rather than next frame: closing the tool has no next
  -- frame, and must still put such a tab back or report it.
  if #stale > 0 or shares_latch(proj, path, token) then
    recover_entries(false, false)
    return pending == nil, pending
  end
  if not journal_remove(token) then
    pending = "Reference mode restored the project's master track to its previous mute state, but couldn't " ..
      "remove its entry from the recovery journal (" .. JOURNAL .. "). Restart yb-Reference to retry. Email " ..
      "yoni.ybtools@gmail.com before deleting the journal manually."
    return false
  end
  pending = nil
  return true
end

--------------------------------------------------------------- startup recovery

local function recovery_message(names)
  if #names == 1 then
    return "Reference mode restored the master track in " .. names[1] .. " to its previous mute state."
  elseif #names > 1 then
    return "Reference mode restored the master tracks in " .. #names .. " projects to their previous mute states."
  end
  return nil
end

-- A damaged marker that no journal entry expects describes nothing this tool is
-- still holding, so it never blocks Reference mode, in session or at startup.
-- It could still be a latch saved into the file long ago, so startup mentions
-- it once.
local function unexpected_damage_message(names)
  if #names == 1 then
    return "Reference mode found a damaged recovery marker inside " .. names[1] ..
      ". Check that its master track isn't left muted."
  elseif #names > 1 then
    return "Reference mode found damaged recovery markers in " .. #names .. " open projects. " ..
      "Check that their master tracks aren't left muted."
  end
  return nil
end

-- Restore every open project whose marker describes a mute we left, then settle
-- the queued entries those projects prove. A valid marker is the authority for
-- its own project (see the header): it is honoured whether or not the journal
-- names its token, at startup and in session alike. Only the live latch's own
-- token is skipped, so recovering A can never stop or restore active B.
-- A damaged marker is a blocking failure where a queued entry may describe it.
-- `startup` also mentions one that no entry expects, without blocking.
function recover_entries(startup, stop_previews)
  local journal_ok = ensure_journal_loaded()
  if stop_previews and reaper.APIExists("CF_Preview_StopAll") then
    reaper.CF_Preview_StopAll()
  end

  local by_path, entry_for, pathless_count = {}, {}, 0
  local active_token = latch.on and latch.token or nil
  for i = 1, #journal_entries do
    local e = journal_entries[i]
    if e.token ~= active_token then
      entry_for[e.token] = e
      if e.project ~= "" then by_path[e.project] = true else pathless_count = pathless_count + 1 end
      for _, p in ipairs(e.also or {}) do by_path[p] = true end
    end
  end

  -- Every open tab is read first, so each judgement below sees all of them,
  -- whatever their order. A valid marker that a queued entry names also makes
  -- its own path an expected one: after Save As the entry names the new file,
  -- but copies of the old file may carry the same mute.
  local tabs, open_paths, i = {}, {}, 0
  while true do
    local proj, path = reaper.EnumProjects(i)
    if not proj then break end
    path = path or ""
    local m, marker_state = marker_read(proj)
    tabs[#tabs + 1] = { proj = proj, path = path, m = m, state = marker_state }
    if path ~= "" then open_paths[path] = true end
    if m and entry_for[m.token] and path ~= "" then by_path[path] = true end
    i = i + 1
  end

  local seen, clean_paths, settled_paths, names = {}, {}, {}, {}
  local failed_restore, failed_marker, missing_marker_data = 0, 0, 0
  local damaged, unexpected_damaged, damaged_paths = {}, {}, {}
  local markers, restore_failed = {}, {}
  for _, t in ipairs(tabs) do
    if t.state == "absent" then
      -- REAPER can open one file in several tabs. Any of them still muted
      -- counts, so a clean copy can never hide a master left muted in another.
      local mute, clean = get_master_mute(t.proj), clean_paths[t.path]
      if not clean then
        clean_paths[t.path] = { mute = mute }
      elseif mute == 1 then
        clean.mute = 1
      end
    elseif t.state == "damaged" then
      -- Non-empty but unreadable is never "clean". If a queued entry may describe
      -- this project, losing it silently could strand a mute.
      if by_path[t.path] or pathless_count > 0 then
        damaged[#damaged + 1] = project_name(t.path)
        -- Another tab of this file can't settle its entries: this marker may be
        -- the one they describe.
        damaged_paths[t.path] = true
      elseif startup then
        unexpected_damaged[#unexpected_damaged + 1] = project_name(t.path)
      end
    elseif t.m.token ~= active_token then
      local token = t.m.token
      seen[token] = true
      -- Restore-if-unchanged: only a master still holding the mute is put back.
      -- A marker whose prior value was already muted changes nothing.
      if get_master_mute(t.proj) == 1 and t.m.prev == 0 then
        if set_master_mute(t.proj, 0) then
          -- A marker the user already resolved by hand is cleared quietly, and
          -- nothing is announced as restored. Neither the unmute nor the
          -- cleared marker dirties the project, so a restored one is marked
          -- changed: closing then asks to save, and the saved file stops
          -- carrying the mute for a launch without this tool. MarkProjectDirty
          -- adds no undo point, so Undo can't re-mute it.
          names[#names + 1] = project_name(t.path)
          reaper.MarkProjectDirty(t.proj)
        else
          failed_restore = failed_restore + 1
          restore_failed[token] = true
        end
      end
      markers[token] = markers[token] or {}
      table.insert(markers[token], t)
    end
  end

  -- Every file an entry is tied to: the one it names, plus any it was found to
  -- have reached and saved as `also`.
  local function entry_paths(e)
    local paths = {}
    if e.project ~= "" then paths[e.project] = true end
    for _, p in ipairs(e.also or {}) do paths[p] = true end
    return paths
  end

  -- Whether any of these files has a copy that may still carry the mute:
  -- muted without a marker, or holding a damaged one. The second value says
  -- it is a muted copy, which gets its own warning. The third lists the files
  -- with such a copy.
  local function unsettled(paths, prev)
    local any, muted, which = false, false, {}
    for p in pairs(paths) do
      local clean = clean_paths[p]
      if damaged_paths[p] then
        any = true
        which[#which + 1] = p
      elseif clean and clean.mute == 1 and prev == 0 then
        any, muted = true, true
        which[#which + 1] = p
      end
    end
    return any, muted, which
  end

  -- One tab's marker proves only that tab. Another tab of the same file, or of
  -- the file the entry names after Save As, may carry the same mute. Until
  -- every such copy is settled, the entry stays with its warning and the
  -- marker stays too. The marker's files, and every file seen with such a
  -- copy, are also saved into the entry as `also` links, so the link survives
  -- that tab closing or a restart. Projects that were never saved all share
  -- the empty file name without being copies of each other, so only a real
  -- file name ties tabs together.
  local held, held_muted, held_entry = {}, {}, {}
  for token, list in pairs(markers) do
    local e = entry_for[token]
    if e then
      local paths = entry_paths(e)
      for _, t in ipairs(list) do
        if t.path ~= "" then paths[t.path] = true end
      end
      local which
      held[token], held_muted[token], which = unsettled(paths, e.prev)
      -- A linked file may have been closed with its unsettled copy saved as
      -- it was, still muted. While no tab of it is open, the entry waits for
      -- it to reopen.
      for _, p in ipairs(e.also or {}) do
        if not open_paths[p] then held[token] = true end
      end
      if held[token] then
        local also, known, grew = {}, {}, false
        for _, p in ipairs(e.also or {}) do
          also[#also + 1], known[p] = p, true
        end
        local function link(p)
          if p ~= "" and not known[p] then
            known[p] = true
            also[#also + 1] = p
            grew = true
          end
        end
        for _, t in ipairs(list) do
          if t.path ~= e.project then link(t.path) end
        end
        for _, p in ipairs(which) do link(p) end
        if grew then
          held_entry[token] = { prev = e.prev, token = e.token, project = e.project, also = also }
        end
      end
    end
  end

  local resolved = {}
  for token, list in pairs(markers) do
    if not held[token] and not restore_failed[token] then
      local cleared = true
      for _, t in ipairs(list) do
        if not marker_clear(t.proj) then cleared = false end
      end
      if cleared then
        resolved[token] = true
        -- The marker proves which latch this file was saved under, so any
        -- other entry for its path is a later latch that never reached it.
        for _, t in ipairs(list) do settled_paths[t.path] = true end
      else
        failed_marker = failed_marker + 1
      end
    end
  end

  -- A damaged disk journal may hide obligations for closed projects, so it must
  -- stay in place and remain an urgent error. Open project markers are independent
  -- copies, however: honouring them here still rescues every project we can prove.
  if not journal_ok then return pending, true end

  -- An open project with a provably ABSENT marker reloaded clean: muting the master
  -- never dirties a project, so neither our mute nor marker reached its .RPP. A
  -- pathless entry is kept: the project may have received its first Save As between
  -- our last frame and a crash, in which case its marker is the only later identity.
  local remaining, changed = {}, false
  for i = 1, #journal_entries do
    local e = journal_entries[i]
    if e.token == active_token then
      remaining[#remaining + 1] = e
    elseif held[e.token] then
      if held_entry[e.token] then
        -- Kept in memory at once, so a failed save below can't lose the new
        -- link before a later sweep, which retries the save.
        e = held_entry[e.token]
        journal_entries[i], journal_dirty = e, true
      end
      remaining[#remaining + 1] = e
      if held_muted[e.token] then missing_marker_data = missing_marker_data + 1 end
    elseif resolved[e.token] then
      changed = true
    elseif seen[e.token] then
      remaining[#remaining + 1] = e
    else
      -- No marker for this entry is open. Every file it is tied to must be open
      -- and proven: an absent marker with the master not still holding our
      -- mute, or a later marker that settled that path. With prior=0/current=1,
      -- deleting the journal could strand exactly the mute it describes, so it
      -- is kept and fails visibly. A file that isn't open keeps the entry
      -- queued until it is.
      local paths = entry_paths(e)
      local any, muted = unsettled(paths, e.prev)
      local proven = next(paths) ~= nil
      for p in pairs(paths) do
        if not clean_paths[p] and not settled_paths[p] then proven = false end
      end
      if muted then missing_marker_data = missing_marker_data + 1 end
      if any or not proven then
        remaining[#remaining + 1] = e
      else
        changed = true
      end
    end
  end

  if (changed or journal_dirty) and not journal_save(remaining) then
    pending = "Reference mode restored a project's master track to its previous mute state, but couldn't " ..
      "update its recovery journal (" .. JOURNAL .. "). Do not delete the journal. Restart " ..
      "yb-Reference to retry."
    return pending, true
  end
  if failed_restore > 0 then
    pending = "Reference mode couldn't restore a project's master track to its previous mute state. Check " ..
      "its master track and unmute it manually. Leave the project open so Reference mode can " ..
      "verify the change."
    return pending, true
  end
  if failed_marker > 0 then
    pending = MARKER_NOT_CLEARED
    return pending, true
  end
  if #damaged > 0 then
    pending = damaged_marker_message(damaged)
    return pending, true
  end
  if missing_marker_data > 0 then
    pending = "Reference mode found a muted project with no recovery marker. Its journal entry " ..
      "was kept. Unmute that project's master track manually, then leave the project open so " ..
      "Reference mode can verify the change."
    return pending, true
  end

  pending = nil
  -- The third value asks for the notice to be shown at once. A damaged marker
  -- may hide a master still muted, and a startup check that stops the tool
  -- before its window opens would otherwise drop the notice unseen. A restore
  -- needs no alert: that master is already back.
  local restored, notice = recovery_message(names), unexpected_damage_message(unexpected_damaged)
  if restored and notice then return restored .. " " .. notice, false, true end
  return restored or notice, false, notice ~= nil
end

-- Startup recovery runs before every dependency gate. It stops previews left by
-- the dead instance, honours every open marker, and leaves closed entries queued.
function reference.recover()
  if latch.on then return nil end
  -- Returns the message, whether it blocks Reference Mode, and whether it must
  -- be shown before the startup checks run.
  journal_loaded = false
  return recover_entries(true, true)
end

local function queued_count()
  local n, active = 0, latch.on and latch.token or nil
  for i = 1, #journal_entries do
    if journal_entries[i].token ~= active then n = n + 1 end
  end
  return n
end

-- What the last frame saw of every open tab, in tab order: its pointer, its path
-- and the raw text of its marker. The recovery sweep only has new work when one of
-- these changes, so idle frames compare a few strings instead of rescanning every
-- project. The marker text is part of it because reopening a file into the same
-- tab can keep both the pointer and the path while replacing the marker.
local seen_proj, seen_path, seen_marker, seen_count = {}, {}, {}, 0

local function open_projects_changed()
  local changed, n = false, 0
  while true do
    local proj, path = reaper.EnumProjects(n)
    if not proj then break end
    n = n + 1
    path = path or ""
    local _, marker = reaper.GetProjExtState(proj, PROJ_SECTION, PROJ_KEY)
    marker = marker or ""
    if seen_proj[n] ~= proj or seen_path[n] ~= path or seen_marker[n] ~= marker then
      seen_proj[n], seen_path[n], seen_marker[n] = proj, path, marker
      changed = true
    end
  end
  if n ~= seen_count then
    for j = n + 1, seen_count do seen_proj[j], seen_path[j], seen_marker[j] = nil, nil, nil end
    seen_count = n
    changed = true
  end
  return changed
end

-- Set when the open projects change, cleared only once a sweep has actually run,
-- so a frame that had to skip the sweep cannot lose the change.
local sweep_due = false

-- Called once per frame. A closed live owner becomes an ordinary queued entry;
-- reopened projects carrying a marker restore automatically, whether or not the
-- journal still names them. The returned latch state is deliberately
-- CURRENT-PROJECT-specific, so every other tab's L button stays off and usable.
function reference.refresh()
  ensure_journal_loaded()
  local current, current_path = current_project()
  local live_ended, immediate_error = false, nil

  if latch.on then
    local owner_state, owner_path = live_owner_state(latch.proj, latch.path, latch.token)
    if owner_state == "owned" then
      if current ~= latch.proj then
        -- Merely returning to a still-rolling owner is not a new Play request.
        -- Disarm as soon as the front tab changes; the owner must be observed
        -- stopped in front again before a later Play may start its reference.
        latch.preview_allowed = false
      end
      if owner_path ~= latch.path then
        if journal_update_path(latch.token, owner_path) then
          if latch.path ~= "" then latch.old_paths[latch.path] = true end
          latch.path = owner_path
        else
          pending = "Reference mode couldn't update its recovery journal after " ..
            project_name(owner_path) .. " changed name. Its master track is still muted. Keep " ..
            "the project open, then email yoni.ybtools@gmail.com."
          immediate_error = pending
        end
      end
    else
      local ok = reference.latch_off() -- gone owner queues; marker trouble stays visible
      if not ok then immediate_error = pending end
      live_ended = true
    end
  end

  -- An outstanding failure is re-checked every frame: the user may unmute by hand
  -- or a refused write may start working, and neither changes what is compared.
  if open_projects_changed() or live_ended then sweep_due = true end
  local msg, urgent
  if not immediate_error and (sweep_due or pending) then
    sweep_due = false
    msg, urgent = recover_entries(false, false)
    current, current_path = current_project()
  end

  return {
    latched = latch.on and current == latch.proj,
    live = latch.on,
    pending = pending ~= nil,
    owner_name = latch.on and project_name(latch.path) or nil,
    queued_count = queued_count(),
  }, immediate_error or msg, immediate_error ~= nil or urgent,
    { live_ended = live_ended }
end

--------------------------------------------------------------- transport

-- Should the live owner's transport be driving reference audio THIS frame?
-- Deliberately current-project-specific, and edge-aware across tab switches:
-- returning to an owner that never stopped is not treated as another Play press.
function reference.transport_preview_wanted()
  if not latch.on or not project_alive(latch.proj) then return false end
  local marker = marker_read(latch.proj)
  if not marker or marker.token ~= latch.token then return false end
  local current = current_project()
  if current ~= latch.proj then
    -- A background project's transport must never start reference audio. More
    -- importantly, returning while it is still rolling is not a new Play press.
    latch.preview_allowed = false
    return false
  end
  local playing = reaper.GetPlayStateEx(latch.proj) & 1 == 1
  if not playing then
    latch.preview_allowed = true
    return false
  end
  return latch.preview_allowed
end

-- Best-effort exit cleanup (window closed or script unloaded normally). Never runs on a
-- crash — that is what the records are for — but on a clean exit it restores the master
-- immediately rather than leaving it to the next startup. Returns false when the
-- un-latch could not settle; reference.pending() then says what is outstanding.
function reference.cleanup()
  if latch.on then return (reference.latch_off()) end
  return true
end

return reference
