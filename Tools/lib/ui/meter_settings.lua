local theme = require('ui.theme')
local widgets = require('ui.widgets')
local tips = require('ui.tips')
local anchored_panel = require('ui.anchored_panel')
local focus = require('ui.focus')
local targets = require('core.meter_targets')
local preferences = require('core.meter_preferences')
local icons = require('ui.icons')

local settings = {}
local R, T, M = reaper, theme.tokens, theme.metrics
local ui = {open=false, page=1}
local preview_view, preview_targets
local pages = {'Display', 'Loudness', 'L/R', 'History', 'Appearance', 'Session'}
local SAVED_DISPLAY_HINT = 'One saved display setup. Restoring it keeps your playback rules and measurements.'
local RESET_HINT = 'Reset All Settings to Defaults to enable changes.'
-- Row counts match the controls in each group. Wrapped paragraphs are measured separately.
local PAGE_GROUPS = {
  {{'display_visible',5}},
  {{'loudness_bars',6},{'loudness_target',4}},
  {{'lr_levels',8}},
  {{'history_plot',6}},
  {{'appearance_style',4}},
  {{'session_runs',2},{'session_preset',3}},
}

local function measure_page(ctx, model, width, view)
  view = view or ui
  local pad, gap = M.WINDOW_PAD, M.ITEM_SPACING_Y
  local frame = R.ImGui_GetFrameHeight(ctx)
  local bold = theme.push_bold_font(ctx)
  local heading = R.ImGui_GetTextLineHeight(ctx)
  if bold then R.ImGui_PopFont(ctx) end
  local function text_height(text, inset)
    return select(2,R.ImGui_CalcTextSize(ctx,text,nil,nil,false,math.max(1,width-inset)))
  end
  local height = pad*2 + frame + gap*2
  local groups = {}
  for index, spec in ipairs(PAGE_GROUPS[view.page]) do
    local id, rows = spec[1], spec[2]
    local group_height = pad*2 + rows*frame + (rows-1)*gap
    if id == 'loudness_target' then
      group_height = group_height + gap + text_height(targets.details(targets.active(model.prefs)),pad*4)
    elseif id == 'session_preset' then
      group_height = group_height + gap + text_height(SAVED_DISPLAY_HINT,pad*4)
      if model.display_preset_error then
        group_height = group_height + gap + text_height(model.display_preset_error,pad*4)
      end
    end
    groups[id] = math.ceil(group_height)
    height = height + heading + gap + groups[id] + (index>1 and gap*2 or 0)
  end
  if model.preference_error then
    height = height + gap*2 + text_height(model.preference_error,pad*2) + text_height(RESET_HINT,pad*2)
    if view.page ~= 6 then height = height + gap + frame end
  end
  return math.ceil(height), groups
end

local OPTIONS = {
  mode = {{'dBFS','LUFS'}, {'K-20','K-20'}, {'K-14','K-14'}, {'K-12','K-12'}},
  colours = {{'Accent Fade','Accent Fade'}, {'Solid','Solid Accent'}, {'Coloured','Thresholds'}},
  range = {{'-36 LUFS',-36}, {'-48 LUFS',-48}, {'-60 LUFS',-60}},
  seconds = {{'5 s',5}, {'10 s',10}, {'15 s',15}, {'30 s',30}, {'60 s',60}},
  loudness_scale = {{'Expanded','Expanded'}, {'Target +9 LU','Target +9'}, {'Target +18 LU','Target +18'}},
  readings = {{'Absolute (LUFS)','Absolute'}, {'Relative (LU)','Relative'}},
  history_position = {{'Automatic','Automatic'}, {'Side by Side','Beside Meters'}, {'Stacked','Below Meters'}},
  tolerance = {{'Off',0}, {'±0.5 LU',.5}, {'±1 LU',1}, {'±2 LU',2}},
  ms_hold = {{'Off',0}, {'0.5 s',.5}, {'1.5 s',1.5}, {'3 s',3}, {'Until Restart',-1}},
  lr_contents = {{'RMS + Peak','RMS + Peak'}, {'Peak Only','Peak Only'}, {'RMS Only','RMS Only'}},
  peak_measurement = {{'True Peak','True Peak'}, {'Sample Peak','Sample Peak'}},
  target_difference_measurement = {
    {'Integrated','Integrated'}, {'Momentary','Momentary'}, {'Short-Term','Short-Term'}},
  lr_floor = {{'-48 dB',-48}, {'-60 dB',-60}, {'-90 dB',-90}},
  lr_hold = {{'Off',0}, {'0.5 s',.5}, {'1.5 s',1.5}, {'3 s',3}},
  peak_fall = {{'Fast','Fast'}, {'Normal','Normal'}, {'Slow','Slow'}},
  clip_hold = {{'Until Cleared',0}, {'0.5 s',.5}, {'2 s',2}},
  history_fill = {{'None','Off'}, {'Short-Term','Short-Term'}, {'Momentary','Momentary'}, {'Integrated','Integrated'}},
  yellow_lead = {{'3 LU Below',3}, {'5 LU Below',5}, {'6 LU Below',6}, {'9 LU Below',9}},
  red_span = {{'1 LU Above',1}, {'3 LU Above',3}, {'6 LU Above',6}},
  loop_reset = {{'Accumulate','Accumulate'}, {'Reset Each Pass','Start New Run'}},
}

