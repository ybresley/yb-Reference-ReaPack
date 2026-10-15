-- Meter palettes share fixed level landmarks. A rising bar reveals more of
-- the ramp; it never stretches the colours to fit its current height.
local colours = {}
local scale = require('core.meter_scale')
colours.names = { 'Accent Fade' }
colours.accent_offset = -5
local yellow, red = 0xE8C668FF, 0xFC6B83FF

function colours.has(name) return name=='Accent Fade' end

local function landmark(index,accent)
  if index==1 then
    local dark=0xFF
    for shift=8,24,8 do dark=dark | (math.floor(((accent>>shift)&255)*.52+.5)<<shift) end
    return dark
  end
  if index==2 then return accent end
  return index==3 and yellow or red
end

function colours.at(name, relative, accent, options)
  assert(colours.has(name), 'Unknown meter palette')
  assert(type(accent)=='number', 'Meter accent colour is required')
  local lead=options and options.yellow_lead or 5
  local span=options and options.red_span or 3
  local first,second,third,fourth=-32,-lead,0,span
  if relative<=first then return landmark(1,accent) end
  for i=2,4 do
    local lower=i==2 and first or i==3 and second or third
    local upper=i==2 and second or i==3 and third or fourth
    if relative<=upper then
      local t=(relative-lower)/(upper-lower)
      local a,b=landmark(i-1,accent),landmark(i,accent)
      local result=0
      for shift=0,24,8 do
        local first,last=(a>>shift)&255,(b>>shift)&255
        result=result | (math.floor(first+(last-first)*t+.5)<<shift)
      end
      return result
    end
  end
  return red
end

-- Split at colour and scale landmarks, bounded at eight draws
-- per bar regardless of window height. No textures or per-pixel drawing.
function colours.paint(draw,dl,name,x,w,top,bottom,low,high,value,target,opacity,accent,map,options)
  if not value or value<=low or bottom<=top then return end
  map=map or scale.y
  local ceiling=math.min(value,high)
  local function rgba(level)
    local c=colours.at(name,level-target,accent,options)
    return (c&0xFFFFFF00) | math.floor(255*(opacity or 1)+.5)
  end
  local function paint_interval(a,b)
    if b<=a then return end
    local y1=map(b,bottom,top,low,high)
    local y2=map(a,bottom,top,low,high)
    local ca,cb=rgba(a),rgba(b)
    draw(dl,x,y1,x+w,y2,cb,cb,ca,ca)
  end
  local function segment(a,b)
    for _,level in ipairs(scale.breaks) do
      if level>a and level<b then paint_interval(a,level);a=level end
    end
    paint_interval(a,b)
  end
  local start=low
  for i=1,4 do
    local offset=i==1 and -32 or i==2 and -(options and options.yellow_lead or 5)
      or i==3 and 0 or (options and options.red_span or 3)
    local level=target+offset
    if level>start and level<ceiling then segment(start,level);start=level end
  end
  segment(start,ceiling)
end

return colours
