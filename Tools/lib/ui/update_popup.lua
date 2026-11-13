-- The update popup: a small window over the Reference View that says a newer
-- version is out and offers its release notes, the update itself, or skipping
-- it. core/update_notice.lua decides when it appears; core/update_status.lua
-- supplies the same status lines and button as Settings → Updates. A ui/
-- module: it draws and returns intent. The entry script saves the choices.
local theme = require("ui.theme")
local widgets = require("ui.widgets")
local tips = require("ui.tips")
local focus = require("ui.focus")
local popups = require("ui.popups")
local whatsnew = require("ui.whatsnew")
local notice = require("core.update_notice")
local update_status = require("core.update_status")
local update_check = require("core.update_check")
local changelog = require("core.changelog")

local popup = {}

local HAS_VIEWPORT = reaper.ImGui_GetMainViewport ~= nil
  and reaper.ImGui_Viewport_GetCenter ~= nil
local HAS_ESCAPE = reaper.ImGui_IsKeyPressed ~= nil and reaper.ImGui_Key_Escape ~= nil
local HAS_ALIGN_TEXT = reaper.ImGui_AlignTextToFramePadding ~= nil

local TITLE = "UPDATE AVAILABLE###yb_update_popup"
local SKIP = "Skip This Version"
local NOTES = "Release Notes"
local SWITCH_LABEL = "Show When an Update Is Available"
local OFF_NOTE = "You can turn this back on in Settings \u{2192} Updates."

local session = notice.new()
local status = {}
local focus_pending = true
-- Whether the popup drew last frame, for callers that must not see through it.
local drawn = false

-- Text that only changes with the versions, the font size or the UI scale,
-- measured once rather than every frame.
local cache = {}

local function bold_width(ctx, text)
  local bold = theme.push_bold_font(ctx)
  local w = reaper.ImGui_CalcTextSize(ctx, text)
  if bold then reaper.ImGui_PopFont(ctx) end
  return w
end

-- `available` is the version on offer, or the one the popup opened for once an
-- update has finished and nothing newer is left.
local function measure(ctx, u, available)
  local notes = u.available_notes or {}
  local newest = notes[1]
  local font = reaper.ImGui_GetFontSize(ctx)
  if cache.available == available and cache.installed == u.installed
      and cache.newest == newest and cache.count == #notes
      and cache.font == font and cache.scale == theme.scale then
    return cache
  end
  cache.available, cache.installed, cache.newest, cache.count = available, u.installed, newest, #notes
  cache.font, cache.scale = font, theme.scale
  local M = theme.metrics

  cache.version = "v" .. tostring(available)
  cache.date = newest and newest.date and whatsnew.human_date(newest.date) or nil
  cache.mine = "v" .. tostring(u.installed or "?")
  cache.behind = #notes > 1 and (" \u{00B7} " .. #notes .. " releases behind") or ""
  local release = newest and newest.text ~= update_check.NO_RELEASE_NOTES
    and changelog.from_catalog(newest) or nil
  cache.overview = release and release.overview or nil

  local gap = M.ITEM_SPACING_X
  cache.version_w = bold_width(ctx, cache.version)
  cache.date_w = cache.date and (reaper.ImGui_CalcTextSize(ctx, cache.date)) or 0
  cache.you_w = reaper.ImGui_CalcTextSize(ctx, "You have ")
  cache.mine_w = bold_width(ctx, cache.mine)
  cache.behind_w = reaper.ImGui_CalcTextSize(ctx, cache.behind)
  local left_w = cache.version_w + (cache.date and gap * 2 + cache.date_w or 0)
  local right_w = cache.you_w + cache.mine_w + cache.behind_w
  cache.line_w = math.ceil(left_w + gap * 3 + right_w)

  -- Three equal buttons, each wide enough for the longest label it can show.
  local button_w = M.POPUP_BTN_W
  for _, label in ipairs({ NOTES, SKIP, "Update Now", "Try Again" }) do
    button_w = math.max(button_w,
      math.ceil(reaper.ImGui_CalcTextSize(ctx, label)) + M.FRAME_PAD_X * 2)
  end
  cache.button_w = button_w
  cache.content_w = math.max(cache.line_w, button_w * 3 + gap * 2)
  return cache
end

local function text_run(ctx, color, text, bold)
  local pushed = bold and theme.push_bold_font(ctx)
  reaper.ImGui_TextColored(ctx, color, text)
  if pushed then reaper.ImGui_PopFont(ctx) end
end

-- The new version and its date on the left, the installed one on the right.
local function version_line(ctx, c)
  local T, M = theme.tokens, theme.metrics
  local x0 = reaper.ImGui_GetCursorPosX(ctx)
  local avail = reaper.ImGui_GetContentRegionAvail(ctx)
  if HAS_ALIGN_TEXT then reaper.ImGui_AlignTextToFramePadding(ctx) end
  text_run(ctx, T.ACCENT, c.version, true)
  if c.date then
    reaper.ImGui_SameLine(ctx, 0, M.ITEM_SPACING_X * 2)
    text_run(ctx, T.TEXT_TERTIARY, c.date)
  end
  reaper.ImGui_SameLine(ctx, x0 + avail - (c.you_w + c.mine_w + c.behind_w))
  text_run(ctx, T.TEXT_TERTIARY, "You have ")
  reaper.ImGui_SameLine(ctx, 0, 0)
  text_run(ctx, T.TEXT_SECONDARY, c.mine, true)
  if c.behind ~= "" then
    reaper.ImGui_SameLine(ctx, 0, 0)
    text_run(ctx, T.TEXT_TERTIARY, c.behind)
  end
