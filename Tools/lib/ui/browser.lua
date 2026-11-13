-- browser: the LIBRARY popup — curation lives here. Rebuilt 2026-07-29 after the
-- full Lavish design review ("library panel redesign"): a full-bleed chrome
-- sidebar (pinned views, tight rows, per-category counts, a passive + New
-- category button on its bottom edge), a search-left / actions-right toolbar,
-- clean table rows (no category dots — the sidebar echoes the hovered/selected
-- row's category instead), a pin column, the audition strip at the BOTTOM, and
-- a selected-name/details row above it and playback controls beneath. The old
-- status/search/count row is gone: search lives in the toolbar, counts live in
-- the sidebar, and status/hints live in the strip's idle face / the info row.
--
-- A ui/ module: it may call reaper.ImGui_* only.

local theme = require("ui.theme")
local tips = require("ui.tips")
local categories = require("core.categories")
local selection = require("core.selection")
local search_rules = require("core.search")
local imgui_label = require("core.imgui_label")
local techfacts = require("core.techfacts")
local transport = require("ui.transport")
local waveform = require("ui.waveform")
local analysis_panel = require("ui.analysis_panel")
local status_card = require("ui.status_card")
local leftover_panel = require("ui.leftover_panel")
local actions = require("core.actions")
local icons = require("ui.icons")
local dropzone = require("ui.dropzone")
local popups = require("ui.popups")
local widgets = require("ui.widgets")
local focus = require("ui.focus")
local shortcuts = require("ui.browser_shortcuts")
local panel_layout = require("core.browser_panel_layout")
local anchored_panel = require("ui.anchored_panel")
local readings = require("ui.readings")
local T = theme.tokens
local M = theme.metrics

local browser = {}

-- Feature detection, checked once at load.
-- Each absent capability degrades on its own: no child padding = flush content,
-- no resize flag = fixed sidebar width, no custom headers = a blank pin header,
-- no context-window popups = the + New category button is the only entry point.
local HAS_CHILD_PAD    = reaper.ImGui_ChildFlags_AlwaysUseWindowPadding ~= nil
local HAS_CHILD_RESIZE = reaper.ImGui_ChildFlags_ResizeX ~= nil
local HAS_SIZE_CONSTRAINTS = reaper.ImGui_SetNextWindowSizeConstraints ~= nil
local HAS_SET_NEXT_SIZE = reaper.ImGui_SetNextWindowSize ~= nil
local HAS_TABLE_HEADER = reaper.ImGui_TableHeader ~= nil and reaper.ImGui_TableRowFlags_Headers ~= nil
local HAS_SB_CTX       = reaper.ImGui_BeginPopupContextWindow ~= nil
  and reaper.ImGui_PopupFlags_MouseButtonRight ~= nil and reaper.ImGui_PopupFlags_NoOpenOverItems ~= nil
-- The audition strip's resize cursor, resolved once at load (the house
-- feature-detection idiom). nil on an older ReaImGui — the drag still works,
-- it just doesn't change the pointer.
local RESIZE_CURSOR    = reaper.ImGui_MouseCursor_ResizeNS and reaper.ImGui_MouseCursor_ResizeNS() or nil
local HAS_NEXT_SCROLL  = reaper.ImGui_SetNextWindowScroll ~= nil
local HAS_NEXT_CONTENT_SIZE = reaper.ImGui_SetNextWindowContentSize ~= nil
local HAS_KEY_MODS     = reaper.ImGui_GetKeyMods ~= nil
local HAS_CTRL_SELECT  = HAS_KEY_MODS and reaper.ImGui_Mod_Ctrl ~= nil
local HAS_SHIFT_SELECT = HAS_KEY_MODS and reaper.ImGui_Mod_Shift ~= nil
local HAS_WRAP_POS     = reaper.ImGui_PushTextWrapPos ~= nil and reaper.ImGui_PopTextWrapPos ~= nil
local COLOR_BUTTON_FLAGS = 0
for _, name in ipairs({ "NoAlpha", "NoPicker", "NoTooltip", "NoDragDrop" }) do
  local flag = reaper["ImGui_ColorEditFlags_" .. name]
  if flag then COLOR_BUTTON_FLAGS = COLOR_BUTTON_FLAGS | flag() end
end

-- The rail scrollbars' bridges between frames (brief `table-scrollbar`,
-- 2026-08-09): each thumb lives OUTSIDE the window it steers — the sound
-- table's in the reserved strip beside the table, the sidebar's beside the
-- category child — but the scroll belongs to that window, only reachable while
-- it is current. So each frame the scrolled window records its numbers here,
-- and a drag on the thumb parks the wanted value in `pending` for the window's
-- next frame to apply. Declared up here because the sidebar (drawn well above
-- the table in this file) shares the idiom.
local list_scroll = { y = 0, max = 0, dir = 0 }
local cats_scroll = { y = 0, max = 0 }
local resize_press_in_header
-- What the sound list was showing last frame (view + search), for the
-- new-view-starts-at-the-top rule in draw_sound_list. nil until first seen.
local last_view_key = nil

--------------------------------------------------------------- arrow browsing

-- (2026-08-08, part of the keyboard-focus work.) While the browser window is
-- focused, Up/Down step the selection exactly as clicking the next row would —
-- in the sound list, or in the sidebar when that was clicked last ("browse the
-- side column", the user's ask). Clicks in those two panes deliberately KEEP
-- OS focus (focus.keep_zone, registered in the draw below) precisely so these
-- keys have somewhere to live; everywhere else a finished click hands focus
-- straight back to REAPER and the arrow keys are REAPER's again (ui/focus.lua).

local HAS_ARROW_NAV = reaper.ImGui_IsKeyPressed ~= nil
  and reaper.ImGui_Key_DownArrow ~= nil and reaper.ImGui_Key_UpArrow ~= nil
  and reaper.ImGui_Key_LeftArrow ~= nil and reaper.ImGui_Key_RightArrow ~= nil
  and reaper.ImGui_IsWindowFocused ~= nil
  and reaper.ImGui_FocusedFlags_RootAndChildWindows ~= nil
  and reaper.ImGui_IsAnyItemActive ~= nil
local HAS_POPUP_ANY = reaper.ImGui_IsPopupOpen ~= nil
  and reaper.ImGui_PopupFlags_AnyPopupId ~= nil and reaper.ImGui_PopupFlags_AnyPopupLevel ~= nil
local HAS_SCROLL_FOLLOW = reaper.ImGui_SetScrollHereY ~= nil
local HAS_WHEEL = reaper.ImGui_GetMouseWheel ~= nil and reaper.ImGui_IsWindowHovered ~= nil
  and reaper.ImGui_HoveredFlags_ChildWindows ~= nil
-- Rows the sound list moves per wheel notch.
local WHEEL_ROWS = 3

-- The sound list scrolls in whole rows, so no row ever sits part-way under
-- its header and resizing the window never slides the rows. Rounds scroll
-- `v` to a row boundary: up when `dir` > 0 (a row stepped into view at the
-- bottom must show whole), down when < 0, otherwise to the nearest; then
-- clamps to 0..`max`.
local function whole_rows(v, row_h, max, dir)
  local r = v / row_h
  if dir > 0 then r = math.ceil(r - 0.001)
  elseif dir < 0 then r = math.floor(r + 0.001)
  else r = math.floor(r + 0.5) end
  return math.max(0, math.min(r * row_h, max))
end

-- Which pane the arrows drive: the pane of the last row the user clicked.
-- Starts on the sound list — the thing arrow-browsing is for — and RESETS to
-- it whenever the window reopens or the search box is in use (Codex,
-- 2026-08-08 review: a sidebar claim from before the window closed surviving
-- into a fresh session — type a search, press Down, and the CATEGORY moves —
-- reads as plain wrong).
local nav_owner = "list"
-- A press on an already-selected row keeps the whole selection so it can be
-- dragged; the collapse to that one row waits here for the release.
local pending_collapse

-- ImGui's frame counter from the last browser.draw, to spot a reopen: this
-- draw only runs while the window is open, so a gap of more than one frame
-- means it was closed in between.
local last_draw_frame = nil
local last_embedded = nil

-- One-frame scroll-follow request from a key step: `list_row` (0-based, the
-- table clipper's numbering) or `view` (the stepped-to sidebar entry), plus the
-- step direction so the row lands at the edge it entered from. Cleared at the
-- end of every browser.draw — never carried across frames.
local nav = { list_row = nil, view = nil, dir = 0 }

-- Scroll the just-submitted (key-stepped) row into view — only when it sits
-- outside the current window's visible band, so a step between two already-
-- visible rows never jolts the scroll. `top_inset` masks a band at the top of
-- the window that doesn't scroll with the rows (the table's frozen header).
local function scroll_follow(ctx, dir, top_inset)
  if not HAS_SCROLL_FOLLOW then return end
  local iy0 = select(2, reaper.ImGui_GetItemRectMin(ctx))
  local iy1 = select(2, reaper.ImGui_GetItemRectMax(ctx))
  local wy = select(2, reaper.ImGui_GetWindowPos(ctx))
  local wh = select(2, reaper.ImGui_GetWindowSize(ctx))
  if iy0 < wy + (top_inset or 0) or iy1 > wy + wh then
    reaper.ImGui_SetScrollHereY(ctx, dir > 0 and 1 or 0)
  end
end

-- Step the sound list: the row `step` away from the browse selection (Down
-- from nothing enters at the top, Up from nothing at the bottom), clamped at
-- the ends. Returns the exact action clicking that row would.
local function step_list(state, step)
  local result = selection.step_sounds(state.visible_sounds, state.browse_id, step)
  if not result then return nil end
  nav.list_row, nav.dir = result.row, step
  return { type = "browse_sound", id = result.id }
end

-- Step the sidebar the same way. A view that somehow isn't in the sequence
-- (can't happen today) steps to All sounds rather than nowhere.
local function step_sidebar(state, step)
  local result = selection.step_sidebar(state.library, state.view, step)
  if not result then return nil end
  nav.view, nav.dir = result.entry, step
  return { type = "select_view", view = result.view }
end

--------------------------------------------------------------- group rows

-- Grouping rows (categories and the two library views) are a different SPECIES
-- from sound rows, and they look it: SMALL-CAPS name at the body size, vs a
-- sound's mixed-case filename at that same size. Colour carries the meaning (sidebar
-- redesign, 2026-07-27, reconfirmed by the 2026-07-29 review):
--   coloured caps = a category
--   white caps    = a view — All sounds / Uncategorised, the ONLY uncoloured rows
-- Selection never recolours a name: the row fill alone marks the active view.
-- No swatches and no per-row dots anywhere — colour lives in the name itself.
--
-- Both views are TEXT_PRIMARY white as of 2026-08-01 (user's call). They used to
-- be two different grays, which made Uncategorised — a row you reach for all the
-- time — the hardest thing in the sidebar to read, and made a category whose
-- stored colour was gray indistinguishable from a view (that gray is gone too;
-- see the schema's v1 -> v2 migration).

-- One grouping row. opts:
--   color    - tint the caps name (categories).
--              Absent = a view, drawn white.
--   selected - the active-view fill (fill only, the colour stands)
--   count    - right-aligned sound count, in the row's OWN colour (2026-08-01:
--              it used to be a flat dim gray on every row, which read as
--              unrelated to the name it belongs to)
--   echo     - the sidebar echo (2026-07-29): the category of the sound the
--              table's cursor is on lights up here — a quiet fill, weaker than
--              selection, so "where does this sound live?" is answered without
--              any mark on the row itself
--   hit_right_pad - excludes an overlay control from the row's click/drop area;
--              the hand-drawn fill and text still use the panel's true edge
-- Sidebar rows draw at the BODY size, not the small one (2026-08-07, user
-- reported them hard to read after the density pass — "are they the same size
-- as the asset table text? maybe they should be slightly bigger"). They are the
-- library's navigation, read as often as the sound names beside them, so they
-- get the same size those do; SMALL CAPS still tells a grouping from a sound,
-- which was always the real signal — the smaller size was only ever reinforcing
-- it, and at 11px it was costing legibility to say something caps already say.
local function group_row_height(ctx)
  return reaper.ImGui_GetTextLineHeight(ctx) + 2 * M.SB_ROW_PAD_Y
end

local function group_row(ctx, id, name, opts)
  opts = opts or {}
  local col = opts.color or T.TEXT_PRIMARY
  -- No visible label on the Selectable itself — the name is hand-drawn below at
  -- its own (possibly indented) position, so indenting the text can never also
  -- shrink the row's fill/hit-area the way ImGui's own label layout would.
  -- The text anchors to the CURSOR captured here, not to the item rect: a
  -- Selectable widens its rect by half an ItemSpacing step on each side (that
  -- is what lets rows sit flush with no click-gaps), so rect-min sits left of
  -- the window's clip edge and text hung on it loses its first pixels
  -- (2026-08-05, user-reported on every non-indented row).
  local text_x = select(1, reaper.ImGui_GetCursorScreenPos(ctx))
  -- The Selectable's OWN fill is suppressed and repainted by hand (2026-08-10,
  -- round 3, user-reported "the background doesn't go all the way to the edge"):
  -- a Selectable's rect overhangs the window on both sides by half an
  -- ItemSpacing step — what lets rows sit flush — so its fill has to be drawn to
  -- the window's TRUE right edge instead.
  --
  -- Since 2026-08-11 that edge is the same one for every sidebar row: the
  -- category list gave up the strip it used to reserve for the slim scrollbar
  -- (the fills' old `fill_ext` escape hatch went with it), because reserving it
  -- inside the list alone left the category counts a strip short of the pinned
  -- views' counts above them, with a band of empty chrome after each. The thumb
  -- floats over the rows' right end instead, like an overlay scrollbar, and
  -- SB_COUNT_PAD keeps the digits clear of it.
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(), 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(), 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(), 0)
  local hit_w = 0
  if opts.hit_right_pad then
    hit_w = math.max(1, select(1, reaper.ImGui_GetContentRegionAvail(ctx))
      - opts.hit_right_pad - M.ITEM_SPACING_X * 0.5)
  end
  reaper.ImGui_Selectable(ctx, "##" .. id, opts.selected or false, 0, hit_w,
    group_row_height(ctx))
  reaper.ImGui_PopStyleColor(ctx, 3)
  -- The click is read on PRESS, not on the Selectable's own release (2026-08-01:
  -- the sidebar felt a beat behind). Two waits stack otherwise — waiting for the
  -- button to come back up, then one more frame for the entry script to rebuild
  -- the list — and the row is what the user is aiming at, so there is nothing a
  -- release could still cancel. Selecting on press is what file lists do.
  local clicked = reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseClicked(ctx, 0)
  -- A sidebar row click hands the arrow keys to the side column (see
  -- "arrow browsing" above). Every sidebar row goes through here.
  if clicked then nav_owner = "sidebar" end

  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local _, y1 = reaper.ImGui_GetItemRectMax(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  -- The hand-drawn fills (see the suppression above). Square corners — these
  -- run flush to the strip's edges now, the Settings-nav look; the echo stays
  -- a translucent overlay-tint (the name reads through it) rather than a
  -- second Selectable state — ImGui has no "half selected".
  local win_r = select(1, reaper.ImGui_GetWindowPos(ctx))
    + select(1, reaper.ImGui_GetWindowWidth(ctx))
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  if opts.selected and not opts.selection_motion_id then
    reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, win_r, y1, T.FILL_SECONDARY)
  elseif hovered then
    reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, win_r, y1, T.FILL_TERTIARY)
  end
  if opts.echo and not opts.selected then
    reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, win_r, y1, T.FILL_TERTIARY)
  end
  -- The actual neutral selection plate travels to the new anchor. Its timing
  -- runs in the child's content coordinates, then returns to screen space, so
  -- scrolling or moving the window cannot create a false selection animation.
  -- Pinned views and the scrolling category child use separate tracks because
  -- a plate cannot safely travel across their clipping boundaries.
  if opts.selection_motion_id then
    local scroll_y = reaper.ImGui_GetScrollY(ctx)
    local window_y = select(2, reaper.ImGui_GetWindowPos(ctx))
    local plate_y = widgets.motion_value(ctx, opts.selection_motion_id,
      y0 - window_y + scroll_y, 0.42) + window_y - scroll_y
    local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
    reaper.ImGui_DrawList_AddRectFilled(dl, x0, plate_y, win_r,
      plate_y + (y1 - y0), theme.fade(T.FILL_SECONDARY, alpha))
  end
  -- The COUNT owns the row's right end and the name is cut to whatever is left
  -- (2026-08-07, user-reported: dragging the sidebar narrow ran the category
  -- name straight underneath the number). Two runs of text must never compete
  -- for the same pixels, so the count's zone is measured BEFORE the name is
  -- laid out and the name can never reach it. The count is also drawn LAST, so
  -- even a rounding error leaves the number legible on top rather than under.
  --
  -- The panel carries ZERO padding since 2026-08-10 (fills flush to its edges,
  -- the Settings nav's grammar), so the name takes its SB_PAD inset HERE,
  -- inside the row. And the text maths use the window's true right edge, not
  -- the Selectable's rect: the rect overhangs by half an ItemSpacing step
  -- (what lets rows sit flush), and without the old padding that overhang
  -- would hang the count past the visible edge.
  local name_x = text_x + M.SB_PAD
  local tx1 = win_r
  local count_text = opts.count and tostring(opts.count) or nil
  local count_w = count_text and select(1, reaper.ImGui_CalcTextSize(ctx, count_text)) or 0
  local name_max = (tx1 - M.SB_COUNT_PAD) - name_x
  if count_text then name_max = name_max - count_w - M.SB_COUNT_GAP end

  local display_name = opts.preserve_case and name or name:upper()
  local label = widgets.ellipsize(ctx, display_name, name_max)
  local _, lh = reaper.ImGui_CalcTextSize(ctx, label)
  reaper.ImGui_DrawList_AddText(dl, name_x, (y0 + y1) * 0.5 - lh * 0.5, col, label)
  if count_text then
    local th = select(2, reaper.ImGui_CalcTextSize(ctx, count_text))
    reaper.ImGui_DrawList_AddText(dl, tx1 - count_w - M.SB_COUNT_PAD,
      (y0 + y1) * 0.5 - th * 0.5, col, count_text)
  end

  return clicked, hovered
end

-- Transient edit scratch (in-progress popup text, which popup to open next frame).
-- View-only state that never belongs in the shared library — kept here, not on
-- `state`, so nothing outside ui/ sees it.
local edit = { new_cat = "", rename = "", query = "", rename_id = nil, open = nil,
  -- Category deletion needs confirmation only when it would uncategorise sounds.
  cat_del = nil,
  -- The sound a delete confirmation is about. Kept apart from `open` above, which
  -- belongs to the sidebar: the sidebar is drawn first each frame and would consume
  -- a request meant for a popup that lives in the list panel.
  del = nil }

-- In-flight category reorder. The row body is the handle, matching the pinned
-- reference picker: a click still selects, while moving that same press reorders.
local category_drag = { id = nil, gap = nil, rows = {}, count = 0 }

-- The sidebar echo (2026-07-29): which category row lights up because the table's
-- cursor (hover, else the browsed selection) sits on one of its sounds. Written
-- by draw_sound_list each frame and read by draw_sidebar on the NEXT frame — the
-- sidebar draws first, so the echo always trails by one frame, which is
-- imperceptible and keeps the draw order simple. UI-local like `edit`.
local echo = { cat = nil, unc = false }

local function set_echo(s)
  if s.category then
    echo.cat = s.category
  else
    echo.unc = true
  end
end

local function clear_echo()
  echo.cat, echo.unc = nil, false
end

-- The audition strip's top-edge drag (2026-08-06): scratch for the in-flight
-- gesture only. `start_h`/`start_my` = the strip height and mouse y when the
-- seam was grabbed (absolute-anchored, so clamping at a limit and coming back
-- can't drift the height); `live` = what's shown while the mouse is still down
-- — state.browser_wave_h is only written on release, one action instead of
-- sixty a second; `hold` = a reset fired mid-grab, so the release that follows
-- must not commit the drag value over it (the faders' reset_hold idiom).
local split = { start_h = nil, start_my = nil, live = nil, hold = false }

-- ImGui remembers a drag-resized child in raw pixels. Keep the user's sidebar
-- proportion through UI Size changes, including changes made while the Library
-- is closed (the accumulated ratio is consumed when it next draws).
local sidebar_last_w
local pending_sidebar_scale = 1

function browser.request_ui_scale(previous, current)
  previous, current = tonumber(previous), tonumber(current)
  if not previous or not current or previous <= 0 or current <= 0 then return end
  pending_sidebar_scale = pending_sidebar_scale * (current / previous)
end

--------------------------------------------------------------- small helpers

local fmt_duration = require("core.duration_text").format

local function fmt_channels(n)
  return tostring(n or 0) -- raw channel count (1 = mono, 2 = stereo)
end

-- The six measurements the Loudness column can show, in the order the menu lists
-- them — peaks first, then LUFS shortest-window to longest, then RMS. `field`
-- matches the record field the analysis stores. The header label is kept short so
-- the column never has to grow to fit it.
local LOUD_UNITS = {
  { field = "peak",       header = "Peak",   menu = "Peak" },
  { field = "true_peak",  header = "dBTP",   menu = "True Peak" },
  { field = "lufs_m_max", header = "LUFS-M", menu = "LUFS-M" },
  { field = "lufs_s_max", header = "LUFS-S", menu = "LUFS-S" },
  { field = "lufs_i",     header = "LUFS-I", menu = "LUFS-I" },
  { field = "rms",        header = "RMS",    menu = "RMS" },
}

local function loud_unit(state)
  local fallback
  for _, u in ipairs(LOUD_UNITS) do
    if u.field == state.loud_unit then return u end
    -- The fallback stays the headline number, not the menu's first row — the
    -- menu is ordered for reading, not for rank.
    if u.field == "lufs_i" then fallback = u end
  end
  return fallback
end

-- The Loudness cell. Three honest states, no layout shift between them: a measured
-- number, "…" while it is still queued behind the background analysis, and "—" when
-- the file couldn't be measured (or holds nothing measurable, like pure silence).
local function fmt_loudness(s, field)
  if s.analysis ~= "done" then
    return s.analysis == "failed" and "—" or "\u{2026}"
  end
  if type(s[field]) ~= "number" then return "—" end
  return string.format("%.1f", s[field])
end

local function view_is(state, scope, id)
  local v = state.view
  if v.scope == "categories" and id ~= nil then
    return v.ids and v.ids[id] == true
  end
  return v.scope == scope and (id == nil or v.id == id)
end

-- Multi-category selection has several real selected rows. Its anchor alone
-- owns the travelling plate; the rest retain their genuine static fills.
local function selection_motion_id(view, scope, id)
  if not theme.motion.enabled then return nil end
  if view.scope == "categories" then
    return view.anchor == id and view.ids and view.ids[id]
      and "sidebar_selection_categories" or nil
  end
  if view.scope == scope and view.id == id then
    return scope == "category" and "sidebar_selection_categories" or "sidebar_selection_pinned"
  end
end

local function seed_selection_motion(ctx, id, y)
  if not id then return end
  local window_y = select(2, reaper.ImGui_GetWindowPos(ctx))
  widgets.motion_value(ctx, id, y - window_y + reaper.ImGui_GetScrollY(ctx), 0.42)
end

-- A normal click keeps the established single-category navigation. Ctrl-click
-- toggles individual rows; Shift-click selects the continuous sidebar range
-- from the last clicked category. Ctrl+Shift adds that range to the current set.
local function select_category_view(ctx, state, scope, id)
  local ctrl = HAS_CTRL_SELECT
    and (reaper.ImGui_GetKeyMods(ctx) & reaper.ImGui_Mod_Ctrl()) ~= 0
  local shift = HAS_SHIFT_SELECT
    and (reaper.ImGui_GetKeyMods(ctx) & reaper.ImGui_Mod_Shift()) ~= 0
  return selection.click_category(state.library, state.view, scope, id, ctrl, shift)
end

-- Which category a sound dropped in the current view should be filed under.
local function view_target(lib, v)
  if v.scope == "category" and categories.get(lib, v.id) then return v.id end
  return nil -- "all" / "uncategorised" -> Uncategorised
end

-- The browser mirrors the sidebar's file-list grammar. The returned set is
-- independent of browse_id: Ctrl-clicking the latest sound out of the set still
-- makes it the sound shown in the audition strip, as requested.
local function select_sound_rows(ctx, state, id)
  local ctrl = HAS_CTRL_SELECT
    and (reaper.ImGui_GetKeyMods(ctx) & reaper.ImGui_Mod_Ctrl()) ~= 0
  local shift = HAS_SHIFT_SELECT
    and (reaper.ImGui_GetKeyMods(ctx) & reaper.ImGui_Mod_Shift()) ~= 0
  return selection.press_sound(state.visible_sounds, state.browse_ids,
    state.browse_anchor_id, id, ctrl, shift)
end

-- A value in a table cell: LEFT-aligned under its own header (2026-08-11, the
-- user's call — this replaces the right-alignment the 2026-07-29 review put
-- here, where digits stacked by place value but every column read as detached
-- from the word naming it), and centred in `row_h`, the row's full height — a
-- row is taller than one line of text (see draw_sound_list), so laid-out text
-- would otherwise sit at its top edge while the name beside it is centred.
-- These columns are resizable, so a value IS cut to its cell (2026-08-12) rather
-- than clipped mid-digit: a half-drawn number reads as a different number, which
-- is worse than no number. The Loudness column's own "\u{2026}" for a pending
-- measurement stays distinguishable from a cut value by its dimmer colour — at
-- the width where a real reading cuts down to bare "\u{2026}" nothing in the
-- column is readable anyway.
local function num_cell(ctx, color, text, row_h)
  text = widgets.ellipsize(ctx, text, select(1, reaper.ImGui_GetContentRegionAvail(ctx)))
  local th = select(2, reaper.ImGui_CalcTextSize(ctx, text))
  if row_h and row_h > th then
    reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetCursorPosY(ctx) + (row_h - th) * 0.5)
  end
  reaper.ImGui_TextColored(ctx, color, text)
end

-- How much of the pin column's right edge belongs to the sort arrow, now that
-- the column sorts (2026-08-01). Reserved ALWAYS, not only while that column is
-- the sorted one, so the pushpins never shift when the sort changes.
local function pin_arrow_zone()
  return M.SORT_ARROW_W + M.SORT_ARROW_GAP * 2
end

-- THE ONE X EVERY PUSHPIN IN THE COLUMN SHARES, read from the item submitted
-- just before this call and snapped to a whole pixel (2026-08-11, user's ask
-- that the header's pin line up perfectly with the ones under it).
--
-- Each pin used to centre itself in ITS OWN cell, and the header's cell is not
-- the same rectangle as a row's: a header spans the column edge to edge, while a
-- row's content sits inside the cell padding, and ImGui pads the table's last
-- column differently on each side. Two pins centred "correctly" that way still
-- land a pixel or so apart — and at 11px, on fractional coordinates, a pixel is
-- the difference between a crisp mark and a soft one. So the column measures the
-- axis ONCE per frame and everything paints on it.
local function pin_axis(ctx, arrow_zone)
  local x0 = select(1, reaper.ImGui_GetItemRectMin(ctx))
  local x1 = select(1, reaper.ImGui_GetItemRectMax(ctx))
  return math.floor((x0 + x1 - arrow_zone) * 0.5)
end

-- The pushpin, painted over the item submitted just before this call: on the
-- column's shared `cx`, at the middle of whatever that item is. Falls back to the
-- drawn shape when the Lucide font is absent.
local function pin_glyph(ctx, font, color, size, cx)
  local y0 = select(2, reaper.ImGui_GetItemRectMin(ctx))
  local y1 = select(2, reaper.ImGui_GetItemRectMax(ctx))
  local cy = math.floor((y0 + y1) * 0.5)
  if not icons.paint_glyph(ctx, font, "pin", cx, cy, color, size) then
    icons.draw_pin(reaper.ImGui_GetWindowDrawList(ctx), cx, cy, color)
  end
end

--------------------------------------------------------------- sidebar

local CATEGORY_COLOR_NAMES = { "Red", "Yellow", "Green", "Teal", "Blue", "Purple" }

-- Mouse and keyboard deletion share the same confirmation rules.
local function request_category_delete(state, ids)
  local request = selection.category_delete(state.library.categories, state.counts.by_id, ids)
  if not request then return nil end
  if request.confirmation_required then
    request.open = true
    edit.cat_del = request
  elseif request.count > 1 then
    return { type = "remove_categories", ids = request.ids }
  else
    return { type = "remove_category", id = request.ids[1] }
  end
end

local function request_sound_delete(ids, name)
  local request = selection.sound_delete(ids, name)
  if request and request.confirmation_required then
    request.open = true
    edit.del = request
  end
end

local function pane_shortcut(ctx, state, pane, in_popup)
  local intent = shortcuts.read(ctx, state, pane, dropzone.file_drag_active(), in_popup)
  if not intent then return nil end
  if intent.type == "request_delete_categories" then
    return request_category_delete(state, intent.ids)
  elseif intent.type == "request_delete_sounds" then
    request_sound_delete(intent.ids, intent.name)
    return nil
  end
  return intent
end

-- The compact palette at the top of a category's right-click menu. Choosing a
-- colour closes the menu immediately; the entry script saves the returned
-- action in the same frame. The current colour gets both a ring and a check so
-- it remains clear without relying on colour perception alone.
local function category_color_row(ctx, ids, current_color)
  local action
  for i, color in ipairs(categories.PALETTE) do
    if i > 1 then reaper.ImGui_SameLine(ctx, 0, M.CATEGORY_SWATCH_GAP) end
    -- With NoAlpha set, ColorButton expects 0xRRGGBB rather than the
    -- 0xRRGGBBAA format used by our stored palette and draw-list colours.
    local clicked = reaper.ImGui_ColorButton(ctx, "##category_color_" .. i,
      color >> 8, COLOR_BUTTON_FLAGS, M.CATEGORY_SWATCH_SIZE, M.CATEGORY_SWATCH_SIZE)
    local hovered = reaper.ImGui_IsItemHovered(ctx)
    local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
    local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
    if current_color == color then
      local dl = reaper.ImGui_GetWindowDrawList(ctx)
      local rounding = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding())
      reaper.ImGui_DrawList_AddRect(dl,
        x0 - M.CATEGORY_SWATCH_RING_GAP, y0 - M.CATEGORY_SWATCH_RING_GAP,
        x1 + M.CATEGORY_SWATCH_RING_GAP, y1 + M.CATEGORY_SWATCH_RING_GAP,
        T.TEXT_PRIMARY, rounding, 0, 1)
      local mark = "\u{2713}"
      local mw, mh = reaper.ImGui_CalcTextSize(ctx, mark)
      reaper.ImGui_DrawList_AddText(dl,
        (x0 + x1 - mw) * 0.5, (y0 + y1 - mh) * 0.5, T.TEXT_ON_ACCENT, mark)
    end
    tips.show(ctx, hovered, CATEGORY_COLOR_NAMES[i], "category_color_" .. i)
    if clicked then
      if current_color ~= color then
        action = { type = "set_category_colors", ids = ids, color = color }
      end
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
  end
  return action
end

-- Right-click menu for a category row. Rename can't OpenPopup directly (it runs
-- inside the closing context popup), so it stashes the popup and entry data;
-- draw_sidebar opens it at its own scope.
local function category_menu(ctx, state, cat)
  local action
  if reaper.ImGui_BeginPopupContextItem(ctx, "ctx_" .. cat.id) then
    local ids = selection.category_targets(state.library.categories, state.view, cat.id)
    local common_color = cat.color
    for _, id in ipairs(ids) do
      local selected_cat = categories.get(state.library, id)
      if not selected_cat or selected_cat.color ~= common_color then
        common_color = nil
        break
      end
    end
    action = category_color_row(ctx, ids, common_color) or action
    reaper.ImGui_Separator(ctx)
    if #ids == 1 then
      if reaper.ImGui_MenuItem(ctx, "Rename\u{2026}") then
        edit.rename_id, edit.rename, edit.open = cat.id, cat.name, "rename_cat"
      end
    end
    local delete_request = selection.category_delete(state.library.categories, state.counts.by_id, ids)
    local label = #ids > 1 and string.format("Delete %d Categories", #ids) or "Delete"
    if delete_request.confirmation_required then label = label .. "\u{2026}" end
    if reaper.ImGui_MenuItem(ctx, label) then
      action = request_category_delete(state, ids)
    end
    reaper.ImGui_EndPopup(ctx)
  end
  return action
end

local function delete_categories_popup(count)
  return count > 1
    and string.format("DELETE %d CATEGORIES###confirm_delete_categories", count)
    or "DELETE CATEGORY###confirm_delete_categories"
end

local function draw_category_delete_confirm(ctx)
  local del = edit.cat_del
  if not del then return nil end
  local popup_id = delete_categories_popup(del.count)
  local heading = del.count > 1 and string.format("Delete %d categories?", del.count)
    or string.format("Delete %s?", del.name)
  local explanation = "Sounds move to Uncategorised.\nThis can't be undone."

  if del.open then
    reaper.ImGui_OpenPopup(ctx, popup_id)
    del.open = false
  end

  if reaper.ImGui_IsPopupOpen(ctx, popup_id) then
    popups.fit_width(ctx, heading, explanation)
  end
  local action
  -- Ordinary popups keep both panels undimmed; dismissal never confirms deletion.
  if reaper.ImGui_BeginPopup(ctx, popup_id) then
    if HAS_WRAP_POS then reaper.ImGui_PushTextWrapPos(ctx, 0) end
    if del.count > 1 then
      reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, heading)
    else
      popups.name_question(ctx, del.name, del.color)
    end
    reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, explanation)
    if HAS_WRAP_POS then reaper.ImGui_PopTextWrapPos(ctx) end

    local cancel, delete = widgets.action_pair(ctx, "Cancel", "Delete")
    if cancel then
      edit.cat_del = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    elseif delete then
      action = del.count > 1 and { type = "remove_categories", ids = del.ids }
        or { type = "remove_category", id = del.ids[1] }
      edit.cat_del = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  elseif not del.open then
    edit.cat_del = nil
  end

  return action
