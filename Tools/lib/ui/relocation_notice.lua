-- Persistent safety notice for a project whose pinned audio could not follow a
-- Save As. Paint-only so it can sit over the working view without moving the
-- waveform, spectrum, or transport controls.

local theme = require("ui.theme")
local T = theme.tokens
local M = theme.metrics

local notice = {}
local HAS_CLIP = reaper.ImGui_DrawList_PushClipRect ~= nil

local HEADING = "PIN EDITS PAUSED"
local BODY = "yb-Reference could not move the pinned audio after Save As. Before closing " ..
  "yb-Reference, use Save As to return the project to its original folder or save it " ..
  "to another valid folder."

function notice.is_visible(state)
  return type(state) == "table" and type(state.pins) == "table"
    and type(state.pins.relocation_error) == "string"
    and state.pins.relocation_error ~= ""
end

function notice.layout(x0, y0, x1, y1, pad, gap, heading_h, body_h)
  local outer_w, outer_h = math.max(0, x1 - x0), math.max(0, y1 - y0)
  if outer_w <= 0 or outer_h <= 0 then return nil end
  local inset = math.min(pad, outer_w * 0.25)
  local left, right = x0 + inset, x1 - inset
  if right <= left then return nil end
  local wanted_h = pad * 2 + heading_h + gap + body_h
  local top = y0 + math.min(pad, math.max(0, outer_h - 1))
  local bottom = math.min(y1, top + wanted_h)
  if bottom <= top then return nil end
  return { x0 = left, y0 = top, x1 = right, y1 = bottom,
    inner_x = left + pad, inner_y = top + pad,
    inner_w = math.max(1, right - left - pad * 2) }
end

function notice.draw(ctx, state, x0, y0, x1, y1)
  if not notice.is_visible(state) then return end

  local inner_w = math.max(1, x1 - x0 - M.WINDOW_PAD * 4)
  local _, heading_h = reaper.ImGui_CalcTextSize(ctx, HEADING)
  local _, body_h = reaper.ImGui_CalcTextSize(ctx, BODY, nil, nil, false, inner_w)
  local card = notice.layout(x0, y0, x1, y1, M.WINDOW_PAD,
    M.ANALYSIS_CARD_GAP, heading_h, body_h)
  if not card then return end

  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  if HAS_CLIP then reaper.ImGui_DrawList_PushClipRect(dl, x0, y0, x1, y1, true) end
  reaper.ImGui_DrawList_AddRectFilled(dl, card.x0, card.y0, card.x1, card.y1,
    T.BG_POPUP, M.ANALYSIS_CARD_RADIUS)
  reaper.ImGui_DrawList_AddRect(dl, card.x0, card.y0, card.x1, card.y1,
    T.DANGER_RED, M.ANALYSIS_CARD_RADIUS)

  local restore_x, restore_y = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_SetCursorScreenPos(ctx, card.inner_x, card.inner_y)
  reaper.ImGui_TextColored(ctx, T.DANGER_RED, HEADING)
  reaper.ImGui_SetCursorScreenPos(ctx, card.inner_x,
    card.inner_y + heading_h + M.ANALYSIS_CARD_GAP)
  local wrap_x = reaper.ImGui_GetCursorPosX(ctx) + card.inner_w
  reaper.ImGui_PushTextWrapPos(ctx, wrap_x)
  reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, BODY)
  reaper.ImGui_PopTextWrapPos(ctx)
  reaper.ImGui_SetCursorScreenPos(ctx, restore_x, restore_y)
  if HAS_CLIP then reaper.ImGui_DrawList_PopClipRect(dl) end
end

return notice