end

local function wrapped(ctx, color, text)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), color)
  reaper.ImGui_TextWrapped(ctx, text)
  reaper.ImGui_PopStyleColor(ctx)
end

local function button(ctx, label, width, enabled)
  reaper.ImGui_BeginDisabled(ctx, not enabled)
  local clicked = reaper.ImGui_Button(ctx, label, width)
  reaper.ImGui_EndDisabled(ctx)
  return enabled and clicked
end

local function close()
  notice.close(session)
  focus.request()
end

-- `waiting` is true while another startup window is open; the popup appears
-- after it closes. Returns at most one action.
function popup.draw(ctx, state, waiting)
  local u, prefs = state.update, state.update_popup or {}
  drawn = notice.step(session, u, prefs, waiting)
  if not drawn then return nil end
  local T, M = theme.tokens, theme.metrics
  update_status.describe(u, status)
  local c = measure(ctx, u, u.available or session.version)

  popups.fit_width(ctx, "", nil, c.content_w)
  if HAS_VIEWPORT then
    local cx, cy = reaper.ImGui_Viewport_GetCenter(reaper.ImGui_GetMainViewport(ctx))
    reaper.ImGui_SetNextWindowPos(ctx, cx, cy, reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
  end
  -- Submission order alone does not raise a native window, so ask once.
  if focus_pending then
    reaper.ImGui_SetNextWindowFocus(ctx)
    focus_pending = false
  end
  local flags = reaper.ImGui_WindowFlags_NoResize()
    | reaper.ImGui_WindowFlags_AlwaysAutoResize()
    | reaper.ImGui_WindowFlags_NoCollapse()
    | reaper.ImGui_WindowFlags_NoScrollbar()
    | reaper.ImGui_WindowFlags_NoScrollWithMouse()
    | reaper.ImGui_WindowFlags_NoSavedSettings()
  if reaper.ImGui_WindowFlags_NoDocking then
    flags = flags | reaper.ImGui_WindowFlags_NoDocking()
  end

  local visible, open = theme.begin_window(ctx, TITLE, true, flags, true)
  if not open then close() end
  -- ReaImGui has already ended a window that did not draw.
  if not visible then return nil end

  local action
  version_line(ctx, c)
  -- While an update is under way its status replaces the overview, as in
  -- Settings → Updates.
  if status.status then
    wrapped(ctx, T.TEXT_SECONDARY, status.status)
    if status.note then wrapped(ctx, T.TEXT_TERTIARY, status.note) end
  elseif c.overview then
    wrapped(ctx, T.TEXT_SECONDARY, c.overview)
  end

  local gap = M.ITEM_SPACING_X
  local avail = reaper.ImGui_GetContentRegionAvail(ctx)
  local width = math.floor((avail - gap * 2) / 3)
  local notes = u.available_notes or {}
  if button(ctx, NOTES, width, #notes > 0) then whatsnew.open_available(notes) end
  reaper.ImGui_SameLine(ctx, 0, gap)
  if button(ctx, SKIP, width, true) then
    action = { type = "skip_update", version = u.available or session.version }
    close()
  end
  reaper.ImGui_SameLine(ctx, 0, gap)
  if button(ctx, status.button or "Update Now", avail - (width + gap) * 2, status.button ~= nil) then
    action = { type = "start_update" }
  end
  tips.show(ctx, status.button_tip and reaper.ImGui_IsItemHovered(ctx), status.button_tip)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Separator(), T.STROKE_SECONDARY)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_PopStyleColor(ctx)
  local x0 = reaper.ImGui_GetCursorPosX(ctx)
  if HAS_ALIGN_TEXT then reaper.ImGui_AlignTextToFramePadding(ctx) end
  reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, SWITCH_LABEL)
  reaper.ImGui_SameLine(ctx, x0 + avail - M.SET_SWITCH_W)
  local enabled = prefs.enabled ~= false
  if widgets.switch(ctx, "update_popup_enabled", enabled) then
    action = action or { type = "set_update_popup", enabled = not enabled }
  end
  if not enabled then wrapped(ctx, T.TEXT_TERTIARY, OFF_NOTE) end

  local focus_flags = reaper.ImGui_FocusedFlags_ChildWindows
    and reaper.ImGui_FocusedFlags_ChildWindows() or 0
  if HAS_ESCAPE and reaper.ImGui_IsWindowFocused(ctx, focus_flags)
      and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
    close()
  end

  reaper.ImGui_End(ctx)
  return action
end

function popup.is_open() return drawn end

-- Tests start each case with a fresh session.
function popup._reset()
  session = notice.new()
  focus_pending = true
  drawn = false
  for key in pairs(cache) do cache[key] = nil end
end

return popup