end

-- Right-click on empty sidebar space: the secondary way to add a category (the
-- passive button below is the primary). NoOpenOverItems keeps the row menus in
-- charge of their own rows.
local function sidebar_context(ctx)
  if not HAS_SB_CTX then return end
  if reaper.ImGui_BeginPopupContextWindow(ctx, "sb_ctx",
      reaper.ImGui_PopupFlags_MouseButtonRight() | reaper.ImGui_PopupFlags_NoOpenOverItems()) then
    if reaper.ImGui_MenuItem(ctx, "New Category\u{2026}") then
      edit.new_cat, edit.open = "", "add_cat"
    end
    reaper.ImGui_EndPopup(ctx)
  end
end

-- Menu requests open after leaving the closing menu's scope.
local function draw_category_edit_popups(ctx)
  if edit.open then
    reaper.ImGui_OpenPopup(ctx, edit.open)
    edit.open = nil
  end
  local action
  local newcat = popups.edit_popup(ctx, edit, "add_cat", "New Category", "new_cat",
    { submit_on_enter = true })
  if newcat then action = { type = "add_category", name = newcat } end
  local renamed = popups.edit_popup(ctx, edit, "rename_cat", "Rename Category", "rename",
    { submit_on_enter = true })
  if renamed then action = { type = "rename_category", id = edit.rename_id, name = renamed } end
  return action
end

-- The category child scrolls without moving the fixed views above it.
local function draw_categories(ctx, state, hit_right_pad)
  local action
  local lib = state.library
  local counts = state.sidebar_counts

  category_drag.count = 0
  for _, cat in ipairs(lib.categories) do
    local clicked, hovered = group_row(ctx, "cat_" .. cat.id, cat.name,
        { color = cat.color, selected = view_is(state, "category", cat.id),
          count = counts and counts.by_id[cat.id],
          echo = echo.cat == cat.id, hit_right_pad = hit_right_pad,
          preserve_case = true,
          selection_motion_id = selection_motion_id(state.view, "category", cat.id) })
    local active = reaper.ImGui_IsItemActive(ctx)
    local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
    local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
    category_drag.count = category_drag.count + 1
    local row = category_drag.rows[category_drag.count]
    if not row then row = {}; category_drag.rows[category_drag.count] = row end
    row.id, row.y0, row.y1 = cat.id, y0, y1
    if clicked then
      action = { type = "select_view", view = select_category_view(ctx, state, "category", cat.id) }
    end
    if active and reaper.ImGui_IsMouseDragging(ctx, 0) then category_drag.id = cat.id end
    -- Keep a key-stepped row in view (the group_row's Selectable is still the
    -- last item here — the drop target and menu below add none of their own).
    if nav.view and nav.view.scope == "category" and nav.view.id == cat.id then
      scroll_follow(ctx, nav.dir)
    end
    if dropzone.sound_drop_target(ctx, state) then
      action = { type = "refile_sounds", ids = state.drag.sound_ids or { state.drag.sound_id },
        category = cat.id, wins_release = true }
    end
    action = dropzone.read_file_drop(ctx, state, { category = cat.id }) or action
    action = category_menu(ctx, state, cat) or action
    tips.show(ctx, hovered,
      "Ctrl-click to toggle categories. Shift-click to select a range.", "category_multiselect",
      tips.rect(x0, y0, x1 - x0, y1 - y0))
  end

  if category_drag.id then
    local mouse_y = select(2, reaper.ImGui_GetMousePos(ctx))
    local gap = category_drag.count + 1
    for i = 1, category_drag.count do
      local row = category_drag.rows[i]
      if mouse_y < (row.y0 + row.y1) * 0.5 then gap = i; break end
    end
    local changed_gap = category_drag.gap ~= gap
    category_drag.gap = gap
    local from = categories.index_of(lib, category_drag.id)
    local to = categories.drop_target(from, gap)
    local edge = category_drag.rows[gap] and category_drag.rows[gap].y0
      or (category_drag.rows[category_drag.count] and category_drag.rows[category_drag.count].y1)
    -- The line must promise a real move. The two gaps around the dragged row
    -- are no-ops, and the first gap sits just inside the child's clip boundary.
    if edge and to then
      local wx = reaper.ImGui_GetWindowPos(ctx)
      local ww = reaper.ImGui_GetWindowWidth(ctx)
      local line_y = gap == 1 and edge + 1 or edge - 1
      local progress = widgets.motion_event(ctx, "category_reorder_gap", true, 0.44,
        changed_gap)
      local grow, pulse = 1, 0
      if progress then
        grow = math.min(1, progress / 0.35)
        pulse = (1 - progress) * (1 - progress)
      end
      local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
      if progress then
        local mid = wx + ww * 0.5
        local half = ww * grow * 0.5
        reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(ctx),
          mid - half, line_y, mid + half, line_y,
          theme.fade(T.ACCENT, (0.72 + 0.28 * pulse) * alpha), 1.5 + pulse * 1.5)
      else
        reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(ctx),
          wx, line_y, wx + ww, line_y, theme.fade(T.ACCENT, alpha), 2)
      end
    else
      widgets.motion_event(ctx, "category_reorder_gap", false, 0.44)
    end
    if not reaper.ImGui_IsMouseDown(ctx, 0) then
      if to then action = action or { type = "reorder_category", id = category_drag.id, to = to } end
      category_drag.id, category_drag.gap = nil, nil
    end
  end

  -- Retarget after every row has drawn, so an older selected row cannot undo the click.
  if action and action.type == "select_view" then
    for i = 1, category_drag.count do
      local row = category_drag.rows[i]
      local id = selection_motion_id(action.view, "category", row.id)
      if id then seed_selection_motion(ctx, id, row.y0); break end
    end
  end
  sidebar_context(ctx) -- this child's own empty space (the sidebar shell has its own)
  return action
