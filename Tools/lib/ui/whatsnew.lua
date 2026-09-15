-- Release highlights share one window with the text-only release history.
-- Demonstrations exist for the matching installed release only. Small updates
-- and older releases retain the compact reading layout.
--
-- It fires after the RESTART, never before: an update swaps the files on disk
-- while REAPER carries on running the old script, so notes shown at install time
-- describe a version the user does not yet have. The tool restarts itself only
-- after ReaPack's report closes, and this card is the first thing the new code
-- draws. See the updater heartbeat in yb-Reference.lua.
--
-- The reading layout is shared with the Settings > Updates history
-- (`whatsnew.draw_release`), so the two surfaces cannot drift.
--
-- A ui/ module: reaper.ImGui_* only. The seen-version mark is written by the
-- entry script when the card is SHOWN, not on dismissal (audit fix, 2026-08-09):
-- dismissal-dependent marking relied on gestures the user could never perform —
-- Esc stays with REAPER until the card is clicked, and closing the whole tool
-- with the card open skipped the write, re-showing the same notes every launch.
-- Closing here is pure view cleanup, reported as an action out of habit only.

local theme = require("ui.theme")
local focus = require("ui.focus")
local showcase = require("ui.release_showcase")
local anchored_panel = require("ui.anchored_panel")
local widgets = require("ui.widgets")
local changelog = require("core.changelog")
local T = theme.tokens
local M = theme.metrics

local whatsnew = { preview_version = showcase.version }

local HAS_ESCAPE     = reaper.ImGui_IsKeyPressed ~= nil and reaper.ImGui_Key_Escape ~= nil
local HAS_VIEWPORT   = reaper.ImGui_GetMainViewport ~= nil and reaper.ImGui_Viewport_GetCenter ~= nil
local HAS_CONSTRAIN  = reaper.ImGui_SetNextWindowSizeConstraints ~= nil

-- View state only. The post-update card is DRIVEN BY `state.whatsnew` — the
-- entry script decides there is something unread and puts { list, version } on
-- the state; `shown_for` remembers the version it already opened for, so a
-- dismissal isn't undone on the next frame.
--
-- `history` is the SAME window doing its second job (2026-08-09,
-- `.brief/changelog-reading/`): Settings' View button opens it over the WHOLE
-- parsed changelog — every release, one scroll, newest first — instead of the
-- missed slice. One window, one rendering, so the two can never drift; and the
-- post-update card became judgeable on demand, which the in-pane reading box
-- (retired the same day as "super cramped") never allowed.
local ui = { open = false, shown_for = nil, history = false, preview = false, notes = false }

function whatsnew.is_open() return ui.open end

function whatsnew.close()
  ui.available = nil
  ui.open, ui.history, ui.shown_for = false, false, nil
  ui.preview, ui.notes = false, false
  ui.work = nil
  showcase.reset()
end

-- Settings' View button. Reading the history never touches the seen-mark —
-- that belongs to the post-update flow alone.
function whatsnew.open_history(releases)
  ui.available = nil
  ui.open, ui.history, ui.preview = true, true, false
  ui.history_list = releases
  ui.notes = false
  ui.work = nil
  showcase.reset()
end

-- Only development copies expose this route; it never changes the seen version.
function whatsnew.open_preview()
  ui.available = nil
  ui.open, ui.history, ui.preview = true, false, true
  ui.notes = false
  ui.work = nil
  showcase.reset()
end

