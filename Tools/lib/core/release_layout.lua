-- Geometry for the What's New release showcase cards.
-- This module is pure so the screen can use the same rules in tests and at runtime.

local layout = {}

local function finite_positive(value)
  return type(value) == "number" and value == value and value > 0
    and value < math.huge
end

local function finite_number(value)
  return type(value) == "number" and value == value and value < math.huge
    and value > -math.huge
end

local function clamp(value, low, high)
  if value < low then return low end
  if value > high then return high end
  return value
end

local function add_row(cards, x, y, width, height, count, gap, selected)
  if count == 1 then
    cards[#cards + 1] = { x = x, y = y, w = width, h = height }
    return
  end

  local weight_total = count - 1 + 2.9
  local available = width - gap * (count - 1)
  local unit = available / weight_total
  local cursor = x
  for i = 1, count do
    local card_width = unit * ((i == selected) and 2.9 or 1)
    cards[#cards + 1] = { x = cursor, y = y, w = card_width, h = height }
    cursor = cursor + card_width + gap
  end
end

local function add_equal_row(cards, x, y, width, height, count, gap)
  local card_width = (width - gap * (count - 1)) / count
  for i = 1, count do
    cards[#cards + 1] = {
      x = x + (i - 1) * (card_width + gap), y = y,
      w = card_width, h = height,
    }
  end
end

function layout.cards(width, count, selected, scale)
  if not finite_positive(width) or not finite_positive(count) then
    return { height = 0, narrow = false, cards = {} }
  end
  count = math.floor(count)
  if count < 1 then return { height = 0, narrow = false, cards = {} } end
  scale = finite_positive(scale) and scale or 1
  selected = tonumber(selected)
  if not finite_number(selected) then selected = 1 end
  selected = math.floor(selected)
  selected = clamp(selected, 1, count)

  local inset = math.min(5 * scale, width * 0.5)
  local gap = 4 * scale
  local card_height = 184 * scale
  local cards = {}
  local narrow = width < 560 * scale

  if not narrow then
    local content_width = math.max(0, width - inset * 2)
    if count <= 4 then
      add_row(cards, inset, inset, content_width, card_height, count, gap, selected)
      return { height = inset * 2 + card_height, narrow = false, cards = cards }
    end

    -- The selected feature gets a full row so it remains the visual focus while
    -- large releases still expose every other feature below it.
    cards[selected] = { x = inset, y = inset, w = content_width, h = card_height }
    local remaining = count - 1
    local row_y = inset + card_height + gap
    local row_count = math.ceil(remaining / 4)
    local feature_index = 1
    for row = 1, row_count do
      local columns = math.min(4, remaining - (row - 1) * 4)
      local row_cards = {}
      add_equal_row(row_cards, inset, row_y, content_width, card_height, columns, gap)
      for _, card in ipairs(row_cards) do
        while feature_index == selected or cards[feature_index] ~= nil do
          feature_index = feature_index + 1
        end
        cards[feature_index] = card
      end
      row_y = row_y + card_height + gap
    end
    return {
      height = inset * 2 + card_height * (row_count + 1) + gap * row_count,
      narrow = false, cards = cards,
    }
  end

  local narrow_height = 171 * scale
  local narrow_gap = 5 * scale
  local content_width = math.max(0, width - inset * 2)
  cards[selected] = { x = inset, y = inset, w = content_width, h = narrow_height }
  if count == 1 then
    return { height = inset * 2 + narrow_height, narrow = true, cards = cards }
  end

  local others = count - 1
  local columns = math.floor((content_width + narrow_gap) / (100 * scale + narrow_gap))
  columns = clamp(columns, 1, 3)
  local rows = math.ceil(others / columns)
  local row_height = 86 * scale
  local row_y = inset + narrow_height + narrow_gap
  local feature_index = 1
  for row = 1, rows do
    local row_count = math.min(columns, others - (row - 1) * columns)
    local row_cards = {}
    add_equal_row(row_cards, inset, row_y, content_width, row_height, row_count, narrow_gap)
    for _, card in ipairs(row_cards) do
      while feature_index == selected or cards[feature_index] ~= nil do
        feature_index = feature_index + 1
      end
      cards[feature_index] = card
    end
    row_y = row_y + row_height + narrow_gap
  end
  return {
    height = inset * 2 + narrow_height + narrow_gap + rows * row_height
      + (rows - 1) * narrow_gap,
    narrow = true, cards = cards,
  }
end

return layout