end

local function draw_sidebar(ctx, state)
  local action, selection_y
  local counts = state.sidebar_counts

  -- Rows sit tight (2026-07-29, "we don't need an empty row between
  -- subcategories") — only the deliberate block separators breathe.
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), M.ITEM_SPACING_X, M.SB_ROW_GAP)

  -- Pinned top block (2026-08-10 reorder, the user's ask — Uncategorised used
  -- to be pinned at the BOTTOM): the two views lead, then the new-category
  -- button directly above the list it adds to, then the categories scroll in
  -- whatever height is left. White caps = a view; every category is coloured.
  if group_row(ctx, "view_all", "All sounds",
      { selected = view_is(state, "all"), count = counts and counts.all,
        selection_motion_id = selection_motion_id(state.view, "all") }) then
    action = { type = "select_view", view = { scope = "all" } }
    selection_y = select(2, reaper.ImGui_GetItemRectMin(ctx))
  end
  -- Files dropped on All sounds join the library at large — no category, same
  -- landing spot as the Uncategorised row (2026-08-01, user's call: every
  -- sidebar row should catch a drop, not just the categories).
  action = dropzone.read_file_drop(ctx, state) or action

  if group_row(ctx, "view_unc", "Uncategorised",
      { selected = view_is(state, "uncategorised"),
        count = counts and counts.uncat, echo = echo.unc,
        selection_motion_id = selection_motion_id(state.view, "uncategorised") }) then
    action = { type = "select_view", view = { scope = "uncategorised" } }
    selection_y = select(2, reaper.ImGui_GetItemRectMin(ctx))
  end
  if dropzone.sound_drop_target(ctx, state) then
    action = { type = "refile_sounds", ids = state.drag.sound_ids or { state.drag.sound_id },
      wins_release = true }
  end
  action = dropzone.read_file_drop(ctx, state) or action

  if selection_y and action and action.type == "select_view" then
    seed_selection_motion(ctx, selection_motion_id(action.view, action.view.scope), selection_y)
  end

  -- The + New category button, inset SB_PAD from the flush edges the rows now
  -- own (the child carries zero padding — see the Begin site). The same compact
  -- spacer sits above and below it, so the button is centred between the pinned
  -- views and the scrolling category list.
  reaper.ImGui_Dummy(ctx, 0, M.SB_ROW_GAP)
  reaper.ImGui_SetCursorPosX(ctx, M.SB_PAD)
  local bw = select(1, reaper.ImGui_GetContentRegionAvail(ctx)) - M.SB_PAD
  if reaper.ImGui_Button(ctx, "+ New Category##newcat", bw) then
    edit.new_cat = ""
    reaper.ImGui_OpenPopup(ctx, "add_cat")
  end
  -- Files dropped on the button create a category AND file the files into it,
  -- one motion (2026-08-01, user's call). The entry script names it after the
  -- folder the files came from.
  action = dropzone.read_file_drop(ctx, state, { action_type = "import_new_category" }) or action

  -- No hairline under the button (offered, removed at the user's ask —
  -- round 3): the button's own frame already ends the pinned block.
  reaper.ImGui_Dummy(ctx, 0, M.SB_ROW_GAP)

  -- The categories take every pixel left below the pinned block.
  local row_h = group_row_height(ctx)
  local cats_h = select(2, reaper.ImGui_GetContentRegionAvail(ctx))
  if cats_h < row_h then cats_h = row_h end
  -- EndChild only inside the `if`: ReaImGui's contract (see app.lua) — a fully
  -- clipped child returns false WITHOUT opening.
  --
  -- The category list wears the SAME slim scrollbar as the sound table (brief
  -- `table-scrollbar`, 2026-08-09), with one difference since 2026-08-11: here
  -- the thumb OVERLAYS the rows instead of the child giving up a reserved strip
  -- for it. Reserving it made every category count sit a strip left of the two
  -- pinned views' counts above them, which is exactly the misalignment the user
  -- reported; the rows now run the panel's full width and SB_COUNT_PAD keeps the
  -- digits clear of the thumb. The child still hides its own bar outright
  -- (NoScrollbar — wheel scrolling is untouched).
  -- The overlay rail is handled inside the child after its rows. Category hit
  -- areas stop at the rail while their fill and count still reach the panel's
  -- true edge, so dragging the thumb cannot also select a category.
  local cats_x, cats_y = reaper.ImGui_GetCursorScreenPos(ctx)
  local cats_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  if cats_scroll.pending and HAS_NEXT_SCROLL then
    reaper.ImGui_SetNextWindowScroll(ctx, -1, cats_scroll.pending)
    cats_scroll.pending = nil
  end
  if reaper.ImGui_BeginChild(ctx, "cats", 0, cats_h, 0,
      reaper.ImGui_WindowFlags_NoScrollbar()) then
    -- Fallback only, for a ReaImGui without SetNextWindowScroll (a frame late).
    if cats_scroll.pending then
      reaper.ImGui_SetScrollY(ctx, cats_scroll.pending)
      cats_scroll.pending = nil
    end
    cats_scroll.max = reaper.ImGui_GetScrollMaxY(ctx)
    local scrollbar_live = cats_scroll.max > 0 and cats_w > M.SCROLL_RAIL_W * 3
    local rail_hovered, rail_active = widgets.scrollbar_input(ctx, "catscroll",
      cats_x + cats_w - M.SCROLL_RAIL_W, cats_y, M.SCROLL_RAIL_W, cats_h, scrollbar_live)
    action = draw_categories(ctx, state,
      scrollbar_live and M.SCROLL_RAIL_W or nil) or action
    cats_scroll.y = reaper.ImGui_GetScrollY(ctx)
    if cats_w > M.SCROLL_RAIL_W * 3 then
      local new = widgets.overlay_scrollbar(ctx, "catscroll",
        cats_x + cats_w - M.SCROLL_RAIL_W, cats_y, M.SCROLL_RAIL_W, cats_h,
        cats_scroll.y, cats_scroll.max, rail_hovered, rail_active)
      if new then cats_scroll.pending = new end
    end
    reaper.ImGui_EndChild(ctx)
  end

  sidebar_context(ctx) -- empty space around the pinned rows

  -- Open a context-menu-requested popup (deferred so it isn't nested in the menu).
  action = draw_category_edit_popups(ctx) or action

  reaper.ImGui_PopStyleVar(ctx, 1)
  return action or draw_category_delete_confirm(ctx)
end

--------------------------------------------------------------- sound list

-- Column user-ids (passed to TableSetupColumn) mapped to the sort keys core
-- understands. Reading the id, not the position, keeps sorting correct even if
-- the user reorders columns later. Only the old-build fallback header row still
-- reads this (see draw_sound_list) — the hand-drawn header names its own key.
local SORT_COLS = { [1] = "name", [2] = "dur", [3] = "ch", [4] = "loud", [5] = "pin" }
local LOUD_COL = 3 -- 0-based column index of the Loudness column

-- Which way a column sorts on its FIRST click. Pin prefers descending so that
-- click brings the pinned sounds to the TOP (ascending would bury them, which is
-- never what "sort by pinned" means — 2026-08-01); everything else starts
-- ascending. Clicking the column that is already sorting flips it instead.
local PREFER_DESC = { pin = true }

-- Feature detection for the "Show in library" scroll (checked once at load, the
-- house idiom): without it the row is still selected, it just isn't scrolled to.
local HAS_CLIPPER_INCLUDE = reaper.ImGui_ListClipper_IncludeItemByIndex ~= nil
  and reaper.ImGui_SetScrollHereY ~= nil
local HAS_PREFER_DESC = reaper.ImGui_TableColumnFlags_PreferSortDescending ~= nil

-- The last "Show in library" request this table has already acted on. UI-local
-- scratch like `edit` and `echo`: the entry script counts requests up and never
-- has to be told when one has been served.
local revealed_seq = nil

-- Which column the open header menu was armed over. The Loudness header offers the
-- measurement list on top of the width reset; every other header offers the reset
-- alone.
local menu_col = nil

-- Arms the header menu for `col`, and is why ImGui's own header menu never reaches
-- the screen. Call it IMMEDIATELY after that column's TableHeader — three details
-- have to line up, and all three are ImGui's, not ours:
--
--  * RELEASE, not press. ImGui arms its menu on the release, so a menu opened on the
--    press is simply replaced a moment later.
--  * Hover tested with AllowWhenBlockedByPopup, which is how ImGui tests it too. The
--    plain test (and the whole column-hover flag) goes dead while ANY popup is open,
--    so a fast second right-click — press and release inside one frame, with the last
--    menu still up — would arm ImGui's menu and not ours.
--  * Right after TableHeader. ImGui opens its popup inside that call; the last popup
--    opened at a level is the one that survives, so ours must be opened after it, in
--    the same frame.
--
-- What we are replacing: ImGui's "size all columns to default" doesn't restore the
-- widths TableSetupColumn asks for — in a resizable table ImGui reads "default" as
-- "shrink each column to fit its contents", which collapses the pin column (its
-- header is a drawn glyph, so ImGui measures it as empty).
local function arm_header_menu(ctx, col)
  if reaper.ImGui_IsMouseReleased(ctx, 1)
    and reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_AllowWhenBlockedByPopup()) then
    menu_col = col
    reaper.ImGui_OpenPopup(ctx, "hdr_menu")
  end
end

-- The sort arrow, painted at `x` and centred between `y0`/`y1`. Up = ascending,
-- ImGui's own convention. Points are given bottom-left, bottom-right, apex (the
-- waveform's playhead caret's winding).
--
-- BOTH COORDINATES ARE SNAPPED TO WHOLE PIXELS (2026-08-11, user-reported: "the
-- sort arrow looks different for the pin column"). Every column draws the same
-- triangle, but the pin column's x came out of a cell edge — a round number —
-- while a text column's was a measured text width added to a cursor, landing
-- part-way across a pixel. A 7×4 shape smeared over two pixel columns really
-- does look like a different, softer arrow. The pin column's crisp one is the
-- one the user picked, so all of them snap to that grid now.
local function sort_arrow(ctx, x, y0, y1, asc, color)
  local w = M.SORT_ARROW_W
  local h = math.floor(w * 0.6)
  x = math.floor(x + 0.5)
  local cy = math.floor((y0 + y1) * 0.5)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  if asc then
    reaper.ImGui_DrawList_AddTriangleFilled(dl,
      x, cy + h * 0.5, x + w, cy + h * 0.5, x + w * 0.5, cy - h * 0.5, color)
  else
    reaper.ImGui_DrawList_AddTriangleFilled(dl,
      x, cy - h * 0.5, x + w, cy - h * 0.5, x + w * 0.5, cy + h * 0.5, color)
  end
end

-- One header cell: the stock TableHeader — which keeps the hover highlight, the
-- resize grip and our own right-click menu — plus the sort arrow painted BY US,
-- immediately after the label (2026-08-11, user-reported: ImGui draws its arrow
-- hard against the cell's right edge, "far away from the text", which on the
-- stretched Name column is most of the window away).
--
-- That position isn't configurable, and ImGui draws the arrow whenever it owns
-- the sorting — so the table is no longer Sortable and the click is read here
-- instead. Nothing changes outside this file: the same `set_sort` action goes to
-- the entry script, which has always been the one doing the actual ordering.
--
-- `arrow_zone`, when given, centres the arrow in that many pixels at the cell's
-- RIGHT end instead of placing it after the label — for the pin column, whose
-- "label" is a glyph painted over the header afterwards.
local function header_cell(ctx, state, idx, label, key, arrow_zone, text_left)
  reaper.ImGui_TableSetColumnIndex(ctx, idx)
  if text_left then
    local _, y = reaper.ImGui_GetCursorScreenPos(ctx)
    reaper.ImGui_SetCursorScreenPos(ctx, text_left, y)
  end
  -- The label's own origin: TableHeader draws it at the cursor, exactly as
  -- group_row's hand-drawn name does (never from the item rect, which starts at
  -- the cell's padding edge).
  local text_x, text_y = reaper.ImGui_GetCursorScreenPos(ctx)
  local sorted_text = key and state.sort.col == key and not arrow_zone
  -- Keep the native header's identity, sizing and resize grip, but reserve the
  -- arrow's space when painting a sorted label in a narrow column.
  if sorted_text then reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0) end
  reaper.ImGui_TableHeader(ctx, label)
  if sorted_text then reaper.ImGui_PopStyleColor(ctx, 1) end
  arm_header_menu(ctx, idx)

  local action
  -- A PRESS THAT IMGUI GAVE TO THIS HEADER, not "the mouse came up over it"
  -- (2026-08-12, user-reported: dragging a column's edge to resize it also
  -- re-sorted that column — two separate gestures landing as one).
  --
  -- The resize grip is a separate invisible item that ImGui submits BEFORE the
  -- header row and that OVERLAPS both headers it sits between. It declares
  -- itself as an overlapping item, which switches OFF the "another item is
  -- active" guard inside IsItemHovered — so the header answers "the cursor is on
  -- me" for the whole drag, and a hover+release test fires on the mouse-up that
  -- ends the resize. What the grip can't do is take the header ACTIVE: only a
  -- press ImGui routes to the header itself does that. So the sort waits for
  -- this header to go active and then be let go on top of itself, which is
  -- exactly what ImGui's own header does with the click it keeps for sorting.
  if key and reaper.ImGui_IsItemDeactivated(ctx) and reaper.ImGui_IsItemHovered(ctx) then
    -- NOT the `cond and a or b` idiom: flipping a column that is currently
    -- ASCENDING wants `false`, which that idiom silently discards.
    local asc
    if state.sort.col == key then asc = not state.sort.asc
    else asc = not PREFER_DESC[key] end
    action = { type = "set_sort", col = key, asc = asc }
  end

  if key and state.sort.col == key then
    local x1 = select(1, reaper.ImGui_GetItemRectMax(ctx))
    local y0, y1 = select(2, reaper.ImGui_GetItemRectMin(ctx)), select(2, reaper.ImGui_GetItemRectMax(ctx))
    local shown = label
    if sorted_text then
      local available = math.max(0, x1 - text_x - M.SORT_ARROW_W - M.SORT_ARROW_GAP - 2)
      shown = widgets.ellipsize(ctx, label, available)
      if select(1, reaper.ImGui_CalcTextSize(ctx, shown)) > available then shown = "" end
      reaper.ImGui_DrawList_AddText(reaper.ImGui_GetWindowDrawList(ctx), text_x, text_y,
        theme.fade(T.TEXT_PRIMARY, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())), shown)
    end
    local ax = arrow_zone
      and (x1 - arrow_zone * 0.5 - M.SORT_ARROW_W * 0.5)
      or (text_x + select(1, reaper.ImGui_CalcTextSize(ctx, shown)) + M.SORT_ARROW_GAP)
    -- Never past the cell: a header squeezed narrow ellipsises its own label,
    -- and an arrow drawn beyond that would sit in the next column.
    local max_x = x1 - M.SORT_ARROW_W - 2
    if ax > max_x then ax = max_x end
    sort_arrow(ctx, ax, y0, y1, state.sort.asc, T.TEXT_SECONDARY)
  end

  return action
end

-- The menu itself, submitted once INSIDE the table just before EndTable — the popup
-- has to be submitted every frame, whether or not it is open.
local function draw_header_menu(ctx, state, loud_col)
  local action
  local unit = loud_unit(state)

  if reaper.ImGui_BeginPopup(ctx, "hdr_menu") then
    if menu_col == (loud_col or LOUD_COL) then
      for _, u in ipairs(LOUD_UNITS) do
        if reaper.ImGui_MenuItem(ctx, u.menu, nil, u.field == unit.field) then
          action = { type = "set_loud_unit", field = u.field }
        end
      end
      reaper.ImGui_Separator(ctx)
    end
    if reaper.ImGui_MenuItem(ctx, "Reset Column Widths") then
      action = { type = "reset_columns" }
    end
    reaper.ImGui_EndPopup(ctx)
  end

  return action
end

-- Draw after the table so scrolling a row out of view cannot lose its warning.
-- OpenPopup and BeginPopup must use the same full ID, including the title.
local function delete_popup(count)
  return count > 1
    and string.format("DELETE %d SOUNDS###confirm_delete", count)
    or "DELETE SOUND###confirm_delete"
end
local function draw_delete_confirm(ctx)
  local action
  local del = edit.del
  if not del then return nil end

  local popup_id = delete_popup(del.count or 1)
  local count = del.count or 1
  local heading = count > 1 and string.format("Delete %d sounds?", count)
    or string.format("Delete %s?", del.name)
  local explanation = "Audio and records move to this Library's trash.\nyb-Reference can't restore them yet."
  if del.open then
    reaper.ImGui_OpenPopup(ctx, popup_id)
    del.open = false
  end

  if reaper.ImGui_IsPopupOpen(ctx, popup_id) then
    popups.fit_width(ctx, heading, explanation)
  end
  -- A modal would dim the other windows even with a transparent local backdrop.
  if reaper.ImGui_BeginPopup(ctx, popup_id) then
    if HAS_WRAP_POS then reaper.ImGui_PushTextWrapPos(ctx, 0) end
    reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, heading)
    reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, explanation)
    if HAS_WRAP_POS then reaper.ImGui_PopTextWrapPos(ctx) end
    local cancel, delete = widgets.action_pair(ctx, "Cancel", "Delete")
    if cancel then
      edit.del = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    elseif delete then
      action = { type = "delete_sounds", ids = del.ids or { del.id } }
      edit.del = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  elseif not del.open then
    -- Escape or an outside click cancels; discard the pending selection.
    edit.del = nil
  end

  return action
end

