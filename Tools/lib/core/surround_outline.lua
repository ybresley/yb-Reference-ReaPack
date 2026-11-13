-- Geometry and readings for the Surround Field outline. Floor speakers join
-- into one shape whose corners sit at each speaker's level; the side between
-- two neighbouring speakers bends with their correlation.
local outline={}

local FLOOR_DB=-60
-- A pair is only judged when both speakers carry audible, comparable signal.
-- Without this, a nearly silent speaker would paint random phase colours.
local QUIET_DB=-50
local MAX_LEVEL_GAP_DB=24
-- Correlation bands shared by the side colour and the hover wording, so the
-- tint and the words always agree. Below NEUTRAL a side stays grey; at FULL
-- and beyond it takes the whole phase colour.
local NEUTRAL=0.15
local FULL=0.6
-- Quadratic control offset as a fraction of the side's length. The curve's
-- visible bow is half of this.
local BEND=0.32
-- Inward bends stop short of the centre so the shape cannot fold through it.
local INWARD_LIMIT=0.8
local TRAIL_SECONDS=1.2
local TRAIL_INTERVAL=1/30
local TAU=2*math.pi

outline.TRAIL_SECONDS=TRAIL_SECONDS

local function finite(value)
  return type(value)=='number' and value==value and value>-math.huge and value<math.huge
end

function outline.amount(level)
  if not finite(level) then return 0 end
  return math.max(0,math.min(1,(level-FLOOR_DB)/-FLOOR_DB))
end

-- Pair numbering shared with the meter helper: (1,2), (1,3) ... (1,n), (2,3) ...
function outline.pair_index(a,b,count)
  if a>b then a,b=b,a end
  if a<1 or b>count or a==b then return nil end
  -- (a-1)*a is always even, so the integer division is exact.
  return (a-1)*count-(a-1)*a//2+(b-a)
end

