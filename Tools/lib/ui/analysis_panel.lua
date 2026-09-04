-- analysis_panel: paint-only progress feedback for loudness measurement.
-- It intentionally submits no ImGui item, so the waveform keeps all of its
-- existing seek, drag, and span interactions.

local theme = require("ui.theme")
local widgets = require("ui.widgets")
local T = theme.tokens
local M = theme.metrics

local panel = {}

local HAS_CLIP = reaper.ImGui_DrawList_PushClipRect ~= nil

function panel.is_visible(state, view, files_active)
  return state.analysis_progress ~= nil and state.analysis_progress.view == view
    and not state.drag and not files_active
end

local function text_size(ctx, text)
  local small = theme.push_small_font(ctx)
  local w, h = reaper.ImGui_CalcTextSize(ctx, text)
  if small then reaper.ImGui_PopFont(ctx) end
  return w, h
end

local function draw_text(ctx, dl, x, y, colour, text)
  local small = theme.push_small_font(ctx)
  reaper.ImGui_DrawList_AddText(dl, x, y, colour, text)
  if small then reaper.ImGui_PopFont(ctx) end
end

local function ellipsize_small(ctx, text, max_w, cut)
  local small = theme.push_small_font(ctx)
  local shown = widgets.ellipsize(ctx, text, max_w, cut)
  if small then reaper.ImGui_PopFont(ctx) end
  return shown
end

local function remaining_text(progress)
  local remaining = tonumber(progress.remaining) or 0
  return string.format("%d remaining", math.max(0, math.floor(remaining)))
end

local function draw_centred(ctx, dl, x, y, width, colour, text)
  local shown = ellipsize_small(ctx, text, width)
  local text_w = text_size(ctx, shown)
  draw_text(ctx, dl, math.floor(x + (width - text_w) * 0.5), y, colour, shown)
end

function panel.draw(ctx, progress, x0, y0, x1, y1)
  if type(progress) ~= "table" then return end
  if type(x0) ~= "number" or type(y0) ~= "number"
    or type(x1) ~= "number" or type(y1) ~= "number" then return end

  local width, height = x1 - x0, y1 - y0
  if width <= 0 or height <= 0 then return end

  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local edge = M.ANALYSIS_CARD_PAD
  local title = progress.paused and "Paused for recording"
    or "Measuring loudness…"
  local detail = remaining_text(progress)
  local _, line_h = text_size(ctx, title)
  local full_h = M.ANALYSIS_CARD_PAD * 2 + line_h * 2 + M.ANALYSIS_CARD_GAP
  local compact = height < full_h + edge
  local target_w = compact and M.ANALYSIS_CARD_COMPACT_W or M.ANALYSIS_CARD_W
  local card_w = math.min(target_w, math.max(1, width - edge * 2))
  local card_x1 = x1 - edge
  local card_x0 = math.max(x0, card_x1 - card_w)
  local card_y0 = math.min(y1, y0 + edge)
  local content_pad = compact
    and math.min(edge, math.max(2, math.floor((height - line_h) * 0.5))) or edge
  local card_h = compact and content_pad * 2 + line_h or full_h
  if compact then card_y0 = y0 + math.max(0, math.min(edge, (height - card_h) * 0.5)) end
  local card_y1 = math.min(y1, card_y0 + card_h)
  if card_y1 <= card_y0 then return end

  if HAS_CLIP then
    reaper.ImGui_DrawList_PushClipRect(dl, x0, y0, x1, y1, true)
  end
  reaper.ImGui_DrawList_AddRectFilled(dl, card_x0, card_y0, card_x1, card_y1,
    T.BG_POPUP, M.ANALYSIS_CARD_RADIUS)
  reaper.ImGui_DrawList_AddRect(dl, card_x0, card_y0, card_x1, card_y1,
    T.STROKE_SECONDARY, M.ANALYSIS_CARD_RADIUS)

  local inner_x = card_x0 + M.ANALYSIS_CARD_PAD
  local inner_w = card_x1 - M.ANALYSIS_CARD_PAD - inner_x
  if compact then
    -- Keep the count and recording state visible when only one line fits.
    local count = ellipsize_small(ctx, detail, inner_w)
    local count_w = text_size(ctx, count)
    local suffix = ellipsize_small(ctx, " · " .. title, math.max(0, inner_w - count_w))
    local suffix_w = text_size(ctx, suffix)
    local text_x = math.floor(inner_x + (inner_w - count_w - suffix_w) * 0.5)
    draw_text(ctx, dl, text_x, card_y0 + content_pad, T.ACCENT, count)
    draw_text(ctx, dl, text_x + count_w, card_y0 + content_pad, T.TEXT_PRIMARY, suffix)
  else
    draw_centred(ctx, dl, inner_x, card_y0 + M.ANALYSIS_CARD_PAD, inner_w,
      T.TEXT_PRIMARY, title)
    draw_centred(ctx, dl, inner_x, card_y0 + M.ANALYSIS_CARD_PAD + line_h + M.ANALYSIS_CARD_GAP,
      inner_w, T.ACCENT, detail)
  end
  if HAS_CLIP then reaper.ImGui_DrawList_PopClipRect(dl) end
end

return panel
