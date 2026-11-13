-- Keep the card inside affected pictures, away from healthy views and transport.
local layout={}
local function overlaps(a,b)
  return a.x<b.x+b.w and b.x<a.x+a.w and a.y<b.y+b.h and b.y<a.y+a.h
end
function layout.anchor(frames,blocked)
  local bounds,largest
  for _,r in ipairs(frames) do
    if blocked[r.id] and r.w>0 and r.h>0 then
      if not largest or r.w*r.h>largest.w*largest.h then largest=r end
      if not bounds then bounds={x=r.x,y=r.y,w=r.w,h=r.h}
      else
        local right,bottom=math.max(bounds.x+bounds.w,r.x+r.w),math.max(bounds.y+bounds.h,r.y+r.h)
        bounds.x,bounds.y=math.min(bounds.x,r.x),math.min(bounds.y,r.y)
        bounds.w,bounds.h=right-bounds.x,bottom-bounds.y
      end
    end
  end
  if not bounds then return end
  for _,r in ipairs(frames) do
    if not blocked[r.id] and overlaps(bounds,r) then
      return {x=largest.x,y=largest.y,w=largest.w,h=largest.h}
    end
  end
  return bounds
end
return layout