local HINTS = {
  mode='K-system readings use sine-calibrated RMS. Listening-level calibration is separate.',
  peak_measurement='Chooses which peak measurement appears in the L/R bars, readings, hold marks and clipping warnings.',
  readings='Absolute shows LUFS. Relative shows LU above or below the target. Bar positions stay the same.',
  preset='Targets change the display only. Audio gain is unchanged.',
  history_position='Arranges the meters and history side by side or stacked. Automatic chooses based on the available space.',
  show_target='Shows the dotted target line on the meters and history.',
  tolerance='Shows a band around the target. This is a visual guide, not a compliance check.',
  extra_readings='Shows maxima above the meters, plus Crest Factor, RMS and Target Diff when space allows.',
  target_difference_measurement='Shows the chosen loudness measurement minus the target in LU. Positive values are above the target; negative values are below it. This does not change the audio.',
  ms_hold='Keeps momentary and short-term peak marks visible for the selected time, or until playback restarts.',
  clip_hold='Until Cleared keeps clipping marks until you clear warnings.',
  keep_integrated='Keeps the integrated reading visible after playback stops. Stopping and starting playback begins a new measurement. Jumping to another position during playback keeps the current measurement.',
  target='Custom loudness target in LUFS. Editing this value changes the selected preset to Custom.',
  ceiling='Warning threshold for the maximum true peak. This does not limit or change the audio.',
  yellow_lead='Starts fading from the accent colour to yellow this far below the target. Reaches yellow at the target.',
  red_span='Reaches full red this far above the target. The fade from yellow to red begins at the target.',
  loudness_scale='Expanded gives louder levels more space. Target +9 and +18 set the top of the scale that far above your target.',
  loop_reset='Controls whether the next loop pass starts a new measurement run. Full-file reference loops are detected on the next display update.',
}

local function set(key, value)
  return {type='meter_set_preference', key=key, value=value}
end

local function accept(current, result)
  return result or current
end

local function row_label(ctx, label, key, width)
  local x = R.ImGui_GetCursorPosX(ctx)
  local available = R.ImGui_GetContentRegionAvail(ctx)
  R.ImGui_AlignTextToFramePadding(ctx)
  R.ImGui_TextColored(ctx, T.TEXT_SECONDARY, label)
  tips.show(ctx, R.ImGui_IsItemHovered(ctx), HINTS[key], 'meter_hint_' .. key)
  R.ImGui_SameLine(ctx, x + available - width)
end

local function record_target(key)
  if not preview_targets then return end
  local x0, y0 = R.ImGui_GetItemRectMin(preview_targets.ctx)
  local x1, y1 = R.ImGui_GetItemRectMax(preview_targets.ctx)
  preview_targets[key] = {x=(x0+x1)*.5,y=(y0+y1)*.5,
    left=x0,top=y0,right=x1,bottom=y1}
end