-- Floor speakers in clockwise order from the front. A side that spans more
-- than half the circle closes through the centre: those two speakers are not
-- neighbours, so it carries no phase reading.
function outline.shape(profile)
  local shape={floor={},edges={},heights={},overhead={},lfe={}}
  if not profile or not profile.positions then return shape end
  local floor={}
  for i=1,profile.count do
    local position=profile.positions[i]
    if not position then
    elseif position.lfe then shape.lfe[#shape.lfe+1]=i
    elseif position.angle~=nil then
      local elevation=position.elevation or 0
      if elevation>=90 then shape.overhead[#shape.overhead+1]=i
      elseif elevation>0 then shape.heights[#shape.heights+1]=i
      else floor[#floor+1]={channel=i,angle=math.rad(position.angle)%TAU} end
    end
  end
  table.sort(floor,function(a,b)
    if a.angle~=b.angle then return a.angle<b.angle end
    return a.channel<b.channel
  end)
  for k,entry in ipairs(floor) do shape.floor[k]=entry.channel end
  for k=1,#floor do
    local a,b=floor[k],floor[k%#floor+1]
    local span=(b.angle-a.angle)%TAU
    if #floor==1 then span=TAU end
    local through_centre=span>math.pi+1e-9
    shape.edges[k]={a=a.channel,b=b.channel,a_angle=a.angle,span=span,
      through_centre=through_centre,phase=not through_centre and span>math.rad(1)}
  end
  return shape
end

-- The pairs the meter must measure: one bit per side that can show phase,
-- numbered like pair_index. Other pairs are never drawn.
function outline.neighbour_mask(profile)
  local mask=0
  if not profile or profile.known==false or type(profile.count)~='number' then return mask end
  for _,edge in ipairs(outline.shape(profile).edges) do
    local index=edge.phase and outline.pair_index(edge.a,edge.b,profile.count)
    if index then mask=mask|(1<<(index-1)) end
  end
  return mask
end

-- Returns a usable correlation, or nil when the pair should stay neutral.
-- The meter adapter has already range-checked the value; false means silent.
function outline.phase(correlation,level_a,level_b)
  if not finite(correlation) then return nil end
  if not finite(level_a) or not finite(level_b) then return nil end
  if level_a<QUIET_DB or level_b<QUIET_DB then return nil end
  if math.abs(level_a-level_b)>MAX_LEVEL_GAP_DB then return nil end
  return correlation
end

-- Colour weight from neutral: positive toward in-phase, negative toward
-- opposite polarity, zero inside the neutral band.
function outline.phase_mix(correlation)
  if not correlation then return 0 end
  local size=math.max(0,math.min(1,(math.abs(correlation)-NEUTRAL)/(FULL-NEUTRAL)))
  return correlation<0 and -size or size
end

-- Words for a reading, using the same bands as phase_mix.
function outline.verdict(correlation)
  if correlation>=FULL then return 'in phase' end
  if correlation>NEUTRAL then return 'partly in phase' end
  if correlation>=-NEUTRAL then return 'unrelated' end
  if correlation>-FULL then return 'partly opposite polarity' end
  return 'opposite polarity'
end

function outline.bend(ax,ay,bx,by,cx,cy,correlation)
  local mx,my=(ax+bx)/2,(ay+by)/2
  if not correlation or correlation==0 then return mx,my end
  local nx,ny=mx-cx,my-cy
  local distance=math.sqrt(nx*nx+ny*ny)
  if distance<1e-9 then return mx,my end
  nx,ny=nx/distance,ny/distance
  local dx,dy=bx-ax,by-ay
  local offset=correlation*BEND*math.sqrt(dx*dx+dy*dy)
  offset=math.max(offset,-INWARD_LIMIT*distance)
  return mx+nx*offset,my+ny*offset
end

function outline.curve_point(ax,ay,qx,qy,bx,by,t)
  local u=1-t
  return u*u*ax+2*u*t*qx+t*t*bx,u*u*ay+2*u*t*qy+t*t*by
end

-- Phantom image between two neighbours: the amplitude balance sets its place
-- along the arc, and lower correlation widens it. Unrelated or opposite pairs
-- share no sound, so they get no image. Returns start and end
-- fractions of the arc from speaker a to speaker b.
function outline.phantom(level_a,level_b,correlation)
  if not correlation or correlation<=NEUTRAL then return nil end
  local ga,gb=10^(level_a/20),10^(level_b/20)
  local centre=gb/(ga+gb)
  local width=0.06+0.4*(1-math.max(0,correlation))
  return math.max(0,centre-width/2),math.min(1,centre+width/2),centre
end

-- A short energy vector means a diffuse field; the halo grows with spread.
function outline.spread(bx,by)
  if not finite(bx) or not finite(by) then return nil end
  return 1-math.min(1,math.sqrt(bx*bx+by*by))
end

-- The afterglow keeps a fixed ring of recent shapes. Items are allocated once
-- and overwritten, so recording costs no garbage per frame.
function outline.new_trail(capacity)
  local trail={capacity=capacity or 36,head=0,count=0,items={},last=nil}
  for i=1,trail.capacity do trail.items[i]={at=0,amounts={},phases={},count=0} end
  return trail
end

function outline.clear_trail(trail)
  trail.head,trail.count,trail.last=0,0,nil
end

function outline.record(trail,now,amounts,phases,count)
  if trail.last and now-trail.last<TRAIL_INTERVAL and now>=trail.last then return false end
  trail.last=now
  trail.head=trail.head%trail.capacity+1
  trail.count=math.min(trail.capacity,trail.count+1)
  local item=trail.items[trail.head]
  item.at,item.count=now,count
  for i=1,count do item.amounts[i]=amounts[i] or 0; item.phases[i]=phases and phases[i] or false end
  return true
end

-- Calls visit(item, alpha) from oldest to newest, skipping the live shape.
function outline.each_glow(trail,now,visit,stride)
  stride=stride or 1
  for step=trail.count-1,1,-1 do
    if step%stride==0 then
      local index=(trail.head-step-1)%trail.capacity+1
      local item=trail.items[index]
      local age=now-item.at
      if age>=0 and age<TRAIL_SECONDS then visit(item,0.22*math.exp(-age/0.45)) end
    end
  end
end

return outline
