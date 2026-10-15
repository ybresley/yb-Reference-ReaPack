-- Silent Stereo examples reuse the live scope and settings painters.
local theme = require('ui.theme')
local signal = require('ui.release_stereo_signal')
local stereo_demo = require('core.release_stereo_demo')
local stereo = require('ui.stereo')
local settings = require('ui.stereo_settings')
local preferences = require('core.stereo_preferences')
local pointer = require('ui.release_pointer')
local scope = require('ui.release_preview_scope')
local customization_layout = require('core.release_customization_layout')

local T, M = theme.tokens, theme.metrics
local release_stereo = {}
local SETTINGS_SPACING = {FRAME_PAD_Y=.25, ITEM_SPACING_Y=.5, WINDOW_PAD=.75}

function release_stereo.new()
  return {sample=stereo_demo.new(signal), prefs=preferences.defaults(), targets={}}
end

function release_stereo.update(value, topic, elapsed)
  value = value or release_stereo.new()
  value.scene = stereo_demo.advance(value.sample, topic, elapsed)
  value.prefs.show_correlation = topic == 'stereo_customization'
    and value.scene.show_correlation or false
  value.prefs.views.lissajous.brightness = topic == 'stereo_customization'
    and value.scene.brightness or 1
  return value
end

local function paint_scope(ctx, res, value, model, view, x, y, width, height, id)
  local state = {
    stereo=model, stereo_view=view, stereo_preferences=value.prefs,
    monitor_filter={system={available=true}},
  }
  reaper.ImGui_PushID(ctx, id)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_DisabledAlpha(), 1)
  reaper.ImGui_BeginDisabled(ctx)
  stereo.draw(ctx, state, width, height, res, nil, nil, nil, {hovered=false})
  reaper.ImGui_EndDisabled(ctx)
  reaper.ImGui_PopStyleVar(ctx)
  reaper.ImGui_PopID(ctx)
end

local function mix(a, b, amount)
  return a + (b-a) * amount
end

local function guide_position(value, x, y, width)
  local home = {x=x-55*theme.scale, y=y+40*theme.scale}
  local scene = value.scene
  local from = value.targets[scene.from] or home
  local to = value.targets[scene.to] or home
  return mix(from.x, to.x, scene.progress), mix(from.y, to.y, scene.progress)
end

local function paint_guide(dl, value, x, y)
  pointer.paint(dl, x, y, value.scene.click)
end

local function paint_settings_pointer(ctx, value, x, y, width, height)
  local px, py = guide_position(value, x, y, width)
  value.pointer_x, value.pointer_y = px, py
  local foreground = reaper.ImGui_GetForegroundDrawList(ctx)
  reaper.ImGui_DrawList_PushClipRect(foreground, x, y, x+width, y+height, true)
  paint_guide(foreground, value, px, py)
  reaper.ImGui_DrawList_PopClipRect(foreground)
end

local function draw_overview(ctx, res, value, x, y, width, height)
  local pad = M.WINDOW_PAD
  local ratio = math.min(1, (width-pad*2)/(692*theme.scale),
    (height-pad*2)/(355*theme.scale))
  scope.paint(ctx, math.max(.1, ratio), function()
    local s = theme.scale
    local panel = 332*s
    local gap = 20*s
    local left = x+(width-panel*2-gap)*.5
    local top = y+(height-panel-23*s)*.5
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    reaper.ImGui_DrawList_AddText(dl, left, top, T.TEXT_SECONDARY, 'Lissajous')
    reaper.ImGui_DrawList_AddText(dl, left+panel+gap, top, T.TEXT_SECONDARY, 'Polar Sample')
    paint_scope(ctx, res, value, value.sample.model, 'lissajous',
      left, top+23*s, panel, panel, 'stereo_overview_lissajous')
    paint_scope(ctx, res, value, value.sample.polar_model, 'polar_sample',
      left+panel+gap, top+23*s, panel, panel, 'stereo_overview_polar')
  end)
end

local function draw_customization(ctx, res, value, x, y, width, height)
  local state = {stereo=value.sample.model,stereo_view='lissajous',
    stereo_preferences=value.prefs}
  local settings_w,settings_h = scope.paint(ctx,1,function()
    return settings.gallery_measure(ctx,state)
  end, SETTINGS_SPACING)
  local fit=customization_layout.measure(width,height,settings_w,settings_h+2*theme.scale,
    280*theme.scale,M.WINDOW_PAD,16*theme.scale)
  scope.paint(ctx, fit.ratio, function()
    local display=fit.display
    paint_scope(ctx, res, value, value.sample.model, 'lissajous',
      x+display.x,y+display.y,display.w,display.h,'stereo_custom_scope')
    local sx, sy = x+fit.settings.x,y+fit.settings.y
    value.pointer_x, value.pointer_y = nil, nil
    value.paint_pointer = paint_settings_pointer
    settings.gallery_preview(ctx, state, sx, sy, 'stereo_customization', value)
    local px, py = value.pointer_x, value.pointer_y
    if not px then px, py = guide_position(value, sx, sy, fit.settings.w) end
    local foreground = reaper.ImGui_GetForegroundDrawList(ctx)
    reaper.ImGui_DrawList_PushClipRect(foreground, x, y, x+width, y+height, true)
    paint_guide(foreground, value, px, py)
    reaper.ImGui_DrawList_PopClipRect(foreground)
  end, SETTINGS_SPACING)
end

function release_stereo.draw(ctx, res, value, topic, elapsed, width, height)
  value = release_stereo.update(value, topic, elapsed)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_PushClipRect(dl, x, y, x+width, y+height, true)
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x+width, y+height, T.BG_WINDOW)
  if topic == 'stereo_overview' then
    draw_overview(ctx, res, value, x, y, width, height)
  elseif topic == 'stereo_customization' then
    draw_customization(ctx, res, value, x, y, width, height)
  else
    local pad = M.WINDOW_PAD
    local scene = value.scene
    local panel_x, panel_y = x+pad, y+pad
    local panel_w, panel_h = math.max(1, width-pad*2), math.max(1, height-pad*2)
    paint_scope(ctx, res, value, value.sample.model, scene.view,
      panel_x, panel_y, panel_w, panel_h, 'stereo_legacy_scope')
    if scene.pointer_x then
      pointer.paint(dl, panel_x+scene.pointer_x*panel_w,
        panel_y+scene.pointer_y*panel_h, scene.click)
    end
  end
  reaper.ImGui_DrawList_PopClipRect(dl)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_Dummy(ctx, width, height)
end

return release_stereo