-- Catalogue notes are a reading-only snapshot; they never consume the update notice.
function whatsnew.open_available(notes)
  ui.open, ui.history, ui.preview = true, false, false
  ui.available, ui.notes, ui.work = {}, false, nil
  for _, record in ipairs(notes) do
    ui.available[#ui.available + 1] = changelog.from_catalog(record)
  end
  showcase.reset()
end

-- "2026-08-08" -> "8 Aug 2026". A changelog date is read, not sorted, and the
-- ISO form is for the file. Anything that isn't an ISO date comes back unchanged
-- rather than being guessed at.
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
function whatsnew.human_date(iso)
  local y, m, d = tostring(iso or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then return iso end
  local name = MONTHS[tonumber(m)]
  if not name then return iso end
  return string.format("%d %s %s", tonumber(d), name, y)
end

-- Entries share a hanging indent. Cache measured lines so bold area labels and
-- their continuations keep the same spacing without remeasuring every frame.
local DASH = " \u{2014} "
local split_cache = setmetatable({}, { __mode = "k" })
local overview_cache = setmetatable({}, { __mode = "k" })
local notes_inset = {}

local function wrap_lines(ctx, value, first_width, width)
  local lines, line, room = {}, "", first_width
  for word in value:gmatch("%S+") do
    local candidate = line == "" and word or line .. " " .. word
    if select(1, reaper.ImGui_CalcTextSize(ctx, candidate)) > room then
      if line ~= "" or (#lines == 0 and room < width) then
        lines[#lines + 1] = line
        line, room = word, width
      else
        line = candidate
      end
    else
      line = candidate
    end
  end
  lines[#lines + 1] = line
  return lines
end

local function split_entry(ctx, e, text_w, area_w)
  local c = split_cache[e]
  local font_size = reaper.ImGui_GetFontSize(ctx)
  if c and c.w == text_w and c.font_size == font_size and c.area_w == area_w then return c end
  local room = e.area and text_w - area_w
    - select(1, reaper.ImGui_CalcTextSize(ctx, DASH)) or text_w
  local lines = wrap_lines(ctx, e.text, room, text_w)
  c = {
    w = text_w, font_size = font_size, area_w = area_w,
    head = (e.area and DASH or "") .. table.remove(lines, 1), lines = lines,
    detail = e.detail and wrap_lines(ctx, e.detail, text_w, text_w),
  }
  split_cache[e] = c
  return c
end

local function entry_line(ctx, e, x0, text_w)
  local reading = theme.push_release_font(ctx)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),
    M.ITEM_SPACING_X, M.WN_LINE_GAP)
  local col = x0 + M.WN_IND
  reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY, "\u{2022}")
  reaper.ImGui_SameLine(ctx, col)

  local area_w = 0
  if e.area then
    local bold = theme.push_release_bold_font(ctx)
    area_w = select(1, reaper.ImGui_CalcTextSize(ctx, e.area))
    reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, e.area)
    if bold then reaper.ImGui_PopFont(ctx) end
    reaper.ImGui_SameLine(ctx, 0, 0)
  end
  local s = split_entry(ctx, e, text_w, area_w)
  reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, s.head)
  for _, line in ipairs(s.lines) do
    reaper.ImGui_SetCursorPosX(ctx, col)
    reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, line)
  end
  if s.detail then
    for _, line in ipairs(s.detail) do
      reaper.ImGui_SetCursorPosX(ctx, col)
      reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY, line)
    end
  end
  reaper.ImGui_PopStyleVar(ctx)
  if reading then reaper.ImGui_PopFont(ctx) end
end

-- One release, headed by its version and date. Shared with Settings' history
-- pane so the two readings of the same file cannot look like different things.
-- `opts.head` draws the version line (the card wants it, a pane that already
-- names the version in its picker does not).
function whatsnew.draw_release(ctx, release, opts)
  opts = opts or {}
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), M.ITEM_SPACING_X, 0)

  if opts.head ~= false then
    local bold = theme.push_release_bold_font(ctx)
    reaper.ImGui_TextColored(ctx, T.ACCENT, "v" .. (release.version or "?"))
    if bold then reaper.ImGui_PopFont(ctx) end
    if release.date then
      reaper.ImGui_SameLine(ctx, 0, M.ITEM_SPACING_X)
      local small = theme.push_small_font(ctx)
      reaper.ImGui_TextColored(ctx, T.TEXT_QUATERNARY, whatsnew.human_date(release.date))
      if small then reaper.ImGui_PopFont(ctx) end
    end
  end

  if release.overview then
    if opts.head ~= false then reaper.ImGui_Dummy(ctx, 0, M.WN_VERSION_GAP) end
    local reading = theme.push_release_font(ctx, M.WN_OVERVIEW_FS)
    local width = reaper.ImGui_GetContentRegionAvail(ctx)
    local font_size = reaper.ImGui_GetFontSize(ctx)
    local cached = overview_cache[release]
    if not cached or cached.w ~= width or cached.font_size ~= font_size
        or cached.text ~= release.overview then
      cached = { w = width, font_size = font_size, text = release.overview,
        lines = wrap_lines(ctx, release.overview, width, width) }
      overview_cache[release] = cached
    end
    for index, line in ipairs(cached.lines) do
      if index > 1 then reaper.ImGui_Dummy(ctx, 0, M.WN_OVERVIEW_LINE_GAP) end
      reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, line)
    end
    if reading then reaper.ImGui_PopFont(ctx) end
  end

  notes_inset.pad_x, notes_inset.pad_y = M.WN_GROUP_PAD_X, M.WN_GROUP_PAD_Y
  notes_inset.border = T.STROKE_TERTIARY
  for gi, g in ipairs(release.groups or {}) do
    if gi > 1 or release.overview or opts.head ~= false then
      reaper.ImGui_Dummy(ctx, 0, M.WN_SECTION_GAP)
    end
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),
      M.ITEM_SPACING_X, M.WN_GROUP_HEADING_GAP)
    local opened, child = widgets.begin_settings_group(ctx,
      "release_notes_" .. (release.version or "?") .. "_" .. gi,
      tostring(g.name), true, false, notes_inset)
    reaper.ImGui_PopStyleVar(ctx)
    if opened then
      local x0 = reaper.ImGui_GetCursorPosX(ctx)
      local text_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx)) - M.WN_IND
      for index, entry in ipairs(g.entries or {}) do
        if index > 1 then reaper.ImGui_Dummy(ctx, 0, M.WN_ENTRY_EXTRA_GAP) end
        entry_line(ctx, entry, x0, text_w)
      end
    end
    widgets.end_settings_group(ctx, child)
  end
  reaper.ImGui_PopStyleVar(ctx)
