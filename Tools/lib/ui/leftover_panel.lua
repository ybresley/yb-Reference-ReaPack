-- leftover_panel: the Review Files panel that opens above the notice about
-- audio files in the Library folder that aren't part of the Library. It lists
-- the files, says what each one is when that is known, lets the user hear them,
-- and sends the ticked ones to the Library or the trash folder.
--
-- Draws from `state.leftovers` (kept by the entry script) and returns actions.
-- Which files are ticked is the panel's own business: every file starts ticked
-- each time the panel opens, so one click acts on all of them.
--
-- Columns, left to right: tick box, play button, name, reason, length. The
-- length column is right-aligned at a fixed width so every length lines up.
-- Long names are cut in the middle, because files from one export often differ
-- only at the end (Take_03, Take_04); reasons are cut at the end. A row whose
-- text was cut shows it in full on hover.

local theme = require("ui.theme")
local icons = require("ui.icons")
local tips = require("ui.tips")
local widgets = require("ui.widgets")
local T = theme.tokens
local M = theme.metrics

local panel = {}

local POPUP_ID = "##review_files"
local NOTICE_ACTION = "review_leftovers"
local FOOTER = "Added files go to Uncategorised. yb-Reference can't restore files from the trash yet."
local CHECKING = "Checking files\u{2026}"

local function draw_play(dl, cx, cy, col)
  local r = M.ICON_SM_FS * 0.35
  reaper.ImGui_DrawList_AddTriangleFilled(dl, cx - r * 0.8, cy - r, cx - r * 0.8, cy + r, cx + r, cy, col)
end

local function draw_stop(dl, cx, cy, col)
  local r = M.ICON_SM_FS * 0.3
  reaper.ImGui_DrawList_AddRectFilled(dl, cx - r, cy - r, cx + r, cy + r, col)
end

-- Hoisted so the frame loop only updates them.
local REVEAL = { name = "folder", fallback = icons.draw_folder,
  tip = "Show the library folder and its trash on your computer." }
local PLAY = { tip = "Play this file" }
local STOP = { tip = "Stop" }

local ticks = {}
local requested = false -- Settings asked for the panel; opens above the next notice drawn
local anchors = {}   -- per window: the notice card the panel sits above
local was_open = {}  -- per window: open last frame, so closing can be reported
-- Each entry's shortened texts at the current column widths, rebuilt only when
-- a width or text changes. Weak keys: entries are dropped with the list.
local shown = setmetatable({}, { __mode = "k" })

local function cut(ctx, e, name_w, reason_w)
  local c = shown[e]
  local size = reaper.ImGui_GetFontSize(ctx)
  if c and c.name_w == name_w and c.reason_w == reason_w and c.reason_src == e.reason and c.size == size then
    return c
  end
  c = { name_w = name_w, reason_w = reason_w, reason_src = e.reason, size = size }
  c.name = widgets.ellipsize(ctx, e.name, name_w, "middle")
  c.reason = (reason_w > 0 and e.reason) and widgets.ellipsize(ctx, e.reason, reason_w) or nil
  c.cut = c.name ~= e.name or (e.reason ~= nil and c.reason ~= e.reason)
  c.tip = e.reason and (e.name .. "\n" .. e.reason) or e.name
  shown[e] = c
  return c
end

-- Whether the panel is open in the window being drawn, for the notice button's
-- pressed look.
function panel.is_open(ctx)
  return reaper.ImGui_IsPopupOpen(ctx, POPUP_ID)
end

-- Open the panel as if the notice's button had been pressed, in the first
-- window that shows the notice.
function panel.request() requested = true end

