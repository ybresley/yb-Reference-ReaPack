-- Pure preferences and geometry for the waveform, spectrum and stereo views.
local json = require('vendor.json')
local layout = {}

local IDS = {'waveform', 'spectrum', 'stereo'}
local SHAPES = {'horizontal', 'vertical', 'top', 'bottom', 'left', 'right'}
local VALID_ID = {waveform = true, spectrum = true, stereo = true}
local VALID_SHAPE = {horizontal = true, vertical = true, top = true,
  bottom = true, left = true, right = true}
local DEFAULT_SHARES = {
  horizontal = {0.36, 0.70}, vertical = {0.30, 0.65},
  top = {0.48, 0.56}, bottom = {0.52, 0.56},
  left = {0.48, 0.50}, right = {0.52, 0.50},
}
local INVALID = 'Saved reference panel settings are invalid.'

local function finite(n)
  return type(n) == 'number' and n == n and math.abs(n) < math.huge
end

local function clamp(n, low, high)
  return math.max(low, math.min(high, n))
end

local function copy_list(list)
  local result = {}
  for i, value in ipairs(list) do result[i] = value end
  return result
end

local function valid_order(value, complete)
  if type(value) ~= 'table' then return false end
  local seen, count = {}, 0
  for i, id in ipairs(value) do
    if not VALID_ID[id] or seen[id] then return false end
    seen[id], count = true, i
  end
  for index in pairs(value) do
    if type(index) ~= 'number' or index % 1 ~= 0
        or index < 1 or index > count then return false end
  end
  if complete then return count == 3 and value[4] == nil end
  return count >= 1 and count <= 3 and value[count + 1] == nil
end

local function key(mode, count)
  return mode .. '_' .. count
end

function layout.default_shares(mode, count)
  if count == 2 then return {0.5, 0.5} end
  return copy_list(DEFAULT_SHARES[mode] or {0.5, 0.5})
end

function layout.defaults()
  local orders, splits = {}, {}
  for _, mode in ipairs(SHAPES) do
    orders[mode] = copy_list(IDS)
    splits[key(mode, 2)] = layout.default_shares(mode, 2)
    splits[key(mode, 3)] = layout.default_shares(mode, 3)
  end
  return {mode = 'auto', enabled = copy_list(IDS), orders = orders,
    splits = splits, fallback = copy_list(IDS)}
end

-- Return a copy so callers cannot mutate a validated stored record by accident.
function layout.normalise(prefs)
  if type(prefs) ~= 'table' or (prefs.mode ~= 'auto' and not VALID_SHAPE[prefs.mode])
      or not valid_order(prefs.enabled, false)
      or not valid_order(prefs.fallback, true)
      or type(prefs.orders) ~= 'table' or type(prefs.splits) ~= 'table' then
    return nil, INVALID
  end
  local result = layout.defaults()
  result.mode = prefs.mode
  result.enabled = copy_list(prefs.enabled)
  result.fallback = copy_list(prefs.fallback)
  for _, mode in ipairs(SHAPES) do
    if not valid_order(prefs.orders[mode], true) then return nil, INVALID end
    result.orders[mode] = copy_list(prefs.orders[mode])
    if (mode == 'top' or mode == 'bottom') and result.orders[mode][1] == 'stereo' then
      result.orders[mode][1], result.orders[mode][2] =
        result.orders[mode][2], result.orders[mode][1]
    end
    for count = 2, 3 do
      local shares = prefs.splits[key(mode, count)]
      if type(shares) ~= 'table' or not finite(shares[1])
          or not finite(shares[2]) or shares[1] < 0 or shares[1] > 1
          or shares[2] < 0 or shares[2] > 1 or shares[3] ~= nil then
        return nil, INVALID
      end
      result.splits[key(mode, count)] = {shares[1], shares[2]}
    end
  end
  return result
end

function layout.encode(prefs)
  local clean, err = layout.normalise(prefs)
  if not clean then return nil, err end
  return json.encode({version = 1, preferences = clean})
