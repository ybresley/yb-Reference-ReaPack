-- Release navigation paints cards and a topic index without giving demo state to controls.
local theme = require('ui.theme')
local widgets = require('ui.widgets')
local layout = require('core.release_layout')
local T, M = theme.tokens, theme.metrics
local navigation = {}
local geometry, geometry_key, text_cache, text_count = nil, nil, {}, 0
local last_width, last_scale, intro_cache

function navigation.reset()
  geometry, geometry_key, text_cache, text_count = nil, nil, {}, 0
  last_width, last_scale, intro_cache = nil, nil, nil
end

local function font(ctx, size, bold)
  -- Static copy uses whole-pixel font sizes.
  return (bold and theme.push_release_bold_font or theme.push_release_font)(ctx, math.floor(size + .5))
end

local function title_size(ctx, title, size, width)
  local pushed = font(ctx, size, true)
  local measured = reaper.ImGui_CalcTextSize(ctx, title)
  if pushed then reaper.ImGui_PopFont(ctx) end
  return size * math.min(1, math.max(1, width) / math.max(1, measured))
end

local function wrapped_text(ctx, text, width)
  local size = reaper.ImGui_GetFontSize(ctx)
  local key = text .. ':' .. width .. ':' .. size
  local cached = text_cache[key]
  if cached then return cached.text, cached.height end
  local lines, line = {}, ''
  for word in text:gmatch('%S+') do
    local next_line = line == '' and word or line .. ' ' .. word
    if line ~= '' and reaper.ImGui_CalcTextSize(ctx, next_line) > width then
      lines[#lines + 1], line = line, word
    else line = next_line end
  end
  if line ~= '' then lines[#lines + 1] = line end
  local value = table.concat(lines, '\n')
  local _, height = reaper.ImGui_CalcTextSize(ctx, value)
  if text_count >= 64 then text_cache, text_count = {}, 0 end
  text_cache[key], text_count = { text = value, height = height }, text_count + 1
  return value, height
end

local function text(ctx, dl, x, y, value, size, colour, bold, width)
  local pushed = font(ctx, size, bold)
  local height
  if width then value, height = wrapped_text(ctx, value, math.max(1, width)) end
  reaper.ImGui_DrawList_AddText(dl, math.floor(x + .5), math.floor(y + .5), colour, value)
  if not height then local _, measured = reaper.ImGui_CalcTextSize(ctx, value); height = measured end
  if pushed then reaper.ImGui_PopFont(ctx) end
  return height
end

local function glasslight(ctx, id, selected, clicked, dl, x, y, w, h)
  widgets.button_bloom(ctx, id, selected, T.ACCENT, clicked, true, .55,
    { left = x, top = y, right = x + w, bottom = y + h })
  local progress = widgets.motion_event(ctx, id .. '_glass', selected,
    theme.motion.WN_GLASSLIGHT, clicked)
  if not progress then return end
  local p, strength = 1 - (1 - progress) ^ 3, (1 - progress) ^ 1.35
  local head = x - w * .5 + p * w * 1.8
  reaper.ImGui_DrawList_PushClipRect(dl, x + 1, y + 1, x + w - 1, y + h - 1, true)
  -- A short band of translucent strokes gives the sweep a soft shoulder.
  for band = 0, 10 do
    local bx = head - band * w * .018
    local alpha = strength * .16 * (1 - band / 11)
    reaper.ImGui_DrawList_AddLine(dl, bx, y, bx - h * .4, y + h,
      theme.fade(T.ACCENT, alpha), math.max(1, w * .02))
  end
  reaper.ImGui_DrawList_AddLine(dl, head, y, head - h * .4, y + h,
    theme.fade(T.ACCENT_HOVER, strength * .6), theme.scale)
  reaper.ImGui_DrawList_PopClipRect(dl)
end

function navigation.feature_height(width, count, selected)
  local key = width .. ':' .. count .. ':' .. selected .. ':' .. theme.scale
  if geometry_key ~= key then
    geometry, geometry_key = layout.cards(width, count, selected, theme.scale), key
  end
  return geometry.height
end

local function card_motion(ctx, id, target, selected, duration)
  local grow = widgets.motion_value(ctx, id .. '_open', selected and 1 or 0, theme.motion.WN_FOLD)
  local x = widgets.motion_value(ctx, id .. '_x', target.x, duration)
  local y = widgets.motion_value(ctx, id .. '_y', target.y, duration)
  local w = widgets.motion_value(ctx, id .. '_w', target.w, duration)
  local h = widgets.motion_value(ctx, id .. '_h', target.h, duration)
  return grow, x, y, w, h
end

function navigation.features(ctx, features, selected, namespace)
  local width = reaper.ImGui_GetContentRegionAvail(ctx)
  local height = navigation.feature_height(width, #features, selected)
  local resized = last_width ~= width or last_scale ~= theme.scale
  last_width, last_scale = width, theme.scale
  local duration = (resized or geometry.narrow or #features > 4) and 0 or theme.motion.WN_FOLD
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local radius = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding())
  reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + width, y0 + height, T.BG_CHROME, radius)
  reaper.ImGui_DrawList_AddRect(dl, x0, y0, x0 + width, y0 + height, T.STROKE_SECONDARY, radius)
  local compact_width, open_width = width, 0
  for _, card in ipairs(geometry.cards) do
    compact_width, open_width = math.min(compact_width, card.w), math.max(open_width, card.w)
  end
  local chosen
  for index, feature in ipairs(features) do
    local id, target = namespace .. '_feature_' .. index, geometry.cards[index]
    local on = selected == index
    -- Only selection animates. Window resizing uses its current available space.
    local grow, x, y, w, h = card_motion(ctx, id, target, on, duration)
    x, y = x0 + x, y0 + y
    reaper.ImGui_SetCursorScreenPos(ctx, x, y)
    local clicked = false
    if #features > 1 then clicked = reaper.ImGui_InvisibleButton(ctx, id, w, h)
    else reaper.ImGui_Dummy(ctx, w, h) end
    local hover = #features > 1 and reaper.ImGui_IsItemHovered(ctx)
    local background = theme.blend(T.SET_GROUP_BG, T.ACCENT, .04 + .22 * grow)
    if hover and not on then background = theme.blend(background, T.TEXT_PRIMARY, .05) end
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + w, y + h, background, radius)
    reaper.ImGui_DrawList_AddRect(dl, x, y, x + w, y + h,
      on and theme.fade(T.ACCENT, .24) or T.STROKE_TERTIARY, radius)
    glasslight(ctx, id, on, clicked, dl, x, y, w, h)
    if clicked then chosen = index end
    local pad = geometry.narrow and M.WN_CARD_COMPACT_PAD or M.WN_CARD_PAD
    local compact_size = geometry.narrow and M.WN_CARD_SMALL_FS or M.WN_CARD_FS
    local title = feature.card_title or feature.title
    compact_size = title_size(ctx, title, compact_size, compact_width - pad * 2)
    local large_size = title_size(ctx, title, M.WN_CARD_LARGE_FS,
      open_width - pad * 2)
    local size = compact_size + (large_size - compact_size) * grow
    reaper.ImGui_DrawList_PushClipRect(dl, x + pad, y + pad,
      x + w - pad, y + h - pad, true)
    -- Draw at the interpolated size so title growth does not jump in whole pixels.
    local pushed_title = font(ctx, M.WN_CARD_LARGE_FS, true)
    reaper.ImGui_DrawList_AddTextEx(dl, nil, size, x + pad, y + pad,
      on and T.TEXT_PRIMARY or T.TEXT_SECONDARY, title)
    if pushed_title then reaper.ImGui_PopFont(ctx) end
    -- Keep wrapping at the destination width while the card changes size.
    if on and grow > .65 and feature.overview then
      local pushed = font(ctx, M.WN_DESCRIPTION_FS)
      local copy, copy_h = wrapped_text(ctx, feature.overview, target.w - pad * 2)
      if pushed then reaper.ImGui_PopFont(ctx) end
      text(ctx, dl, x + pad, y + h - pad - copy_h, copy, M.WN_DESCRIPTION_FS,
        theme.fade(T.TEXT_PRIMARY, (grow - .65) / .35))
    end
    reaper.ImGui_DrawList_PopClipRect(dl)
  end
  if chosen and chosen ~= selected then
    -- Seed all destinations on the click's frame so the next redraw already moves.
    navigation.feature_height(width, #features, chosen)
    for index, target in ipairs(geometry.cards) do
      card_motion(ctx, namespace .. '_feature_' .. index, target, chosen == index, duration)
    end
  end
  reaper.ImGui_SetCursorScreenPos(ctx, x0, y0)
  reaper.ImGui_Dummy(ctx, width, height)
  return chosen
end

local function intro_dimensions(ctx, features, width)
  if intro_cache and intro_cache.width == width and intro_cache.scale == theme.scale then
    return intro_cache.height, intro_cache.rail, intro_cache.heading
  end
  local rail = math.min(M.WN_TOPIC_RAIL, width * .32)
  local body_width = math.max(1, width - rail - M.WN_TOPIC_GAP - M.WN_CARD_PAD * 2)
  local heading_h, body_h, rows = 0, 0, 1
  local pushed = font(ctx, M.WN_HEADING_FS, true)
  for _, feature in ipairs(features) do
    for _, topic in ipairs(feature.topics) do
      local _, h = wrapped_text(ctx, topic.title, body_width)
      heading_h = math.max(heading_h, h)
    end
    rows = math.max(rows, math.min(4, #feature.topics))
  end
  if pushed then reaper.ImGui_PopFont(ctx) end
  pushed = font(ctx, M.WN_TOPIC_BODY_FS)
  for _, feature in ipairs(features) do
    for _, topic in ipairs(feature.topics) do
      local _, h = wrapped_text(ctx, topic.body, body_width)
      body_h = math.max(body_h, h)
    end
  end
  if pushed then reaper.ImGui_PopFont(ctx) end
  local height = math.max(rows * M.WN_TOPIC_ROW, heading_h + body_h + M.ITEM_SPACING_Y)
    + M.WN_CARD_PAD + M.ITEM_SPACING_Y
  intro_cache = { width = width, scale = theme.scale, height = height, rail = rail, heading = heading_h }
  return height, rail, heading_h
end

function navigation.topics(ctx, content, feature_index, active, namespace)
  local feature = content.features[feature_index]
  local width = reaper.ImGui_GetContentRegionAvail(ctx)
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  local height, rail, heading_h = intro_dimensions(ctx, content.features, width)
  local pad, gap = M.WN_CARD_PAD, M.WN_TOPIC_GAP
  local selected, choice = active
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  if #feature.topics > 1 then
    reaper.ImGui_SetCursorScreenPos(ctx, x0 + pad, y0 + pad)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
    local visible = reaper.ImGui_BeginChild(ctx, 'release_topic_index', rail,
      height - pad - M.ITEM_SPACING_Y, 0, reaper.ImGui_WindowFlags_NoScrollWithMouse())
    reaper.ImGui_PopStyleVar(ctx)
    if visible then
      local row_x, row_y = reaper.ImGui_GetCursorScreenPos(ctx)
      local row_w = reaper.ImGui_GetContentRegionAvail(ctx)
      local row_h, number_w = M.WN_TOPIC_ROW, M.WN_TOPIC_NUMBER
      local child_dl = reaper.ImGui_GetWindowDrawList(ctx)
      local highlight = widgets.motion_value(ctx, namespace .. '_topic_y_' .. feature_index,
        (active - 1) * row_h, theme.motion.SETTINGS_TAB_GROW)
      reaper.ImGui_DrawList_AddRectFilled(child_dl, row_x, row_y + highlight,
        row_x + row_w, row_y + highlight + row_h, T.ACTIVE_CONTROL_FILL, theme.scale * 2)
      for index, topic in ipairs(feature.topics) do
        local id = namespace .. '_topic_' .. feature_index .. '_' .. index
        local y = row_y + (index - 1) * row_h
        reaper.ImGui_SetCursorScreenPos(ctx, row_x, y)
        local clicked = reaper.ImGui_InvisibleButton(ctx, id, row_w, row_h)
        if clicked then choice, selected = index, index end
        local on = selected == index
        if reaper.ImGui_IsItemHovered(ctx) and not on then
          reaper.ImGui_DrawList_AddRectFilled(child_dl, row_x, y, row_x + row_w,
            y + row_h, T.FILL_QUATERNARY, theme.scale * 2)
        end
        local progress = widgets.motion_event(ctx, id .. '_tumble', on,
          theme.motion.WN_TOPIC_TUMBLE, clicked)
        local nx, ny = row_x + theme.scale * 3, y + (row_h - number_w) / 2
        if progress then
          reaper.ImGui_DrawList_AddRect(child_dl, nx, ny, nx + number_w, ny + number_w,
            theme.fade(T.ACCENT, .55 * (1 - progress)), theme.scale * 3)
        end
        local pushed = font(ctx, M.WN_TOPIC_NUMBER_FS)
        local digits = string.format('%02d', index)
        local tw, th = reaper.ImGui_CalcTextSize(ctx, digits)
        reaper.ImGui_DrawList_PushClipRect(child_dl, nx, ny, nx + number_w, ny + number_w, true)
        reaper.ImGui_DrawList_AddText(child_dl, nx + (number_w - tw) / 2,
          ny + (number_w - th) / 2, on and T.ACCENT_HOVER or T.TEXT_TERTIARY, digits)
        reaper.ImGui_DrawList_PopClipRect(child_dl)
        if pushed then reaper.ImGui_PopFont(ctx) end
        local tx = nx + number_w + M.ITEM_SPACING_X
        pushed = font(ctx, M.WN_TOPIC_FS)
        local label = widgets.ellipsize(ctx, topic.title, row_w - (tx - row_x) - theme.scale * 3)
        local _, th2 = reaper.ImGui_CalcTextSize(ctx, label)
        reaper.ImGui_DrawList_AddText(child_dl, tx, y + (row_h - th2) / 2,
          on and T.TEXT_PRIMARY or T.TEXT_SECONDARY, label)
        if progress and progress < .85 then
          local gx = tx + (row_w - (tx - row_x)) * progress / .85
          reaper.ImGui_DrawList_AddLine(child_dl, gx, y + row_h * .25, gx, y + row_h * .75,
            theme.fade(T.ACCENT, .28 * (1 - progress)), theme.scale)
        end
        if pushed then reaper.ImGui_PopFont(ctx) end
      end
      if choice and choice ~= active then
        widgets.motion_value(ctx, namespace .. '_topic_y_' .. feature_index,
          (choice - 1) * row_h, theme.motion.SETTINGS_TAB_GROW)
      end
      reaper.ImGui_EndChild(ctx)
    end
    reaper.ImGui_DrawList_AddLine(dl, x0 + pad + rail + gap / 2, y0 + pad,
      x0 + pad + rail + gap / 2, y0 + height - M.ITEM_SPACING_Y, T.STROKE_SECONDARY)
  end
  local topic = feature.topics[selected]
  local tx = x0 + pad + (#feature.topics > 1 and rail + gap or 0)
  local available = width - (tx - x0) - pad
  -- Topic copy is deliberately immediate, including the full-width single-topic case.
  text(ctx, dl, tx, y0 + pad, topic.title, M.WN_HEADING_FS, T.TEXT_PRIMARY, true, available)
  text(ctx, dl, tx, y0 + pad + heading_h + M.ITEM_SPACING_Y, topic.body,
    M.WN_TOPIC_BODY_FS, T.TEXT_SECONDARY, false, available)
  reaper.ImGui_SetCursorScreenPos(ctx, x0, y0)
  reaper.ImGui_Dummy(ctx, width, height)
  return choice
end

return navigation
