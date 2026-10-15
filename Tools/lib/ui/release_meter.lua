-- Silent metering example using the live panel painter and isolated display state.
local theme = require('ui.theme')
local meter_panel = require('ui.meter_panel')
local preferences = require('core.meter_preferences')
local session = require('core.meter_session')
local warnings = require('core.meter_warnings')
local story = require('core.release_meter_demo')
local pointer = require('ui.release_pointer')
local signal = require('ui.release_meter_signal')
local settings = require('ui.meter_settings')
local scope = require('ui.release_preview_scope')
local customization_layout = require('core.release_customization_layout')
local metering = require('metering')

local T, M = theme.tokens, theme.metrics
local meter = {}
-- Compact row spacing leaves room for readable text on the longer settings page.
local SETTINGS_SPACING = {FRAME_PAD_Y=.25, ITEM_SPACING_Y=.5, WINDOW_PAD=.75}

local maxima = {}
local m_max, s_max
for index, point in ipairs(signal.points) do
  if point.m then m_max = math.max(m_max or point.m, point.m) end
  if point.s then s_max = math.max(s_max or point.s, point.s) end
  local crest
  if point.peak_l and point.rms_l and point.peak_r and point.rms_r then
    crest = math.max(point.peak_l - point.rms_l, point.peak_r - point.rms_r)
  end
  maxima[index] = {m=m_max, s=s_max, tp=point.tp_max, crest=crest}
end

local function model_new()
  local model = session.new()
  model.prefs = preferences.defaults()
  model.prefs.history_position = 'Beside Meters'
  model.prefs.history_fill = 'Short-Term'
  model.prefs.history_colours = false
  model.prefs.peak_measurement = 'Sample Peak'
  model.prefs.show_lra = false
  model.prefs.seconds = 10
  model.prefs.ms_hold, model.prefs.lr_hold = 0, 0
  model.attached, model.playing, model.valid = true, true, true
  model.values, model.display = {}, {}
  model.history, model.history_head = {}, 1
  for index, point in ipairs(signal.points) do model.history[index] = point end
  model.history_count = 0
  model.warnings = warnings.new()
  metering.prepare_history_draw(model)
  return model
end

function meter.new()
  return {model=model_new(), script={}, targets={}, history_tip={}}
end

function meter.update(demo, topic, elapsed)
  topic = topic or 'meter_overview'
  local model = demo.model
  local step = story.sample(topic, elapsed, demo.script)
  local restarted = demo.topic ~= topic or (demo.phase and step.phase < demo.phase)
    or (demo.last_elapsed and elapsed < demo.last_elapsed)
  local dt = demo.last_elapsed and math.max(0, elapsed-demo.last_elapsed) or 0
  if restarted then
    model.display = {}
    demo.section_popup_open = nil
    dt = 0
  end
  demo.topic, demo.phase, demo.last_elapsed = topic, step.phase, elapsed

  if demo.history_tip_slot then
    model.history[demo.history_tip_slot] = signal.points[demo.history_tip_slot]
    demo.history_tip_slot = nil
  end
  local custom = topic == 'meter_customization'
  -- Start the visible history after both loudness windows have settled.
  local start = custom and 3.1 or 3.1 + model.prefs.seconds
  local recording_time = start + step.phase % (signal.duration - start)
  local index, point = story.readings(signal, recording_time, model.values)
  if not point then return demo end
  model.history_count = index
  model.history[index] = point
  local tip = story.history_tip(signal, recording_time, index, demo.history_tip)
  if tip then
    model.history[index + 1] = tip
    model.history_count = index + 1
    demo.history_tip_slot = index + 1
  end
  model.elapsed, model.view_elapsed = point.t, recording_time
  preferences.set(model.prefs, 'show_history', not custom)
  preferences.set(model.prefs, 'show_lr', not custom or step.show_lr)
  preferences.set(model.prefs, 'extra_readings', custom and step.extra_readings or false)
  preferences.set(model.prefs, 'show_target', not custom or step.show_target)
  preferences.set(model.prefs, 'show_i', not custom or step.show_i)
  local peak = maxima[index]
  model.m_max, model.s_max, model.tp_max = peak.m, peak.s, peak.tp
  model.values.crest = peak.crest
  session.animate(model, theme.motion.enabled and dt or .25, -48)
  return demo
