-- Settings retain their proportions while the display uses the remaining space.
local layout = {}

function layout.measure(width, height, settings_width, settings_height, display_minimum, pad, gap)
  local available_w = math.max(1,width-pad*2)
  local available_h = math.max(1,height-pad*2)
  local ratio = math.min(available_w/(display_minimum+settings_width+gap),
    available_h/math.max(1,settings_height))
  local sw, spacing = settings_width*ratio, gap*ratio
  return {
    ratio=ratio,
    display={x=pad,y=pad,w=available_w-sw-spacing,h=available_h},
    settings={x=pad+available_w-sw,y=pad,w=sw,h=settings_height*ratio},
  }
end

return layout