local function option_row(ctx, prefs, key, label, disabled, disabled_hint)
  local width = M.SPECTRUM_OPTION_W
  row_label(ctx, label, key, width)
  if disabled then R.ImGui_BeginDisabled(ctx) end
  R.ImGui_SetNextItemWidth(ctx, width)
  local current = prefs[key]
  local preview = tostring(current)
  for _, entry in ipairs(OPTIONS[key]) do
    if entry[2] == current then preview = entry[1]; break end
  end
  local action
  if R.ImGui_BeginCombo(ctx, '##meter_' .. key, preview) then
    for _, entry in ipairs(OPTIONS[key]) do
      local available = key ~= 'history_fill' or entry[2] == 'Off'
        or (entry[2] == 'Momentary' and prefs.history_m)
        or (entry[2] == 'Short-Term' and prefs.history_s)
        or (entry[2] == 'Integrated' and prefs.history_integrated)
      if not available then R.ImGui_BeginDisabled(ctx) end
      if R.ImGui_Selectable(ctx, entry[1], entry[2] == current) and not disabled and available then
        action = set(key, entry[2])
      end
      if not available then R.ImGui_EndDisabled(ctx) end
    end
    R.ImGui_EndCombo(ctx)
  end
  record_target(key)
  if disabled then R.ImGui_EndDisabled(ctx) end
  tips.show(ctx, R.ImGui_IsItemHovered(ctx, R.ImGui_HoveredFlags_AllowWhenDisabled()),
    disabled and (disabled_hint or 'Show this meter group to change the setting.')
      or HINTS[key], 'meter_option_' .. key)
  return action
end

local function switch_row(ctx, prefs, key, label, disabled, disabled_hint)
  row_label(ctx, label, key, M.SET_SWITCH_W)
  local on = prefs[key] == true
  local clicked = widgets.switch(ctx, 'meter_' .. key, on,
      disabled and disabled_hint or HINTS[key], not disabled)
  record_target(key)
  if clicked then return set(key, not on) end
end

local function percent_row(ctx, prefs, key, label, low, high, default, disabled)
  row_label(ctx, label, key, M.SPECTRUM_OPTION_W)
  if disabled then R.ImGui_BeginDisabled(ctx) end
  local number_width = R.ImGui_CalcTextSize(ctx, '150%')
  local next_value, commit = widgets.step_slider(ctx, 'meter_' .. key, prefs[key] * 100,
    {min=low, max=high, step=1, tick_step=10,
      width=M.SPECTRUM_OPTION_W - number_width - M.ITEM_SPACING_X})
  local reset = widgets.wants_reset(ctx)
  R.ImGui_SameLine(ctx)
  R.ImGui_AlignTextToFramePadding(ctx)
  R.ImGui_TextColored(ctx, T.TEXT_PRIMARY,
    string.format('%d%%', math.floor((next_value or prefs[key] * 100) + .5)))
  if disabled then R.ImGui_EndDisabled(ctx) end
  if disabled then return end
  if reset then next_value, commit = default * 100, true end
  if next_value then
    local action = set(key, next_value / 100)
    action.commit = commit == true
    return action
  end
end

local function group(ctx, id, title, first, draw)
  local view = preview_view or ui
  local opened, child = widgets.begin_settings_group(ctx, 'meter_' .. id, title, first, view.group_heights[id])
  local action
  if opened then action = draw() end
  widgets.end_settings_group(ctx, child)
  return action
end

local function target_row(ctx, prefs)
  row_label(ctx, 'Target Preset', 'preset', M.SPECTRUM_OPTION_W)
  R.ImGui_SetNextItemWidth(ctx, M.SPECTRUM_OPTION_W)
  local selected = targets.active(prefs)
  local action
  if R.ImGui_BeginCombo(ctx, '##meter_preset',
      selected and selected.name or 'Custom', R.ImGui_ComboFlags_HeightLarge()) then
    if R.ImGui_Selectable(ctx, 'Custom', not selected) then action = set('preset', '') end
    for group_id, title in ipairs(targets.groups) do
      R.ImGui_Separator(ctx)
      R.ImGui_TextDisabled(ctx, title)
      for _, entry in ipairs(targets.presets) do
        if entry.group == group_id then
          local unavailable = entry.target == nil
          if unavailable then R.ImGui_BeginDisabled(ctx) end
          local label = entry.name .. (unavailable and ' · Unavailable'
            or string.format(' · %g LUFS', entry.target))
          if R.ImGui_Selectable(ctx, label .. '##' .. entry.id, selected == entry)
              and not unavailable then action = set('preset', entry.id) end
          tips.show(ctx, R.ImGui_IsItemHovered(ctx, R.ImGui_HoveredFlags_AllowWhenDisabled()),
            targets.details(entry), 'meter_target_' .. entry.id)
          if unavailable then R.ImGui_EndDisabled(ctx) end
        end
      end
    end
    R.ImGui_EndCombo(ctx)
  end
  return action