-- The table's INTERNAL NAME, which is also its identity in ImGui's own settings
-- file: ImGui saves the widths a user drags there, keyed by a hash of this
-- string, and hands them straight back the next time a table of that name is
-- created — in this REAPER session or any later one. "Reset column widths" works
-- by asking for a name ImGui has never seen, since a table with nothing saved
-- starts at the widths TableSetupColumn asks for (there is no call that sets a
-- column's width directly).
--
-- Three parts, all needed for remembered widths to stay honest:
-- (2026-08-11, user-reported: "it gives a different effect based on which header
-- you right click"; it was really a different effect on each PRESS):
--
--  * COL_LAYOUT — bumped BY HAND here whenever the default widths in theme.lua
--    change. Without it, widths a user dragged to suit the old layout are
--    restored over the new defaults and the change never reaches them.
--  * state.col_gen — the user's own reset count, now persisted (see
--    reaper_api.get_col_gen). It used to restart at 0 each run, so a reset
--    stepped back onto names this REAPER had already saved widths under and
--    restored those instead of the defaults — a different set each press, until
--    it walked past the last one.
--  * UI Size — each scale level gets its own saved widths. Otherwise ImGui
--    restores raw pixel widths chosen for smaller text and cramps every fixed
--    column after scaling up.
--
-- The name is rebuilt only when the count or UI Size changes, never per frame.
-- 1 = the original widths; 2 = the 2026-08-11 shorter Ch/Loudness; 3 = the same
-- widths again, bumped 2026-08-12 at the user's ask to drop the widths that got
-- dragged around while the resize-also-sorts bug above was being found (one set
-- had reached 139/117). Bumping is the ONLY way to put a column back — ImGui has
-- no "set this width" call — so the stamp means "the defaults this build asks
-- for", and re-landing everyone on them is the same operation as changing them.
local COL_LAYOUT = 3
local table_id, table_id_gen, table_id_scale = nil, nil, nil
local function sounds_table_id(state)
  local gen = state.col_gen or 0
  local scale = theme.scale_percent(theme.scale)
  if gen ~= table_id_gen or scale ~= table_id_scale then
    table_id = "sounds##" .. COL_LAYOUT .. "." .. gen .. ".s" .. scale
    table_id_gen, table_id_scale = gen, scale
  end
  return table_id
end

local function sound_menu(ctx, state, sound)
  local action
  local pinned = state.pins and state.pins.by_origin[sound.id]
  if reaper.ImGui_BeginPopupContextItem(ctx, "row_" .. sound.id) then
    local ids = selection.sound_targets(state.visible_sounds, state.browse_ids, sound.id)
    if pinned then
      if reaper.ImGui_MenuItem(ctx, "Unpin (Keep Audio Copy)") then
        action = { type = "unpin", id = pinned.id }
      end
    elseif reaper.ImGui_MenuItem(ctx, "Pin To This Project") then
      action = { type = "pin_sounds", ids = ids }
    end
    if reaper.ImGui_MenuItem(ctx, "Delete\u{2026}") then
      request_sound_delete(ids, sound.name)
    end
    reaper.ImGui_EndPopup(ctx)
  end
  return action
end

local row_fills = {}
local function draw_sound_list(ctx, state, res, text_left, compact)
  local action
  if pending_collapse and not reaper.ImGui_IsMouseDown(ctx, 0)
    and not reaper.ImGui_IsMouseReleased(ctx, 0) then
    pending_collapse = nil
  end
  local channels = not compact or compact.channels
  local show_loudness = not compact or compact.loudness
  local loud_col = channels and LOUD_COL or (show_loudness and 2 or -1)
  local pin_col = 2 + (channels and 1 or 0) + (show_loudness and 1 or 0)
  local sounds = state.visible_sounds
  local unit = loud_unit(state)
  local font = res.icon_font

  -- A NEW VIEW STARTS AT THE TOP (2026-08-10, user-reported: switching away
  -- from a deeply-scrolled category "glitched the whole browser" — the table
  -- kept the OLD scroll for a frame, drew the new short list somewhere past
  -- its own end (a blank flash), then clamped). This watch fires on the first
  -- frame the new list exists, whatever changed it — a sidebar click, search,
  -- nav arrows, a deleted category — and the reset is handed to the table's
  -- own Begin below, so that same first frame already draws at the top. A
  -- reveal ("Show in library") survives it: its SetScrollHereY runs later
  -- inside the same table and overwrites this.
  local vk = ""
  if state.view then
    vk = tostring(state.view.scope) .. "\0" .. tostring(state.view.id)
    if state.view.scope == "categories" then
      local ids = {}
      for id, selected in pairs(state.view.ids or {}) do
        if selected then ids[#ids + 1] = id end
      end
      table.sort(ids)
      vk = vk .. "\0" .. table.concat(ids, "\0")
    end
  end
  vk = vk .. "\0" .. (state.query or "")
  if vk ~= last_view_key then
    if last_view_key ~= nil then list_scroll.pending = 0 end
    last_view_key = vk
  end

  -- The sidebar echo for this frame: rebuilt BEFORE the table so a table that
  -- fails to open (a clipped, zero-size main panel) darkens the echo rather
  -- than leaving the last frame's row lit for as long as the clipped state
  -- lasts (Codex, 2026-07-29 review). Only the row under the pointer echoes;
  -- the browsed sound does not leave a category looking selected at rest.
  clear_echo()

  -- Flat rows (2026-07-29 review): no zebra striping (RowBg dropped — ImGui's
  -- default alt-row tint was faint zebra) and no vertical column lines. ImGui
  -- force-enables inner vertical borders whenever a table is Resizable, so the
  -- flag alone can't remove them — their COLOUR is pushed to transparent
  -- instead; the resize grab zones still work, invisibly. The header bg goes
  -- transparent too, so the header and body share the panel background.
  local flags = reaper.ImGui_TableFlags_ScrollY() | reaper.ImGui_TableFlags_Resizable()
  -- NOT Sortable on a build that can draw its own headers: ImGui draws the sort
  -- arrow itself whenever it owns the sorting, always at the cell's right edge,
  -- and 2026-08-11 moved that arrow next to the label (see header_cell). The
  -- clicks are read there instead. The old fallback row can't be armed per
  -- column, so on those builds ImGui keeps both its sorting and its arrow.
  if not HAS_TABLE_HEADER then flags = flags | reaper.ImGui_TableFlags_Sortable() end

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TableBorderLight(), 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TableBorderStrong(), 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TableHeaderBg(), 0)

  -- The selected row's fill used to bleed over the rows above and below it
  -- (reported 2026-08-01). ImGui grows a Selectable's rectangle by ItemSpacing.y
  -- — half above, half below — so that a LIST of them has no seams; inside a
  -- table, where rows already sit flush against each other, that overhang lands
  -- squarely on the neighbours. These two are pushed around the row Selectable
  -- ONLY (see the loop below), never across the whole table: held open they'd
  -- also land on the right-click menus submitted inside it, and the same menu
  -- would then look different depending on where it was opened from.
  local spacing_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))

  -- THE ROW'S HIGHLIGHT NOW FILLS THE WHOLE ROW (2026-08-08, user-reported: "a
  -- bit of empty space between each row, you can tell from the row background
  -- highlights"). The cause was a split of duties: the highlight is the Name
  -- cell's Selectable, sized to one line of TEXT, while the row's own pitch came
  -- from that line PLUS the table's CellPadding above and below it — so every
  -- row wore an unfilled band of exactly CellPadding.y at each end.
  --
  -- The fix moves the padding INSIDE the highlight rather than removing it:
  -- CellPadding.y goes to 0 and the same number is added to `row_h` below. Row
  -- pitch is arithmetically identical to before — the user's explicit ask ("make
  -- the overall spacing the same, just make the rows make up for it") — and the
  -- fill now spans it. CellPadding.x is untouched: that is column gutter, and
  -- nothing is wrong with it.
  local cellpad_x, cellpad_y = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_CellPadding())
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_CellPadding(), cellpad_x, 0)

  -- One row height for the whole table (2026-08-05: tightened from control
  -- height, which read as too spaced out for a dense data list — that number was
  -- sized for a click target, not a line of text). It is the text's own line
  -- height PLUS the cell padding the push above just took away, so the row is
  -- exactly as tall as it always was and the Name cell's Selectable — which IS
  -- the highlight — now covers all of it instead of just the text band.
  local row_h = reaper.ImGui_GetTextLineHeight(ctx) + cellpad_y * 2

  -- The scrollbar strip is always reserved, so columns keep the same width
  -- whether this view scrolls or not. Claim its input before the table and
  -- paint after EndTable so the wrapper keeps its normal content bounds.
  local table_x, table_y = reaper.ImGui_GetCursorScreenPos(ctx)
  local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  -- ReaImGui does not expose Dear ImGui's NoBordersInBody flag. Disable
  -- column grips outside the header instead, keeping a header-started drag
  -- enabled through release even if the pointer leaves the header vertically.
  local mx, my = reaper.ImGui_GetMousePos(ctx)
  local over_header = mx >= table_x and mx < table_x + avail_w
    and my >= table_y and my < table_y + row_h
  if reaper.ImGui_IsMouseClicked(ctx, 0) then resize_press_in_header = over_header end
  local allow_resize = resize_press_in_header == true
    or (resize_press_in_header == nil and over_header)
  if not reaper.ImGui_IsMouseDown(ctx, 0) then resize_press_in_header = nil end
  local resize_flags = allow_resize and 0 or reaper.ImGui_TableColumnFlags_NoResize()
  local row_fill_count = 0
  local natural_content_h = row_h * (#sounds + 1) -- body plus header
  local content_scrolls = natural_content_h > avail_h
  local stable_content_h
  if HAS_NEXT_CONTENT_SIZE then
    -- Dear ImGui decides a table child's scrollbar from its content height. A
    -- fixed minimum overflow keeps the hidden native bar present in every view,
    -- while the exact natural height preserves the real range for long lists.
    stable_content_h = math.max(natural_content_h, avail_h + 1)
  end
  -- outer width/height 0 = fill the wrapping child region (see draw_main); a
  -- window squashed too thin skips the rail rather than starving the columns.
  local outer_w = 0
  if avail_w > M.SCROLL_RAIL_W * 3 then outer_w = avail_w - M.SCROLL_RAIL_W end
  local rail_top, rail_h
  if outer_w > 0 then
    rail_top = table_y + row_h + 3
    rail_h = avail_h - row_h - 3
  end
  local rail_hovered, rail_active = widgets.scrollbar_input(ctx, "soundscroll",
    table_x + outer_w, rail_top or table_y, M.SCROLL_RAIL_W, rail_h or 0,
    outer_w > 0 and content_scrolls)

  -- Short views use one pixel of artificial overflow solely to hold the native
  -- scrollbar geometry steady. Keep their real scroll position at the top.
  if stable_content_h and not content_scrolls then list_scroll.pending = 0 end

  -- Whole rows (see whole_rows). Space below the last row makes the furthest
  -- scroll a whole number of rows too; the wheel moves whole rows itself, and
  -- the handed-over scroll replaces the native wheel step this frame.
  local max_scroll = 0
  if content_scrolls then
    max_scroll = math.ceil((natural_content_h - avail_h) / row_h - 0.001) * row_h
    if stable_content_h then stable_content_h = avail_h + max_scroll end
    if HAS_WHEEL and not list_scroll.pending then
      local wheel = reaper.ImGui_GetMouseWheel(ctx)
      if wheel ~= 0 and mx >= table_x and mx < table_x + avail_w
          and my >= table_y and my < table_y + avail_h
          and reaper.ImGui_IsWindowHovered(ctx, reaper.ImGui_HoveredFlags_ChildWindows()) then
        local rows = math.max(1, math.floor(math.abs(wheel) * WHEEL_ROWS + 0.5))
        if wheel > 0 then rows = -rows end
        list_scroll.pending = whole_rows(list_scroll.y + rows * row_h, row_h, max_scroll, 0)
      end
    end
  end

  local id = sounds_table_id(state)
  if compact then
    -- Each measurement keeps its own resized widths, starting from a header
    -- that fits it. A short unit need not inherit the wider LUFS layout.
    id = id .. "_compact_v3" .. (show_loudness and ("_" .. unit.field) or "")
      .. (channels and "_channels" or "")
  end
  -- A column appearing or going as the panel is resized switches to another
  -- table, which has its own scroll. Carry the list's position across, so the
  -- rows stay where they were.
  if list_scroll.id ~= id then
    if list_scroll.id ~= nil and not list_scroll.pending then
      list_scroll.pending = content_scrolls and whole_rows(list_scroll.y, row_h, max_scroll, 0) or 0
    end
    list_scroll.id = id
  end

  -- The parked scroll is handed to the table's own Begin, which applies it
  -- THIS frame; the in-table SetScrollY fallback below lands a frame late.
  -- Dear ImGui 1.92.1 passes both next-window values to the ScrollY table's
  -- inner child. A culled table clears them, and -1 leaves x untouched.
  if list_scroll.pending and HAS_NEXT_SCROLL then
    reaper.ImGui_SetNextWindowScroll(ctx, -1, list_scroll.pending)
    list_scroll.pending = nil
  end
  if stable_content_h then
    reaper.ImGui_SetNextWindowContentSize(ctx, 0, stable_content_h)
  end

  -- The native bar cannot start below the header, and a zero width asserts in
  -- Dear ImGui. Keep it as a transparent 0.02 sliver; the content-size hint
  -- above keeps that same sliver present so the table never relayouts when the
  -- custom bar appears or disappears. Pop these Begin-time styles immediately.
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ScrollbarSize(), 0.02)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarBg(), 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrab(), 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrabHovered(), 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrabActive(), 0)
  -- Row backgrounds belong to the wrapper so their edges remain continuous.
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0)

  if not reaper.ImGui_BeginTable(ctx, id, pin_col + 1, flags, outer_w, 0) then
    reaper.ImGui_PopStyleVar(ctx, 2)   -- ScrollbarSize + CellPadding
    reaper.ImGui_PopStyleColor(ctx, 8) -- child background, 4 scrollbar, 3 table colours
    return nil
  end
  reaper.ImGui_PopStyleVar(ctx, 1)   -- ScrollbarSize (CellPadding stays for the rows)
  reaper.ImGui_PopStyleColor(ctx, 5) -- child background and scrollbar colours

  -- Fallback only, for a ReaImGui without SetNextWindowScroll: applied from
  -- inside the table (the one scope where its scrolling window is current),
  -- landing a frame late — the degrade, not the design.
  if list_scroll.pending then
    reaper.ImGui_SetScrollY(ctx, list_scroll.pending)
    list_scroll.pending = nil
  end

  -- 5th arg is the column's stable user-id (see SORT_COLS). The sort flags below
  -- only reach ImGui on the old fallback path — where it is still the one
  -- sorting; the hand-drawn header carries the same two rules itself (Name is
  -- state.sort's own default, pin prefers descending — see PREFER_DESC).
  reaper.ImGui_TableSetupColumn(ctx, "Name",
    reaper.ImGui_TableColumnFlags_WidthStretch() | reaper.ImGui_TableColumnFlags_DefaultSort() | resize_flags, 0, 1)
  reaper.ImGui_TableSetupColumn(ctx, "Dur", reaper.ImGui_TableColumnFlags_WidthFixed() | resize_flags,
    compact and M.BROWSER_PANEL_DUR_W or M.COL_DUR_W, 2)
  if channels then
    reaper.ImGui_TableSetupColumn(ctx, "Ch", reaper.ImGui_TableColumnFlags_WidthFixed() | resize_flags, M.COL_CH_W, 3)
  end
  if show_loudness then
    local loud_width = M.COL_LOUD_W
    if compact then
      -- Capture widths only; extra API return values must not enter math.max.
      local header_width = reaper.ImGui_CalcTextSize(ctx, unit.header)
      local value_width = reaper.ImGui_CalcTextSize(ctx, "-100.0")
      loud_width = math.max(header_width
        + M.SORT_ARROW_W + M.SORT_ARROW_GAP + M.FRAME_PAD_X, value_width)
    end
    reaper.ImGui_TableSetupColumn(ctx, unit.header, reaper.ImGui_TableColumnFlags_WidthFixed() | resize_flags,
      loud_width, 4)
  end
  -- The pin column (2026-07-29 review): pinned state moves out of the name cell
  -- into its own slim end column, labelled by a pushpin in the header — each
  -- mark now has one home, and nothing shifts when pinned toggles.
  -- Sortable since 2026-08-01, preferring DESCENDING so the first click on it
  -- brings the pinned sounds to the TOP (ascending would bury them, which is
  -- never what "sort by pinned" means — PREFER_DESC says the same thing to the
  -- hand-drawn header).
  local pin_flags = reaper.ImGui_TableColumnFlags_WidthFixed() | resize_flags
  if HAS_PREFER_DESC then pin_flags = pin_flags | reaper.ImGui_TableColumnFlags_PreferSortDescending() end
  reaper.ImGui_TableSetupColumn(ctx, "##pin", pin_flags,
    compact and M.BROWSER_PANEL_PIN_W or M.PIN_COL_W, 5)
  reaper.ImGui_TableSetupScrollFreeze(ctx, 0, 1)

  -- The pushpins (header and rows alike) centre in the part of the pin column
  -- left of the sort arrow, so the arrow has somewhere to go and the pins keep
  -- one axis whether or not that column is the one sorting. `pin_cx` is that
  -- axis, measured once from the header (or from the first row on a build with
  -- no custom header) and shared by every pin drawn this frame — see pin_axis.
  local arrow_zone = compact and (M.SORT_ARROW_W + M.SORT_ARROW_GAP) or pin_arrow_zone()
  local pin_cx
  local header_line
  -- The frozen header's height, for scroll_follow's top inset: rows scroll under
  -- it, so "visible" for a key-stepped row starts below it, not at the table's
  -- true top edge. It matches a body row now — with CellPadding.y at 0 the
  -- header takes its height from the explicit one passed to TableNextRow below.
  local header_h = row_h

  -- Header row, submitted by hand when the build allows it so the pin column's
  -- header can be the glyph itself; otherwise the stock row (blank pin header).
  -- Each header arms our own right-click menu the moment it is submitted, which is
  -- the only order that keeps ImGui's out (see arm_header_menu). The stock row
  -- can't be armed per column, so on those old builds ImGui's menu is what shows.
  -- Body rows paint their own centred text with zero cell padding. Headers
  -- need the normal padding so native labels and our sorted labels centre too.
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_CellPadding(), cellpad_x, cellpad_y)
  if HAS_TABLE_HEADER then
    reaper.ImGui_TableNextRow(ctx, reaper.ImGui_TableRowFlags_Headers(), row_h)
    action = header_cell(ctx, state, 0, "Name", "name", nil, text_left) or action
    local ux0, _ = reaper.ImGui_GetItemRectMin(ctx)
    action = header_cell(ctx, state, 1, "Dur", "dur") or action
    if channels then action = header_cell(ctx, state, 2, "Ch", "ch") or action end
    if show_loudness then
      action = header_cell(ctx, state, loud_col, unit.header, "loud") or action
    end
    -- The pin column's "label" is the pushpin painted over the header below, so
    -- its arrow goes in the zone the pins already leave clear at the cell's
    -- right end — immediately right of the pin, wherever a resize puts it. The
    -- header pin is WHITE (2026-08-11, user's ask): it names the column, and
    -- TEXT_QUATERNARY is reserved for what nobody has to read.
    action = header_cell(ctx, state, pin_col, "##pin", "pin", arrow_zone) or action
    pin_cx = pin_axis(ctx, arrow_zone)
    pin_glyph(ctx, font, T.TEXT_PRIMARY, M.ICON_PIN_FS, pin_cx)
    -- The one hairline under the header (the flat-table separation the design
    -- calls for), spanning first column's left edge to last column's right.
    -- It sits on the header's last pixel row: the scrolling rows are clipped
    -- at the header's bottom edge, so a row scrolled part-way under the header
    -- is cut at the line and never shows above it.
    local ux1, uy1 = reaper.ImGui_GetItemRectMax(ctx)
    header_line = { x0 = ux0, y = uy1 - 0.5, x1 = compact and (table_x + avail_w) or ux1 }
  else
    reaper.ImGui_TableHeadersRow(ctx)
  end
  reaper.ImGui_PopStyleVar(ctx)

  -- OLD BUILDS ONLY (the stock header row above): there ImGui still owns the
  -- sorting, and this reports it so the entry re-orders the cached list — it
  -- ignores a repeat of the current sort, so emitting whenever ImGui flags it is
  -- safe. We never emit a "cleared" sort: a columned table always keeps one, and
  -- toggling to no sort and back re-shuffled the rows for a frame — that was the
  -- list "flashing". Asked only when the table IS sortable: ImGui hands back no
  -- sort specs at all otherwise.
  if not HAS_TABLE_HEADER and reaper.ImGui_TableNeedSort(ctx) then
    local ok, _, col_user_id, dir = reaper.ImGui_TableGetColumnSortSpecs(ctx, 0)
    -- Sort wins over a unit pick in the (practically impossible) frame that has
    -- both: reading the sort specs clears ImGui's "needs sorting" flag, so a
    -- dropped sort is lost for good, while a dropped unit pick is one more click.
    if ok and SORT_COLS[col_user_id] then
      action = { type = "set_sort", col = SORT_COLS[col_user_id],
        asc = dir == reaper.ImGui_SortDirection_Ascending() }
    end
  end

  -- A pending reveal (set by the entry script when it restores the last-selected
  -- sound at startup): find the row's place in the list ONCE, on the frame the
  -- request is new — the scan happens per request, never per frame. Marked
  -- handled either way, so a sound that somehow isn't in this view can't make
  -- it scan again and again.
  local reveal_row
  if state.reveal_seq ~= revealed_seq then
    revealed_seq = state.reveal_seq
    if state.reveal_id then
      -- The reveal may have cleared a search that was hiding the row; the box's
      -- own buffer is UI-local, so it has to be told (typing is the only other
      -- thing that changes it, and this only fires on a reveal).
      edit.query = state.query
      for i, s in ipairs(sounds) do
        if s.id == state.reveal_id then reveal_row = i - 1; break end
      end
    end
  end

  local span = reaper.ImGui_SelectableFlags_SpanAllColumns()
  -- The Name cell's usable width, measured off the first row submitted and shared
  -- by every row after it (one column, one width — asking per row would be the
  -- same answer at a per-frame cost). A SpanAllColumns Selectable renders its
  -- label against the WHOLE row, not its own cell, so a long name would otherwise
  -- run straight under Dur/Ch — the same "two runs of text competing for the same
  -- pixels" rule the sidebar's count/name split answers.
  local name_w
  reaper.ImGui_ListClipper_Begin(res.clipper, #sounds)
  -- The clipper only submits what's on screen, and the row we're revealing is
  -- exactly the one that usually isn't — this makes it submit that row too, so
  -- there's something for SetScrollHereY to aim at.
  if reveal_row and HAS_CLIPPER_INCLUDE then
    reaper.ImGui_ListClipper_IncludeItemByIndex(res.clipper, reveal_row)
  end
  -- Same for a key-stepped row: it's usually the one just OUTSIDE the clipped
  -- band, and scroll_follow needs it submitted to have a rect to test. Without
  -- IncludeItemByIndex the step still happens — the list just doesn't scroll
  -- until the selection re-enters view (the house degrade-don't-break rule).
  if nav.list_row and HAS_CLIPPER_INCLUDE then
    reaper.ImGui_ListClipper_IncludeItemByIndex(res.clipper, nav.list_row)
  end
  while reaper.ImGui_ListClipper_Step(res.clipper) do
    local first, last = reaper.ImGui_ListClipper_GetDisplayRange(res.clipper)
    for i = first, last - 1 do -- clipper range is 0-based; sounds is 1-based
      local s = sounds[i + 1]
      reaper.ImGui_TableNextRow(ctx)

      reaper.ImGui_TableNextColumn(ctx)
      local _, name_y = reaper.ImGui_GetCursorScreenPos(ctx)
      reaper.ImGui_SetCursorScreenPos(ctx, text_left, name_y)
      -- A clean name, nothing else (2026-07-29 review): the category dot is gone
      -- — the sidebar echo answers "where does this sound live?" — and the pin
      -- marker moved to its own column at the row's end.
      --
      -- Browsing is its OWN selection, independent of the Reference View's armed
      -- reference (Phase 5.9) — this row must never touch state.selected*, or
      -- clicking through the library while comparing would silently retarget
      -- (and re-audition) whatever the user has armed there.
      --
      -- This selectable IS the row highlight, so the row's look is decided right
      -- here (explicit height) rather than by however tall one line of text
      -- happens to be. Zero vertical ItemSpacing while it is submitted stops
      -- ImGui growing its rectangle into the rows above and below — the bleed the
      -- user reported — and the text align centres the name inside the taller
      -- rectangle. Both popped immediately, so nothing else in the table (the
      -- right-click menus especially) inherits them.
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), spacing_x, 0)
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_SelectableTextAlign(), 0, 0.5)
      name_w = name_w or select(1, reaper.ImGui_GetContentRegionAvail(ctx))
      -- The row's identity is the sound id alone (after ###), so a name that
      -- changes its cut, or contains ##, can never change which row this is.
      local row_selected = state.browse_ids and state.browse_ids[s.id] == true
      -- Paint one continuous background in the wrapper rather than joining
      -- a native highlight to a separate fill across the scrollbar boundary.
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(), 0)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(), 0)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(), 0)
      local row_clicked = reaper.ImGui_Selectable(ctx,
        widgets.ellipsize(ctx, imgui_label.visible(s.name), name_w) .. "###" .. s.id,
        row_selected, span, 0, row_h)
      reaper.ImGui_PopStyleColor(ctx, 3)
      local row_hovered = reaper.ImGui_IsItemHovered(ctx)
      -- Save visible fills for the wrapper. ReaImGui resolves window draw
      -- lists at drawing time, so drawing here would clip them to the table.
      if row_selected or row_hovered then
        local _, y0 = reaper.ImGui_GetItemRectMin(ctx)
        local _, y1 = reaper.ImGui_GetItemRectMax(ctx)
        y0 = math.max(y0, table_y + header_h)
        y1 = math.min(y1, table_y + avail_h)
        local held = row_hovered and reaper.ImGui_IsItemActive(ctx)
        local fill = (held or (row_selected and row_hovered)) and T.FILL_PRIMARY
          or (row_hovered and T.FILL_TERTIARY or T.FILL_SECONDARY)
        if y1 > y0 then
          row_fills[row_fill_count + 1] = y0
          row_fills[row_fill_count + 2] = y1
          row_fills[row_fill_count + 3] = fill
          row_fill_count = row_fill_count + 3
        end
      end
      local row_pressed = row_hovered and reaper.ImGui_IsMouseClicked(ctx, 0)
      reaper.ImGui_PopStyleVar(ctx, 2)
      local next_selection
      if row_pressed then
        next_selection = select_sound_rows(ctx, state, s.id)
        pending_collapse = next_selection.pending
          and { id = s.id, selection = next_selection.pending } or nil
        action = { type = "browse_sound", id = s.id,
          selection = next_selection, quiet = true }
        nav_owner = "list" -- the arrows follow the last-clicked pane
      end

      -- The press above selects immediately but stays silent until ImGui confirms
      -- a click on release. Moving far enough to begin a drag never produces this
      -- activation, so pinning or dragging to the timeline cannot auto-audition.
      if row_clicked then
        local collapse = pending_collapse and pending_collapse.id == s.id
          and pending_collapse.selection or nil
        pending_collapse = nil
        action = { type = "audition_browse_sound", id = s.id, selection = collapse }
      end
      -- Scroll the revealed row into the middle of the list, on the one frame
      -- the request is fresh.
      if reveal_row == i and HAS_CLIPPER_INCLUDE then
        reaper.ImGui_SetScrollHereY(ctx, 0.5)
        list_scroll.requested = 0
      end
      -- A key-stepped row scrolls into view at the edge it entered from; the
      -- frozen header row masks the table's top band (scroll_follow's inset).
      if nav.list_row == i then
        scroll_follow(ctx, nav.dir, header_h)
        list_scroll.requested = nav.dir
      end
      -- The Name selectable spans the whole row (SpanAllColumns), so its hover
      -- marks the whole row as hovered — that is what feeds the sidebar echo.
      if row_hovered then
        clear_echo()
        set_echo(s)
      end
      -- Holding a row and moving the mouse starts a drag: out to REAPER's timeline,
      -- or onto the Reference View's reference row to pin it. ImGui's own drag-and-drop
      -- can't leave the window, so all this reports is "a drag has begun" — where it
      -- lands is worked out when the mouse is let go.
      if state.deps.drag_out and not state.drag
        and reaper.ImGui_IsItemActive(ctx) and reaper.ImGui_IsMouseDragging(ctx, 0) then
        action = { type = "drag_sound", id = s.id, target = "browse",
          ids = selection.sound_targets(state.visible_sounds, state.browse_ids, s.id) }
      end
      -- Right-click the row: pin it to (or unpin it from) the current project, or
      -- delete it. Like the category menus, the delete confirmation can't be opened
      -- from in here (we're inside the closing menu) — stash which sound it's about
      -- and open it below, once the table is finished.
      local pinned = state.pins and state.pins.by_origin[s.id]
      action = sound_menu(ctx, state, s) or action

      reaper.ImGui_TableNextColumn(ctx)
      num_cell(ctx, T.TEXT_TERTIARY, fmt_duration(s.duration), row_h)

      if channels then
        reaper.ImGui_TableNextColumn(ctx)
        num_cell(ctx, T.TEXT_TERTIARY, fmt_channels(s.channels), row_h)
      end

      if show_loudness then
        reaper.ImGui_TableNextColumn(ctx)
        -- Missing measurements stay dimmer than actual values.
        local measured = s.analysis == "done" and type(s[unit.field]) == "number"
        num_cell(ctx, measured and T.TEXT_TERTIARY or T.TEXT_QUATERNARY,
          fmt_loudness(s, unit.field), row_h)
      end

      reaper.ImGui_TableNextColumn(ctx)
      -- The pin cell: an accent pushpin when pinned (matched by origin id via
      -- state.pins.by_origin — the SAME lookup the menu above uses, never
      -- re-derived by name), nothing otherwise. The Dummy reserves the cell
      -- either way, so a pin appearing can't move a single pixel.
      local cw = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
      reaper.ImGui_Dummy(ctx, cw, row_h)
      -- The axis, if the header didn't set it (no custom header row on this
      -- build): the first row submitted stands in, and every later one shares it.
      pin_cx = pin_cx or pin_axis(ctx, arrow_zone)
      if pinned then
        pin_glyph(ctx, font, T.ACCENT, M.ICON_PIN_FS, pin_cx)
      end
    end
  end

  -- Painted after the body so the first selected row can never cover the
  -- separator's lower pixels.
  if header_line then
    reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(ctx),
      header_line.x0, header_line.y, header_line.x1, header_line.y,
      compact and T.STROKE_SECONDARY or T.STROKE_TERTIARY, 1)
  end

  -- The header right-click menu, submitted last so its own items sit at the end of
  -- the table's id stack (it is armed up at the header row). Always CALLED — the
  -- popup must be submitted every frame — then merged without clobbering an action
  -- an earlier row already reported.
  local hdr_action = draw_header_menu(ctx, state, loud_col)
  action = action or hdr_action

  -- What the rail thumb below reads this frame — taken here because this is the
  -- scrolling window (BeginTable leaves its inner child current through row
  -- submission; verified upstream 2026-08-09).
  list_scroll.y = reaper.ImGui_GetScrollY(ctx)
  list_scroll.max = reaper.ImGui_GetScrollMaxY(ctx)
  -- A scroll asked for this frame lands next frame; round it to whole rows
  -- once it has, in the direction it was asked for.
  if list_scroll.requested then
    list_scroll.dir, list_scroll.requested = list_scroll.requested, nil
  else
    if content_scrolls and not list_scroll.pending then
      local snapped = whole_rows(list_scroll.y, row_h, max_scroll, list_scroll.dir)
      if math.abs(snapped - list_scroll.y) > 0.5 then list_scroll.pending = snapped end
    end
    list_scroll.dir = 0
  end
  if stable_content_h and not content_scrolls then
    -- Do not expose the one-pixel native layout guard as a real scrollbar.
    list_scroll.y, list_scroll.max = 0, 0
  end

  reaper.ImGui_EndTable(ctx)
  reaper.ImGui_PopStyleVar(ctx, 1) -- the CellPadding pushed before BeginTable
  reaper.ImGui_PopStyleColor(ctx, 3)

  local panel_draw_list = reaper.ImGui_GetWindowDrawList(ctx)
  local row_right = table_x + (outer_w > 0 and outer_w or avail_w)
  for i = 1, row_fill_count, 3 do
    reaper.ImGui_DrawList_AddRectFilled(panel_draw_list,
      table_x, row_fills[i], row_right,
      row_fills[i + 1], row_fills[i + 2])
  end
  for i = #row_fills, row_fill_count + 1, -1 do row_fills[i] = nil end

  -- The table clips its separator at the scrollbar rail. Continue it in the
  -- wrapper, whose drawing bounds include the rail and reach the frame.
  if compact and header_line and outer_w > 0 then
    reaper.ImGui_DrawList_AddLine(panel_draw_list,
      row_right, header_line.y, table_x + avail_w, header_line.y,
      T.STROKE_SECONDARY, 1)
  end

  if outer_w > 0 then
    -- Unlike the sidebar, this rail reaches the outer window's right edge.
    -- Its inherited clip trims half the border, rounded inward to a pixel.
    local border = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_WindowBorderSize())
    local new = widgets.overlay_scrollbar(ctx, "soundscroll",
      table_x + outer_w, rail_top, M.SCROLL_RAIL_W, rail_h,
      list_scroll.y, list_scroll.max, rail_hovered, rail_active, math.ceil(border * 0.5))
    if new then
      list_scroll.pending = content_scrolls and whole_rows(new, row_h, max_scroll, 0) or new
    end
  end

  local confirmed = draw_delete_confirm(ctx)
  action = action or confirmed

  return action