end

local function draw_notes(ctx, list, preview)
  if preview and #list == 0 then
    local bold = theme.push_release_bold_font(ctx)
    reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, 'Full Release Notes')
    if bold then reaper.ImGui_PopFont(ctx) end
    reaper.ImGui_PushTextWrapPos(ctx, 0)
    reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY,
      'The full notes will appear here when this release is prepared.')
    reaper.ImGui_PopTextWrapPos(ctx)
  end
  for i, release in ipairs(list) do
    if i > 1 then
      reaper.ImGui_Dummy(ctx, 0, M.ITEM_SPACING_Y)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Separator(), T.STROKE_SECONDARY)
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_PopStyleColor(ctx)
      reaper.ImGui_Dummy(ctx, 0, M.ITEM_SPACING_Y)
    end
    whatsnew.draw_release(ctx, release)
  end
end

function whatsnew.draw(ctx, state, res)
  local pending = state.whatsnew
  local available_mode = ui.available ~= nil
  -- Open once per unread version. Keyed on the version rather than a plain flag
  -- so dismissing it doesn't reopen on the very next frame, and so a second
  -- update in one session (which cannot happen today — an update restarts the
  -- tool — but might once that changes) would still get its own card.
  if pending and not ui.available and ui.shown_for ~= pending.version then
    ui.open, ui.shown_for = true, pending.version
    ui.notes = false
  end

  -- History mode wins while both apply — the full file is a superset of the
  -- missed slice, so nothing the card had to say is lost by the takeover.
  local list, title
  local preview = ui.preview and state.dev_copy == true
  if ui.available then
    list = ui.available
    title = "AVAILABLE UPDATE · RELEASE NOTES###yb_whatsnew"
  elseif preview then
    list = {}
    for _, release in ipairs(state.changelog or {}) do
      if release.version == showcase.version then
        list[1] = release
        break
      end
    end
    title = "WHAT'S NEW · PREVIEW###yb_whatsnew"
  elseif ui.history then
    list = ui.history_list or state.changelog
    title = "RELEASE NOTES###yb_whatsnew"
  elseif pending then
    list = pending.list
    -- Titled by the version the user has ARRIVED at, so the window says what
    -- happened rather than naming a feature.
    title = "UPDATED TO V" .. (pending.version or "?") .. "###yb_whatsnew"
  end
  if not ui.open or not list or not preview and #list == 0 then return nil end
  local illustrated = not ui.available and (preview or showcase.available(state.update and state.update.installed, list))
  local action
  local cx, cy
  if HAS_VIEWPORT then
    cx, cy = reaper.ImGui_Viewport_GetCenter(reaper.ImGui_GetMainViewport(ctx))
  end

  -- Text notes and demonstrations share one resizable, screen-bounded window.
  do
    if cx and res and res.monitor_work_area and (not ui.work or ui.scale ~= theme.scale) then
      ui.work = anchored_panel.work_area(ctx, res, {left = cx, right = cx, top = cy, bottom = cy})
      ui.scale = theme.scale
    end
    local max_w = ui.work and ui.work.right - ui.work.left - M.WINDOW_PAD * 2 or M.WN_SHOWCASE_W
    local max_h = ui.work and ui.work.bottom - ui.work.top - M.WINDOW_PAD * 2 or M.WN_SHOWCASE_H
    local width, height = math.min(M.WN_SHOWCASE_W, max_w), math.min(M.WN_SHOWCASE_H, max_h)
    if HAS_CONSTRAIN then
      reaper.ImGui_SetNextWindowSizeConstraints(ctx,
        math.min(M.WN_SHOWCASE_MIN_W, max_w), math.min(M.WN_SHOWCASE_MIN_H, max_h), max_w, max_h)
    end
    reaper.ImGui_SetNextWindowSize(ctx, width, height,
      reaper.ImGui_Cond_Appearing())
    if ui.work then
      cx = math.max(ui.work.left + width / 2, math.min(ui.work.right - width / 2, cx))
      cy = math.max(ui.work.top + height / 2, math.min(ui.work.bottom - height / 2, cy))
    end
  end
  if cx then
    reaper.ImGui_SetNextWindowPos(ctx, cx, cy, reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
  end

  local flags = reaper.ImGui_WindowFlags_NoCollapse()
    | reaper.ImGui_WindowFlags_NoSavedSettings()
  if illustrated then
    flags = flags | reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
  end
  if reaper.ImGui_WindowFlags_NoDocking then
    flags = flags | reaper.ImGui_WindowFlags_NoDocking()
  end

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(),
    M.WN_SHOWCASE_PAD, M.WN_SHOWCASE_PAD)
  local visible, still_open = theme.begin_window(ctx, title, true, flags, true)
  reaper.ImGui_PopStyleVar(ctx)
  if not still_open then
    ui.open, ui.history, ui.preview = false, false, false
    showcase.reset()
    focus.request()
    if not available_mode then action = { type = "whatsnew_closed" } end
    ui.available = nil
  end
  -- No End on this path — ReaImGui's Begin already ended a not-visible window
  -- itself (see the matchwin note, verified 2026-08-09); End belongs to the
  -- visible path only.
  if not visible then
    return action
  end

  if illustrated then
    -- Keep the notes control outside the content that can scroll.
    local _, available_h = reaper.ImGui_GetContentRegionAvail(ctx)
    local body_h = math.max(1, available_h - reaper.ImGui_GetFrameHeight(ctx) - M.ITEM_SPACING_Y * 2 - 1)
    local body_flags = ui.notes and 0 or
      reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
    if reaper.ImGui_BeginChild(ctx, ui.notes and 'release_notes_body' or 'release_highlights_body',
        0, body_h, 0, body_flags) then
      if ui.notes then draw_notes(ctx, list, preview)
      else showcase.draw(ctx, res, preview) end
      reaper.ImGui_EndChild(ctx)
    end
    reaper.ImGui_Separator(ctx)
    local footer_w = math.max(reaper.ImGui_CalcTextSize(ctx, 'Back to Highlights'),
      (reaper.ImGui_CalcTextSize(ctx, 'Full Release Notes'))) + M.FRAME_PAD_X * 2
    local footer_label = ui.notes and 'Back to Highlights' or 'Full Release Notes'
    if reaper.ImGui_Button(ctx, footer_label .. '###release_notes_toggle', footer_w) then
      ui.notes = not ui.notes
    end
  else
    draw_notes(ctx, list, false)
  end

  local focus_flags = reaper.ImGui_FocusedFlags_ChildWindows and reaper.ImGui_FocusedFlags_ChildWindows() or 0
  if HAS_ESCAPE and reaper.ImGui_IsWindowFocused(ctx, focus_flags)
    and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
    ui.open, ui.history, ui.preview = false, false, false
    showcase.reset()
    focus.request()
    if not available_mode then action = action or { type = "whatsnew_closed" } end
    ui.available = nil
  end

  reaper.ImGui_End(ctx)
  return action
end

return whatsnew