end

local function input_row(ctx, prefs, key, label, low, high)
  row_label(ctx, label, key, M.SPECTRUM_OPTION_W)
  R.ImGui_SetNextItemWidth(ctx, M.SPECTRUM_OPTION_W)
  local format = key=='target' and '%.1f LUFS' or '%.1f dBTP'
  local changed, value = R.ImGui_InputDouble(ctx, '##meter_' .. key, prefs[key], 0, 0, format)
  if changed and value >= low and value <= high then return set(key, value) end
end

local function segments(ctx, prefs, id, label, entries, disabled)
  row_label(ctx, label, id, M.SPECTRUM_OPTION_W)
  local choices = {}
  for _, entry in ipairs(entries) do
    local trial = {}
    for key,value in pairs(prefs) do trial[key]=value end
    local _,err = preferences.set(trial,entry[1],not prefs[entry[1]])
    choices[#choices+1] = {key=entry[1], label=entry[2], on=prefs[entry[1]] == true,
      enabled=not disabled and not err, tip=err or entry[3]}
  end
  local key = widgets.multi_switch(ctx, 'meter_' .. id, choices, M.SPECTRUM_OPTION_W)
  if preview_targets then
    local x0, y0 = R.ImGui_GetItemRectMin(ctx)
    local x1, y1 = R.ImGui_GetItemRectMax(ctx)
    local part = M.SPECTRUM_OPTION_W / #choices
    for index, choice in ipairs(choices) do
      preview_targets[choice.key] = {x=x1-M.SPECTRUM_OPTION_W+(index-.5)*part,
        y=(y0+y1)*.5,left=x1-M.SPECTRUM_OPTION_W+(index-1)*part,
        top=y0,right=x1-M.SPECTRUM_OPTION_W+index*part,bottom=y1}
    end
  end
  if key then return set(key, not prefs[key]) end
end

local function display_page(ctx, prefs)
  return group(ctx, 'display_visible', 'Display', true, function()
    local result = segments(ctx,prefs,'panels','Panels',
      {{'show_meters','Meters'},{'show_history','History'}})
    result = accept(result, segments(ctx,prefs,'meter_groups','Meters',
      {{'show_loudness','Loudness'},{'show_lr','L/R'}}, not prefs.show_meters))
    result = accept(result, option_row(ctx,prefs,'history_position','Panel Layout',not prefs.show_history))
    result = accept(result, switch_row(ctx,prefs,'extra_readings','Extra Readings'))
    result = accept(result, option_row(ctx,prefs,'target_difference_measurement','Target Diff',
      not prefs.extra_readings, 'Turn on Extra Readings to change this setting.'))
    return result
  end)
end

local function loudness_page(ctx, prefs)
  local disabled = not prefs.show_loudness or not prefs.show_meters
  local no_display = disabled and not prefs.show_history
  local action = group(ctx, 'loudness_bars', 'Meters', true, function()
    local result = segments(ctx,prefs,'loudness_meters','Show',
      {{'show_m','M','Momentary'},{'show_s','S','Short-Term'},
       {'show_i','I','Integrated'},{'show_lra','LRA','Loudness Range'}},disabled)
    result = accept(result, switch_row(ctx,prefs,'show_target','Target Line',no_display))
    result = accept(result, option_row(ctx,prefs,'loudness_scale','Scale',no_display))
    result = accept(result, option_row(ctx,prefs,'range','Scale Bottom',no_display or prefs.loudness_scale~='Expanded'))
    result = accept(result, option_row(ctx,prefs,'readings','Value Units',no_display))
    result = accept(result, option_row(ctx,prefs,'ms_hold','Peak Hold',disabled))
    return result
  end)
  return accept(action, group(ctx, 'loudness_target', 'Target', false, function()
    local result = target_row(ctx,prefs)
    result = accept(result,input_row(ctx,prefs,'target','Custom Target',-60,0))
    result = accept(result,input_row(ctx,prefs,'ceiling','True-Peak Warning',-24,3))
    result = accept(result,option_row(ctx,prefs,'tolerance','Target Tolerance'))
    R.ImGui_PushTextWrapPos(ctx,0)
    R.ImGui_TextDisabled(ctx,targets.details(targets.active(prefs)))
    R.ImGui_PopTextWrapPos(ctx)
    return result
  end))