local function names_ticked(entries)
  local out = {}
  for _, e in ipairs(entries) do
    if ticks[e.name] then out[#out + 1] = e.name end
  end
  return out
end

-- Call after the status card is painted, in the same window. `handle` is the
-- card's handle this frame (nil when it isn't showing); `window_id` tells the
-- two windows apart.
function panel.draw(ctx, state, res, handle, window_id)
  local lo = state.leftovers
  local entries = lo and lo.entries
  if not entries or #entries == 0 then requested = false end
  if handle and handle.view.action == NOTICE_ACTION then
    local a = anchors[window_id] or {}
    anchors[window_id] = a
    a.x0, a.y0, a.x1 = handle.x0, handle.y0, handle.x1
    if (handle.pressed or requested) and entries and #entries > 0 then
      requested = false
      reaper.ImGui_OpenPopup(ctx, POPUP_ID)
      ticks = {}
      for _, e in ipairs(entries) do ticks[e.name] = true end
    end
  end
  if not reaper.ImGui_IsPopupOpen(ctx, POPUP_ID) then
    if was_open[window_id] then
      was_open[window_id] = nil
      return { type = "leftovers_closed" }
    end
    return nil
  end

  local a = anchors[window_id]
  if not a or not entries or #entries == 0 then
    -- Nothing left to review (every file was dealt with elsewhere).
    if reaper.ImGui_BeginPopup(ctx, POPUP_ID) then
      reaper.ImGui_CloseCurrentPopup(ctx)
      reaper.ImGui_EndPopup(ctx)
    end
    return nil
  end

  -- Size and place the panel before it begins, so the opening frame fits too.
  local wx, wy = reaper.ImGui_GetWindowPos(ctx)
  local ww = reaper.ImGui_GetWindowSize(ctx)
  local pad = M.WINDOW_PAD
  local width = math.max(1, math.min(M.LEFTOVER_PANEL_W, ww - pad * 2))
  local inner = width - pad * 2
  local row_h = M.LEFTOVER_ROW_H
  local line_h = reaper.ImGui_GetTextLineHeight(ctx)
  local frame_h = reaper.ImGui_GetFrameHeight(ctx)
  local gap = M.ITEM_SPACING_Y
  local thin = math.floor(M.ANALYSIS_CARD_GAP * 0.5)
  local summary = lo.checking and CHECKING or lo.summary
  local note_h = select(2, reaper.ImGui_CalcTextSize(ctx, FOOTER, nil, nil, false, inner))
  local fixed = pad * 2 + row_h + (summary and (line_h + thin * 2) or 0) + (1 + thin * 2)
    + gap + note_h + gap + frame_h
  local bottom = a.y0 - M.ANALYSIS_CARD_GAP
  local top = wy + frame_h + pad
  local fit = math.floor((bottom - top - fixed) / row_h)
  local rows = math.min(#entries, math.max(M.LEFTOVER_MIN_ROWS, fit))
  local list_h = rows * row_h
  local height = fixed + list_h
  local x = (a.x0 + a.x1) * 0.5 - width * 0.5
  x = math.max(wx + pad, math.min(x, wx + ww - pad - width))
  reaper.ImGui_SetNextWindowPos(ctx, math.floor(x), math.floor(bottom - height), reaper.ImGui_Cond_Always())
  reaper.ImGui_SetNextWindowSize(ctx, width, height, reaper.ImGui_Cond_Always())
  local flags = reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
  if not reaper.ImGui_BeginPopup(ctx, POPUP_ID, flags) then
    was_open[window_id] = nil
    return { type = "leftovers_closed" }
  end
  was_open[window_id] = true

  local action
  local font = res and res.icon_font
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  local sx = M.ITEM_SPACING_X
  local play = M.LEFTOVER_PLAY
  -- With no frame padding a tick box is exactly the font size.
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 0, 0)
  local tick = reaper.ImGui_GetFrameHeight(ctx)
  local name_x = tick + sx + play + sx
  local text_dy = math.floor((row_h - line_h) * 0.5)

  -- Heading: tick or untick everything, what the list is, the folder.
  local all = true
  for _, e in ipairs(entries) do
    if not ticks[e.name] then all = false; break end
  end
  reaper.ImGui_SetCursorScreenPos(ctx, x0, y0 + math.floor((row_h - tick) * 0.5))
  local changed, value = reaper.ImGui_Checkbox(ctx, "##all", all)
  if changed then
    for _, e in ipairs(entries) do ticks[e.name] = value end
  end
  reaper.ImGui_DrawList_AddText(dl, x0 + tick + sx, y0 + text_dy, T.TEXT_PRIMARY, lo.heading)
  reaper.ImGui_SetCursorScreenPos(ctx, x0 + inner - play, y0 + math.floor((row_h - play) * 0.5))
  REVEAL.size, REVEAL.glyph_size = play, M.ICON_FS
  if icons.button(ctx, font, "leftover_reveal", "folder", REVEAL) then
    action = { type = "reveal_library" }
  end
  local y = y0 + row_h

  if summary then
    y = y + thin
    local indent = tick + sx
    local text = widgets.ellipsize(ctx, summary, inner - indent)
    reaper.ImGui_DrawList_AddText(dl, x0 + indent, y, T.TEXT_TERTIARY, text)
    y = y + line_h + thin
  end
  y = y + thin
  reaper.ImGui_DrawList_AddLine(dl, x0, y + 0.5, x0 + inner, y + 0.5, T.STROKE_TERTIARY, 1)
  y = y + 1 + thin

  -- The list scrolls inside its own child once it is taller than the room.
  reaper.ImGui_SetCursorScreenPos(ctx, x0, y)
  if reaper.ImGui_BeginChild(ctx, "##leftover_list", inner, list_h, 0) then
    local scrolls = #entries > rows
    local bar = scrolls and reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ScrollbarSize()) or 0
    local cw = inner - bar
    local length_w = M.LEFTOVER_LENGTH_W
    local col_gap = M.LEFTOVER_COL_GAP
    local flex = cw - length_w - col_gap - name_x
    local reason_w = 0
    if lo.show_reasons then
      reason_w = math.max(0, math.min(M.LEFTOVER_REASON_W, math.floor((flex - col_gap) * 0.5)))
    end
    local name_w = flex - (reason_w > 0 and (reason_w + col_gap) or 0)
    local reason_x = name_x + name_w + col_gap
    local list_dl = reaper.ImGui_GetWindowDrawList(ctx)
    local mx, my = reaper.ImGui_GetMousePos(ctx)
    local list_hovered = reaper.ImGui_IsWindowHovered(ctx)
    local live = state.preview
    local playing_key = live.playing and live.slot == "leftover" and live.sound_id or nil
    local rounding = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding())

    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), sx, 0)
    reaper.ImGui_ListClipper_Begin(res.clipper, #entries, row_h)
    while reaper.ImGui_ListClipper_Step(res.clipper) do
      local first, last = reaper.ImGui_ListClipper_GetDisplayRange(res.clipper)
      for i = first, last - 1 do
        local e = entries[i + 1]
        local rx, ry = reaper.ImGui_GetCursorScreenPos(ctx)
        local over = list_hovered and mx >= rx and mx < rx + cw and my >= ry and my < ry + row_h
        if over then
          reaper.ImGui_DrawList_AddRectFilled(list_dl, rx, ry, rx + cw, ry + row_h, T.FILL_TERTIARY, rounding)
        end
        reaper.ImGui_PushID(ctx, e.key)

        reaper.ImGui_SetCursorScreenPos(ctx, rx, ry + math.floor((row_h - tick) * 0.5))
        local c, v = reaper.ImGui_Checkbox(ctx, "##tick", ticks[e.name] == true)
        if c then ticks[e.name] = v end

        local is_playing = playing_key ~= nil and playing_key == e.key
        local opts = is_playing and STOP or PLAY
        opts.size, opts.glyph_size = play, M.ICON_SM_FS
        opts.color = is_playing and T.ACCENT_HOVER or nil
        opts.fallback = is_playing and draw_stop or draw_play
        reaper.ImGui_SetCursorScreenPos(ctx, rx + tick + sx, ry + math.floor((row_h - play) * 0.5))
        if icons.button(ctx, font, "play", is_playing and "square" or "play", opts) then
          action = { type = "audition_leftover", name = e.name }
        end

        -- The rest of the row ticks and unticks the file.
        reaper.ImGui_SetCursorScreenPos(ctx, rx + name_x, ry)
        if reaper.ImGui_InvisibleButton(ctx, "##row", math.max(1, cw - name_x), row_h) then
          ticks[e.name] = not ticks[e.name]
        end

        local text = cut(ctx, e, name_w, reason_w)
        reaper.ImGui_DrawList_AddText(list_dl, rx + name_x, ry + text_dy, T.TEXT_PRIMARY, text.name)
        if text.reason then
          reaper.ImGui_DrawList_AddText(list_dl, rx + reason_x, ry + text_dy, T.TEXT_TERTIARY, text.reason)
        end
        if e.length and e.length ~= "" then
          local tw = reaper.ImGui_CalcTextSize(ctx, e.length)
          reaper.ImGui_DrawList_AddText(list_dl, rx + cw - tw, ry + text_dy, T.TEXT_SECONDARY, e.length)
        end
        local hidden_reason = reason_w == 0 and e.reason ~= nil and not lo.summary
        tips.show(ctx, over and (text.cut or hidden_reason) and reaper.ImGui_IsItemHovered(ctx),
          text.tip, e.key, tips.rect(rx, ry, cw, row_h))

        reaper.ImGui_PopID(ctx)
        reaper.ImGui_SetCursorScreenPos(ctx, rx, ry + row_h)
      end
    end
    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleVar(ctx) -- FramePadding

  y = y + list_h + gap
  reaper.ImGui_SetCursorScreenPos(ctx, x0, y)
  reaper.ImGui_PushTextWrapPos(ctx, 0)
  reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY, FOOTER)
  reaper.ImGui_PopTextWrapPos(ctx)
  reaper.ImGui_SetCursorScreenPos(ctx, x0, y + note_h + gap)

  local any = false
  for _, e in ipairs(entries) do
    if ticks[e.name] then any = true; break end
  end
  local idle = not any or lo.checking
  if idle then reaper.ImGui_BeginDisabled(ctx) end
  local trash_clicked, add_clicked = widgets.action_pair(ctx, "Move to Trash", "Add to Library")
  if idle then reaper.ImGui_EndDisabled(ctx) end
  if trash_clicked or add_clicked then
    action = { type = trash_clicked and "trash_leftovers" or "add_leftovers", names = names_ticked(entries) }
    reaper.ImGui_CloseCurrentPopup(ctx)
  end

  reaper.ImGui_EndPopup(ctx)
  return action
end

return panel