end

function layout.decode(text)
  if text == nil or text == '' then return nil, 'No saved reference panel settings.' end
  if type(text) ~= 'string' then return nil, INVALID end
  local ok, stored = pcall(json.decode, text)
  if not ok or type(stored) ~= 'table' then return nil, INVALID end
  if stored.version ~= 1 then
    return nil, 'Saved reference panel settings use an unsupported version.'
  end
  return layout.normalise(stored.preferences)
end

-- Legacy shares describe waveform width/height, whereas new shares describe
-- the first fixed frame. Swapping content must not move that frame.
function layout.migrate(legacy, split, stack_split, visual)
  local prefs = layout.defaults()
  legacy = type(legacy) == 'table' and legacy or {}
  if legacy.mode == 'horizontal' or legacy.mode == 'vertical' then
    prefs.mode = legacy.mode
  end
  local horizontal_first = legacy.horizontal_first == 'spectrum' and 'spectrum' or 'waveform'
  local vertical_first = legacy.vertical_first == 'spectrum' and 'spectrum' or 'waveform'
  prefs.orders.horizontal = {horizontal_first,
    horizontal_first == 'waveform' and 'spectrum' or 'waveform', 'stereo'}
  prefs.orders.vertical = {vertical_first,
    vertical_first == 'waveform' and 'spectrum' or 'waveform', 'stereo'}
  local horizontal = finite(split) and clamp(split, 0, 1) or 0.45
  local vertical = finite(stack_split) and clamp(stack_split, 0, 1) or 0.4
  if horizontal_first == 'spectrum' then horizontal = 1 - horizontal end
  if vertical_first == 'spectrum' then vertical = 1 - vertical end
  prefs.splits.horizontal_2 = {horizontal, 0.5}
  prefs.splits.vertical_2 = {vertical, 0.5}
  if visual == 'spectrum' then prefs.fallback = {'spectrum', 'waveform', 'stereo'} end
  return prefs
end

local function enabled_map(prefs)
  local map = {}
  for _, id in ipairs(prefs.enabled) do map[id] = true end
  return map
end