end

-- Passive entry point for the combined Reference View example.
function meter.paint(ctx, demo, x, y, width, height, presentation, footer_height)
  local geometry = meter_panel.measure(width, height, demo.model.prefs, nil, nil, footer_height)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_DisabledAlpha(), 1)
  reaper.ImGui_BeginDisabled(ctx)
  meter_panel.paint(ctx, demo.model, geometry, x, y, presentation or {})
  reaper.ImGui_EndDisabled(ctx)
  reaper.ImGui_PopStyleVar(ctx)
  return geometry
end

local function mix(a, b, amount)
  return a+(b-a)*amount
end

local function guide_position(demo, settings_x, settings_y, settings_w)
  local home = {x=settings_x-55*theme.scale, y=settings_y+40*theme.scale}
  local from = demo.targets[demo.script.from] or home
  local to = demo.targets[demo.script.to] or home
  return mix(from.x, to.x, demo.script.progress),
    mix(from.y, to.y, demo.script.progress)
end

local function paint_settings_pointer(ctx, demo, x, y, width, height)
  local px, py = guide_position(demo, x, y, width)
  demo.pointer_x, demo.pointer_y = px, py
  local foreground = reaper.ImGui_GetForegroundDrawList(ctx)
  reaper.ImGui_DrawList_PushClipRect(foreground, x, y, x+width, y+height, true)
  pointer.paint(foreground, px, py, demo.script.pulse)
  reaper.ImGui_DrawList_PopClipRect(foreground)
end

local function draw_customization(ctx, demo, x, y, width, height)
  -- Measure with the same font and spacing used by the controls, rather than
  -- the larger release-note reading font surrounding this preview.
  local settings_height = scope.paint(ctx,1,function()
    return math.max(settings.gallery_measure(ctx,demo.model,1),
      settings.gallery_measure(ctx,demo.model,2))
  end, SETTINGS_SPACING)
  local fit=customization_layout.measure(width,height,M.SPECTRUM_SETTINGS_W,
    settings_height+2*theme.scale,280*theme.scale,M.WINDOW_PAD,16*theme.scale)
  local display=fit.display
  -- Extra Readings needs its own width allowance, without shrinking the settings.
  local meter_ratio=math.min(fit.ratio,display.w/(470*theme.scale))
  scope.paint(ctx, meter_ratio, function()
    meter.paint(ctx,demo,x+display.x,y+display.y,display.w,display.h)
  end)
  scope.paint(ctx, fit.ratio, function()
    local settings_x, settings_y = x+fit.settings.x,y+fit.settings.y
    demo.paint_pointer = paint_settings_pointer
    demo.pointer_x, demo.pointer_y = nil, nil
    settings.gallery_preview(ctx, demo.model,
      settings_x, settings_y, 'meter_customization', demo)
    local px, py = demo.pointer_x, demo.pointer_y
    if not px then px, py = guide_position(demo, settings_x, settings_y, fit.settings.w) end
    local foreground = reaper.ImGui_GetForegroundDrawList(ctx)
    reaper.ImGui_DrawList_PushClipRect(foreground, x, y, x+width, y+height, true)
    pointer.paint(foreground, px, py, demo.script.pulse)
    reaper.ImGui_DrawList_PopClipRect(foreground)
  end, SETTINGS_SPACING)
end

function meter.draw(ctx, _, demo, topic, elapsed, width, height)
  demo = meter.update(demo or meter.new(), topic, elapsed)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_PushClipRect(dl, x, y, x+width, y+height, true)
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x+width, y+height, T.BG_WINDOW)
  if topic == 'meter_customization' then
    draw_customization(ctx, demo, x, y, width, height)
  else
    local pad = M.WINDOW_PAD
    meter.paint(ctx, demo, x+pad, y+pad,
      math.max(1, width-pad*2), math.max(1, height-pad*2))
  end
  reaper.ImGui_DrawList_PopClipRect(dl)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_Dummy(ctx, width, height)
end

return meter
