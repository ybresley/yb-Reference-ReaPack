-- Saved four-panel arrangements for Reference View.
-- The UI supplies the space left after the transport and draws the returned frames.
local layout = {}

local IDS = {'waveform', 'spectrum', 'stereo', 'loudness'}
local VALID_ID = {waveform=true, spectrum=true, stereo=true, loudness=true}
local VALID_VARIANT = {automatic=true, map=true, direct=true}
local VALID_MODE = {auto=true, row=true, stack=true, grid=true,
  top=true, bottom=true, left=true, right=true}

local function copy(list)
  local result = {}
  for i, value in ipairs(list) do result[i] = value end
  return result
end

local function variant(mode)
  return {mode=mode, enabled=copy(IDS), order=copy(IDS),
    shares={x=0.5, y=0.5}}
end

function layout.new()
  return {active='automatic', editing=false, variants={
    automatic=variant('auto'), map=variant('auto'), direct=variant('grid'),
  }}
end

function layout.current(model)
  if type(model) ~= 'table' then return nil end
  return model.variants and model.variants[model.active] or nil
end

local function finite(value)
  return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

local function enabled(prefs, id)
  for _, value in ipairs(prefs.enabled) do if value == id then return true end end
  return false
end

local function split_key(mode, count, axis, index)
  return mode .. '_' .. count .. '_' .. axis .. index
end

local function valid_split_key(key, axis)
  if type(key) ~= 'string' then return false end
  local mode, count, key_axis, index = key:match('^(%a+)_(%d+)_(%a)(%d+)$')
  count, index = tonumber(count), tonumber(index)
  if not count or count < 2 or count > 4 or key_axis ~= axis
      or not index or index < 1 then
    return false
  end
  if mode == 'row' then return axis == 'x' and index < count end
  if mode == 'stack' then return axis == 'y' and index < count end
  if mode == 'grid' then return index == 1 and (count > 2 or axis == 'x') end
  if mode == 'top' or mode == 'bottom' then
    return axis == 'y' and index == 1 or axis == 'x' and index <= count-2
  end
  if mode == 'left' or mode == 'right' then
    return axis == 'x' and index == 1 or axis == 'y' and index <= count-2
  end
  return false
end

-- Stored proportions use the same identities and limits as live divider edits.
function layout.valid_share(key, value)
  if not finite(value) or value < 0 or value > 1 then return false end
  if key == 'x' or key == 'y' then return true end
  if type(key) ~= 'string' then return false end
  local mode, count, axis, index = key:match('^(%a+)_(%d+)_(%a)(%d+)$')
  if not count or key ~= split_key(mode, tonumber(count), axis, tonumber(index)) then
    return false
  end
  return valid_split_key(key, axis)
end