end

--------------------------------------------------------------- main panel

-- Fallback guidance for the strip's idle face — what the old status row's
-- default hint used to say, updated for the labelled Add button.
local IDLE_HINT = "Choose a sound to audition it. Drag audio files here or use + Add Sounds."
local EMPTY_HINT = "Library is empty. Drag audio files here or use + Add Sounds."

-- Cache complete detail prefixes so resizing never cuts a fact in half.
-- The source-info identity also changes when the same file is reopened.
local preview_heading
local function heading_cache(ctx, state)
  local sound, info = state.browse, state.browse_info
  if not sound then
    preview_heading = nil
    return nil
  end
  local size = reaper.ImGui_GetFontSize(ctx)
  local cached = preview_heading
  if not cached or cached.ctx ~= ctx or cached.size ~= size or cached.id ~= sound.id
      or cached.info ~= info or cached.name ~= sound.name or cached.duration ~= sound.duration then
    local parts = techfacts.parts(info, true)
    if sound.duration then table.insert(parts, 1, fmt_duration(sound.duration)) end
    cached = { ctx = ctx, size = size, id = sound.id, info = info,
      name = sound.name, duration = sound.duration, texts = {}, widths = {},
      name_width = reaper.ImGui_CalcTextSize(ctx, sound.name) }
    for i = 1, #parts do
      cached.texts[i] = table.concat(parts, "  \u{00B7}  ", 1, i)
      cached.widths[i] = reaper.ImGui_CalcTextSize(ctx, cached.texts[i])
    end
    cached.tip = sound.name .. (#parts > 0 and ("\n" .. table.concat(parts, "  \u{00B7}  ")) or "")
    preview_heading = cached
  end
  return cached
end

local function draw_preview_heading(ctx, state, height)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local width = math.max(1, select(1, reaper.ImGui_GetContentRegionAvail(ctx)))
  local cached = heading_cache(ctx, state)
  local sound = state.browse
  if not cached then
    reaper.ImGui_Dummy(ctx, width, height)
    return
  end
  local name_width, count = panel_layout.preview_heading(width, cached.name_width,
    cached.widths, M.BROWSER_PREVIEW_DETAILS_GAP, M.BROWSER_PREVIEW_NAME_W)
  local name = widgets.ellipsize(ctx, sound.name, name_width)
  local text_h = reaper.ImGui_GetTextLineHeight(ctx)
  local text_y = math.floor(y + (height - text_h) / 2 + 0.5)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_InvisibleButton(ctx, "##preview_heading", width, height)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
  reaper.ImGui_DrawList_AddText(dl, x, text_y, theme.fade(T.TEXT_PRIMARY, alpha), name)
  if count > 0 then
    reaper.ImGui_DrawList_AddText(dl, x + width - cached.widths[count], text_y,
      theme.fade(T.TEXT_TERTIARY, alpha), cached.texts[count])
  end
  tips.show(ctx, hovered, cached.tip, "library_preview_heading")
end

-- Toolbar (2026-07-29 review): search top-left on the list it filters; the one
-- global action top-right — Add sounds, labelled. The folder and gear squares
-- that used to follow it left on 2026-08-10 (`.brief/settings-move`): the gear
-- lives in the Reference View's bar now, and the folder became a Settings row.
local function draw_toolbar(ctx, state, res)
  local action

  -- The search field: filled, no outline, magnifier embedded in its left
  -- padding, hint dimmer than typed text (theme's TextDisabled) — a native-tool
  -- search, not a web form.
  -- Local buffer drives the box immediately; the entry re-filters next frame.
  local _, q = widgets.search_input(ctx, res.icon_font, "##search", "Search", edit.query or "", M.SEARCH_W)
  -- Searching means the SOUND LIST is what's being narrowed — while the box is
  -- active the arrows step results, whatever pane was clicked before.
  if reaper.ImGui_IsItemActive(ctx) then nav_owner = "list" end
  if q ~= (edit.query or "") then
    edit.query = q
    action = { type = "set_query", query = q }
  end

  -- The one global action, placed by the measure-then-push idiom (same as the
  -- old master fader). If a narrow window leaves no room the button stays put
  -- and clips — nothing jumps.
  reaper.ImGui_SameLine(ctx)
  local add_label = "Add Sounds"
  local pad_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding()))
  local label_w, label_h = reaper.ImGui_CalcTextSize(ctx, add_label)
  local add_w = label_w + M.ICON_FS + M.ITEM_SPACING_X + pad_x * 2
  local panel_w = reaper.ImGui_GetFrameHeight(ctx)
  local cx = reaper.ImGui_GetCursorPosX(ctx)
  local avail = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local target = cx + avail - add_w - panel_w - M.ITEM_SPACING_X
  if target > cx then reaper.ImGui_SetCursorPosX(ctx, target) end

  local cat = view_target(state.library, state.view)
  local dest = categories.get(state.library, cat)
  if reaper.ImGui_Button(ctx, "##add_sounds", add_w) then
    action = { type = "pick", category = cat }
  end
  local ax0, ay0 = reaper.ImGui_GetItemRectMin(ctx)
  local _, ay1 = reaper.ImGui_GetItemRectMax(ctx)
  local icon_x, icon_y = ax0 + pad_x + M.ICON_FS / 2, (ay0 + ay1) / 2
  local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
  local colour = theme.fade(T.TEXT_SECONDARY, alpha)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  if not icons.paint_glyph(ctx, res.icon_font, "plus", icon_x, icon_y, T.TEXT_SECONDARY, M.ICON_FS) then
    icons.draw_plus(dl, icon_x, icon_y, colour)
  end
  reaper.ImGui_DrawList_AddText(dl,
    math.floor(ax0 + pad_x + M.ICON_FS + M.ITEM_SPACING_X + 0.5),
    math.floor(icon_y - label_h / 2 + 0.5), colour, add_label)
  local add_tip = dest
    and ("Choose audio files to add to " .. dest.name .. ".")
    or "Choose audio files to add as Uncategorised."
  tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), add_tip)

  reaper.ImGui_SameLine(ctx)
  if widgets.panel_button(ctx, res.icon_font, "embed_library", "panel-left", false, "[") then
    action = { type = "set_library_placement", placement = "embedded" }
  end
  tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), "Dock to Reference View")

  return action
end

local compact_search = { open = false, focus = false }

local function header_button(ctx, font, id, icon, fallback, highlighted)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0)
  local clicked = widgets.panel_button(ctx, font, id, icon, false, fallback, highlighted)
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_PopStyleVar(ctx, 1)
  return clicked
end

-- Open in Separate Window and Hide Library, at window-relative x positions.
-- The docked Library's mark at the left of its top row, in the accent like
-- the Reference card's pin, so the two cards read apart. Paints it centred in
-- a square `size` wide at screen (x, y), `h` tall, and returns the width it
-- took with the gap after it (0 when the icon font is missing).
local function draw_library_mark(ctx, res, x, y, h)
  local size = M.ICON_SM_FS
  if not icons.paint_glyph(ctx, res.icon_font, "library", x + size * 0.5, y + h * 0.5, T.ACCENT, size) then
    return 0
  end
  return size + M.ITEM_SPACING_X
end

local function draw_window_buttons(ctx, res, popout_x, close_x, y)
  local action
  reaper.ImGui_SetCursorPos(ctx, popout_x, y)
  if header_button(ctx, res.icon_font, "float_library", "external-link", "↗") then
    action = { type = "set_library_placement", placement = "floating" }
  end
  tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), "Open in Separate Window")
  reaper.ImGui_SetCursorPos(ctx, close_x, y)
  if header_button(ctx, res.icon_font, "hide_library", "x", "×") then
    action = { type = "close_browser" }
  end
  tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), "Hide Library")
  return action
end

