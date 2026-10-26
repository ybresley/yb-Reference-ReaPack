-- Pure geometry for the compact numeric loudness surface. Coordinates are
-- physical pixels relative to that surface; the caller has removed its footer.
local compact = {}

local PRIMARY = { "m", "s", "i", "tp" }
local FONTS = { 26, 24, 22, 20 }
local LABEL_SIZE = 13
local MAXIMUM_SIZE = 16
-- Reserve secondary rows for the height of a full two-by-two layout with maxima.
-- Short numeric panels keep the essentials through the bar-to-number transition.
local OPTIONAL_MIN_HEIGHT = 148
local MIN_TILE = { [26] = 120, [24] = 112, [22] = 103, [20] = 94 }
-- Inline cells must hold a label, the value, and its unit on one line.
local MIN_INLINE = { [26] = 150, [24] = 140, [22] = 130, [20] = 120 }

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

local function plan(area, scale, size, columns, inline, level, details)
  local gap_x = rounded((inline and 2 or 8) * scale)
  local gap_y = inline and 0 or rounded(2 * scale)
  local measured_heights = details.text_heights or {}
  local label_height = measured_heights.header or rounded((LABEL_SIZE + 4) * scale)
  local header_height = inline and 0 or label_height
  local value_height = measured_heights.value and measured_heights.value[size]
    or rounded((size + 2) * scale)
  local show_maxima = level ~= "essential" and details.extra_readings == true
  local maximum_height = show_maxima
    and (measured_heights.maxima or rounded((MAXIMUM_SIZE + 4) * scale)) or 0
  local primary_height = inline and value_height
    or header_height + value_height + maximum_height
  local rows = 4 / columns
  local primary_total = rows * primary_height + (rows - 1) * gap_y
  local cell_width = (area.w - gap_x * (columns - 1)) / columns
  local measured = details.text_widths or {}
  local measured_widths = inline and measured.inline or measured.tile
  local min_width = measured_widths and measured_widths[size]
    or (inline and MIN_INLINE[size] or MIN_TILE[size]) * scale
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
  local detail_header_height = measured_heights.detail_header or label_height
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
  local items = cells(PRIMARY, primary_area, columns, primary_height, gap_x, gap_y, false)
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
    inline = inline,
    show_maxima = show_maxima,
    value_size = size,
    label_size = LABEL_SIZE,
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

-- options.text_widths may supply physical-pixel tile/inline widths by value
-- size, plus maxima/detail widths. options.text_heights may supply physical
-- header, value-by-size, maxima and detail heights from the same fixed strings.
function compact.measure(width, height, options)
  options = options or {}
  local scale = options.scale or 1
  if not finite_positive(width) or not finite_positive(height)
    or not finite_positive(scale) then return nil end
  local inset = rounded(8 * scale)
  local area = { x = inset, y = inset, w = width - 2 * inset, h = height - 2 * inset }
  if area.w <= 0 or area.h <= 0 then return nil end

  -- A shallow, wide surface keeps one inline row throughout the collapse.
  -- Otherwise try every readable tile size before switching to inline labels;
  -- font fallback must not bring an earlier arrangement back while shrinking.
  local essential
  local shallow_row = plan(area, scale, 20, 4, true, "essential", options)
    and not plan(area, scale, 26, 2, false, "essential", options)
  if not shallow_row then
    for _, columns in ipairs({ 2, 4, 1 }) do
      for _, size in ipairs(FONTS) do
        essential = plan(area, scale, size, columns, false, "essential", options)
        if essential then break end
      end
      if essential then break end
    end
  end
  if not essential then
    for _, columns in ipairs(shallow_row and { 4 } or { 1, 2, 4 }) do
      for _, size in ipairs(FONTS) do
        essential = plan(area, scale, size, columns, true, "essential", options)
        if essential then break end
      end
      if essential then break end
    end
  end
  if not essential then return nil end
  -- Optional content uses the established primary size and never shrinks it.
  if essential.inline or height < OPTIONAL_MIN_HEIGHT * scale then return essential end

  for _, level in ipairs({ "details", "maxima" }) do
    if level ~= "maxima" or options.extra_readings then
      for _, columns in ipairs({ 2, 4, 1 }) do
        local result = plan(area, scale, essential.value_size, columns,
          false, level, options)
        if result then return result end
      end
    end
  end
  return essential
end

return compact