end

local function lr_page(ctx,prefs)
  return group(ctx,'lr_levels','Levels',true,function()
    local disabled = not prefs.show_meters or not prefs.show_lr
    local action = option_row(ctx,prefs,'mode','Scale',disabled)
    action = accept(action,option_row(ctx,prefs,'lr_contents','Bar Contents',disabled))
    action = accept(action,option_row(ctx,prefs,'peak_measurement','Peak Measurement',disabled))
    action = accept(action,option_row(ctx,prefs,'lr_floor','Floor',disabled))
    action = accept(action,option_row(ctx,prefs,'lr_hold','Peak Hold',disabled))
    action = accept(action,option_row(ctx,prefs,'peak_fall','Peak Fall',disabled or prefs.lr_hold==0))
    action = accept(action,switch_row(ctx,prefs,'show_clipping','Show Clipping',disabled))
    action = accept(action,option_row(ctx,prefs,'clip_hold','Clipping Hold',disabled or not prefs.show_clipping))
    return action
  end)
end

local function history_page(ctx,prefs)
  return group(ctx,'history_plot','History',true,function()
    local disabled = not prefs.show_history
    local action = segments(ctx,prefs,'history_lines','Lines',
      {{'history_m','M','Momentary'},{'history_s','S','Short-Term'},{'history_integrated','I','Integrated'}},disabled)
    action = accept(action,option_row(ctx,prefs,'seconds','Time Window',disabled))
    action = accept(action,option_row(ctx,prefs,'history_fill','Fill Under',disabled))
    action = accept(action,percent_row(ctx,prefs,'history_opacity','Fill Opacity',0,50,.22,disabled or prefs.history_fill=='Off'))
    action = accept(action,switch_row(ctx,prefs,'history_colours','Loudness Colours',disabled or prefs.colours~='Accent Fade',
      'Choose Accent Fade to colour the short-term line and its fill by level.'))
    action = accept(action,switch_row(ctx,prefs,'history_legend','Show Legend',disabled))
    return action
  end)
end

local function appearance_page(ctx,prefs)
  return group(ctx,'appearance_style','Colour',true,function()
    local action = option_row(ctx,prefs,'colours','Meter Colours')
    action = accept(action,option_row(ctx,prefs,'yellow_lead','Yellow Fade Start',prefs.colours~='Accent Fade'))
    action = accept(action,option_row(ctx,prefs,'red_span','Red Fade End',prefs.colours~='Accent Fade'))
    action = accept(action,switch_row(ctx,prefs,'lr_shading','L/R Shading',not prefs.show_meters or not prefs.show_lr))
    return action
  end)
end

local function session_page(ctx,model,failed)
  local prefs = model.prefs
  if failed then R.ImGui_BeginDisabled(ctx) end
  local action = group(ctx,'session_runs','Playback',true,function()
    local result = switch_row(ctx,prefs,'keep_integrated','Keep Integrated After Stop')
    result = accept(result,option_row(ctx,prefs,'loop_reset','On Loop'))
    return result
  end)
  if failed then R.ImGui_EndDisabled(ctx) end
  action = accept(action,group(ctx,'session_preset','Saved Display',false,function()
    local result
    local width = R.ImGui_GetContentRegionAvail(ctx)
    R.ImGui_PushTextWrapPos(ctx,0)
    R.ImGui_TextDisabled(ctx,SAVED_DISPLAY_HINT)
    R.ImGui_PopTextWrapPos(ctx)
    if failed then R.ImGui_BeginDisabled(ctx) end
    if R.ImGui_Button(ctx,'Save Current Display',width) and not failed then result={type='meter_save_display_preset'} end
    if failed or not model.saved_display_preset then R.ImGui_BeginDisabled(ctx) end
    if R.ImGui_Button(ctx,'Restore Saved Display',width) and not failed and model.saved_display_preset then
      result={type='meter_load_display_preset'}
    end
    if failed or not model.saved_display_preset then R.ImGui_EndDisabled(ctx) end
    if failed then R.ImGui_EndDisabled(ctx) end
    if model.display_preset_error then
      R.ImGui_PushTextWrapPos(ctx,0)
      R.ImGui_TextColored(ctx,T.DANGER_RED,model.display_preset_error)
      R.ImGui_PopTextWrapPos(ctx)
    end
    if R.ImGui_Button(ctx,'Reset All Settings to Defaults',width) then result={type='meter_reset_settings'} end
    return result
  end))
  return action
