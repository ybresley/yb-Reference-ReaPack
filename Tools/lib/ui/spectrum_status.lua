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

function panel.minimum_height(ctx)
  return reaper.ImGui_GetFrameHeight(ctx)
end

local function action_fit(ctx, message, width, height)
  local frame_h = panel.minimum_height(ctx)
  if not message.button or height < reaper.ImGui_GetTextLineHeight(ctx) then return end
  local label = message.button
  local label_w = reaper.ImGui_CalcTextSize(ctx, label) + 2 * M.FRAME_PAD_X
  if label_w > width and height >= frame_h and not message.setup then
    label = label:match('^%S+') or label
    label_w = reaper.ImGui_CalcTextSize(ctx, label) + 2 * M.FRAME_PAD_X
  end
  if label_w <= width then return label, label_w, math.min(frame_h, height) end
end

local function action_rows(ctx,message,width,height)
  local label,label_w,button_h=action_fit(ctx,message,width,height)
  if not label then return {},0 end
  local first={label=label,w=math.min(width,math.max(M.RECOVERY_ACTION_W,label_w)),h=button_h,
    action=message.action_data or {type=message.action}}
  if not message.secondary_button then return {first},button_h end
  local second_w=reaper.ImGui_CalcTextSize(ctx,message.secondary_button)+2*M.FRAME_PAD_X
  local second={label=message.secondary_button,w=math.min(width,math.max(M.RECOVERY_ACTION_W,second_w)),
    h=button_h,action={type=message.secondary_action}}
  if second_w>width then return {},0 end
  local gap=M.ITEM_SPACING_X
  if first.w+second.w+gap<=width then
    first.x=(width-first.w-second.w-gap)/2
    second.x=first.x+first.w+gap
    return {first,second},button_h
  end
  local total=2*panel.minimum_height(ctx)+M.ITEM_SPACING_Y
  if total>height then return {},0 end
  first.h,second.h=panel.minimum_height(ctx),panel.minimum_height(ctx)
  second.y=first.h+M.ITEM_SPACING_Y
  return {first,second},total
end

function panel.measure(ctx,message,width)
  local content_w=math.max(1,math.min(width,M.FILTER_CONTENT_W))
  local _,title_h=wrapped_lines(ctx,message.title,content_w,'title')
  local _,detail_h=wrapped_lines(ctx,message.detail,content_w,'detail')
  local _,actions_h=action_rows(ctx,message,width,math.huge)
  local recommendation_space=0
  if message.recommendation then
    local _,recommendation_h=wrapped_lines(ctx,message.recommendation,content_w,'recommendation')
    recommendation_space=recommendation_h+M.ITEM_SPACING_Y
  end
  if message.compact_setup then return actions_h+recommendation_space end
  return title_h+detail_h+M.ITEM_SPACING_Y+recommendation_space
    +(message.button and actions_h+M.ITEM_SPACING_Y or 0)
end

function panel.compact_fits(ctx, message, width, height)
  if message.button then
    local recommendation_space=0
    if message.recommendation then
      local _,text_h=wrapped_lines(ctx,message.recommendation,
        math.max(1,math.min(width,M.FILTER_CONTENT_W)),'recommendation')
      recommendation_space=text_h+M.ITEM_SPACING_Y
    end
    local buttons=action_rows(ctx,message,width,height-recommendation_space)
    return #buttons==(message.secondary_button and 2 or 1)
  end
  local _, title_h = wrapped_lines(ctx, message.title, math.max(1, math.min(width, M.FILTER_CONTENT_W)), 'title')
  return title_h <= height
end

local function shortened_line(ctx, line, width)
  if line.shortened then return line.shortened end
  local ending = '…'
  local prefix = line.text:gsub('…$', '')
  while prefix ~= '' do
    local candidate = prefix .. ending
    local candidate_w = reaper.ImGui_CalcTextSize(ctx, candidate)
    if candidate_w <= width then
      line.shortened = {text = candidate, width = candidate_w}
      return line.shortened
    end
    prefix = prefix:sub(1, utf8.offset(prefix, -1) - 1):gsub('%s+$', '')
  end
  -- With room for one glyph, keep the start of the message visible.
  return line
end