-- The docked Library's category row. `compact_search` says whether its search
-- field is open. The picker's list passes its own state and no window buttons.
local function draw_compact_toolbar(ctx, state, res, compact_search, window_buttons)
  local action
  local width = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local x, y = reaper.ImGui_GetCursorPos(ctx)
  local sx, sy = reaper.ImGui_GetCursorScreenPos(ctx)
  local button_step = ctrl + M.BROWSER_PANEL_ACTION_GAP
  local close_x = x + width - ctrl
  local popout_x = close_x - button_step
  local search_x = window_buttons and popout_x - button_step or close_x
  -- Docked, the row starts with the Library's mark.
  local mark_w = window_buttons and draw_library_mark(ctx, res, sx, sy, ctrl) or 0
  x, sx = x + mark_w, sx + mark_w
  reaper.ImGui_SetCursorPos(ctx, x, y)
  local category_w = search_x - x - M.ITEM_SPACING_X
  local view = state.view
  local cat = view_target(state.library, view)
  local category = categories.get(state.library, cat)
  local name = category and category.name or (view.scope == "uncategorised"
    and "Uncategorised" or (view.scope == "categories" and "Categories" or "All"))
  if compact_search.open then
    if header_button(ctx, res.icon_font, "back_to_category", "arrow-left", "←") then
      compact_search.open = false
    end
    tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), "Return to Category")
    reaper.ImGui_SetCursorPos(ctx, x + ctrl + M.ITEM_SPACING_X, y)
    -- Keep the current query when Escape closes the field. InputText otherwise
    -- restores the text it had when it first received focus.
    local escape = reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_ChildWindows())
      and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape())
    if compact_search.focus then
      reaper.ImGui_SetKeyboardFocusHere(ctx)
      compact_search.focus = false
    end
    local _, q = widgets.search_input(ctx, res.icon_font, "##search", "Search", edit.query or "", category_w)
    if reaper.ImGui_IsItemActive(ctx) then nav_owner = "list" end
    focus.keep_zone(sx, sy, sx + search_x - x + ctrl, sy + ctrl)
    if escape then
      compact_search.open = false
      focus.consume_key(reaper.ImGui_Key_Escape())
    elseif q ~= (edit.query or "") then
      edit.query = q
      action = { type = "set_query", query = q }
    end
  else
    local count = " (" .. #state.visible_sounds .. ")"
    local count_w = select(1, reaper.ImGui_CalcTextSize(ctx, count))
    local label = widgets.ellipsize(ctx, name, category_w - count_w - M.ICON_SM_FS - M.BROWSER_PANEL_ACTION_GAP)
    local name_w, text_h = reaper.ImGui_CalcTextSize(ctx, label)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 0)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0)
    local clicked = widgets.panel_button_frame(ctx, "##category_heading", category_w, ctrl, false)
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_PopStyleVar(ctx, 1)
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
    local text_y = math.floor(sy + (ctrl - text_h) / 2 + 0.5)
    reaper.ImGui_DrawList_AddText(dl, sx, text_y, theme.fade(category and category.color or T.TEXT_PRIMARY, alpha), label)
    reaper.ImGui_DrawList_AddText(dl, sx + name_w, text_y, theme.fade(category and category.color or T.TEXT_PRIMARY, alpha), count)
    local cx = sx + name_w + count_w + M.BROWSER_PANEL_ACTION_GAP + M.ICON_SM_FS / 2
    local cy = sy + ctrl / 2
    if not icons.paint_glyph(ctx, res.icon_font, "chevron-down", cx, cy, T.TEXT_TERTIARY, M.ICON_SM_FS) then
      local r = M.ICON_SM_FS / 4
      reaper.ImGui_DrawList_AddLine(dl, cx-r, cy-r/2, cx, cy+r/2, theme.fade(T.TEXT_TERTIARY, alpha), theme.scale)
      reaper.ImGui_DrawList_AddLine(dl, cx, cy+r/2, cx+r, cy-r/2, theme.fade(T.TEXT_TERTIARY, alpha), theme.scale)
    end
    tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), name)
    if clicked then reaper.ImGui_OpenPopup(ctx, "library_categories") end
    reaper.ImGui_SetNextWindowPos(ctx, sx, sy + ctrl)
    if reaper.ImGui_BeginPopup(ctx, "library_categories") then
      local counts = state.sidebar_counts
      local all_count = counts and (" (" .. counts.all .. ")") or ""
      local uncat_count = counts and (" (" .. counts.uncat .. ")") or ""
      if reaper.ImGui_Selectable(ctx, "All" .. all_count .. "###all", view.scope == "all") then
        action = action or { type = "select_view", view = { scope = "all" } }
      end
      if reaper.ImGui_Selectable(ctx, "Uncategorised" .. uncat_count .. "###uncategorised", view.scope == "uncategorised") then
        action = action or { type = "select_view", view = { scope = "uncategorised" } }
      end
      for _, entry in ipairs(state.library.categories) do
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), entry.color or T.TEXT_PRIMARY)
        local count = counts and counts.by_id[entry.id]
        local count_label = count and (" (" .. count .. ")") or ""
        local selected = reaper.ImGui_Selectable(ctx, entry.name .. count_label .. "###category_" .. entry.id,
          view_is(state, "category", entry.id))
        reaper.ImGui_PopStyleColor(ctx, 1)
        if selected then
          action = action or { type = "select_view", view = { scope = "category", id = entry.id } }
        end
        -- The same right-click menu as the separate window's sidebar: colour,
        -- rename and delete.
        action = category_menu(ctx, state, entry) or action
      end
      reaper.ImGui_Separator(ctx)
      if reaper.ImGui_MenuItem(ctx, "+ New Category\u{2026}") then
        edit.new_cat, edit.open = "", "add_cat"
      end
      reaper.ImGui_EndPopup(ctx)
    end
    reaper.ImGui_SetCursorPos(ctx, search_x, y)
    if header_button(ctx, res.icon_font, "open_search", "search", icons.draw_search, search_rules.active(edit.query or "")) then
      compact_search.open, compact_search.focus = true, true
      focus.keep_zone(sx, sy, sx + width, sy + ctrl)
    end
    tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), search_rules.active(edit.query or "") and ("Search: " .. edit.query) or "Search")
  end
  if window_buttons then
    action = draw_window_buttons(ctx, res, popout_x, close_x, y) or action
  end
  -- Leave the cursor below the row, whichever control was placed last.
  reaper.ImGui_SetCursorPos(ctx, x - mark_w, y + ctrl + M.ITEM_SPACING_Y)
  -- Open after leaving the category menu so its closing scope cannot dismiss
  -- the name-entry popup. Keep it anchored to the heading in the narrow panel.
  if edit.open == "add_cat" or reaper.ImGui_IsPopupOpen(ctx, "add_cat") then
    reaper.ImGui_SetNextWindowPos(ctx, sx, sy + ctrl)
  end
  local category_action = draw_category_edit_popups(ctx)
  local deleted = draw_category_delete_confirm(ctx)
  return deleted or category_action or action
end

-- Reused every frame (frame-allocation rule).
local joined_slot = { slot = "browse" }
local JOINED_MASTER_OPTS = { id = "browse_master" }

local joined_cell = widgets.segment_cell

-- The Library's audition row, docked or in its own window: play, pause, stop
-- and loop joined; mono, pitch and auto-audition joined; then the volume.
-- Edges come from core/browser_panel_layout.lua so all three stretch with the
-- row. Each control is drawn, then merged.
local function draw_joined_browse_controls(ctx, state, res, compact)
  local font = res.icon_font
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local y1 = y + ctrl
  joined_slot.id, joined_slot.sound = state.browse_id, state.browse

  local action
  local playback_action = transport.draw_playback_group(ctx, state, font, joined_slot,
    x, x + compact.playback_end, y, "browseloop", "Loop: keep the sound repeating until you stop it")

  local x0, x1 = x + compact.listening_x, x + compact.listening_end
  widgets.begin_segment(ctx, x0, y, x1, y1)
  local w = joined_cell(ctx, x0, x1, 3, 0, y)
  -- Mono is one shared preview setting, so this button and the Reference
  -- card's always agree. Availability follows the playing sound, else the
  -- sound this panel would play (the same test the toggle itself applies).
  local sound = state.browse
  local channels = state.preview.playing and (tonumber(state.preview.channels) or 0)
    or (sound and (tonumber(sound.channels) or 0) or 0)
  local available = channels <= 2
  local tip = available
    and "Fold left and right together in both speakers to check mono compatibility."
    or "Mono is available for mono and stereo sounds."
  if widgets.toggle(ctx, "browsemono", "M", state.mono, tips.with_shortcut(state, "mono", tip),
      font, nil, available, "mono", w) then
    action = action or { type = "toggle_mono", target = "browse" }
  end
  w = joined_cell(ctx, x0, x1, 3, 1, y)
  transport.draw_pitch(ctx, state, font, "browse", w)
  w = joined_cell(ctx, x0, x1, 3, 2, y)
  if widgets.toggle(ctx, "auto", "A", state.auto_audition,
      "Auto-audition: play a sound the moment you click it in this browser",
      font, "ear", nil, "audition", w) then
    action = action or { type = "toggle_auto" }
  end
  widgets.end_segment(ctx, x0, y, x1, y1, 3)

  reaper.ImGui_SetCursorScreenPos(ctx, x + compact.volume_x, y)
  JOINED_MASTER_OPTS.width = compact.volume_width
  local master_action = transport.draw_master(ctx, state, JOINED_MASTER_OPTS)
  return playback_action or action or master_action
end

--------------------------------------------------------------- sound picker

-- A docked Library too short for its list shows the sounds as a picker, the
-- same control as the Reference card's: the browsed name opens the full list,
-- ‹ › step through it, and the name pulls out to the timeline like a row.
local picker = {
  open_request = false, rows = 0,
  anchor = { left = 0, top = 0, right = 0, bottom = 0 },
  search = { open = false, focus = false },
  -- The browsed sound's place in the visible list, looked up once per change.
  index_id = nil, index_list = nil, index = nil,
}
local PICKER_POPUP = "library_picker"

local function picker_index(state)
  local list = state.visible_sounds
  if picker.index_id ~= state.browse_id or picker.index_list ~= list then
    picker.index_id, picker.index_list, picker.index = state.browse_id, list, nil
    for i, s in ipairs(list) do
      if s.id == state.browse_id then picker.index = i; break end
    end
  end
  return picker.index
end

-- How far the browsed sound has played, 0..1, or nil when it is not playing or
-- paused in the Library. The same ownership test the waveform uses.
local function browse_progress(state)
  local id, preview = state.browse_id, state.preview
  local pos, len
  if preview.playing and preview.slot == "browse" and preview.sound_id == id then
    pos, len = preview.position, preview.length
  else
    local parked = preview.paused and preview.paused.browse
    if parked and parked.sound_id == id then pos, len = parked.at, parked.length end
  end
  if not pos or not len or len <= 0 then return nil end
  return math.max(0, math.min(1, pos / len))
end

-- The picker row at screen (x, y), `width` wide. `progress` draws the playback
-- line along the name box's bottom edge, and shows a standing message in the
-- empty name box, for forms without a waveform.
local function draw_sound_picker(ctx, state, res, x, y, width, arrows_w, progress)
  local action
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local pad_x = select(1, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding()))
  local gap = M.ITEM_SPACING_X
  local total = #state.visible_sounds
  local index = picker_index(state)
  -- Rebuilt only when the position or total changes (frame-allocation rule).
  if picker.count_index ~= index or picker.count_total ~= total then
    picker.count_index, picker.count_total = index, total
    picker.count = total > 0 and ((index and tostring(index) or "\u{2013}") .. "/" .. total) or nil
  end
  local count = picker.count
  -- Reserved at its widest, so a growing count never moves the arrows.
  local count_w = widgets.count_width(ctx, total)
  -- The arrows follow the name box; the count is centred in the space after
  -- them, which fits the widest count, so its room either side stays even.
  local count_space = count_w > 0 and count_w + 2 * gap or 0
  local arrows_x = x + width - count_space - arrows_w
  local slot_w = math.max(1, arrows_x - gap - x)

  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  local open = picker.open_request or reaper.ImGui_IsPopupOpen(ctx, PICKER_POPUP)
  local clicked = widgets.panel_button_frame(ctx, "##library_picker_slot", slot_w, ctrl, open)
  local held = reaper.ImGui_IsItemActive(ctx)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
  picker.anchor.left, picker.anchor.top, picker.anchor.right, picker.anchor.bottom = x0, y0, x1, y1

  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local sound = state.browse
  local message = progress and not sound and state.drag and state.drag.hint
  local text = sound and sound.name or message
    or (#state.library.sounds == 0 and "No sounds yet" or "Choose a sound")
  local chev_w = ctrl * 0.6
  local text_x = x0 + pad_x
  local shown = widgets.ellipsize(ctx, text, x1 - pad_x - chev_w - text_x)
  local th = select(2, reaper.ImGui_CalcTextSize(ctx, shown))
  reaper.ImGui_DrawList_AddText(dl, math.floor(text_x), math.floor((y0 + y1 - th) * 0.5),
    sound and T.TEXT_PRIMARY or T.TEXT_QUATERNARY, shown)
  local cx, cy = x1 - pad_x - chev_w * 0.5, (y0 + y1) * 0.5
  if not icons.paint_glyph(ctx, res.icon_font, "chevron-down", cx, cy,
      open and T.ACCENT_HOVER or T.TEXT_SECONDARY) then
    local cw, ch = reaper.ImGui_CalcTextSize(ctx, "\u{25BE}")
    reaper.ImGui_DrawList_AddText(dl, cx - cw * 0.5, cy - ch * 0.5, T.TEXT_SECONDARY, "\u{25BE}")
  end
  if progress then
    local frac = browse_progress(state)
    if frac then
      local line_y = y1 - theme.scale * 1.5
      reaper.ImGui_DrawList_AddLine(dl, x0 + 3 * theme.scale, line_y,
        x0 + 3 * theme.scale + (x1 - x0 - 6 * theme.scale) * frac, line_y,
        T.ACCENT, 2 * theme.scale)
    end
  end

  -- Pulling the name out drags the browsed sound, like pulling out its row.
  if state.deps.drag_out and state.browse_id and not state.drag
      and held and reaper.ImGui_IsMouseDragging(ctx, 0) then
    action = { type = "drag_sound", id = state.browse_id, target = "browse",
      ids = selection.sound_targets(state.visible_sounds, state.browse_ids, state.browse_id) }
    picker.dragged = true
  end
  if clicked and not picker.dragged then
    picker.open_request = true
  end
  if not held then picker.dragged = false end
  if hovered and message then
    tips.show(ctx, true, message, nil, picker.anchor)
  elseif hovered and sound then
    local cached = heading_cache(ctx, state)
    local tip = cached and cached.tip or sound.name
    if state.deps.drag_out then tip = tip .. "\n\nDrag to the Reaper timeline to add it." end
    tips.show(ctx, true, tip, nil, picker.anchor)
  end

  if count then widgets.draw_count(ctx, count, arrows_x + arrows_w, y, count_space) end

  -- Previous and next step the list as Up and Down do.
  local delta = widgets.step_arrows(ctx, res.icon_font, "library", arrows_x, y, arrows_w, total > 1,
    "Previous sound", "Next sound")
  if delta then action = action or step_list(state, delta) end
  return action
end

-- The picker's list: the category row and search, then the full sound list.
-- It opens above the picker, past the docker if it needs to, and keeps its
-- size while it is open so filtering never makes it jump.
local function draw_picker_popup(ctx, state, res)
  local action
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local gap_y = M.ITEM_SPACING_Y
  local cellpad_y = select(2, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_CellPadding()))
  local row_h = reaper.ImGui_GetTextLineHeight(ctx) + cellpad_y * 2
  if picker.open_request then
    picker.open_request = false
    picker.rows = math.max(M.BROWSER_LIST_MIN_ROWS + 2,
      math.min(#state.visible_sounds, M.BROWSER_PICKER_LIST_ROWS))
    picker.search.open, picker.search.focus = false, false
    reaper.ImGui_OpenPopup(ctx, PICKER_POPUP)
  end
  if reaper.ImGui_IsPopupOpen(ctx, PICKER_POPUP) then
    local a = picker.anchor
    local width = math.max(a.right - a.left, M.BROWSER_PICKER_LIST_W)
    local height = M.WINDOW_PAD * 2 + ctrl + gap_y + row_h * (picker.rows + 1) + theme.scale * 2
    local geometry = anchored_panel.place(ctx, res, a, {
      width = width, height = height, min_height = M.WINDOW_PAD * 2 + ctrl + gap_y + row_h * 3,
      gap = M.PICK_ANCHOR_GAP, margin = M.PICK_SCREEN_MARGIN, prefer_above = true,
    })
    reaper.ImGui_SetNextWindowPos(ctx, geometry.x, geometry.y)
    reaper.ImGui_SetNextWindowSize(ctx, geometry.w, geometry.h)
  end
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), M.WINDOW_PAD, M.WINDOW_PAD)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(), T.BG_WINDOW)
  local opened = reaper.ImGui_BeginPopup(ctx, PICKER_POPUP,
    reaper.ImGui_WindowFlags_NoMove() | reaper.ImGui_WindowFlags_NoScrollbar()
      | reaper.ImGui_WindowFlags_NoScrollWithMouse())
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_PopStyleVar(ctx, 1)
  if not opened then
    picker.search.open, picker.search.focus = false, false
    return nil
  end
  -- Names line up with the category text, as in the docked list.
  local text_left = reaper.ImGui_GetCursorScreenPos(ctx)
  local searching = picker.search.open
  action = draw_compact_toolbar(ctx, state, res, picker.search, false)
  -- The page's arrow keys stop while a popup is open; this list takes them,
  -- as the page does: Up and Down step, Left restarts the browsed sound and
  -- Right jumps to its end (not while a field has the text cursor). A menu
  -- opened from the list keeps them. Escape closes the list unless it was
  -- closing the search field.
  if HAS_ARROW_NAV and not state.drag
      and reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_ChildWindows())
      and not reaper.ImGui_IsPopupOpen(ctx, "", reaper.ImGui_PopupFlags_AnyPopupId()) then
    if not searching and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
      reaper.ImGui_CloseCurrentPopup(ctx)
    elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_DownArrow()) then
      action = action or step_list(state, 1)
    elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_UpArrow()) then
      action = action or step_list(state, -1)
    elseif state.browse and not reaper.ImGui_IsAnyItemActive(ctx) then
      if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_LeftArrow()) then
        action = action or { type = "seek", fraction = 0, target = "browse" }
      elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_RightArrow()) then
        action = action or { type = "seek", fraction = 1, target = "browse" }
      end
    end
  end
  local list_w, list_h = reaper.ImGui_GetContentRegionAvail(ctx)
  local compact = panel_layout.geometry(list_w, ctrl, M)
  local no_scroll = reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0)
  local list_open = reaper.ImGui_BeginChild(ctx, "picker_listarea", list_w, list_h, 0, no_scroll)
  reaper.ImGui_PopStyleColor(ctx)
  if list_open then
    -- The list keeps the docked list's Ctrl+A and Delete.
    local shortcut_action = pane_shortcut(ctx, state, "list", true)
    local list_action = draw_sound_list(ctx, state, res, text_left, compact)
    action = list_action or action or shortcut_action
    reaper.ImGui_EndChild(ctx)
  end
  -- Get out of the way of a drag: it lands somewhere this list is covering.
  if action and action.type == "drag_sound" then reaper.ImGui_CloseCurrentPopup(ctx) end
  reaper.ImGui_EndPopup(ctx)
  return action
end