local function filtered(order, allowed)
  local result = {}
  for _, id in ipairs(order) do if allowed[id] then result[#result + 1] = id end end
  return result
end

function layout.panel_order(prefs, mode)
  local order = filtered(prefs.orders[mode], enabled_map(prefs))
  if mode == 'vertical' and #order == 3 then
    order = {'stereo'}
    for _, id in ipairs(prefs.orders[mode]) do
      if id ~= 'stereo' then order[#order + 1] = id end
    end
  elseif (mode == 'top' or mode == 'bottom') and #order == 3 and order[1] == 'stereo' then
    order[1], order[2] = order[2], order[1]
  end
  return order
end

function layout.can_swap(prefs, mode, a, b)
  local allowed = enabled_map(prefs)
  if a == b or not allowed[a] or not allowed[b] or not prefs.orders[mode] then return false end
  if #prefs.enabled == 3 and (a == 'stereo' or b == 'stereo') then
    if mode == 'vertical' then return false end
    local order = layout.panel_order(prefs, mode)
    if (mode == 'top' or mode == 'bottom') and (a == order[1] or b == order[1]) then
      return false
    end
  end
  return true
end

local function metrics_of(metrics)
  metrics = type(metrics) == 'table' and metrics or {}
  return {gap = math.max(0, finite(metrics.gap) and metrics.gap or 8),
    footer_height = math.max(0, finite(metrics.footer_height) and metrics.footer_height or 0),
    min_width = math.max(0, finite(metrics.min_width) and metrics.min_width or 300),
    min_height = math.max(0, finite(metrics.min_height) and metrics.min_height or 180),
    hide_height = math.max(0, finite(metrics.hide_height) and metrics.hide_height or 24),
    stereo_side_width = math.max(0, finite(metrics.stereo_side_width) and metrics.stereo_side_width or 0),
    stereo_aspect = metrics.stereo_aspect == 2 and 2 or 1}
end

-- Correlation sits beside the picture, outside its fixed aspect ratio.
local function scope_width(metrics, height)
  return metrics.stereo_aspect * math.max(0, height) + metrics.stereo_side_width
end

local function scope_height(metrics, width)
  return math.max(0, width - metrics.stereo_side_width) / metrics.stereo_aspect
end

local function fit(mode, count, width, height, metrics, order)
  if count == 1 then return width > 0 and height >= metrics.hide_height end
  if not VALID_SHAPE[mode] then return false end
  local gap, mw, mh = metrics.gap, metrics.min_width, metrics.min_height
  local widths = {}
  local scope
  for i = 1, count do
    if order and order[i] == 'stereo' then scope = i end
    local footer = (mode == 'left' or mode == 'right') and i == 2
      and 0 or metrics.footer_height
    widths[i] = order and order[i] == 'stereo'
      and scope_width(metrics, math.min(mw, mh) - footer) or mw
  end
  if mode == 'horizontal' then
    if scope then widths[scope] = scope_width(metrics, height - metrics.footer_height) end
    local minimum = (count - 1) * gap
    for _, size in ipairs(widths) do minimum = minimum + size end
    return width >= minimum and height >= mh
  end
  if mode == 'vertical' then
    return width >= math.max(mw, scope and scope_width(metrics, mh) or 0)
      and height >= count * mh + (count - 1) * gap
  end
  if count ~= 3 then return false end
  if (mode == 'left' or mode == 'right') and scope == 1 then
    widths[1] = scope_width(metrics, height - metrics.footer_height)
  elseif (mode == 'left' or mode == 'right') and scope then
    local footer = scope == 3 and metrics.footer_height or 0
    if height < scope_height(metrics, mw) + footer + mh + gap then return false end
  end
  local minimum = (mode == 'top' or mode == 'bottom')
    and math.max(widths[1], widths[2] + widths[3] + gap)
    or widths[1] + math.max(widths[2], widths[3]) + gap
  local needed_height = 2 * mh + gap
  if (mode == 'top' or mode == 'bottom') and scope == 1 then
    needed_height = math.max(needed_height, scope_height(metrics, width)
      + metrics.footer_height + mh + gap)
  end
  return width >= minimum and height >= needed_height
end

local function effective_mode(mode, count)
  if count == 2 then
    if mode == 'top' or mode == 'bottom' then return 'vertical' end
    if mode == 'left' or mode == 'right' then return 'horizontal' end
  end
  return mode
end

local function content_mode(mode, count, order)
  if mode == 'vertical' and count == 3 and order then
    for i = 1, count do
      if order[i] == 'stereo' then return 'right' end
    end
  end
  return effective_mode(mode, count)
end

-- Each share is a fraction of usable space after gaps are removed.
-- Clamping uses the current extent so a resize during a drag cannot invert a frame.
local function minimums(axis, usable, cross, count, metrics, order)
  local result, total = {}, 0
  for i = 1, count do
    local size = axis == 'x' and metrics.min_width or metrics.min_height
    if order and order[i] == 'stereo' then
      if axis == 'x' then
        size = scope_width(metrics, math.min(size, metrics.min_height, cross) - metrics.footer_height)
      else
        size = math.min(size, metrics.min_height, scope_height(metrics, cross))
      end
    end
    result[i], total = size, total + size
  end
  for i = 1, count do
    result[i] = usable > 0 and result[i] / math.max(usable, total) or 1 / count
  end
  return result
end

local function frame_bounds(mode, count, share, width, height, shares, metrics, order)
  local axis = (mode == 'horizontal' or (mode == 'left' or mode == 'right') and share == 1
    or (mode == 'top' or mode == 'bottom') and share == 2) and 'x' or 'y'
  local extent = axis == 'x' and width or height
  local gap_count = (mode == 'horizontal' or mode == 'vertical') and count - 1 or 1
  local usable = math.max(0, extent - metrics.gap * gap_count)
  local minimum = axis == 'x' and metrics.min_width or metrics.min_height
  local min_fraction = usable > 0 and math.min(0.5, minimum / usable) or 0.5
  local low, high = min_fraction, 1 - min_fraction
  if count == 3 and (mode == 'horizontal' or mode == 'vertical') then
    local mins = minimums(axis, usable, axis == 'x' and height or width, count, metrics, order)
    if share == 1 then
      low = mins[1]
      high = clamp(shares[2], mins[1] + mins[2], 1 - mins[3]) - mins[2]
    else
      low = clamp(shares[1], mins[1], 1 - mins[2] - mins[3]) + mins[2]
      high = 1 - mins[3]
    end
  elseif order then
    local pair_order = order
    if count == 3 and share == 1 then
      local reversed = mode == 'bottom' or mode == 'right'
      pair_order = reversed and {'waveform', order[1]} or {order[1], 'waveform'}
    elseif count == 3 then pair_order = {order[2], order[3]} end
    local mins = minimums(axis, usable, axis == 'x' and height or width, 2, metrics, pair_order)
    low, high = mins[1], 1 - mins[2]
  end
  if high < low then
    -- A shrinking frame can briefly be below the fit threshold while captured.
    low, high = (low + high) / 2, (low + high) / 2
  end
  return low, high, usable, axis, gap_count
end

function layout.clamp_share(mode, count, share, pointer, width, height, shares, metrics, order)
  if not VALID_SHAPE[mode] or (count ~= 2 and count ~= 3)
      or (share ~= 1 and share ~= 2) or not finite(pointer) then
    return nil, 'Invalid divider.'
  end
  metrics = metrics_of(metrics)
  shares = type(shares) == 'table' and shares or layout.default_shares(mode, count)
  local low, high, usable = frame_bounds(mode, count, share,
    math.max(0, width or 0), math.max(0, height or 0), shares, metrics, order)
  local preceding = (mode == 'horizontal' or mode == 'vertical') and share - 1 or 0
  local raw = usable > 0 and (pointer - metrics.gap * (preceding + 0.5)) / usable or 0.5
  return clamp(raw, low, high)
end

local function safe_shares(mode, count, width, height, shares, metrics, order)
  local value = copy_list(shares or layout.default_shares(mode, count))
  if count == 3 and (mode == 'horizontal' or mode == 'vertical') then
    local extent = mode == 'horizontal' and width or height
    local usable = math.max(0, extent - 2 * metrics.gap)
    local axis = mode == 'horizontal' and 'x' or 'y'
    local mins = minimums(axis, usable, axis == 'x' and height or width, count, metrics, order)
    value[1] = clamp(value[1], mins[1], 1 - mins[2] - mins[3])
    value[2] = clamp(value[2], value[1] + mins[2], 1 - mins[3])
  else
    for share = 1, (count == 3 and 2 or 1) do
      local low, high = frame_bounds(mode, count, share, width, height, value, metrics, order)
      value[share] = clamp(value[share], low, high)
    end
  end
  return value
end

local function scope_footer(mode, index, metrics)
  if mode == 'horizontal' or mode == 'top' or mode == 'bottom'
      or ((mode == 'left' or mode == 'right') and index ~= 2) then
    return metrics.footer_height
  end
  return 0
end

-- The plot fills its row, with a fixed footer outside the plot. Give it the
-- required width even when a saved divider would otherwise leave empty margins.
local function scope_shares(mode, count, width, height, shares, metrics, order)
  if not order then return shares end
  local index
  for i = 1, count do if order[i] == 'stereo' then index = i end end
  if not index then return shares end
  local gap = metrics.gap
  local footer = scope_footer(mode, index, metrics)
  if mode == 'horizontal' or mode == 'vertical' then
    local horizontal = mode == 'horizontal'
    local usable = (horizontal and width or height) - gap * (count - 1)
    if usable <= 0 then return shares end
    local cross = horizontal and math.max(0, height - footer) or width
    local lengths = {shares[1] * usable, (1 - shares[1]) * usable}
    if count == 3 then
      lengths[2], lengths[3] = (shares[2] - shares[1]) * usable, (1 - shares[2]) * usable
    end
    local target = horizontal and scope_width(metrics, cross)
      or math.min(lengths[index], scope_height(metrics, cross))
    local remaining = math.max(0, usable - target)
    local minimum = horizontal and metrics.min_width or metrics.min_height
    minimum = math.min(minimum, remaining / (count - 1))
    local flexible = 0
    for i = 1, count do
      if i ~= index then flexible = flexible + math.max(0, lengths[i] - minimum) end
    end
    if math.abs(lengths[index] - target) > 0.000001 then
      for i = 1, count do
        if i ~= index then
          local fraction = flexible > 0 and math.max(0, lengths[i] - minimum) / flexible
            or 1 / (count - 1)
          lengths[i] = minimum + (remaining - minimum * (count - 1)) * fraction
        end
      end
      lengths[index] = target
      shares[1] = lengths[1] / usable
      if count == 3 then shares[2] = (lengths[1] + lengths[2]) / usable end
    end
  else
    local wide = mode == 'top' or mode == 'bottom'
    local reversed = mode == 'bottom' or mode == 'right'
    local primary = (wide and height or width) - gap
    local secondary = (wide and width or height) - gap
    if primary <= 0 or secondary <= 0 then return shares end
    if index == 1 then
      local cross = wide and scope_height(metrics, width) + footer
        or scope_width(metrics, height - footer)
      shares[1] = reversed and 1 - cross / primary or cross / primary
    else
      local pair = primary * (reversed and shares[1] or 1 - shares[1])
      local maximum = wide and scope_height(metrics, secondary - metrics.min_width) + footer
        or scope_width(metrics, secondary - metrics.min_height - footer)
      local minimum = wide and metrics.min_height
        or math.max(metrics.min_width,
          scope_width(metrics, metrics.min_height - footer))
      pair = clamp(pair, math.min(minimum, maximum), math.max(0, maximum))
      local own = wide and scope_width(metrics, pair - footer)
        or scope_height(metrics, pair) + footer
      shares[1] = reversed and pair / primary or 1 - pair / primary
      shares[2] = index == 2 and own / secondary or 1 - own / secondary
    end
  end
  return shares
end

function layout.geometry(mode, count, width, height, shares, metrics, order)
  metrics = metrics_of(metrics)
  width, height = math.max(0, width or 0), math.max(0, height or 0)
  local gap = metrics.gap
  local rects, dividers = {}, {}
  if count == 1 then
    local plot_height = math.min(height, scope_height(metrics, width))
    local plot_width = math.min(width, scope_width(metrics, plot_height))
    local rect = order and order[1] == 'stereo'
      and {x = (width - plot_width) / 2, y = (height - plot_height) / 2,
        w = plot_width, h = plot_height, background_x = 0, background_w = width}
      or {x = 0, y = 0, w = width, h = height}
    return {rects = {rect}, dividers = dividers, mode = 'single'}
  end
  mode = content_mode(mode, count, order)
  if not VALID_SHAPE[mode] or (count ~= 2 and count ~= 3) then
    return nil, 'Invalid panel arrangement.'
  end
  shares = safe_shares(mode, count, width, height, shares, metrics, order)
  shares = scope_shares(mode, count, width, height, shares, metrics, order)
  if mode == 'horizontal' or mode == 'vertical' then
    local horizontal = mode == 'horizontal'
    local extent = horizontal and width or height
    local usable = math.max(0, extent - gap * (count - 1))
    local stops = {0, shares[1] * usable}
    if count == 3 then stops[3] = shares[2] * usable end
    stops[count + 1] = usable
    for i = 1, count do
      local pos, size = stops[i] + gap * (i - 1), math.max(0, stops[i + 1] - stops[i])
      rects[i] = horizontal and {x = pos, y = 0, w = size, h = height}
        or {x = 0, y = pos, w = width, h = size}
      if i < count then
        local point = stops[i + 1] + gap * (i - 1)
        dividers[i] = horizontal
          and {x = point, y = 0, w = gap, h = height, axis = 'x', share = i,
            pairs = {{i, i + 1}}}
          or {x = 0, y = point, w = width, h = gap, axis = 'y', share = i,
            pairs = {{i, i + 1}}}
      end
    end
  elseif mode == 'top' or mode == 'bottom' then
    local y = shares[1] * math.max(0, height - gap)
    local x = shares[2] * math.max(0, width - gap)
    local bottom = mode == 'bottom'
    local pair_y, pair_h = bottom and 0 or y + gap,
      bottom and y or math.max(0, height - y - gap)
    rects = {
      {x = 0, y = bottom and y + gap or 0, w = width,
        h = bottom and math.max(0, height - y - gap) or y},
      {x = 0, y = pair_y, w = x, h = pair_h},
      {x = x + gap, y = pair_y, w = math.max(0, width - x - gap), h = pair_h},
    }
    dividers = {
      {x = 0, y = y, w = width, h = gap, axis = 'y', share = 1,
        pairs = {{1, 2}, {1, 3}}},
      {x = x, y = pair_y, w = gap, h = pair_h, axis = 'x', share = 2,
        pairs = {{2, 3}}},
    }
  else
    local x = shares[1] * math.max(0, width - gap)
    local y = shares[2] * math.max(0, height - gap)
    local right = mode == 'right'
    local pair_x, pair_w = right and 0 or x + gap,
      right and x or math.max(0, width - x - gap)
    rects = {
      {x = right and x + gap or 0, y = 0,
        w = right and math.max(0, width - x - gap) or x, h = height},
      {x = pair_x, y = 0, w = pair_w, h = y},
      {x = pair_x, y = y + gap, w = pair_w,
        h = math.max(0, height - y - gap)},
    }
    dividers = {
      {x = x, y = 0, w = gap, h = height, axis = 'x', share = 1,
        pairs = {{1, 2}, {1, 3}}},
      {x = pair_x, y = y, w = pair_w, h = gap, axis = 'y', share = 2,
        pairs = {{2, 3}}},
    }
  end
  for i, rect in ipairs(rects) do
    if order and order[i] == 'stereo' then
      -- The picture keeps its aspect ratio; its background fills the assigned row.
      rect.background_x, rect.background_w = rect.x, rect.w
      local footer = scope_footer(mode, i, metrics)
      local plot_height = math.min(scope_height(metrics, rect.w),
        math.max(0, rect.h - footer))
      local plot_width = math.min(rect.w, scope_width(metrics, plot_height))
      rect.x = rect.x + (rect.w - plot_width) / 2
      rect.w, rect.h, rect.footer_height = plot_width, plot_height + footer, footer
      -- A plot at the outer edge follows row height, so that divider cannot
      -- change its width. Swap buttons on the gap remain available.
      if mode == 'horizontal' and (i == 1 or i == count) then
        dividers[i == 1 and 1 or count - 1].resizable = false
      elseif (mode == 'left' or mode == 'right') and i == 1 then
        dividers[1].resizable = false
      end
    end
  end
  return {rects = rects, dividers = dividers, shares = shares, mode = mode}
end

function layout.measure(width, height, prefs, last_mode, metrics, locked_mode)
  prefs = prefs or layout.defaults()
  metrics = metrics_of(metrics)
  width, height = math.max(0, width or 0), math.max(0, height or 0)
  local available = height >= metrics.hide_height and height or 0
  local allowed, count = enabled_map(prefs), #prefs.enabled
  local function fits(shape)
    local order = shape and prefs.orders[shape] and layout.panel_order(prefs, shape)
    return fit(content_mode(shape, count, order), count, width, available, metrics, order)
  end
  local intended = prefs.mode
  if intended == 'auto' then
    local ratio = width / math.max(available, 1)
    if count == 3 then
      intended = ratio >= 2.1 and 'horizontal' or ratio >= 1.18 and 'top' or 'vertical'
    else
      intended = ratio >= 1.85 and 'horizontal' or 'vertical'
    end
    if VALID_SHAPE[locked_mode] then
      intended = effective_mode(locked_mode, count)
    elseif VALID_SHAPE[last_mode] and effective_mode(last_mode, count) ~= intended then
      local margin = count == 3 and (math.abs(ratio - 2.1) < 0.12
        or math.abs(ratio - 1.18) < 0.08) or math.abs(ratio - 1.85) < 0.10
      local prior = effective_mode(last_mode, count)
      if margin and fits(prior) then intended = prior end
    end
    if not fits(intended) then
      local prior = effective_mode(last_mode, count)
      if fits(prior) then
        intended = prior
      else
        for _, candidate in ipairs(count == 3
            and {'horizontal', 'top', 'vertical', 'left'}
            or {'horizontal', 'vertical'}) do
          if fits(candidate) then
            intended = candidate
            break
          end
        end
      end
    end
  else
    intended = effective_mode(intended, count)
  end
  if available == 0 then
    return {mode = 'single', intended = intended, count = 0,
      temporary = true, panels = {}, dividers = {}, visual_h = 0}
  end
  local mode, visible_count, temporary, order = intended, count, false,
    layout.panel_order(prefs, intended)
  if not fits(mode) then
    temporary, order = true, filtered(prefs.fallback, allowed)
    if count == 3 and fit('horizontal', 2, width, available, metrics, order) then
      mode, visible_count = 'horizontal', 2
    elseif count == 3 and fit('vertical', 2, width, available, metrics, order) then
      mode, visible_count = 'vertical', 2
    else
      mode, visible_count = 'single', 1
    end
  end
  if count == 1 then mode, visible_count, temporary = 'single', 1, false end
  local geo = layout.geometry(mode, visible_count, width, available,
    prefs.splits[key(mode, visible_count)], metrics, order)
  local panels = {}
  for i = 1, visible_count do
    local rect = geo.rects[i]
    panels[i] = {id = order[i], x = rect.x, y = rect.y, w = rect.w, h = rect.h,
      footer_height = rect.footer_height,
      background_x = rect.background_x, background_w = rect.background_w}
  end
  return {mode = geo.mode, intended = intended, split_mode = mode, count = visible_count,
    temporary = temporary, panels = panels, dividers = geo.dividers,
    visual_h = available, shares = geo.shares}
end

function layout.drag_shares(geometry, share, pointer, width, metrics)
  metrics = metrics_of(metrics)
  local order = {}
  local scope_index
  for i, panel in ipairs(geometry.panels) do
    order[i] = panel.id
    if panel.id == 'stereo' then scope_index = i end
  end
  local values = copy_list(geometry.shares)
  values[share] = layout.clamp_share(geometry.mode, geometry.count, share,
    pointer, width, geometry.visual_h, values, metrics, order)
  local mode = geometry.mode
  if geometry.count == 3 and scope_index and scope_index > 1
      and mode ~= 'horizontal' and mode ~= 'vertical' then
    -- Both edges must follow a plot resize. Shrinking each axis independently
    -- would let either divider make the scope smaller but neither make it larger.
    local wide = mode == 'top' or mode == 'bottom'
    local reversed = mode == 'bottom' or mode == 'right'
    local primary = (wide and geometry.visual_h or width) - metrics.gap
    local secondary = (wide and width or geometry.visual_h) - metrics.gap
    local direction = share == 1 and (reversed and 1 or -1)
      or (scope_index == 2 and 1 or -1)
    local delta = (values[share] - geometry.shares[share])
      * (share == 1 and primary or secondary) * direction
    if (wide and share == 1) or (not wide and share == 2) then
      delta = delta * metrics.stereo_aspect
    end
    if math.abs(delta) > 0.000001 then
      local footer = scope_footer(mode, scope_index, metrics)
      local maximum = math.min(width - metrics.gap - metrics.min_width,
        scope_width(metrics, geometry.visual_h - metrics.gap
          - metrics.min_height - footer))
      local minimum = math.min(wide and scope_width(metrics, metrics.min_height - footer)
        or metrics.min_width, maximum)
      local size = clamp(geometry.panels[scope_index].w + delta, minimum, maximum)
      local pair = wide and scope_height(metrics, size) + footer or size
      local own = wide and size or scope_height(metrics, size) + footer
      values[1] = reversed and pair / primary or 1 - pair / primary
      values[2] = scope_index == 2 and own / secondary or 1 - own / secondary
    end
  end
  -- Save the visible result, including space released by the square limit.
  return layout.geometry(geometry.mode, geometry.count, width, geometry.visual_h,
    values, metrics, order).shares
end

local function swap(order, a, b)
  local ai, bi
  for i, id in ipairs(order) do
    if id == a then ai = i end
    if id == b then bi = i end
  end
  if not ai or not bi or ai == bi then return false end
  order[ai], order[bi] = order[bi], order[ai]
  return true
end

function layout.update(prefs, action)
  local next_prefs, err = layout.normalise(prefs)
  if not next_prefs then return nil, err end
  if type(action) ~= 'table' then return nil, 'Invalid reference panel action.' end
  local kind = action.type
  if kind == 'reset' then return layout.defaults() end
  if kind == 'set_mode' then
    if action.mode ~= 'auto' and not VALID_SHAPE[action.mode] then
      return nil, 'Invalid reference panel arrangement.'
    end
    next_prefs.mode = action.mode
  elseif kind == 'toggle_panel' then
    if not VALID_ID[action.id] or type(action.enabled) ~= 'boolean' then
      return nil, 'Invalid reference panel choice.'
    end
    local enabled = enabled_map(next_prefs)
    enabled[action.id] = action.enabled
    next_prefs.enabled = filtered(IDS, enabled)
    if #next_prefs.enabled == 0 then return nil, 'Keep at least one panel visible.' end
  elseif kind == 'swap' or kind == 'fallback_swap' then
    local enabled = enabled_map(next_prefs)
    if not enabled[action.a] or not enabled[action.b] then
      return nil, 'Invalid panel swap.'
    end
    if kind == 'swap' and not layout.can_swap(next_prefs, action.mode, action.a, action.b) then
      return nil, 'Invalid panel swap.'
    end
    local order = kind == 'fallback_swap' and next_prefs.fallback
      or next_prefs.orders[action.mode]
    if not order or not swap(order, action.a, action.b) then
      return nil, 'Invalid panel swap.'
    end
  elseif kind == 'set_single' then
    if not VALID_ID[action.id] or not enabled_map(next_prefs)[action.id] then
      return nil, 'Invalid reference panel choice.'
    end
    local first = next_prefs.fallback[1]
    if action.id ~= first then swap(next_prefs.fallback, first, action.id) end
  elseif kind == 'split' then
    if not VALID_SHAPE[action.mode] or (action.count ~= 2 and action.count ~= 3)
        or (action.share ~= 1 and action.share ~= 2)
        or not finite(action.value) or action.value < 0 or action.value > 1 then
      return nil, 'Invalid divider position.'
    end
    if action.count == 2 and action.share ~= 1 then
      return nil, 'Invalid divider position.'
    end
    if action.shares ~= nil then
      if type(action.shares) ~= 'table' or not finite(action.shares[1])
          or not finite(action.shares[2]) or action.shares[1] < 0 or action.shares[1] > 1
          or action.shares[2] < 0 or action.shares[2] > 1 or action.shares[3] ~= nil then
        return nil, 'Invalid divider position.'
      end
      next_prefs.splits[key(action.mode, action.count)] = copy_list(action.shares)
    else
      next_prefs.splits[key(action.mode, action.count)][action.share] = action.value
    end
  else
    return nil, 'Invalid reference panel action.'
  end
  return next_prefs
end

return layout