end

local DRAW_PAGE = {
  function(ctx, model) return display_page(ctx, model.prefs) end,
  function(ctx, model) return loudness_page(ctx, model.prefs) end,
  function(ctx, model) return lr_page(ctx, model.prefs) end,
  function(ctx, model) return history_page(ctx, model.prefs) end,
  function(ctx, model) return appearance_page(ctx, model.prefs) end,
  session_page,
}

local function section_items(ctx, view)
  for i,name in ipairs(pages) do
    if R.ImGui_Selectable(ctx,name,view.page==i) and i ~= view.page then
      view.next_page=i
    end
    if preview_view then
      record_target('section_' .. name:lower())
    end
  end
  if view.paint_popup_pointer then
    local px, py = R.ImGui_GetWindowPos(ctx)
    local pw, ph = R.ImGui_GetWindowSize(ctx)
    view.paint_popup_pointer(ctx, view.preview, px, py, pw, ph)
  end
end

local function draw_content(ctx, model, res, view)
  view = view or ui
  local frame = R.ImGui_GetFrameHeight(ctx)
  local width = R.ImGui_GetContentRegionAvail(ctx)
  R.ImGui_SetNextItemWidth(ctx,width-2*(frame+M.ITEM_SPACING_X))
  local section_open = R.ImGui_BeginCombo(ctx,'##meter_section',pages[view.page])
  if section_open then
    section_items(ctx, view)
    R.ImGui_EndCombo(ctx)
  end
  record_target('section')
  if preview_view and (view.section_visible or view.select_page) then
    local rect = preview_targets.section
    R.ImGui_SetNextWindowPos(ctx, rect.left, rect.bottom, R.ImGui_Cond_Always())
    R.ImGui_SetNextWindowSize(ctx, rect.right-rect.left,
      #pages*R.ImGui_GetTextLineHeight(ctx)+(#pages-1)*M.ITEM_SPACING_Y+M.WINDOW_PAD*2,
      R.ImGui_Cond_Always())
    -- A separate input-free window looks like the selector's menu without
    -- entering ImGui's popup stack or intercepting the user's other menus.
    local flags = R.ImGui_WindowFlags_NoInputs() | R.ImGui_WindowFlags_NoNav()
      | R.ImGui_WindowFlags_NoSavedSettings() | R.ImGui_WindowFlags_NoTitleBar()
      | R.ImGui_WindowFlags_NoResize() | R.ImGui_WindowFlags_NoMove()
      | R.ImGui_WindowFlags_NoCollapse() | R.ImGui_WindowFlags_NoScrollbar()
      | R.ImGui_WindowFlags_NoFocusOnAppearing()
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_WindowBg(), T.BG_POPUP)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(), T.STROKE_SECONDARY)
    local menu = R.ImGui_Begin(ctx,'##meter_gallery_section_' .. view.preview_id,nil,flags)
    R.ImGui_PopStyleColor(ctx,2)
    if menu then
      section_items(ctx, view)
      R.ImGui_End(ctx)
    end
  end
  R.ImGui_SameLine(ctx)
  local reset_page = icons.button(ctx,res and res.icon_font,'meter_reset_page','rotate-ccw',
    {size=frame,fallback=icons.draw_reset,tip='Reset '..pages[view.page]..' settings to defaults'})
  R.ImGui_SameLine(ctx)
  local closed = widgets.close_button(ctx, 'meter_settings_close')
  R.ImGui_SetCursorPosY(ctx,R.ImGui_GetCursorPosY(ctx)+M.ITEM_SPACING_Y)
  local failed = model.preference_error ~= nil
  if failed and view.page ~= 6 then R.ImGui_BeginDisabled(ctx) end
  local action = DRAW_PAGE[view.page](ctx, model, failed)
  if reset_page and not failed then action={type='meter_reset_page',page=pages[view.page]} end
  if failed and view.page ~= 6 then R.ImGui_EndDisabled(ctx) end
  if failed then
    R.ImGui_PushTextWrapPos(ctx, 0)
    R.ImGui_TextColored(ctx, T.DANGER_RED, model.preference_error)
    R.ImGui_TextDisabled(ctx, RESET_HINT)
    R.ImGui_PopTextWrapPos(ctx)
    if view.page ~= 6 and R.ImGui_Button(ctx, 'Reset All Settings to Defaults',
        R.ImGui_GetContentRegionAvail(ctx)) then
      action = {type='meter_reset_settings'}
    end
  end
  return action, closed