-- One cached message keeps idle painting cheap while the table is scrolling.
local idle_text_cache
-- Wraps the message onto as many lines as `max_lines` allows. Only when even
-- that is not enough does the last line end in an ellipsis; `cut` then tells
-- the caller to offer the whole message on hover.
local function idle_lines(ctx, message, width, max_lines)
  local size = reaper.ImGui_GetFontSize(ctx)
  local cached = idle_text_cache
  if cached and cached.ctx == ctx and cached.message == message and cached.width == width
      and cached.size == size and cached.max_lines == max_lines then
    return cached.lines, cached.cut
  end
  local words, line = {}, ""
  for word in message:gmatch("%S+") do
    local candidate = line == "" and word or line .. " " .. word
    if line ~= "" and reaper.ImGui_CalcTextSize(ctx, candidate) > width then
      words[#words + 1], line = line, word
    else
      line = candidate
    end
  end
  words[#words + 1] = line
  local cut = #words > max_lines
  if cut then
    -- The last line that fits carries the rest, so the ellipsis marks the cut.
    words[max_lines] = table.concat(words, " ", max_lines)
    for i = #words, max_lines + 1, -1 do words[i] = nil end
  end
  local lines = {}
  for i, value in ipairs(words) do
    local text = widgets.ellipsize(ctx, value, width)
    if text ~= value then cut = true end
    lines[i] = { text = text, width = reaper.ImGui_CalcTextSize(ctx, text) }
  end
  idle_text_cache = { ctx = ctx, message = message, width = width, size = size,
    max_lines = max_lines, lines = lines, cut = cut }
  return lines, cut
end

-- Progress and the idle message over the preview's waveform (sx0, sy0 to sx1,
-- sy1). The idle message is the drag hint while one is in flight, else the
-- how-to line. Progress shares the waveform with the drag hint but replaces
-- the how-to line, and so does a status card with a button, which is taller
-- than the middle allows. With `area_y0` the preview above the waveform is
-- blank too, and the message is centred over all of it. Painted without
-- moving controls.
local function draw_idle_face(ctx, state, sx0, sy0, sx1, sy1, area_y0, card_button)
  local show_progress = analysis_panel.is_visible(state, "browse", dropzone.file_drag_active())
  local idle_message = not state.browse and state.drag and state.drag.hint
  if show_progress then
    -- Import summaries and errors remain below progress in the empty strip.
    local bottom = idle_message and sy1 - M.GROUP_FS - M.ANALYSIS_CARD_GAP * 2 or sy1
    analysis_panel.draw(ctx, state.analysis_progress, sx0, sy0, sx1, bottom)
  end
  if state.browse or ((show_progress or card_button) and not idle_message) then return end
  local hint = #state.library.sounds == 0 and EMPTY_HINT or IDLE_HINT
  local msg = idle_message or hint
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local col = state.drag and T.TEXT_PRIMARY or T.TEXT_TERTIARY
  local small = theme.push_small_font(ctx)
  local text_w = math.max(0, sx1 - sx0 - M.WINDOW_PAD * 2)
  if area_y0 and not show_progress then
    -- Never let a line run past the blank area.
    local line_h = reaper.ImGui_GetTextLineHeight(ctx)
    local max_lines = math.max(1, math.floor((sy1 - area_y0 - 2 * M.FRAME_PAD_Y) / line_h))
    local lines, cut = idle_lines(ctx, msg, text_w, max_lines)
    local top = (area_y0 + sy1 - #lines * line_h) * 0.5
    for i, line in ipairs(lines) do
      reaper.ImGui_DrawList_AddText(dl,
        math.floor((sx0 + sx1 - line.width) * 0.5), math.floor(top + (i - 1) * line_h),
        col, line.text)
    end
    if cut then
      tips.show(ctx, reaper.ImGui_IsMouseHoveringRect(ctx, sx0, area_y0, sx1, sy1), msg, nil,
        tips.rect(sx0, area_y0, sx1 - sx0, sy1 - area_y0))
    end
  else
    local shown = widgets.ellipsize(ctx, msg, text_w)
    local tw, th = reaper.ImGui_CalcTextSize(ctx, shown)
    local ty = show_progress and sy1 - th - M.ANALYSIS_CARD_GAP or (sy0 + sy1 - th) * 0.5
    reaper.ImGui_DrawList_AddText(dl, math.floor(sx0 + (sx1 - sx0 - tw) * 0.5), math.floor(ty), col, shown)
  end
  if small then reaper.ImGui_PopFont(ctx) end
end

-- The selected sound's details on one line in the small font: the longest
-- run of whole facts that fits `w`.
local function draw_picker_facts(ctx, state, x, y, w)
  local cached = heading_cache(ctx, state)
  if not cached then return end
  local small = theme.push_small_font(ctx)
  local text
  for i = #cached.texts, 1, -1 do
    if reaper.ImGui_CalcTextSize(ctx, cached.texts[i]) <= w then text = cached.texts[i]; break end
  end
  if text then
    local th = select(2, reaper.ImGui_CalcTextSize(ctx, text))
    reaper.ImGui_DrawList_AddText(reaper.ImGui_GetWindowDrawList(ctx), x,
      math.floor(y + (M.STRIP_FACTS_H - th) * 0.5 + 0.5), T.TEXT_SECONDARY, text)
  end
  if small then reaper.ImGui_PopFont(ctx) end
end

-- The docked Library below its list's height. It mirrors the Reference card
-- beside it row for row (opts.plan, from core/card_plan.lua): the picker row,
-- the details when they fit, the selected sound's readings, the waveform with
-- its ruler, and the audition row. Its readings may fit fewer rows than the
-- card's; the waveform then takes their height, so both waveforms end level.
-- The category row and search live in the picker's list.
local function draw_picker_main(ctx, state, res, opts)
  local plan = opts.plan
  local text_left, frame_top = reaper.ImGui_GetCursorScreenPos(ctx)
  local x = text_left
  local width = reaper.ImGui_GetContentRegionAvail(ctx)
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local gap = M.STRIP_FACTS_GAP
  local frame_x, frame_w = x - M.WINDOW_PAD, width + M.WINDOW_PAD * 2
  local frame_bottom = frame_top + plan.height
  local compact = panel_layout.geometry(width, ctrl, M, opts.cell_w)
  local action

  -- The picker row, then the window buttons, which the list form keeps on its
  -- category row.
  local y = math.floor(frame_top + plan.pad + 0.5)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  local wx, wy = reaper.ImGui_GetCursorPos(ctx)
  local step = ctrl + M.BROWSER_PANEL_ACTION_GAP
  local close_x = wx + width - ctrl
  action = draw_window_buttons(ctx, res, close_x - step, close_x, wy)
  local mark_w = draw_library_mark(ctx, res, x, y, ctrl)
  local picker_action = draw_sound_picker(ctx, state, res, x + mark_w, y, width - 2 * step - mark_w,
    2 * ctrl, plan.wave == 0)
  action = action or picker_action
  y = y + ctrl

  local controls_y = math.floor(frame_bottom - plan.pad - ctrl + 0.5)
  local wave_action, wave_id, wave_cols
  if plan.wave > 0 then
    -- With nothing selected the details and readings keep their space blank
    -- and the idle message is centred over it and the waveform.
    local blank_y0 = not state.browse and y or nil
    if plan.facts then
      draw_picker_facts(ctx, state, x, y + gap, width)
      y = y + gap + M.STRIP_FACTS_H
    end
    local rows = opts.readings or 0
    if rows > 0 and state.browse then
      local readings_action = readings.draw_section(ctx, state, state.browse, frame_x, frame_x + frame_w,
        y + gap, x, width, rows, "##library_reading_extra")
      action = action or readings_action
    end
    y = y + readings.section_height(rows)
    local bars = plan.wave + readings.section_height(plan.readings) - readings.section_height(rows)
      - M.RULER_H
    reaper.ImGui_SetCursorScreenPos(ctx, x, y + gap)
    local sx0, sy0, sx1, sy1
    wave_action, wave_id, wave_cols, sx0, sy0, sx1, sy1 = waveform.draw(ctx, state, math.max(1, bars),
      { id = state.browse_id, waveform = state.browse_waveform, detail = state.browse_detail,
        slot = "browse", empty_baseline = state.browse ~= nil, ruler = true,
        min_lane_h = M.BROWSER_PICKER_LANE_MIN_H,
        duration = state.browse and state.browse.duration or nil })
    if wave_action then wave_action.target = "browse" end
    action = action or wave_action
    if sx0 then draw_idle_face(ctx, state, sx0, sy0, sx1, sy1, blank_y0) end
  elseif plan.facts then
    -- Centred between the two rows, as on the card.
    draw_picker_facts(ctx, state, x, math.floor((y + controls_y - M.STRIP_FACTS_H) * 0.5 + 0.5), width)
  end

  -- One outline around everything, the audition row included, like the card.
  widgets.card_outline(ctx, frame_x, frame_top, frame_x + frame_w, frame_bottom)

  -- Audio files dropped anywhere above the audition row add to the viewed
  -- category.
  local cat = view_target(state.library, state.view)
  local dest = categories.get(state.library, cat)
  local drop_top, drop_bottom = frame_top, controls_y - gap
  local drop_action = dropzone.file_drop_over_rect(ctx, state, frame_x, drop_top,
    frame_x + frame_w, drop_bottom,
    { category = cat, label = "Add to " .. (dest and dest.name or "your Library") })
  action = action or drop_action

  reaper.ImGui_SetCursorScreenPos(ctx, x, controls_y)
  local controls_action = draw_joined_browse_controls(ctx, state, res, compact)
  local popup_action = draw_picker_popup(ctx, state, res)
  -- A drop that consumed the release keeps precedence (see merge_action).
  if action and action.wins_release then return action, wave_id, wave_cols end
  return popup_action or action or controls_action, wave_id, wave_cols
end

-- The readings under the preview's name: how they are drawn and the block's
-- height, hairline and gaps included. The docked Library shows the rows the
-- host chose; the separate window uses two wide rows, or three narrow ones
-- when it is too narrow for those. Reused every frame.
local preview_readings = {}
local function measure_preview_readings(ctx, embedded, opts, width)
  local r = preview_readings
  r.kind, r.rows, r.height = nil, 0, 0
  if embedded then
    r.rows = opts and opts.readings or 0
    if r.rows > 0 then r.kind, r.height = "block", readings.section_height(r.rows) end
    return r
  end
  local s = readings.measure(ctx)
  if width >= s.wide_w then
    -- Two rows at the three-row form's row height.
    r.kind, r.height = "wide", readings.section_height(3) - M.STRIP_READING_H
  elseif width >= s.two_w then
    r.kind, r.rows, r.height = "block", 3, readings.section_height(3)
  end
  return r
end

-- Draws the readings measured above, with the cursor one gap below the name
-- row: a hairline from `line_x0` to `line_x1`, a gap, the rows and a gap.
-- Leaves the cursor where the waveform starts and returns the one-row form's
-- action. With nothing selected the block keeps its space but stays blank.
local function draw_preview_readings(ctx, state, r, line_x0, line_x1)
  if not r.kind then return nil end
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local action
  if r.kind == "wide" and state.browse then
    local stroke = theme.scale
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    reaper.ImGui_DrawList_AddLine(dl, line_x0, y + stroke * 0.5, line_x1, y + stroke * 0.5,
      T.STROKE_SECONDARY, stroke)
    readings.draw_wide_rows(ctx, dl, state.browse, x, y + stroke + M.STRIP_FACTS_GAP,
      select(1, reaper.ImGui_GetContentRegionAvail(ctx)), M.STRIP_READING_H)
  elseif state.browse then
    -- The cursor already sits one gap below the name row.
    action = readings.draw_section(ctx, state, state.browse, line_x0, line_x1, y, x,
      select(1, reaper.ImGui_GetContentRegionAvail(ctx)), r.rows, "##library_reading_extra")
  end
  reaper.ImGui_SetCursorScreenPos(ctx, x, y + r.height)
  return action
end

-- form: the docked Library's form for its height (core/browser_panel_layout.lua);
-- nil in the separate window.
-- bottom_pad: the docked Library's space below its audition row, inside the
-- outline.
-- opts: the docked Library's options from ui/library_host.lua (its card plan
-- and readings); nil in the separate window.
local function draw_main(ctx, state, res, embedded, form, bottom_pad, opts)
  bottom_pad = embedded and (bottom_pad or M.STRIP_PAD) or 0
  if form == "picker" then
    return draw_picker_main(ctx, state, res, opts)
  end
  -- Grown back past the picker forms: close a list left open, or it would
  -- linger unseen and keep the arrow keys from the sound list.
  if embedded and reaper.ImGui_IsPopupOpen(ctx, PICKER_POPUP) then
    -- Invisible for the one frame it takes to close.
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), 0)
    local open = reaper.ImGui_BeginPopup(ctx, PICKER_POPUP)
    reaper.ImGui_PopStyleVar(ctx)
    if open then
      reaper.ImGui_CloseCurrentPopup(ctx)
      reaper.ImGui_EndPopup(ctx)
    end
  end
  local text_left = select(1, reaper.ImGui_GetCursorScreenPos(ctx))
  local action
  local ruler = true
  local ruler_h = M.RULER_H
  -- The docked Library's outline holds the category row, the list and the
  -- preview, like the strip's card. The category row sits at the card's
  -- first-row inset.
  local frame_top
  if embedded then
    local hx
    hx, frame_top = reaper.ImGui_GetCursorScreenPos(ctx)
    reaper.ImGui_SetCursorScreenPos(ctx, hx, frame_top + M.STRIP_PAD)
  end
  if embedded then action = draw_compact_toolbar(ctx, state, res, compact_search, true)
  else action = draw_toolbar(ctx, state, res) end
  local compact = embedded and panel_layout.geometry(
    select(1, reaper.ImGui_GetContentRegionAvail(ctx)), reaper.ImGui_GetFrameHeight(ctx), M,
    opts and opts.cell_w)

  -- Height budget: the strip and the info row are anchored to the bottom, the
  -- table takes everything in between (the 2026-07-29 arrangement — results on
  -- top, preview at the bottom, mirroring the Reference View's waveform-then-
  -- controls order).
  local gap_y = select(2, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))
  local info_h = reaper.ImGui_GetFrameHeight(ctx)
  local heading_h = info_h
  -- The name row, the readings under it and the gap before the waveform.
  local preview = measure_preview_readings(ctx, embedded, opts,
    select(1, reaper.ImGui_GetContentRegionAvail(ctx)))
  local name_block = heading_h + gap_y + preview.height
  local avail_h = select(2, reaper.ImGui_GetContentRegionAvail(ctx)) - bottom_pad

  -- The strip's height (drag-resizable since 2026-08-06): the in-flight drag
  -- value while the seam is held, else the remembered preference, else the
  -- default. Clamped EVERY frame, display only — never below the floor, and
  -- never so tall the table above loses its header plus a couple of sound
  -- rows, measured from the live row metrics so the ceiling follows the
  -- window (a bigger window allows a bigger strip). The stored preference is
  -- left alone by the clamp: squeezing the window only compresses the strip
  -- for as long as the window stays small.
  local cellpad_y = select(2, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_CellPadding()))
  local row_block = reaper.ImGui_GetTextLineHeight(ctx) + cellpad_y * 2
  local frame_stroke = embedded and theme.scale or 0
  local frame_bottom_pad = embedded and M.FRAME_PAD_Y or 0
  local min_list_h = row_block * (M.BROWSER_LIST_MIN_ROWS + 1) + frame_stroke
  -- The separate window's floor leaves no room for the readings: they fold
  -- away before the list, the waveform or the controls lose their minimums.
  -- (The docked Library's host already chose rows that fit.)
  if not embedded and preview.kind and avail_h - min_list_h - gap_y - M.BROWSER_WAVE_MIN_H
      - ruler_h - name_block - (info_h + gap_y) < 0 then
    preview.kind, preview.rows, preview.height = nil, 0, 0
    name_block = heading_h + gap_y
  end
  local wave_max = avail_h - min_list_h - gap_y - ruler_h - frame_bottom_pad
    - name_block - (info_h + gap_y)
  -- Stored custom heights are 100%-scale authoring values. This makes a
  -- remembered strip grow with the rest of the Library instead of becoming a
  -- smaller-looking slot around larger labels and controls.
  local remembered_wave_h = state.browser_wave_h and state.browser_wave_h * theme.scale
  local wave_h = split.live or remembered_wave_h
    or (embedded and M.BROWSER_PANEL_WAVE_H or M.BROWSER_WAVE_H)
  if wave_h > wave_max then wave_h = wave_max end
  if wave_h < M.BROWSER_WAVE_MIN_H then wave_h = M.BROWSER_WAVE_MIN_H end

  local list_h = avail_h - (wave_h + ruler_h + frame_bottom_pad + gap_y)
    - name_block - (info_h + gap_y)
  if list_h < min_list_h then list_h = min_list_h end

  -- Wrap the list in a child so the whole area is one reliable drop target (a bare
  -- table isn't dependable across ReaImGui versions, and dropping into an empty view
  -- is normal). The wrapper must NOT scroll itself — the table inside owns ScrollY,
  -- and two scroll owners at an exact-fit height fight for the boundary and make
  -- the list flicker frame-to-frame.
  local no_scroll = reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
  -- EndChild only inside the `if`: ReaImGui's contract (see app.lua) — a fully
  -- clipped child (window squashed to zero width) returns false WITHOUT opening,
  -- and an unmatched EndChild is a hard assertion that kills the script.
  -- Keep the framed list inside its border. Its bottom stays fixed so the
  -- waveform and transport retain their shared height budget.
  local list_x = reaper.ImGui_GetCursorPosX(ctx)
  local panel_pad = M.WINDOW_PAD
  local list_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx)) + panel_pad * 2
  local frame_x, frame_y = reaper.ImGui_GetCursorScreenPos(ctx)
  frame_x = frame_x - panel_pad
  reaper.ImGui_SetCursorScreenPos(ctx, frame_x + frame_stroke, frame_y + frame_stroke)
  if embedded then reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0) end
  local list_open = reaper.ImGui_BeginChild(ctx, "listarea",
    list_w - frame_stroke * 2, list_h - frame_stroke, 0, no_scroll)
  if embedded then reaper.ImGui_PopStyleColor(ctx) end
  if list_open then
    local shortcut_action = pane_shortcut(ctx, state, "list")
    -- Always draw the list (never short-circuit it behind `action or ...`, which
    -- would blank the list for a frame whenever the search box set an action).
    local list_action = draw_sound_list(ctx, state, res, text_left, compact)
    action = action or list_action or shortcut_action
    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_SetCursorPosX(ctx, list_x)
  -- The main panel's drop target spans the list AND the audition strip below
  -- it (2026-08-01, user's call) — the list rect is captured here, the one
  -- rect-based target (dropzone.file_drop_over_rect, the same mechanism as the
  -- Reference View) is submitted after the strip is drawn, once the combined
  -- rect is known. Guarded by list_open so a clipped-away child can't leave a
  -- stale rect.
  local list_rect
  if list_open then
    local lx0, ly0 = reaper.ImGui_GetItemRectMin(ctx)
    local lx1, ly1 = reaper.ImGui_GetItemRectMax(ctx)
    -- The list is a browsing pane: a click inside it keeps OS focus so the
    -- arrow keys can step the rows afterwards (ui/focus.lua).
    focus.keep_zone(lx0, ly0, lx1, ly1)
    list_rect = { x0 = lx0, y0 = ly0 }
  end

  -- Docked, a permanent hairline closes the list across the outline, in the
  -- gap below it.
  if list_open and embedded then
    local line_y = select(2, reaper.ImGui_GetCursorScreenPos(ctx)) - gap_y * 0.5
    reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(ctx),
      frame_x + frame_stroke, line_y, frame_x + list_w - frame_stroke, line_y,
      T.STROKE_SECONDARY, frame_stroke)
  end

  -- The preview: the same waveform widget as the Reference card (seek,
  -- playhead, loop, ruler), at the user's browsing height. It draws the
  -- Library's own selection (state.browse_id/browse_waveform), never the armed
  -- reference, and has no latch, so browsing can never mute the master. The
  -- returned seek is tagged target="browse" so the entry script acts on the
  -- browsed sound. No `trim_db`: a browse audition plays at no trim, so the
  -- waveform shows the sound as recorded. The ruler adds RULER_H below the bars
  -- and the list above pays for it. Its own cache slot ("browse") keeps the two
  -- views from thrashing one entry.
  -- Top of the preview section (name, waveform, ruler). With nothing selected
  -- in the docked Library, none of those has anything to show, so the section
  -- is left blank and the idle message is centred over all of it.
  local section_y0 = select(2, reaper.ImGui_GetCursorScreenPos(ctx))
  local blank_section = embedded and not state.browse
  draw_preview_heading(ctx, state, heading_h)
  do
    -- Docked, the hairline spans the outline like the list's closing line; in the
    -- separate window it spans the content.
    local line_x0, line_x1 = frame_x + frame_stroke, frame_x + list_w - frame_stroke
    if not embedded then line_x0, line_x1 = frame_x + panel_pad, frame_x + list_w - panel_pad end
    local readings_action = draw_preview_readings(ctx, state, preview, line_x0, line_x1)
    action = action or readings_action
  end
  -- The gap above the waveform is its resize handle: an InvisibleButton laid
  -- over the gap, submitted out of flow (the cursor is put back afterwards) so
  -- the layout the budget above counted on doesn't move by a pixel. Dragging
  -- it moves the waveform's top edge (up = taller, the list pays); the result
  -- is committed on release and remembered like the sidebar width.
  -- Right-click or double-click snaps back to the default height, the reset
  -- every fader answers to (widgets.wants_reset). The gap is the readings'
  -- bottom gap, or the item spacing under the name row without readings.
  local seam_h = preview.kind and M.STRIP_FACTS_GAP or gap_y
  do
    local seam_x, seam_y = reaper.ImGui_GetCursorScreenPos(ctx)
    local seam_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
    if seam_w >= 1 then
      reaper.ImGui_SetCursorScreenPos(ctx, seam_x, seam_y - seam_h)
      reaper.ImGui_InvisibleButton(ctx, "##strip_seam", seam_w, seam_h)
      local hovered = reaper.ImGui_IsItemHovered(ctx)
      local active = reaper.ImGui_IsItemActive(ctx)
      if hovered or active then
        -- Feature-detected: an older ReaImGui defines no ResizeNS cursor, and
        -- calling it raises mid-drag (Codex, 2026-08-06). No cursor is a
        -- cosmetic loss; a raise kills the script.
        if RESIZE_CURSOR then reaper.ImGui_SetMouseCursor(ctx, RESIZE_CURSOR) end
        -- The affordance: a hairline across the seam, accent while grabbed.
        -- Drawn over the gap, never laid out — nothing shifts.
        reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(ctx),
          seam_x, seam_y - seam_h * 0.5, seam_x + seam_w, seam_y - seam_h * 0.5,
          active and T.ACCENT or T.STROKE_PRIMARY, 1)
      end
      if widgets.wants_reset(ctx) then
        -- No height in the action = "back to whatever the default is", so the
        -- stored slot is cleared rather than frozen at a copy of the default.
        action = action or { type = "set_browser_wave_h" }
        split.hold, split.live, split.start_h = active, nil, nil
      elseif reaper.ImGui_IsItemActivated(ctx) then
        -- Anchor on the CLAMPED on-screen height, not the stored one: a value
        -- saved on a big screen must start dragging from where the eye sees it.
        split.start_h = wave_h
        split.start_my = select(2, reaper.ImGui_GetMousePos(ctx))
        split.hold = false
      elseif active and not split.hold and split.start_h then
        local my = select(2, reaper.ImGui_GetMousePos(ctx))
        local live = split.start_h - (my - split.start_my)
        if live > wave_max then live = wave_max end
        if live < M.BROWSER_WAVE_MIN_H then live = M.BROWSER_WAVE_MIN_H end
        split.live = live
      elseif reaper.ImGui_IsItemDeactivated(ctx) then
        if split.live and not split.hold and split.live ~= split.start_h then
          action = action or { type = "set_browser_wave_h", h = split.live / theme.scale }
        end
        split.start_h, split.start_my, split.live, split.hold = nil, nil, nil, false
      end
      reaper.ImGui_SetCursorScreenPos(ctx, seam_x, seam_y)
    end
  end

  -- The status card sits on the waveform's bottom edge. Its button is submitted
  -- first so a click on its close mark cannot also seek the waveform. Docked,
  -- the Reference View's own card shows the messages instead.
  local card_handle, card_action
  if not embedded then
    local strip_x, strip_y = reaper.ImGui_GetCursorScreenPos(ctx)
    local strip_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
    local strip_bottom = strip_y + wave_h + (ruler and M.RULER_H or 0)
    card_handle, card_action = status_card.prepare(ctx, state, "library",
      strip_x, strip_y, strip_x + strip_w, strip_bottom - M.WINDOW_PAD)
    action = action or card_action
  end
  local wave_action, wave_id, wave_cols, sx0, sy0, sx1, sy1 = waveform.draw(ctx, state, wave_h,
    { id = state.browse_id, waveform = state.browse_waveform, detail = state.browse_detail,
      ruler = ruler, slot = "browse",
      background_painted = blank_section,
      empty_baseline = not embedded or state.browse ~= nil,
      duration = state.browse and state.browse.duration or nil })
  if wave_action then wave_action.target = "browse" end
  action = action or wave_action
  if embedded then
    -- Reserve space below the ruler inside the frame. Submit an item so the
    -- parent accounts for the padding without shifting the transport's baseline.
    reaper.ImGui_SetCursorScreenPos(ctx, sx0, sy1)
    reaper.ImGui_Dummy(ctx, sx1 - sx0, frame_bottom_pad)
    sy1 = sy1 + frame_bottom_pad
    -- Painted in the parent after the children have closed. The inset leaves
    -- the border visible even though child-window drawing sits above the parent.
    widgets.card_outline(ctx, frame_x, frame_top, frame_x + list_w, sy1 + gap_y + info_h + bottom_pad)
  end
  draw_idle_face(ctx, state, sx0, sy0, sx1, sy1, blank_section and section_y0 or nil,
    card_handle and card_handle.button ~= nil)

  status_card.paint(ctx, card_handle, leftover_panel.is_open(ctx))
  if not embedded then
    local leftover_action = leftover_panel.draw(ctx, state, res, card_handle, "library")
    -- Combined, so closing the panel is never lost to another click that frame.
    action = actions.combine(action, leftover_action)
  end

  -- The combined list + audition-strip drop target (see the list_rect capture
  -- above). Falls back to the strip alone when the list child was clipped away.
  -- The target names where a drop will file: the viewed category, or the
  -- library at large when viewing All/Uncategorised.
  do
    local x0 = list_rect and list_rect.x0 or sx0
    local y0 = list_rect and list_rect.y0 or sy0
    local cat = view_target(state.library, state.view)
    local dest = categories.get(state.library, cat)
    local drop_action = dropzone.file_drop_over_rect(ctx, state, x0, y0, sx1, sy1,
      { category = cat,
        label = "Add to " .. (dest and dest.name or "your Library") })
    action = action or drop_action
  end

  if embedded then
    local controls_action = draw_joined_browse_controls(ctx, state, res, compact)
    return action or controls_action, wave_id, wave_cols
  end

  -- The separate window uses the docked Library's audition row, capped so a
  -- wide window keeps its buttons button-shaped, and centred under the waveform.
  local row_x, row_y = reaper.ImGui_GetCursorScreenPos(ctx)
  local row_w, row_offset = panel_layout.capped_row(
    select(1, reaper.ImGui_GetContentRegionAvail(ctx)), M.BROWSER_ROW_MAX_W)
  reaper.ImGui_SetCursorScreenPos(ctx, row_x + row_offset, row_y)
  local controls_action = draw_joined_browse_controls(ctx, state, res,
    panel_layout.geometry(row_w, reaper.ImGui_GetFrameHeight(ctx), M))
  action = action or controls_action

  -- Settings is drawn by ui/app.lua, not here: since 2026-08-08 it is a real
  -- top-level window rather than a modal inside this panel, so closing the
  -- browser must not take it with it. Since 2026-08-10 nothing in this window
  -- touches it at all — the gear lives in the Reference View's bar.

  return action, wave_id, wave_cols
