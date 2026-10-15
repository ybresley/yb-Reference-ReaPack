local theme=require('ui.theme')
local widgets=require('ui.widgets')
local scale=require('core.meter_scale')
local style=require('ui.meter_style')
local T,R=theme.tokens,reaper
local drawing={}
local function brightness(colour, amount)
  amount=amount or 1
  if amount<=1 then return theme.fade(colour,amount) end
  return theme.blend(colour,T.TEXT_PRIMARY,math.min(1,(amount-1)*1.2))
end
local function number(v)
  if v == nil or v ~= v then return '—' end
  if v == -math.huge or v <= -99 then return '−∞' end
  return string.format('%.1f', v):gsub('^-', '−')
end

local function loudness_number(value,opts)
  local reading=scale.reading(value,opts)
  local formatted=number(reading)
  return opts.readings=='Relative' and reading and reading>=.05 and '+'..formatted or formatted
end

local function loudness_tick(value,opts)
  local reading=scale.reading(value,opts)
  return (reading>0 and '+' or '')..string.format('%g',reading):gsub('^-','−')
end

local function time_label(seconds,opts)
  seconds = math.max(0, seconds or 0)
  if opts and opts.time_format=='Seconds' then return string.format('%.1fs',seconds) end
  return string.format('%02d:%04.1f', seconds // 60, seconds % 60)
end

local function text(ctx, dl, x, y, value, colour, size, align, width, row_height)
  local pushed = size and theme.push_release_font(ctx, size)
  local tw,th = R.ImGui_CalcTextSize(ctx, value)
  if row_height then
    local padding=size and size>=20*theme.scale and 2 or 4
    local available=row_height-padding*theme.scale
    if size and th>available then
      if pushed then R.ImGui_PopFont(ctx) end
      pushed=theme.push_release_font(ctx,size*available/th)
      tw,th=R.ImGui_CalcTextSize(ctx,value)
    end
    y=y+(row_height-th)/2
  end
  if width and tw > width then
    value = widgets.ellipsize(ctx, value, width)
    tw = R.ImGui_CalcTextSize(ctx, value)
  end
  if align == 'center' then x = x - tw / 2 end
  if align == 'number' then
    -- Centre the magnitude; the sign hangs to its left instead of shifting the digits.
    local sign=value:match('^(−)') or value:match('^([+-])')
    local body=sign and value:sub(#sign+1) or value
    x=x-tw+R.ImGui_CalcTextSize(ctx,body)/2
  end
  if align == 'right' then x = x - tw end
  R.ImGui_DrawList_AddText(dl, x, y, colour or T.TEXT_SECONDARY, value)
  if pushed then R.ImGui_PopFont(ctx) end
end

local function line(dl, x, y, x2, y2, colour, thickness)
  R.ImGui_DrawList_AddLine(dl, x, y, x2, y2, colour or T.STROKE_TERTIARY, thickness or 1)
end

local function axis_label(ctx,dl,edge,y,value,side,size,colour,tick_colour)
  local pushed=size and theme.push_release_font(ctx,size)
  local label=value:gsub('^-','−')
  local width,height=R.ImGui_CalcTextSize(ctx,label)
  local direction=side=='right' and 1 or -1
  local tip=edge+direction*theme.metrics.RULER_TICK_MINOR
  line(dl,edge,y,tip,y,tick_colour or T.STROKE_TERTIARY)
  local column=R.ImGui_CalcTextSize(ctx,'−00')
  column=math.max(width,column)
  local x=side=='right' and tip+theme.metrics.RULER_LABEL_GAP
    or tip-theme.metrics.RULER_LABEL_GAP-column
  -- A shared sign column keeps single- and double-digit negative labels aligned.
  if not label:match('^−') and not label:match('^%+') then
    x=x+R.ImGui_CalcTextSize(ctx,'−')
  end
  R.ImGui_DrawList_AddText(dl,x,y-height/2,colour or T.TEXT_TERTIARY,label)
  if pushed then R.ImGui_PopFont(ctx) end
end

function drawing.axis_ticks(ctx,top,bottom,low,step,size,high,map,priority)
  local pushed=theme.push_release_font(ctx,size)
  local _,height=R.ImGui_CalcTextSize(ctx,'−00')
  if pushed then R.ImGui_PopFont(ctx) end
  return scale.ticks(top,bottom,low,step,theme.scale,high,map,{height=height,priority=priority})
end

local function rect(dl, x, y, w, h, colour, radius)
  if w > 0 and h > 0 then
    R.ImGui_DrawList_AddRectFilled(dl, x, y, x+w, y+h, colour, radius or 0)
  end
end

-- Bars and history share labels, spacing and the highlighted target.
function drawing.loudness_axis(ctx,dl,left,right,top,bottom,opts,side)
  local s=theme.scale
  local low,high,map=scale.loudness(opts)
  local edge=side=='right' and right or left
  local target_y=map(opts.target,bottom,top,low,high)
  local target_visible=opts.target>=low and opts.target<=high
  local show_line=target_visible and opts.show_target==true
  local grid=brightness(T.STROKE_TERTIARY,opts.grid_brightness)
  local tolerance=opts.tolerance or 0
  if target_visible and tolerance>0 then
    local upper=map(opts.target+tolerance,bottom,top,low,high)
    local lower=map(opts.target-tolerance,bottom,top,low,high)
    rect(dl,left,upper,right-left,lower-upper,theme.fade(style.warning,.12))
  end
  local target_label=false
  for _,value in ipairs(drawing.axis_ticks(ctx,top,bottom,low,3,11*s,high,map,opts.target)) do
    local y=map(value,bottom,top,low,high)
    if value==opts.target then
      target_label=true
    else
      line(dl,left,y,right,y,grid)
      axis_label(ctx,dl,edge,y,loudness_tick(value,opts),side,11*s,
        brightness(T.TEXT_TERTIARY,opts.grid_brightness),grid)
    end
  end
  if target_visible then
    local colour=theme.fade(style.warning,style.target_opacity)
    local target_grid=brightness(T.STROKE_SECONDARY,opts.grid_brightness)
    if target_label then
      axis_label(ctx,dl,edge,target_y,loudness_tick(opts.target,opts),side,11*s,style.warning,
        show_line and colour or target_grid)
    end
    if show_line then
      local size=style.target_dot*s
      for x=left,right,style.target_spacing*s do
        rect(dl,x,target_y-size/2,math.min(size,right-x),size,colour)
      end
    else
      line(dl,left,target_y,right,target_y,target_grid)
    end
  end
end

local function surface(dl, r)
  rect(dl, r.x, r.y, r.w, r.h, T.WAVE_BG, 3 * theme.scale)
end

function drawing.meter_bottom(r)
  return r.y+r.h-(r.footer_height or theme.metrics.RULER_H)-style.caption_height*theme.scale
end

-- Backgrounds, bars and grids reserve the same gutter for the current axis side.
function drawing.meter_bounds(r,side)
  local s=theme.scale
  return r.x+(side=='left' and 32 or 8)*s,
    r.x+r.w-(side=='right' and style.history_right or 8)*s
end

function drawing.meter_readout(ctx,dl,r,cx,label,value,colour,size)
  local s=theme.scale
  local footer_height=r.footer_height or theme.metrics.RULER_H
  local row_y=r.y+r.h-footer_height
  local caption_y=drawing.meter_bottom(r)
  text(ctx,dl,cx,caption_y,label,T.TEXT_SECONDARY,12*s,'center',nil,style.caption_height*s)
  if footer_height>0 then
    text(ctx,dl,cx,row_y,value,colour,size,'number',nil,footer_height)
  end
end


drawing.number=number
drawing.loudness_number=loudness_number
drawing.loudness_tick=loudness_tick
drawing.time_label=time_label
drawing.text=text
drawing.line=line
drawing.axis_label=axis_label
drawing.rect=rect
drawing.surface=surface
drawing.brightness=brightness
return drawing
