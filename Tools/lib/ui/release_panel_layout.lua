-- The settings map and the four displays share one private layout model.
local theme = require('ui.theme')
local layout = require('core.layout_prototype')
local story = require('core.release_panel_layout_demo')
local displays = require('ui.release_layout_panels')
local settings = require('ui.layout_prototype_settings')
local widgets = require('ui.widgets')
local scope = require('ui.release_preview_scope')
local pointer = require('ui.release_pointer')
local T, M = theme.tokens, theme.metrics
local panels = {}

function panels.new()
  return {model=layout.new(), scene={}, displays=displays.new(), guide={targets={}}}
end

local function setting_label(ctx, text)
  local bold = theme.push_bold_font(ctx)
  reaper.ImGui_TextColored(ctx,T.TEXT_PRIMARY,text)
  if bold then reaper.ImGui_PopFont(ctx) end
end

local function setting_note(ctx, text)
  local x = reaper.ImGui_GetCursorPosX(ctx)
  local width = reaper.ImGui_GetContentRegionAvail(ctx)
  reaper.ImGui_PushTextWrapPos(ctx,x+width)
  reaper.ImGui_TextColored(ctx,T.TEXT_TERTIARY,text)
  reaper.ImGui_PopTextWrapPos(ctx)
end

local function draw_settings(ctx,res,demo,x,y,w,h)
  for key in pairs(demo.guide.targets) do demo.guide.targets[key] = nil end
  reaper.ImGui_SetCursorScreenPos(ctx,x,y)
  reaper.ImGui_PushStyleVar(ctx,reaper.ImGui_StyleVar_WindowPadding(),0,0)
  local opened = reaper.ImGui_BeginChild(ctx,'release_layout_settings',w,h,0,
    reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
    | reaper.ImGui_WindowFlags_NoInputs() | reaper.ImGui_WindowFlags_NoNav())
  reaper.ImGui_PopStyleVar(ctx)
  if not opened then return end
  local visible,child = widgets.begin_settings_group(ctx,'release_layout_reference','Reference View',true)
  if visible then
    local first = true
    local function begin_setting()
      if not first then
        reaper.ImGui_PushStyleColor(ctx,reaper.ImGui_Col_Separator(),T.STROKE_SECONDARY)
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_PopStyleColor(ctx)
      end
      first = false
    end
    local state = {layout_prototype=demo.model,stereo_view='lissajous',
      stereo_preferences=demo.displays.stereo_preferences}
    demo.guide.dragging = demo.scene.dragging
    demo.guide.source, demo.guide.target = 'waveform', 'stereo'
    demo.guide.progress = demo.scene.progress
    settings.draw(ctx,state,begin_setting,setting_label,setting_note,
      res and res.icon_font,demo.guide)
  end
  widgets.end_settings_group(ctx,child)
  reaper.ImGui_EndChild(ctx)
end

local function centre(rect)
  return {x=rect.x+rect.w*.5,y=rect.y+rect.h*.5}
end

local function draw_pointer(ctx,demo,x,y,w,h,settings_x,settings_y,frame)
  local targets,scene = demo.guide.targets,demo.scene
  if not targets.map_waveform or not targets.map_stereo then return end
  -- These are fixed slots: releasing a swap changes the labels under the pointer.
  local anchors = {
    top=centre(scene.swapped and targets.map_stereo or targets.map_waveform),
    bottom=centre(scene.swapped and targets.map_waveform or targets.map_stereo),
    home={x=settings_x-35*theme.scale,y=settings_y+160*theme.scale},
    toggle_spectrum=centre(targets.toggle_spectrum),
    bottom_edge={x=frame.x+frame.w*.55,y=frame.y+frame.h},
    right_edge={x=frame.x+frame.w,y=frame.y+frame.h*.5},
  }
  local from,to = anchors[scene.from],anchors[scene.to]
  local px = from.x+(to.x-from.x)*scene.progress
  local py = from.y+(to.y-from.y)*scene.progress
  local dl = reaper.ImGui_GetForegroundDrawList(ctx)
  reaper.ImGui_DrawList_PushClipRect(dl,x,y,x+w,y+h,true)
  if scene.resize_axis then
    pointer.paint_click(dl,px,py,scene.pulse)
    if scene.resize_axis=='x' then pointer.paint_resize_ew(dl,px,py)
    else pointer.paint_resize_ns(dl,px,py) end
  elseif scene.dragging then pointer.paint_grab(dl,px,py)
  else pointer.paint(dl,px,py,scene.pulse) end
  reaper.ImGui_DrawList_PopClipRect(dl)
end

function panels.draw(ctx,res,demo,topic,elapsed,width,height)
  local scene = story.sample(topic,elapsed,demo.scene)
  local first = scene.swapped and 'stereo' or 'waveform'
  if layout.current(demo.model).order[1] ~= first then
    assert(layout.apply(demo.model,{type='swap',a='waveform',b='stereo'}))
  end
  local spectrum_visible=false
  for _,id in ipairs(layout.current(demo.model).enabled) do
    if id=='spectrum' then spectrum_visible=true end
  end
  if spectrum_visible~=scene.spectrum_visible then
    assert(layout.apply(demo.model,{type='toggle',id='spectrum'}))
  end
  displays.update(demo.displays,elapsed)
  local x,y = reaper.ImGui_GetCursorScreenPos(ctx)
  local pad = M.WINDOW_PAD
  local show_settings = topic == 'layout_settings'
  local logical_w = show_settings and 1064 or 900
  local logical_h = show_settings and 536 or 520
  local ratio = math.min(1,(width-M.WINDOW_PAD*2)/(logical_w*theme.scale),
    (height-M.WINDOW_PAD*2)/(logical_h*theme.scale))
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_PushClipRect(dl,x,y,x+width,y+height,true)
  scope.paint(ctx,math.max(.1,ratio),function()
    local s = theme.scale
    local px,py = x+(width-logical_w*s)*.5,y+(height-logical_h*s)*.5
    if show_settings then
      local frame={x=px,y=py,w=(scene.width+16)*s,h=(scene.height+16)*s}
      reaper.ImGui_DrawList_AddRectFilled(dl,px,py,px+frame.w,py+frame.h,T.BG_WINDOW)
      reaper.ImGui_DrawList_AddRect(dl,px,py,px+frame.w,py+frame.h,
        T.STROKE_PRIMARY,0,0,s)
      displays.paint(ctx,res,demo.displays,demo.model,px+8*s,py+8*s,
        scene.width*s,scene.height*s,elapsed)
      if scene.resize_axis then
        local colour=scene.resizing and T.ACCENT or T.STROKE_PRIMARY
        if scene.resize_axis=='x' then
          reaper.ImGui_DrawList_AddLine(dl,px+frame.w,py,px+frame.w,py+frame.h,colour,2*s)
        else
          reaper.ImGui_DrawList_AddLine(dl,px,py+frame.h,px+frame.w,py+frame.h,colour,2*s)
        end
      end
      local settings_x,settings_y = px+674*s,py+40*s
      draw_settings(ctx,res,demo,settings_x,settings_y,390*s,480*s)
      draw_pointer(ctx,demo,x,y,width,height,settings_x,settings_y,frame)
    else
      displays.paint(ctx,res,demo.displays,demo.model,x+pad,y+pad,
        math.max(1,width-pad*2),math.max(1,height-pad*2),elapsed)
    end
  end)
  reaper.ImGui_DrawList_PopClipRect(dl)
  reaper.ImGui_SetCursorScreenPos(ctx,x,y)
  reaper.ImGui_Dummy(ctx,width,height)
end

return panels
