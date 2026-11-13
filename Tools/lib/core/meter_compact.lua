-- Pure geometry for the compact numeric loudness surface. Coordinates are
-- physical pixels relative to that surface; the caller has removed its footer.
local compact = {}

local PRIMARY = { "m", "s", "i", "tp" }
compact.value_sizes = { 26, 24, 22, 20, 18, 16 }
local LABEL_SIZE = 13
local MAXIMUM_SIZE = 16
-- Reserve secondary rows for the height of a full two-by-two layout with maxima.
-- Short numeric panels keep the essentials through the bar-to-number transition.
local OPTIONAL_MIN_HEIGHT = 148
local MIN_TILE = { [26] = 120, [24] = 112, [22] = 103, [20] = 94, [18] = 84, [16] = 70 }

function compact.label_size(value_size)
  return value_size < 20 and 11 or LABEL_SIZE
end

local function finite_positive(value)
  return type(value) == "number" and value > 0
    and value < math.huge and value == value
end

local function rounded(value)
  return math.floor(value + 0.5)
end

local function cells(keys, area, columns, cell_height, gap_x, gap_y, detail)
  local rows = math.ceil(#keys / columns)
  local width = (area.w - gap_x * (columns - 1)) / columns
  local total_height = rows * cell_height + (rows - 1) * gap_y
  local start_y = area.y + (area.h - total_height) / 2
  local result = {}
  for index, key in ipairs(keys) do
    local column = (index - 1) % columns
    local row = math.floor((index - 1) / columns)
    result[#result + 1] = {
      key = key,
      x = area.x + column * (width + gap_x),
      y = start_y + row * (cell_height + gap_y),
      w = width,
      h = cell_height,
      detail = detail or false,
    }
  end
  return result
end

local function plan(area, scale, size, columns, level, details)
  local primary=details.primary_keys or PRIMARY
  local gap_x = rounded((size < 20 and 4 or 8) * scale)
  local gap_y = rounded(2 * scale)
  local measured_heights = details.text_heights or {}
  local label_size = compact.label_size(size)
  local header_height = measured_heights.headers and measured_heights.headers[size]
    or measured_heights.header or rounded((label_size + 4) * scale)
  local value_height = measured_heights.value and measured_heights.value[size]
    or rounded((size + 2) * scale)
  local show_maxima = level ~= "essential" and details.extra_readings == true
  local maximum_height = show_maxima
    and (measured_heights.maxima or rounded((MAXIMUM_SIZE + 4) * scale)) or 0
  local primary_height = header_height + value_height + maximum_height
  local rows = math.ceil(#primary / columns)
  local primary_total = rows * primary_height + (rows - 1) * gap_y
  local cell_width = (area.w - gap_x * (columns - 1)) / columns
  local measured = details.text_widths or {}
  local min_width = measured.tile and measured.tile[size] or MIN_TILE[size] * scale
  if show_maxima then min_width = math.max(min_width,
    measured.maxima or 90 * scale) end
  if cell_width < min_width or primary_total > area.h then return nil end

  local detail_keys = {}
  if level == "details" then
    if details.extra_readings then
      detail_keys = { "crest", "rms", "target" }
    end
    if details.show_lra then detail_keys[#detail_keys + 1] = "lra" end
    if #detail_keys == 0 then return nil end
  end

  local detail_value_size = 20
  local detail_header_height = measured_heights.detail_header or rounded((LABEL_SIZE + 4) * scale)
  local detail_value_height = measured_heights.detail_value
    or rounded((detail_value_size + 4) * scale)
  local detail_height = detail_header_height + detail_value_height
  local section_gap = rounded(8 * scale)
  local detail_columns = math.min(columns, #detail_keys)
  local detail_gap_x = rounded(8 * scale)
  local detail_gap_y = rounded(4 * scale)
  if #detail_keys > 0 then
    local detail_width = (area.w - detail_gap_x * (detail_columns - 1)) / detail_columns
    if detail_width < (measured.detail or 100 * scale) then return nil end
  end
  local detail_rows = #detail_keys > 0 and math.ceil(#detail_keys / detail_columns) or 0
  local detail_total = detail_rows * detail_height
    + math.max(0, detail_rows - 1) * detail_gap_y
  local total = primary_total
    + (#detail_keys > 0 and section_gap + detail_total or 0)
  if total > area.h then return nil end

  local content_y = area.y + (area.h - total) / 2
  local primary_area = { x = area.x, y = content_y, w = area.w, h = primary_total }
  local items = cells(primary, primary_area, columns, primary_height, gap_x, gap_y, false)
  if #detail_keys > 0 then
    local detail_area = {
      x = area.x,
      y = content_y + primary_total + section_gap,
      w = area.w,
      h = detail_total,
    }
    local extras = cells(detail_keys, detail_area, detail_columns,
      detail_height, detail_gap_x, detail_gap_y, true)
    for _, item in ipairs(extras) do items[#items + 1] = item end
  end

  return {
    items = items,
    level = level,
    columns = columns,
    show_maxima = show_maxima,
    value_size = size,
    label_size = label_size,
    detail_label_size = LABEL_SIZE,
    maximum_size = MAXIMUM_SIZE,
    header_height = header_height,
    value_height = value_height,
    maximum_height = maximum_height,
    detail_header_height = detail_header_height,
    detail_value_height = detail_value_height,
    detail_value_size = detail_value_size,
    area = area,
  }
end

-- options.text_widths may supply physical-pixel tile widths by value
-- size, plus maxima/detail widths. options.text_heights may supply physical
-- headers/value heights by size, maxima and detail heights from fixed strings.
function compact.measure(width, height, options)
  options = options or {}
  local scale = options.scale or 1
  if not finite_positive(width) or not finite_positive(height)
    or not finite_positive(scale) then return nil end
  local inset = rounded(8 * scale)
  if width <= 2 * inset then return nil end

  -- Keep headings above values and prefer two-row or single-row grids.
  -- Trying sizes first prevents text growth; narrow panels can use one column.
  local essential
  local grid_choices=options.primary_keys and #options.primary_keys==1 and {{1}} or {{2,4},{1}}
  for _, grids in ipairs(grid_choices) do
    for _, size in ipairs(compact.value_sizes) do
      local inset_y = rounded((size < 20 and 4 or 8) * scale)
      local area = { x = inset, y = inset_y, w = width - 2 * inset, h = height - 2 * inset_y }
      for _, columns in ipairs(grids) do
        essential = plan(area, scale, size, columns, "essential", options)
        if essential then break end
      end
      if essential then break end
    end
    if essential then break end
  end
  if not essential then return compact.measure_inline(width, height, options) end
  -- Optional content uses the established primary size and never shrinks it.
  if height < OPTIONAL_MIN_HEIGHT * scale then return essential end

  for _, level in ipairs({ "details", "maxima" }) do
    if level ~= "maxima" or options.extra_readings then
      for _, columns in ipairs({ 2, 4, 1 }) do
        local result = plan(essential.area, scale, essential.value_size, columns,
          level, options)
        if result then return result end
      end
    end
  end
  return essential
end

-- Below the stacked layouts, each label moves beside its value at the smallest
-- size, so the readings keep working in panels too short for a heading row.
-- When even that cannot fit, fewer readings remain; the panel's chosen ones
-- (options.short_keys) come first, then this order.
local SHORT_ORDER = { "i", "tp", "s", "m" }
local INLINE_SIZE = 16

local function contains(list, value)
  for _, entry in ipairs(list) do if entry == value then return true end end
  return false
end

-- The first `count` readings to keep, in slot order, without repeats.
function compact.short_keys(primary, chosen, count)
  local result = {}
  local function add(key)
    if #result < count and contains(primary, key) and not contains(result, key) then
      result[#result + 1] = key
    end
  end
  for _, key in ipairs(chosen or {}) do add(key) end
  for _, key in ipairs(SHORT_ORDER) do add(key) end
  for _, key in ipairs(primary) do add(key) end
  return result
end

-- The reading a slot shows next: the following primary reading that no other
-- slot already shows.
function compact.next_short_key(shown, slot)
  local start = 1
  for index, key in ipairs(PRIMARY) do
    if key == shown[slot] then start = index; break end
  end
  for step = 1, #PRIMARY do
    local key = PRIMARY[(start + step - 1) % #PRIMARY + 1]
    local taken = false
    for index, other in ipairs(shown) do
      if index ~= slot and other == key then taken = true end
    end
    if not taken then return key end
  end
  return shown[slot]
end

local function inline_plan(area, scale, keys, columns, options)
  local measured = options.text_widths or {}
  local heights = options.text_heights or {}
  -- Clear space between readings, so a value never reads as the next label's.
  local gap_x = rounded(16 * scale)
  local gap_y = rounded(2 * scale)
  local row_height = heights.inline
    or heights.value and heights.value[INLINE_SIZE] or rounded((INLINE_SIZE + 2) * scale)
  local min_width = measured.inline or 96 * scale
  local rows = math.ceil(#keys / columns)
  local total = rows * row_height + (rows - 1) * gap_y
  local cell_width = (area.w - gap_x * (columns - 1)) / columns
  if cell_width < min_width or total > area.h then return nil end
  return {
    items = cells(keys, area, columns, row_height, gap_x, gap_y, false),
    level = "essential",
    columns = columns,
    inline = true,
    show_maxima = false,
    value_size = INLINE_SIZE,
    label_size = compact.label_size(INLINE_SIZE),
    detail_label_size = LABEL_SIZE,
    maximum_size = MAXIMUM_SIZE,
    header_height = 0,
    value_height = row_height,
    maximum_height = 0,
    area = area,
  }
end

function compact.measure_inline(width, height, options)
  options = options or {}
  local scale = options.scale or 1
  if not finite_positive(width) or not finite_positive(height)
    or not finite_positive(scale) then return nil end
  local inset = rounded(8 * scale)
  local inset_y = rounded(4 * scale)
  if width <= 2 * inset or height <= 2 * inset_y then return nil end
  local area = { x = inset, y = inset_y, w = width - 2 * inset, h = height - 2 * inset_y }
  local primary = options.primary_keys or PRIMARY
  local counts = #primary >= 4 and { #primary, 2, 1 } or #primary == 2 and { 2, 1 } or { #primary }
  for _, count in ipairs(counts) do
    local keys = count == #primary and primary or compact.short_keys(primary, options.short_keys, count)
    local grids = count >= 4 and { count, 2 } or count == 2 and { 2, 1 } or { 1 }
    for _, columns in ipairs(grids) do
      local result = inline_plan(area, scale, keys, columns, options)
      if result then
        -- Only the four standard readings can be swapped; other frames keep theirs.
        result.reduced = count < #primary
        result.choosable = result.reduced and options.primary_keys == nil
        return result
      end
    end
  end
  return nil
end

return compact
