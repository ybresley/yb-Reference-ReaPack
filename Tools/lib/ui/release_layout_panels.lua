-- Shared production painters with measured, silent example data for all four panels.
local theme=require('ui.theme')
local layout=require('core.layout_prototype')
local waveform=require('ui.waveform')
local wave_view=require('core.wave_view')
local wave_signal=require('ui.release_layout_wave')
local stereo=require('ui.stereo')
local stereo_demo=require('core.release_stereo_demo')
local stereo_signal=require('ui.release_stereo_signal')
local stereo_preferences=require('core.stereo_preferences')
local meter=require('ui.release_meter')
local spectrum=require('ui.spectrum')
local spectrum_axis=require('ui.spectrum_axis')
local level_axis=require('ui.spectrum_level_axis')
local surfaces=require('core.panel_surface_layout')
local meter_panel=require('ui.meter_panel')
local axis_geometry=require('core.spectrum_axis')
local mathx=require('core.spectrum_math')
local spectrum_signal=require('ui.release_layout_spectrum')
local T,M=theme.tokens,theme.metrics
local panels={}
local decode={}
local alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
for i=1,#alphabet do decode[alphabet:byte(i)]=i-1 end
local smoothing={motion_mode='power',attack_seconds=.012,
  release_seconds=mathx.power_release_seconds(20,.9),average_seconds=3}

function panels.new()
  return {view=wave_view.new(),scope=stereo_demo.new(stereo_signal),meter=meter.new(),
    stereo_preferences=stereo_preferences.defaults(),
    spectrum=mathx.new(spectrum_signal.bins,spectrum_signal.db_min),target={},live={}}
end