end

function settings.is_open()
  return ui.open
end

function settings.gallery_measure(ctx, model, page)
  local height = measure_page(ctx, model, M.SPECTRUM_SETTINGS_W, {page=page})
  return height
end

function settings.update_anchor(anchor)
  ui.anchor = anchor
end

-- The gallery reuses real settings sections with separate view state and inert
-- controls. Target rectangles let its scripted pointer follow real items.
function settings.gallery_preview(ctx, model, x, y, id, preview)
  preview = preview or {}
  preview.targets = preview.targets or {}
  preview.targets.ctx = ctx
  local script = preview.script or {}
  local view = {page=script.settings_page or 1,
    section_visible=script.section_open, select_page=script.section_select,
    paint_popup_pointer=preview.paint_pointer, preview=preview,
    preview_id=tostring(id or 'preview')}
  local width = M.SPECTRUM_SETTINGS_W
  local height
  height, view.group_heights = measure_page(ctx, model, width, view)
  R.ImGui_SetNextWindowPos(ctx, x, y, R.ImGui_Cond_Always())
  R.ImGui_SetNextWindowSize(ctx, width, height, R.ImGui_Cond_Always())
  local flags = R.ImGui_WindowFlags_NoTitleBar() | R.ImGui_WindowFlags_NoResize()
    | R.ImGui_WindowFlags_NoCollapse() | R.ImGui_WindowFlags_NoSavedSettings()
    | R.ImGui_WindowFlags_NoScrollbar() | R.ImGui_WindowFlags_NoScrollWithMouse()
  if R.ImGui_WindowFlags_NoDocking then flags = flags | R.ImGui_WindowFlags_NoDocking() end
  if R.ImGui_WindowFlags_NoInputs then flags = flags | R.ImGui_WindowFlags_NoInputs() end
  if R.ImGui_WindowFlags_NoNav then flags = flags | R.ImGui_WindowFlags_NoNav() end
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_WindowBg(), T.BG_WINDOW)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(), T.STROKE_SECONDARY)
  local opened = R.ImGui_Begin(ctx, '##meter_settings_gallery_' .. tostring(id or 'preview'), nil, flags)
  R.ImGui_PopStyleColor(ctx, 2)
  if opened then
    local alpha = R.ImGui_GetStyleVar(ctx, R.ImGui_StyleVar_Alpha())
    R.ImGui_BeginDisabled(ctx)
    R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_Alpha(), alpha)
    preview_view, preview_targets = view, preview.targets
    local result = table.pack(xpcall(function() draw_content(ctx, model, nil, view) end, debug.traceback))
    preview_view, preview_targets = nil, nil
    R.ImGui_PopStyleVar(ctx)
    R.ImGui_EndDisabled(ctx)
    if result[1] and preview.paint_pointer then
      preview.paint_pointer(ctx, preview, x, y, width, height)
    end
    R.ImGui_End(ctx)
    if not result[1] then error(result[2], 0) end
  end
  preview.targets.ctx = nil
  return width, height
end

function settings.toggle()
  if ui.open then
    ui.closing = true
  else
    ui.open, ui.opening, ui.closing = true, true, nil
    ui.reposition = true
  end
end

