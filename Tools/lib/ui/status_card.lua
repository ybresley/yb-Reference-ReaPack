-- status_card: the one message card for what the app just did or could not do.
--
-- Same family as the loudness progress card and the pin notice: popup fill,
-- hairline border, small text. It floats at the bottom centre of a picture area
-- and never moves the panels beneath it.
--
-- Input order matters. `prepare` runs BEFORE the pictures it overlaps and
-- submits one invisible button over the card, so that button wins the pointer
-- and a click on the close mark cannot also seek the waveform. `paint` runs
-- afterwards so the card sits on top.
--
-- A standing notice can carry one button after its words. The card only
-- reports the press (`handle.pressed`); the window opens whatever the button
-- is for.

local theme = require("ui.theme")
local tips = require("ui.tips")
local message = require("core.status_message")
local T = theme.tokens
local M = theme.metrics

local card = {}

local HAS_CLOCK = reaper.ImGui_GetTime ~= nil and reaper.ImGui_GetFrameCount ~= nil
local HAS_CLIP = reaper.ImGui_DrawList_PushClipRect ~= nil

-- Last frame each window saw the pointer on the card. Either window holding it
-- keeps an info message alive.
local hover_frame = {}
-- One entry per window: the windows differ in width, so a shared entry would be
-- thrown away and rebuilt twice every frame.
local lines_cache = {}

local function hovered_recently(frame)
  for _, seen in pairs(hover_frame) do
    if seen >= frame - 1 then return true end
  end
  return false
end

local function wrapped(ctx, id, text, max_w)
  local size = reaper.ImGui_GetFontSize(ctx)
  local c = lines_cache[id]
  if c and c.ctx == ctx and c.text == text and c.width == max_w and c.size == size then
    return c.lines, c.truncated, c.widest
  end
  local function measure(s) return (reaper.ImGui_CalcTextSize(ctx, s)) end
  local lines, truncated = message.wrap(text, max_w, measure, message.MAX_LINES)
  local widest = 0
  for _, line in ipairs(lines) do widest = math.max(widest, measure(line)) end
  lines_cache[id] = { ctx = ctx, text = text, width = max_w, size = size,
    lines = lines, truncated = truncated, widest = widest }
  return lines, truncated, widest
end

local function inside(px, py, x0, y0, x1, y1)
  return px >= x0 and px <= x1 and py >= y0 and py <= y1
end

-- Lay the card out inside [x0, x1] x [y0, bottom] and submit its button.
-- Returns a handle for `paint`, or nil when there is nothing to show.
function card.prepare(ctx, state, id, x0, y0, x1, bottom)
  if not HAS_CLOCK or state.drag then return nil end
  local frame = reaper.ImGui_GetFrameCount(ctx)
  local view = message.view(state, reaper.ImGui_GetTime(ctx),
    hovered_recently(frame), theme.motion.enabled)
  if not view then
    hover_frame[id] = nil
    return nil
  end

  local pad_x = M.ANALYSIS_CARD_PAD
  local pad_y = math.floor(M.ANALYSIS_CARD_PAD * 0.75)
  -- The button is an ordinary control: normal-size text on a framed face.
  local button_w, button_h, button_gap = 0, 0, 0
  if view.button then
    button_w = math.floor(reaper.ImGui_CalcTextSize(ctx, view.button) + M.FRAME_PAD_X * 2 + 0.5)
    button_h = reaper.ImGui_GetFrameHeight(ctx)
    button_gap = M.ANALYSIS_CARD_GAP * 2
  end
  local small = theme.push_small_font(ctx)
  local line_h = reaper.ImGui_GetTextLineHeight(ctx)
  local mark = view.closable and line_h or 0
  local mark_gap = view.closable and M.ANALYSIS_CARD_GAP * 2 or 0
  local max_w = math.max(1, (x1 - x0) - M.WINDOW_PAD * 2 - pad_x * 2 - mark - mark_gap
    - button_w - button_gap)
  local lines, truncated, widest = wrapped(ctx, id, view.text, max_w)
  if small then reaper.ImGui_PopFont(ctx) end

  local text_h = #lines * line_h
  local inner_h = math.max(text_h, button_h)
  local w = widest + button_gap + button_w + pad_x * 2 + mark + mark_gap
  local h = inner_h + pad_y * 2
  local cx0 = math.floor(x0 + ((x1 - x0) - w) * 0.5)
  local cy1 = bottom
  local cy0 = math.max(y0, cy1 - h)
  if cy1 - cy0 < h * 0.5 then return nil end
  local handle = {
    id = id, view = view, lines = lines, truncated = truncated,
    x0 = cx0, y0 = cy0, x1 = cx0 + w, y1 = cy1,
    pad_x = pad_x, pad_y = pad_y, line_h = line_h,
    -- Words and button share one centre line; without a button the close mark
    -- stays level with the first line of text.
    text_y = cy0 + pad_y + math.floor((inner_h - text_h) * 0.5),
    mark_cy = cy0 + pad_y + (view.button and inner_h or line_h) * 0.5,
    clip = { x0, y0, x1, bottom },
  }
  if view.button then
    local bx0 = cx0 + pad_x + widest + button_gap
    local by0 = cy0 + pad_y + math.floor((inner_h - button_h) * 0.5)
    handle.button = { x0 = bx0, y0 = by0, x1 = bx0 + button_w, y1 = by0 + button_h, label = view.button }
  end

  local saved_x, saved_y = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_SetCursorScreenPos(ctx, handle.x0, handle.y0)
  reaper.ImGui_InvisibleButton(ctx, "##status_card_" .. id, w, cy1 - cy0)
  handle.hovered = reaper.ImGui_IsItemHovered(ctx)
  if handle.hovered then hover_frame[id] = frame else hover_frame[id] = nil end
  if view.closable then
    handle.close = { x0 = handle.x1 - pad_x - mark, y0 = handle.y0,
      x1 = handle.x1, y1 = handle.y1 }
  end
  if reaper.ImGui_IsItemClicked(ctx, 0) then
    local mx, my = reaper.ImGui_GetMousePos(ctx)
    local c, b = handle.close, handle.button
    if c and inside(mx, my, c.x0, c.y0, c.x1, c.y1) then
      -- Says which card was closed, so a message that arrives before the
      -- action is handled can't be closed in the notice's place.
      handle.action = { type = "dismiss_status", notice = view.notice }
    elseif b and inside(mx, my, b.x0, b.y0, b.x1, b.y1) then
      handle.pressed = true
    end
  end
  reaper.ImGui_SetCursorScreenPos(ctx, saved_x, saved_y)
  return handle, handle.action
