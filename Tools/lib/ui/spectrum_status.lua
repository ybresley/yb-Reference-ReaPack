-- Recovery lives in the vacant graph area, not over an active spectrum trace.
local theme = require('ui.theme')
local tips = require('ui.tips')
local status = require('core.monitor_helper_status')
local T, M = theme.tokens, theme.metrics
local panel = {}

-- ImGui centres a text block, not its wrapped lines. Measure the lines once so
-- each can share the button's centre, including after a width or UI-size change.
local text_cache = {}
local function wrapped_lines(ctx, value, width, slot)
  local font_size = reaper.ImGui_GetFontSize(ctx)
  local cached = text_cache[slot]
  if cached and cached.value == value and cached.width == width
      and cached.font_size == font_size and cached.ctx == ctx then
    return cached.lines, cached.height
  end
  local lines, line = {}, ''
  local line_h = reaper.ImGui_GetTextLineHeight(ctx)
  local function add_line()
    lines[#lines + 1] = {text = line, width = reaper.ImGui_CalcTextSize(ctx, line)}
    line = ''
  end
  for paragraph in (value .. '\n'):gmatch('(.-)\n') do
    for word in paragraph:gmatch('%S+') do
      local candidate = line == '' and word or line .. ' ' .. word
      if reaper.ImGui_CalcTextSize(ctx, candidate) <= width then
        line = candidate
      else
        if line ~= '' then add_line() end
        -- Long paths and other unbroken error details must also fit the graph.
        for character in word:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
          if line ~= '' and reaper.ImGui_CalcTextSize(ctx, line .. character) > width then
            add_line()
          end
          line = line .. character
        end
      end
    end
    add_line()
  end
  local height = #lines * line_h
  text_cache[slot] = {ctx = ctx, value = value, width = width, font_size = font_size,
    lines = lines, height = height}
  return lines, height
end

function panel.draw(ctx, system, x, y, width, height)
  local message = status.describe(system)
  if not message then return end
  local content_w = math.max(1, math.min(width, M.FILTER_CONTENT_W))
  local title_lines, title_h = wrapped_lines(ctx, message.title, content_w, 'title')
  local detail_lines, detail_h = wrapped_lines(ctx, message.detail, content_w, 'detail')
  local gap = M.ITEM_SPACING_Y
  local button_h = message.button and reaper.ImGui_GetFrameHeight(ctx) or 0
  local show_button = button_h > 0 and height >= button_h
  local used = show_button and button_h or 0
  local show_title = title_h + used + (used > 0 and gap or 0) <= height
  if show_title then used = used + title_h + (used > 0 and gap or 0) end
  local show_detail = show_title and used + gap + detail_h <= height
  if show_detail then used = used + gap + detail_h end
  local top = y + math.max(0, (height - used) / 2)
  local function text(lines, measured_h, colour)
    local line_h = reaper.ImGui_GetTextLineHeight(ctx)
    reaper.ImGui_PushTextWrapPos(ctx, -1)
    for i, line in ipairs(lines) do
      reaper.ImGui_SetCursorScreenPos(ctx,
        x + math.max(0, (width - line.width) / 2), top + (i - 1) * line_h)
      reaper.ImGui_TextColored(ctx, colour, line.text)
    end
    reaper.ImGui_PopTextWrapPos(ctx)
    top = top + measured_h + gap
  end
  if show_title then text(title_lines, title_h, T.TEXT_PRIMARY) end
  if show_detail then text(detail_lines, detail_h, T.TEXT_SECONDARY) end
  if show_button then
    local button_w = math.min(width, M.RECOVERY_ACTION_W)
    local button_x = x + (width - button_w) / 2
    -- Keep the standard translucent button fills, but block the grid beneath them.
    local rounding = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding())
    reaper.ImGui_DrawList_AddRectFilled(reaper.ImGui_GetWindowDrawList(ctx),
      button_x, top, button_x + button_w, top + button_h, T.BG_WINDOW, rounding)
    reaper.ImGui_SetCursorScreenPos(ctx, button_x, top)
    local clicked = reaper.ImGui_Button(ctx, message.button .. '##spectrum_helper_recovery', button_w, button_h)
    tips.show(ctx, reaper.ImGui_IsItemHovered(ctx), message.title .. '.\n' .. message.detail,
      'spectrum_helper_recovery')
    if clicked then return {type = message.action} end
  end
end

return panel