function panel.draw(ctx, system, x, y, width, height, override)
  local message = override or status.describe(system)
  if not message or width <= 0 or height <= 0 then return end
  local content_w = math.max(1, math.min(width, M.FILTER_CONTENT_W))
  local title_lines = wrapped_lines(ctx, message.title, content_w, 'title')
  local detail_lines = wrapped_lines(ctx, message.detail, content_w, 'detail')
  local gap, line_h = M.ITEM_SPACING_Y, reaper.ImGui_GetTextLineHeight(ctx)
  local recommendation_lines,recommendation_h={},0
  if message.recommendation then
    recommendation_lines,recommendation_h=wrapped_lines(ctx,message.recommendation,content_w,'recommendation')
  end
  local recommendation_space=recommendation_h>0 and recommendation_h+gap or 0
  local buttons,actions_h=action_rows(ctx,message,width,height-recommendation_space)
  local show_button=#buttons>0
  local text_room=message.compact_setup and 0 or height-recommendation_space-(show_button and actions_h+gap or 0)
  local title_count = math.min(#title_lines, math.max((show_button or message.compact_setup) and 0 or 1, math.floor(text_room / line_h)))
  local detail_room = title_count > 0 and text_room - title_count * line_h - gap or 0
  local detail_count = math.min(#detail_lines, math.max(0, math.floor(detail_room / line_h)))
  local text_h = title_count * line_h + (detail_count > 0 and gap + detail_count * line_h or 0)
  local used = text_h + recommendation_space + (show_button and actions_h + (text_h > 0 and gap or 0) or 0)
  local truncated = title_count < #title_lines or detail_count < #detail_lines or used > height
    or message.button ~= nil and not show_button
  local top = y + math.max(0, (height - used) / 2)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local function text(lines, count, colour, more)
    if count == 0 then return end
    for index = 1, count do
      local line = lines[index]
      if line.width > content_w then truncated = true end
      if index == count and more then line = shortened_line(ctx, line, content_w) end
      reaper.ImGui_DrawList_AddText(dl, x + math.max(0, (width - line.width) / 2),
        top + (index - 1) * line_h, colour, line.text)
    end
    top = top + count * line_h + gap
  end
  if title_count > 0 or recommendation_h > 0 then
    local alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
    reaper.ImGui_DrawList_PushClipRect(dl, x, y, x + width, y + height, true)
    text(title_lines, title_count, theme.fade(T.TEXT_PRIMARY, alpha), truncated and detail_count == 0)
    text(detail_lines, detail_count, theme.fade(T.TEXT_SECONDARY, alpha), detail_count < #detail_lines)
    text(recommendation_lines, #recommendation_lines, theme.fade(T.TEXT_SECONDARY, alpha), false)
    reaper.ImGui_DrawList_PopClipRect(dl)
  end
  local selected,button_hovered
  for index,button in ipairs(buttons) do
    local button_x=x+(button.x or (width-button.w)/2)
    local button_y=top+(button.y or 0)
    local rounding=reaper.ImGui_GetStyleVar(ctx,reaper.ImGui_StyleVar_FrameRounding())
    reaper.ImGui_DrawList_AddRectFilled(dl,button_x,button_y,
      button_x+button.w,button_y+button.h,T.BG_WINDOW,rounding)
    reaper.ImGui_SetCursorScreenPos(ctx,button_x,button_y)
    local shallow=button.h<panel.minimum_height(ctx)
    if shallow then
      reaper.ImGui_PushStyleVar(ctx,reaper.ImGui_StyleVar_FramePadding(),M.FRAME_PAD_X,
        (button.h-line_h)/2)
    end
    if reaper.ImGui_Button(ctx,button.label..'##spectrum_helper_recovery_'..index,button.w,button.h) then
      selected=button.action
    end
    if shallow then reaper.ImGui_PopStyleVar(ctx) end
    -- A demonstration's guide pointer needs the real button's place.
    if message.button_targets then
      message.button_targets[index]={x=button_x+button.w/2,y=button_y+button.h/2}
    end
    button_hovered=button_hovered or reaper.ImGui_IsItemHovered(ctx)
  end
  if truncated and not button_hovered and reaper.ImGui_IsMouseHoveringRect(ctx, x, y, x + width, y + height) then
    tips.show(ctx, true, message.title .. '\n' .. message.detail
      .. (message.recommendation and '\n' .. message.recommendation or ''), 'spectrum_status_card',
      tips.rect(x, y, width, height))
  end
  return selected
end

return panel