end

-- `button_on` shows the button pressed while what it opened is open.
function card.paint(ctx, handle, button_on)
  if not handle then return end
  local view, alpha = handle.view, handle.view.alpha
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local border = view.kind == "problem" and T.DANGER_RED or T.STROKE_SECONDARY
  if HAS_CLIP then
    reaper.ImGui_DrawList_PushClipRect(dl, handle.clip[1], handle.clip[2],
      handle.clip[3], handle.clip[4], true)
  end
  reaper.ImGui_DrawList_AddRectFilled(dl, handle.x0, handle.y0, handle.x1, handle.y1,
    theme.fade(T.BG_POPUP, alpha), M.ANALYSIS_CARD_RADIUS)
  reaper.ImGui_DrawList_AddRect(dl, handle.x0, handle.y0, handle.x1, handle.y1,
    theme.fade(border, alpha), M.ANALYSIS_CARD_RADIUS, 0, theme.scale)

  local small = theme.push_small_font(ctx)
  local colour = theme.fade(T.TEXT_PRIMARY, alpha)
  for i, line in ipairs(handle.lines) do
    reaper.ImGui_DrawList_AddText(dl, handle.x0 + handle.pad_x,
      handle.text_y + (i - 1) * handle.line_h, colour, line)
  end
  if small then reaper.ImGui_PopFont(ctx) end

  if handle.button then
    -- Painted rather than submitted, so the card's one invisible button keeps
    -- the pointer. The colours are the theme's own button states.
    local b = handle.button
    local mx, my = reaper.ImGui_GetMousePos(ctx)
    local over = handle.hovered and inside(mx, my, b.x0, b.y0, b.x1, b.y1)
    local fill = (button_on or (over and reaper.ImGui_IsMouseDown(ctx, 0))) and T.FILL_PRIMARY
      or over and T.FILL_SECONDARY or T.FILL_TERTIARY
    local rounding = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding())
    reaper.ImGui_DrawList_AddRectFilled(dl, b.x0, b.y0, b.x1, b.y1, theme.fade(fill, alpha), rounding)
    reaper.ImGui_DrawList_AddRect(dl, b.x0, b.y0, b.x1, b.y1,
      theme.fade(T.STROKE_SECONDARY, alpha), rounding, 0, theme.scale)
    local tw, th = reaper.ImGui_CalcTextSize(ctx, b.label)
    reaper.ImGui_DrawList_AddText(dl, math.floor(b.x0 + (b.x1 - b.x0 - tw) * 0.5),
      math.floor(b.y0 + (b.y1 - b.y0 - th) * 0.5), theme.fade(T.TEXT_SECONDARY, alpha), b.label)
  end

  if handle.close then
    local c = handle.close
    local mx, my = reaper.ImGui_GetMousePos(ctx)
    local over = handle.hovered and inside(mx, my, c.x0, c.y0, c.x1, c.y1)
    local size = handle.line_h * 0.5
    local cx = c.x0 + (handle.line_h) * 0.5
    local cy = handle.mark_cy
    local mark = theme.fade(over and T.TEXT_PRIMARY or T.TEXT_TERTIARY, alpha)
    local half = size * 0.5
    reaper.ImGui_DrawList_AddLine(dl, cx - half, cy - half, cx + half, cy + half, mark, theme.scale)
    reaper.ImGui_DrawList_AddLine(dl, cx - half, cy + half, cx + half, cy - half, mark, theme.scale)
  end
  if HAS_CLIP then reaper.ImGui_DrawList_PopClipRect(dl) end

  -- One tooltip key per window, so the two windows' hover delays stay apart.
  tips.show(ctx, handle.hovered and handle.truncated, handle.view.text, "status_card_" .. tostring(handle.id),
    tips.rect(handle.x0, handle.y0, handle.x1 - handle.x0, handle.y1 - handle.y0))
end

return card