function settings.draw_panel(ctx, model, res)
  if not ui.open or not model or not model.prefs then return end
  -- Switch before Begin so the new page receives its own window bounds.
  if ui.next_page then
    ui.page, ui.next_page, ui.reposition = ui.next_page, nil, true
    R.ImGui_SetNextWindowScroll(ctx, -1, 0)
  end
  local desired_height
  local measured_width = M.SPECTRUM_SETTINGS_W
  if ui.geometry and ui.scale == theme.scale and not ui.opening then
    measured_width = ui.geometry.w
    if ui.scrollbar then
      measured_width = measured_width - R.ImGui_GetStyleVar(ctx,R.ImGui_StyleVar_ScrollbarSize())
    end
  end
  desired_height, ui.group_heights = measure_page(ctx, model, measured_width)
  if ui.opening or ui.reposition or ui.scale ~= theme.scale
      or ui.desired_height ~= desired_height then
    if ui.opening or not ui.bounds then
      ui.geometry = anchored_panel.place(ctx, res, ui.anchor, {
        width=M.SPECTRUM_SETTINGS_W, height=desired_height,
        min_height=math.min(desired_height, 300 * theme.scale),
        gap=M.PANEL_ANCHOR_GAP, margin=M.PICK_SCREEN_MARGIN,
      })
    else
      -- Page and UI-size changes keep the user's dragged position where it fits.
      ui.geometry = anchored_panel.resize(ctx, res, ui.bounds,
        M.SPECTRUM_SETTINGS_W, desired_height, M.PICK_SCREEN_MARGIN)
    end
    local content_width = ui.geometry.w
    if ui.geometry.h < desired_height then
      content_width = content_width - R.ImGui_GetStyleVar(ctx,R.ImGui_StyleVar_ScrollbarSize())
    end
    if content_width ~= measured_width then
      desired_height, ui.group_heights = measure_page(ctx, model, content_width)
      local bounds = {left=ui.geometry.x,top=ui.geometry.y}
      bounds.right,bounds.bottom = bounds.left+ui.geometry.w,bounds.top+ui.geometry.h
      ui.geometry = anchored_panel.resize(ctx,res,bounds,ui.geometry.w,desired_height,M.PICK_SCREEN_MARGIN)
    end
    R.ImGui_SetNextWindowPos(ctx, ui.geometry.x, ui.geometry.y, R.ImGui_Cond_Always())
    ui.opening, ui.reposition, ui.scale = false, false, theme.scale
    ui.desired_height = desired_height
    ui.scrollbar = ui.geometry.h < desired_height
  end
  R.ImGui_SetNextWindowSize(ctx, ui.geometry.w, ui.geometry.h, R.ImGui_Cond_Always())
  -- Supply the current page's extent so Begin cannot reuse the previous page's scroll range.
  R.ImGui_SetNextWindowContentSize(ctx,0,desired_height-M.WINDOW_PAD*2)
  local flags = R.ImGui_WindowFlags_NoTitleBar() | R.ImGui_WindowFlags_NoResize()
    | R.ImGui_WindowFlags_NoCollapse() | R.ImGui_WindowFlags_NoSavedSettings()
    | R.ImGui_WindowFlags_NoDocking()
  -- A scrollbar is only needed when the monitor limits the fitted height.
  if ui.geometry.h >= desired_height then
    flags = flags | R.ImGui_WindowFlags_NoScrollbar()
  end
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_WindowBg(), T.BG_WINDOW)
  local visible = R.ImGui_Begin(ctx, '##yb_meter_settings', nil, flags)
  R.ImGui_PopStyleColor(ctx)
  if not visible then return end
  local wx, wy = R.ImGui_GetWindowPos(ctx)
  local ww, wh = R.ImGui_GetWindowSize(ctx)
  ui.bounds = {left=wx, top=wy, right=wx+ww, bottom=wy+wh}
  local dismiss = anchored_panel.dismissed(ctx, ui)
  local action, closed = draw_content(ctx, model, res)
  if ui.closing or dismiss then ui.open, ui.closing = false, nil end
  if closed or (R.ImGui_IsWindowFocused(ctx, R.ImGui_FocusedFlags_RootAndChildWindows())
      and R.ImGui_IsKeyPressed(ctx, R.ImGui_Key_Escape())) then
    ui.open = false
    focus.request()
  end
  R.ImGui_End(ctx)
  return action
end

return settings