function panels.update(value,elapsed)
  stereo_demo.advance(value.scope,'stereo_lissajous',elapsed)
  meter.update(value.meter,'meter_overview',elapsed)
  value.meter.model.prefs.history_position='Below Meters'
  value.meter.model.prefs.show_history=true
  local index=math.min(#spectrum_signal.frames,math.floor((elapsed%4)/spectrum_signal.step)+1)
  if index~=value.frame then
    local encoded=spectrum_signal.frames[index]
    for i=1,spectrum_signal.bins do
      local code=decode[encoded:byte(i*2-1)]*64+decode[encoded:byte(i*2)]
      value.target[i]=spectrum_signal.db_min+code*spectrum_signal.db_step
    end
    value.frame=index
  end
  local dt=value.elapsed and math.max(0,math.min(.1,elapsed-value.elapsed)) or 0
  mathx.update(value.spectrum,value.target,dt,smoothing)
  for i=1,spectrum_signal.bins do
    value.live[i]=mathx.tilted_db(value.spectrum.live[i],mathx.bin_frequency(i,spectrum_signal.bins,10,22050),4.5)
  end
  value.elapsed=elapsed
end

local function paint_wave(ctx,dl,value,x,y,w,h,elapsed,footer)
  local picture_h=h-footer
  local fraction=(elapsed%wave_signal.duration)/wave_signal.duration
  reaper.ImGui_DrawList_AddRectFilled(dl,x,y,x+w,y+picture_h,T.WAVE_BG,3*theme.scale)
  local lane_h=picture_h/#wave_signal.channels
  for index,channel in ipairs(wave_signal.channels) do
    local lane_y=y+(index-1)*lane_h
    waveform.paint_lane(dl,x,lane_y,lane_h,math.floor(w),channel,nil,nil,nil,value.view,true,fraction,1)
    waveform.paint_baseline(dl,x,lane_y,lane_h,w,value.view,fraction,1)
  end
  reaper.ImGui_DrawList_AddLine(dl,x+fraction*w,y,x+fraction*w,y+picture_h,T.WAVE_PLAYHEAD,1)
  if footer > 0 then
    waveform.paint_ruler(ctx,dl,'release_layout',x,y+picture_h,w,wave_signal.duration,value.view)
  end
end

local function paint_spectrum(ctx,dl,value,x,y,w,h,footer)
  local gx,gy=x+M.SPECTRUM_PLOT_PAD,y
  local gw,gh=w-M.SPECTRUM_PLOT_PAD-M.SPECTRUM_LEVEL_W,h-footer
  reaper.ImGui_DrawList_AddRectFilled(dl,x,y,gx+gw,gy+gh,T.SPECTRUM_BG,3*theme.scale)
  reaper.ImGui_DrawList_PushClipRect(dl,gx,gy,gx+gw,gy+gh,true)
  spectrum.paint_grid(dl,gx,gy,gw,gh,-90,10,axis_geometry.MAX_HZ)
  spectrum.paint_curve(dl,value.live,spectrum_signal.bins,gx,gy,
    axis_geometry.trace_width(gw,10,22050),gh,-90,T.SPECTRUM_LIVE,T.SPECTRUM_LIVE_FILL)
  reaper.ImGui_DrawList_PopClipRect(dl)
  local axes={gx=gx,gy=gy,gw=gw,gh=gh,axis=footer,
    fmin=10,fmax=axis_geometry.MAX_HZ,bottom=-90,eligible=false,
    level_right=x+w-M.SPECTRUM_BAND_GAP}
  spectrum_axis.draw(ctx,dl,nil,axes)
  level_axis.draw(ctx,dl,axes)
end

function panels.measure(value,model,w,h)
  local geometry=layout.measure(w,h,layout.current(model),{scale=theme.scale,
    gap=M.SPECTRUM_SPLIT_GAP,min_width=M.SPECTRUM_PANE_MIN_W,
    min_height=M.REFERENCE_PANE_MIN_H,loudness_min_height=228*theme.scale,
    stereo_hide_height=M.STEREO_HIDE_H,
    stereo_side_width=value.stereo_preferences.show_correlation and M.STEREO_CORRELATION_W or 0})
  geometry.frame_h=M.BASE_FS+M.FRAME_PAD_Y*2
  geometry.width,geometry.visual_h,geometry.prototype_variant=w,h,model.active
  return geometry
end

function panels.paint(ctx,res,value,model,x,y,w,h,elapsed)
  local geometry=panels.measure(value,model,w,h)
  local frames=surfaces.measure(geometry.panels,0,M.RULER_H,M.WAVE_MIN_H)
  local meter_inset=0
  for _,pane in ipairs(geometry.panels) do
    if pane.id=='loudness' then
      local measured=meter_panel.measure(pane.w,pane.h,value.meter.model.prefs,
        nil,nil,frames[pane.id].footer_height)
      meter_inset=meter_panel.surface_left_inset(measured,pane.w,pane.h,value.meter.model.prefs)
    end
  end
  frames=surfaces.measure(geometry.panels,meter_inset,M.RULER_H,M.WAVE_MIN_H)
  local dl=reaper.ImGui_GetWindowDrawList(ctx)
  local state={stereo=value.scope.model,stereo_view='lissajous',
    stereo_preferences=value.stereo_preferences,monitor_filter={system={available=true}}}
  reaper.ImGui_PushStyleVar(ctx,reaper.ImGui_StyleVar_DisabledAlpha(),1)
  reaper.ImGui_BeginDisabled(ctx)
  for _,pane in ipairs(geometry.panels) do
    local frame=frames[pane.id]
    if frame.w < 1 or frame.h < 1 then goto next_panel end
    local px,py=x+frame.x,y+frame.y
    reaper.ImGui_PushID(ctx,'release_layout_'..pane.id)
    if geometry.temporary then
      reaper.ImGui_PushClipRect(ctx,x+pane.x,y+pane.y,x+pane.x+pane.w,y+pane.y+pane.h,true)
    end
    reaper.ImGui_SetCursorScreenPos(ctx,px,py)
    if pane.id=='waveform' then paint_wave(ctx,dl,value,px,py,frame.w,frame.h,elapsed,frame.footer_height)
    elseif pane.id=='spectrum' then paint_spectrum(ctx,dl,value,px,py,frame.w,frame.h,frame.footer_height)
    elseif pane.id=='stereo' then stereo.draw(ctx,state,frame.w,frame.h-(frame.footer_height or 0),res,nil,nil,nil,{hovered=false})
    else meter.paint(ctx,value.meter,px,py,pane.w,pane.h,nil,frame.footer_height) end
    if geometry.temporary then reaper.ImGui_PopClipRect(ctx) end
    reaper.ImGui_PopID(ctx)
    ::next_panel::
  end
  reaper.ImGui_EndDisabled(ctx)
  reaper.ImGui_PopStyleVar(ctx)
  return geometry
end

return panels