function layout.apply(model, op)
  if type(model) ~= 'table' or type(op) ~= 'table' then
    return nil, 'Invalid layout action.'
  end
  if op.type == 'variant' then
    if not VALID_VARIANT[op.id] then return nil, 'Invalid layout approach.' end
    model.active = op.id
    model.editing = false
    return model
  end
  if op.type == 'edit' then
    if type(op.value) ~= 'boolean' then return nil, 'Invalid edit state.' end
    model.editing = op.value
    return model
  end
  local prefs = layout.current(model)
  if not prefs then return nil, 'Choose a layout control mode first.' end
  if op.type == 'reset' then
    model.variants[model.active] = variant(model.active == 'direct' and 'grid' or 'auto')
    model.editing = false
  elseif op.type == 'toggle' then
    if not VALID_ID[op.id] then return nil, 'Invalid panel.' end
    if enabled(prefs, op.id) then
      if #prefs.enabled == 1 then return nil, 'Keep at least one panel visible.' end
      for i, id in ipairs(prefs.enabled) do
        if id == op.id then table.remove(prefs.enabled, i); break end
      end
    else
      local chosen = {[op.id]=true}
      for _, id in ipairs(prefs.enabled) do chosen[id]=true end
      prefs.enabled = {}
      for _, id in ipairs(prefs.order) do
        if chosen[id] then prefs.enabled[#prefs.enabled+1]=id end
      end
    end
  elseif op.type == 'mode' then
    if not VALID_MODE[op.value] then return nil, 'Invalid panel arrangement.' end
    prefs.mode = op.value
  elseif op.type == 'swap' then
    if not VALID_ID[op.a] or not VALID_ID[op.b] or op.a == op.b
        or not enabled(prefs, op.a) or not enabled(prefs, op.b) then
      return nil, 'Invalid panel swap.'
    end
    local ai, bi
    for i, id in ipairs(prefs.order) do
      if id == op.a then ai = i end
      if id == op.b then bi = i end
    end
    prefs.order[ai], prefs.order[bi] = prefs.order[bi], prefs.order[ai]
  elseif op.type == 'split' then
    if (op.axis ~= 'x' and op.axis ~= 'y') or not finite(op.value)
        or op.value < 0 or op.value > 1
        or (op.key ~= nil and not valid_split_key(op.key, op.axis)) then
      return nil, 'Invalid divider position.'
    end
    prefs.shares[op.key or op.axis] = op.value
  else
    return nil, 'Invalid layout action.'
  end
  return model
end

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

local function dimensions(id, options)
  local scale = options.scale or 1
  local header = math.max(0, options.header_height or 0)
  if id == 'loudness' then
    return 320*scale, (options.loudness_min_height or 200*scale) + header
  end
  if id == 'waveform' then return options.min_width or 300*scale, 120*scale + header end
  if id == 'spectrum' then return options.min_width or 300*scale,
    (options.min_height or 180*scale) + header end
  local aspect = options.stereo_aspect == 2 and 2 or 1
  return math.max(180*scale, 180*scale*aspect + (options.stereo_side_width or 0)),
    180*scale + header
end

local function minimums(order, options)
  local widths, heights = {}, {}
  for i, id in ipairs(order) do
    local w, h = dimensions(id, options)
    widths[i], heights[i] = w, h
  end
  return widths, heights
end

local function max_many(values, first, last)
  local result = 0
  for i = first, last do result = math.max(result, values[i] or 0) end
  return result
end

local function sum(values, first, last)
  local result = 0
  for i = first, last do result = result + (values[i] or 0) end
  return result
end

local function required_size(mode, count, gap, mw, mh)
  if count == 1 then return mw[1], mh[1] end
  if mode == 'row' then
    return sum(mw, 1, count) + gap * (count-1), max_many(mh, 1, count)
  elseif mode == 'stack' then
    return max_many(mw, 1, count), sum(mh, 1, count) + gap * (count-1)
  elseif mode == 'grid' then
    if count == 2 then return required_size('row', count, gap, mw, mh) end
    if count == 3 then
      return math.max(mw[1]+mw[2]+gap, mw[3]), math.max(mh[1],mh[2])+mh[3]+gap
    end
    return math.max(mw[1],mw[3])+math.max(mw[2],mw[4])+gap,
      math.max(mh[1],mh[2])+math.max(mh[3],mh[4])+gap
  elseif mode == 'top' or mode == 'bottom' then
    return math.max(mw[1],sum(mw,2,count)+gap*(count-2)),
      mh[1]+max_many(mh,2,count)+gap
  elseif mode == 'left' or mode == 'right' then
    return mw[1]+max_many(mw,2,count)+gap,
      math.max(mh[1],sum(mh,2,count)+gap*(count-2))
  end
  return math.huge, math.huge
end

local function fits(mode, count, width, height, gap, mw, mh)
  if count == 1 then return true end
  local required_w, required_h = required_size(mode, count, gap, mw, mh)
  return width >= required_w and height >= required_h
end

local function frame(id, x, y, w, h)
  return {id=id, x=x, y=y, w=math.max(0,w), h=math.max(0,h)}
end

local function divider(axis, x, y, w, h, key, origin, span, low, high)
  return {axis=axis, x=x, y=y, w=w, h=h, share=axis, key=key,
    origin=origin, span=span, min_share=low, max_share=high}
end

local function divide(total, gap, fraction, first_min, second_min)
  local usable = math.max(0, total-gap)
  local first = clamp(usable*fraction, first_min, usable-second_min)
  return first, usable-first
end

-- A strip's fractions describe cumulative panel widths/heights with gaps removed.
-- Each boundary has its own stored value, so moving it leaves other seams fixed.
local function strip(extent, gap, mins, shares, mode, count, axis, first_fraction)
  local n = #mins
  local usable = math.max(0, extent-gap*(n-1))
  local defaults, positions, sizes, seams = {}, {}, {}, {}
  if n == 1 then return {extent}, seams end
  local first = first_fraction and clamp(usable*first_fraction,
    mins[1], usable-sum(mins,2,n)) or usable*mins[1]/sum(mins,1,n)
  defaults[1] = first/usable
  local remaining = usable-first
  local cumulative = first
  for i=2,n-1 do
    local size = remaining*mins[i]/sum(mins,i,n)
    cumulative = cumulative+size
    defaults[i] = cumulative/usable
    remaining = remaining-size
  end
  for i=1,n-1 do
    local key = split_key(mode,count,axis,i)
    local raw = shares[key]
    if not finite(raw) or raw < 0 or raw > 1 then raw = defaults[i] end
    local low = (positions[i-1] or 0)+mins[i]/usable
    local high = 1-sum(mins,i+1,n)/usable
    positions[i] = clamp(raw,low,high)
  end
  local previous = 0
  for i=1,n do
    local stop = positions[i] or 1
    sizes[i] = (stop-previous)*usable
    previous = stop
  end
  for i=1,n-1 do
    local low = (positions[i-1] or 0)+mins[i]/usable
    local high = (positions[i+1] or 1)-mins[i+1]/usable
    if high < low then high = low end
    seams[i] = {key=split_key(mode,count,axis,i),
      coordinate=positions[i]*usable+(i-1)*gap,
      origin=(i-1)*gap, span=usable, low=low, high=high}
  end
  return sizes, seams
end

local function geometry(mode, order, width, height, gap, shares, mw, mh)
  local count = #order
  local panels, dividers = {}, {}
  if count == 1 then
    panels[1] = frame(order[1],0,0,width,height)
  elseif mode == 'row' or mode == 'stack' then
    local along_x = mode == 'row'
    local extent = along_x and width or height
    local mins = along_x and mw or mh
    local axis = along_x and 'x' or 'y'
    local sizes, seams = strip(extent,gap,mins,shares,mode,count,axis,shares[axis])
    local cursor = 0
    for i=1,count do
      local size = sizes[i]
      panels[i] = along_x and frame(order[i],cursor,0,size,height)
        or frame(order[i],0,cursor,width,size)
      cursor = cursor+size+gap
    end
    for i,seam in ipairs(seams) do
      dividers[i] = along_x
        and divider('x',seam.coordinate,0,gap,height,seam.key,
          seam.origin,seam.span,seam.low,seam.high)
        or divider('y',0,seam.coordinate,width,gap,seam.key,
          seam.origin,seam.span,seam.low,seam.high)
    end
  elseif mode == 'grid' and count == 2 then
    local sizes, seams = strip(width,gap,mw,shares,'grid',count,'x',shares.x)
    panels[1], panels[2] = frame(order[1],0,0,sizes[1],height),
      frame(order[2],sizes[1]+gap,0,sizes[2],height)
    local seam = seams[1]
    dividers[1] = divider('x',seam.coordinate,0,gap,height,seam.key,
      seam.origin,seam.span,seam.low,seam.high)
  elseif mode == 'grid' then
    local top_min = math.max(mh[1],mh[2])
    local bottom_min = count == 3 and mh[3] or math.max(mh[3],mh[4])
    local top_key = split_key('grid',count,'y',1)
    local top_share = shares[top_key] or shares.y
    local top, bottom = divide(height,gap,top_share,top_min,bottom_min)
    local left_min = count == 3 and mw[1] or math.max(mw[1],mw[3])
    local right_min = count == 3 and mw[2] or math.max(mw[2],mw[4])
    local left_key = split_key('grid',count,'x',1)
    local left_share = shares[left_key] or shares.x
    local left, right = divide(width,gap,left_share,left_min,right_min)
    panels[1], panels[2] = frame(order[1],0,0,left,top),
      frame(order[2],left+gap,0,right,top)
    dividers[1] = divider('y',0,top,width,gap,top_key,0,height-gap,
      top_min/(height-gap),1-bottom_min/(height-gap))
    dividers[2] = divider('x',left,0,gap,count == 3 and top or height,
      left_key,0,width-gap,left_min/(width-gap),1-right_min/(width-gap))
    if count == 3 then
      panels[3] = frame(order[3],0,top+gap,width,bottom)
    else
      panels[3], panels[4] = frame(order[3],0,top+gap,left,bottom),
        frame(order[4],left+gap,top+gap,right,bottom)
    end
  elseif mode == 'top' or mode == 'bottom' then
    local reversed = mode == 'bottom'
    local first_min, pair_min = mh[1], max_many(mh,2,count)
    local primary_key = split_key(mode,count,'y',1)
    local primary_share = shares[primary_key] or shares.y
    local top, bottom = divide(height,gap,primary_share,
      reversed and pair_min or first_min,
      reversed and first_min or pair_min)
    panels[1] = frame(order[1],0,reversed and top+gap or 0,
      width,reversed and bottom or top)
    dividers[1] = divider('y',0,top,width,gap,primary_key,0,height-gap,
      (reversed and pair_min or first_min)/(height-gap),
      1-(reversed and first_min or pair_min)/(height-gap))
    local inner_mins = {}
    for i=2,count do inner_mins[#inner_mins+1]=mw[i] end
    local sizes, seams = strip(width,gap,inner_mins,shares,mode,count,'x')
    local cursor = 0
    for i=2,count do
      local size = sizes[i-1]
      panels[i] = frame(order[i],cursor,reversed and 0 or top+gap,
        size,reversed and top or bottom)
      cursor=cursor+size+gap
    end
    for i,seam in ipairs(seams) do
      dividers[#dividers+1] = divider('x',seam.coordinate,
        reversed and 0 or top+gap,gap,reversed and top or bottom,
        seam.key,seam.origin,seam.span,seam.low,seam.high)
    end
  elseif mode == 'left' or mode == 'right' then
    local reversed = mode == 'right'
    local first_min, pair_min = mw[1], max_many(mw,2,count)
    local primary_key = split_key(mode,count,'x',1)
    local primary_share = shares[primary_key] or shares.x
    local left, right = divide(width,gap,primary_share,
      reversed and pair_min or first_min,
      reversed and first_min or pair_min)
    panels[1] = frame(order[1],reversed and left+gap or 0,0,
      reversed and right or left,height)
    dividers[1] = divider('x',left,0,gap,height,primary_key,0,width-gap,
      (reversed and pair_min or first_min)/(width-gap),
      1-(reversed and first_min or pair_min)/(width-gap))
    local inner_mins = {}
    for i=2,count do inner_mins[#inner_mins+1]=mh[i] end
    local sizes, seams = strip(height,gap,inner_mins,shares,mode,count,'y')
    local cursor = 0
    for i=2,count do
      local size = sizes[i-1]
      panels[i] = frame(order[i],reversed and 0 or left+gap,cursor,
        reversed and left or right,size)
      cursor=cursor+size+gap
    end
    for i,seam in ipairs(seams) do
      dividers[#dividers+1] = divider('y',reversed and 0 or left+gap,
        seam.coordinate,reversed and left or right,gap,
        seam.key,seam.origin,seam.span,seam.low,seam.high)
    end
  end
  return panels, dividers
end

function layout.measure(width, height, prefs, options)
  options = options or {}
  width, height = math.max(0,width or 0), math.max(0,height or 0)
  local gap = math.max(0,options.gap or 8*(options.scale or 1))
  local order = {}
  for _, id in ipairs(prefs.order) do
    if enabled(prefs,id) then order[#order+1]=id end
  end
  local mw, mh = minimums(order, options)
  local count = #order
  local mode, candidates
  if count == 1 then
    mode = 'single'
  elseif prefs.mode ~= 'auto' then
    candidates = {prefs.mode}
    for _, fallback in ipairs({'grid','top','bottom','left','right','row','stack'}) do
      if fallback ~= prefs.mode then candidates[#candidates+1] = fallback end
    end
  else
    local ratio = width/math.max(height,1)
    candidates = ratio >= 3 and {'row','grid','top','bottom','left','right','stack'}
      or ratio >= 1.1 and {'grid','row','top','bottom','left','right','stack'}
      or {'stack','left','right','grid','top','bottom','row'}
  end
  local candidate_fits = false
  if candidates then
    mode = candidates[1]
    for _, candidate in ipairs(candidates) do
      if fits(candidate,count,width,height,gap,mw,mh) then
        mode, candidate_fits = candidate, true
        break
      end
    end
  end
  if count > 1 and prefs.mode == 'auto' and not candidate_fits then
    -- Keep undersized layouts from changing shape at aspect-ratio boundaries.
    -- Row remains useful when the full panel widths fit; otherwise grid keeps
    -- the two picture columns available while their heights compress evenly.
    local row_width = required_size('row',count,gap,mw,mh)
    mode = width >= row_width and 'row' or 'grid'
  end
  if count > 1 and prefs.mode == 'auto' then
    local ratio = width/math.max(height,1)
    local previous = options.previous_mode
    if previous and previous ~= mode
        and fits(previous,count,width,height,gap,mw,mh) then
      local boundary = ratio >= 2.85 and ratio <= 3.15
        or ratio >= 1.02 and ratio <= 1.18
      if boundary then mode = previous end
    end
  end
  local temporary = count > 1 and not fits(mode,count,width,height,gap,mw,mh)
  local adapted = count > 1 and not temporary
    and prefs.mode ~= 'auto' and prefs.mode ~= mode
  local layout_w, layout_h = width, height
  if temporary then
    local required_w, required_h = required_size(mode, count, gap, mw, mh)
    layout_w, layout_h = math.max(width, required_w), math.max(height, required_h)
  end
  local panels, dividers = geometry(mode,order,layout_w,layout_h,gap,prefs.shares,mw,mh)
  if temporary then
    -- Keep every enabled panel when none of the normal arrangements fit.
    -- Scale only the measured frames; saved proportions remain untouched.
    local sx, sy = width/layout_w, height/layout_h
    for _, rects in ipairs({panels, dividers}) do
      for _, rect in ipairs(rects) do
        rect.x, rect.w = rect.x*sx, rect.w*sx
        rect.y, rect.h = rect.y*sy, rect.h*sy
        if rect.axis then
          local factor = rect.axis == 'x' and sx or sy
          rect.origin, rect.span = rect.origin*factor, rect.span*factor
        end
      end
    end
  end
  if width < 1 or height < 1 then dividers = {} end
  -- Measure the full arrangement first so reclaiming the scope's space cannot
  -- make it alternate between visible and hidden on successive frames.
  if count > 1 and options.stereo_hide_height then
    local hide_height = options.stereo_hidden
      and math.max(options.stereo_hide_height, options.stereo_restore_height or 0)
      or options.stereo_hide_height
    for _, pane in ipairs(panels) do
      if pane.id == 'stereo'
          and pane.h-(options.header_height or 0) < hide_height-.0001 then
        local visible = {}
        for _, id in ipairs(order) do
          if id ~= 'stereo' then visible[#visible+1] = id end
        end
        local compact = layout.measure(width, height,
          {mode=prefs.mode, order=prefs.order, enabled=visible, shares=prefs.shares}, options)
        compact.enabled, compact.temporary = copy(order), true
        compact.hidden = {stereo=true}
        return compact
      end
    end
  end
  return {panels=panels, dividers=dividers, temporary=temporary, adapted=adapted,
    mode=mode, intended=prefs.mode, enabled=copy(order),
    tab_height=0, content_y=0}
end

return layout