end

--------------------------------------------------------------- draw

-- Merge one panel's action into the frame's. A drop that consumed the mouse
-- release (`wins_release`) must survive to the END of the frame: a later
-- panel's same-frame action may not displace it — two release-consuming drops
-- can't co-fire (one release lands on one target).
local function merge_action(prev, new)
  if prev and prev.wins_release then return prev end
  return new or prev
end

-- Draws the browser's whole content (sidebar + main panel). The window's own
-- Begin/End is owned by ui/app.lua — this only fills what's between them. The
-- window comes with ZERO padding (see app.lua): the sidebar bleeds to the true
-- window edges (the 2026-07-29 review's headline fix — the old 12px padding
-- showed as a lighter frame around it), and each panel pads itself instead.
-- With opts.embedded, the caller supplies WINDOW_PAD horizontally and no vertical padding.
-- opts.form is the docked Library's form for its height (core/browser_panel_layout.lua).
function browser.draw(ctx, state, res, opts)
  local action
  local embedded = opts and opts.embedded == true
  if embedded ~= last_embedded then
    resize_press_in_header = nil
    nav_owner = "list"
    split.start_h, split.start_my, split.live, split.hold = nil, nil, nil, false
    last_embedded = embedded
    compact_search.open, compact_search.focus = false, false
    edit.query = state.query or ""
  end

  -- A reopened window starts arrow-browsing back on the sound list (see
  -- nav_owner above). Frame-count gap = the window wasn't drawn last frame.
  if reaper.ImGui_GetFrameCount ~= nil then
    local frame = reaper.ImGui_GetFrameCount(ctx)
    if last_draw_frame ~= frame - 1 then
      nav_owner = "list"
      resize_press_in_header = nil
      -- The box and the list filter are two copies; Esc can close the window
      -- right after the box reverted, leaving them disagreeing on reopen.
      edit.query = state.query or ""
    end
    last_draw_frame = frame
  end

  -- Arrow-key browsing, read at the top of the draw so this same frame's panes
  -- can scroll-follow the step. Only while this window (or a child of it)
  -- holds focus, no popup is up (an open menu's arrow keys must stay its own),
  -- and no drag is in flight. The search box deliberately does NOT block
  -- stepping: a single-line field ignores Up/Down, so refining a search and
  -- walking its results coexist — the Media Explorer's behaviour.
  if HAS_ARROW_NAV and not state.drag
    and reaper.ImGui_IsWindowFocused(ctx, embedded and reaper.ImGui_FocusedFlags_ChildWindows()
      or reaper.ImGui_FocusedFlags_RootAndChildWindows()) then
    local popup_up = HAS_POPUP_ANY and reaper.ImGui_IsPopupOpen(ctx, "",
      reaper.ImGui_PopupFlags_AnyPopupId() | reaper.ImGui_PopupFlags_AnyPopupLevel())
    if not popup_up then
      -- Left/Right drive the audition itself (2026-08-08, the user's ask —
      -- "standard stuff"): Left restarts the browsed sound, Right jumps to the
      -- end of playback. Same seek action a click on the strip's waveform
      -- reports, so reference-mode refusal and auditioning behave identically.
      -- Skipped while ANY item is active — unlike Up/Down, these two are the
      -- text cursor's own keys in the search box.
      if state.browse and not reaper.ImGui_IsAnyItemActive(ctx) then
        if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_LeftArrow()) then
          action = { type = "seek", fraction = 0, target = "browse" }
        elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_RightArrow()) then
          action = { type = "seek", fraction = 1, target = "browse" }
        end
      end
      local step = 0
      if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_DownArrow()) then step = 1
      elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_UpArrow()) then step = -1 end
      if step ~= 0 then
        -- NOT the `cond and a or b` idiom: a step refused at a list edge
        -- returns nil, which would wrongly fall through to the other pane.
        if nav_owner == "sidebar" then
          action = step_sidebar(state, step)
        else
          action = step_list(state, step)
        end
        -- Precedence, decided (Codex, 2026-08-08 review): a panel action in
        -- the SAME frame replaces this step (merge_action below prefers new).
        -- Deliberate — the collisions that can really happen (a keystroke's
        -- set_query, a header click's set_sort) stay wrong until the next
        -- interaction if dropped, while a dropped arrow press is one missed
        -- step. The step's scroll-follow may then run without its selection
        -- change: one frame of scroll, self-corrected on the next press.
      end
    end
  end

  if embedded then
    local panel_action, wave_id, wave_cols = draw_main(ctx, state, res, true, opts.form or "list",
      opts.bottom_pad, opts)
    nav.list_row, nav.view = nil, nil
    return merge_action(action, panel_action), wave_id, wave_cols
  end

  -- Sidebar: full-bleed chrome. Square corners (it meets the window edges) and
  -- a drag-resizable right edge where the build supports it (ImGui's own ini
  -- remembers the width the user leaves it at). ZERO inner padding since
  -- 2026-08-10 (user-reported: "the category backgrounds start slightly
  -- further in" — the old SB_PAD padding inset every row's fill from the
  -- panel edges): a row's fill now runs the strip's full width and the first
  -- row butts the top edge, the Settings nav's own grammar. The NAME is inset
  -- SB_PAD inside the row instead (group_row), never by padding the panel.
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), T.BG_CHROME)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(), 0)
  local sb_flags = 0
  if HAS_CHILD_RESIZE then sb_flags = reaper.ImGui_ChildFlags_ResizeX() end
  -- The drag has a FLOOR (2026-08-07, user's ask). A child window goes through
  -- the same Begin path as a real one, so the standard size constraint applies
  -- to its resize edge; the ceiling is left effectively open, since a wide
  -- sidebar costs nothing but the list's width, which the user can see.
  -- Guarded like every other optional call: on a build without it the edge just
  -- keeps its old unbounded drag.
  --
  -- This floor is also an INPUT to theme.BROWSER_MIN_W (the browser window's
  -- own width floor, next to MIN_WIN_H in theme.lua): that number assumes the
  -- sidebar can never be narrower than SIDEBAR_MIN_W, so the info row always
  -- gets at least the room BROWSER_MIN_W was sized for. Raising this value
  -- without revisiting that derivation would let the splitter eat into room
  -- the row's floor already promised it.
  if HAS_SIZE_CONSTRAINTS then
    reaper.ImGui_SetNextWindowSizeConstraints(ctx, M.SIDEBAR_MIN_W, 0, 10000, 10000)
  end
  if math.abs(pending_sidebar_scale - 1) >= 0.000001 then
    if sidebar_last_w and HAS_SET_NEXT_SIZE then
      reaper.ImGui_SetNextWindowSize(ctx,
        math.floor(sidebar_last_w * pending_sidebar_scale + 0.5), 0,
        reaper.ImGui_Cond_Always())
    end
    pending_sidebar_scale = 1
  end
  -- Style var popped the instant the child has taken it (a Begin-time read).
  -- Scale is part of the child identity too. On a fresh launch, ImGui can then
  -- restore the width last used at this UI Size rather than applying a raw-pixel
  -- width saved at another size.
  local sidebar_id = "sidebar##s" .. theme.scale_percent(theme.scale)
  local sb_open = reaper.ImGui_BeginChild(ctx, sidebar_id, M.SIDEBAR_W, 0, sb_flags)
  reaper.ImGui_PopStyleVar(ctx, 1)
  if sb_open then
    local shortcut_action = pane_shortcut(ctx, state, "sidebar")
    local sidebar_action = draw_sidebar(ctx, state)
    action = merge_action(action, sidebar_action or shortcut_action)
    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx)

  -- One hairline on the seam (the only separation the two surfaces need), then
  -- the main panel flush against it. The closed sidebar child is the last item,
  -- so its rect is read here.
  local sx1, sy1 = reaper.ImGui_GetItemRectMax(ctx)
  local sx0, sy0 = reaper.ImGui_GetItemRectMin(ctx)
  sidebar_last_w = sx1 - sx0
  -- The sidebar is a browsing pane too: clicks inside keep OS focus so the
  -- arrows can step the side column afterwards (ui/focus.lua).
  if sb_open then
    focus.keep_zone(select(1, reaper.ImGui_GetItemRectMin(ctx)), sy0, sx1, sy1)
  end
  reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(ctx),
    sx1 + 0.5, sy0, sx1 + 0.5, sy1, T.STROKE_TERTIARY, 1)

  reaper.ImGui_SameLine(ctx, 0, 0)

  -- The main panel never scrolls (its list scrolls internally). Forbidding a
  -- scrollbar keeps its content width fixed — a scrollbar toggling on/off would
  -- change the width every frame and jitter the right-aligned toolbar cluster
  -- and fader that are sized from it.
  local main_flags = reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), M.WINDOW_PAD, M.WINDOW_PAD)
  local main_child_flags = HAS_CHILD_PAD and reaper.ImGui_ChildFlags_AlwaysUseWindowPadding() or 0
  local main_open = reaper.ImGui_BeginChild(ctx, "main", 0, 0, main_child_flags, main_flags)
  reaper.ImGui_PopStyleVar(ctx, 1)
  local wave_id, wave_cols
  if main_open then
    local main_action
    main_action, wave_id, wave_cols = draw_main(ctx, state, res)
    action = merge_action(action, main_action)
    reaper.ImGui_EndChild(ctx)
  end

  -- The one-frame scroll-follow requests have been served (or their pane was
  -- clipped away this frame) — never carried across frames.
  nav.list_row, nav.view = nil, nil

  return action, wave_id, wave_cols
end

-- The isolated review script seeds transient inputs and calls the production
-- drawers in one stable scope. As in browser.draw, returned actions are intent
-- only; the caller decides whether to apply them to its sample state.
function browser.draw_gallery(ctx, state, res, spec, opening)
  local kind, ids = spec.kind, spec.ids or {}
  local action
  if opening then
    edit.del, edit.cat_del, edit.open = nil, nil, nil
    if kind == "delete_sound" then
      request_sound_delete(ids, spec.name)
    elseif kind == "delete_category" then
      action = request_category_delete(state, ids)
    elseif kind == "new_category" then
      edit.new_cat, edit.open = spec.name or "", "add_cat"
    elseif kind == "rename_category" then
      edit.rename_id, edit.rename, edit.open = ids[1], spec.name or "", "rename_cat"
    elseif kind == "category_menu" then
      reaper.ImGui_OpenPopup(ctx, "ctx_" .. ids[1])
    elseif kind == "sidebar_menu" then
      reaper.ImGui_OpenPopup(ctx, "sb_ctx")
    elseif kind == "header_menu" then
      menu_col = spec.loud_header and LOUD_COL or 0
      reaper.ImGui_OpenPopup(ctx, "hdr_menu")
    elseif kind == "sound_menu" then
      reaper.ImGui_OpenPopup(ctx, "row_" .. ids[1])
    end
  end
  -- Category menus and entry fields inherit the sidebar's tighter spacing.
  local sidebar_spacing = kind == "category_menu" or kind == "sidebar_menu"
    or kind == "new_category" or kind == "rename_category"
  if sidebar_spacing then
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), M.ITEM_SPACING_X, M.SB_ROW_GAP)
  end
  if kind == "category_menu" then
    local cat = categories.get(state.library, ids[1])
    if cat then action = category_menu(ctx, state, cat) or action end
  elseif kind == "sidebar_menu" then
    sidebar_context(ctx)
  elseif kind == "header_menu" then
    action = draw_header_menu(ctx, state) or action
  elseif kind == "sound_menu" then
    for _, sound in ipairs(state.library.sounds) do
      if sound.id == ids[1] then
        action = sound_menu(ctx, state, sound) or action
        break
      end
    end
  end
  local edited = draw_category_edit_popups(ctx)
  if sidebar_spacing then reaper.ImGui_PopStyleVar(ctx, 1) end
  local category_deleted = draw_category_delete_confirm(ctx)
  local sound_deleted = draw_delete_confirm(ctx)
  return sound_deleted or category_deleted or edited or action
end

return browser
