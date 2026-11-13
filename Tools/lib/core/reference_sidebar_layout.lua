-- Places the Reference card, the optional docked Library and the panels.
--
-- The card is one column. Beside the panels it runs the full height, and
-- core/card_plan.lua decides what fits inside it; the waveform takes the spare
-- height, so nothing is ever left empty below it. Above other content (the
-- panels in a narrow window, or the docked Library in a tall one) it keeps its
-- natural height instead.
-- Beside the panels or the Library the card keeps its own measured width, so
-- resizing the Library never resizes it. Only stacked above the Library does it
-- share the Library's width, up to the Library's maximum. The panels always
-- stay; they compress instead.
local layout = {}

-- Unscaled sizes. The Library widths match its embedded limits.
local GAP, LIBRARY_MIN, LIBRARY_MAX, PANELS_MIN = 8, 220, 440, 300
-- Panels below a top card need at least this much height to stay useful.
local PANELS_MIN_H = 180

local function clamp(v, lo, hi) return math.max(lo, math.min(v, hi)) end

local function rect(x, y, w, h) return { x = x, y = y, w = w, h = h } end

local function measures(opts)
  local scale = opts.scale or 1
  local m = {
    gap = GAP * scale, panels_min = PANELS_MIN * scale, panels_min_h = PANELS_MIN_H * scale,
    block_min = opts.block_width,
    card_min = opts.card_minimum, card_natural = math.max(opts.card_minimum, opts.card_natural),
  }
  m.lib_min = math.max(LIBRARY_MIN * scale, opts.library_minimum or 0)
  m.lib_max = math.max(LIBRARY_MAX * scale, m.lib_min)
  -- The shared column's width: the remembered Library width, never narrower
  -- than the Library or the card needs.
  local floor = math.max(m.lib_min, m.block_min)
  m.column = clamp((opts.library_width or LIBRARY_MIN) * scale, floor, math.max(m.lib_max, floor))
  return m, scale
end

-- The shared column's width when the card stacks above the Library: the
-- remembered width, narrowed to keep the panels their minimum.
local function stacked_column(m, w)
  return math.max(math.max(m.lib_min, m.block_min), math.min(m.column, w - m.gap - m.panels_min))
end

-- The width the Library would have stacked below the card, so its height
-- needs are measured at that width (opts as for resolve; the heights are not
-- needed).
function layout.stacked_width(opts)
  return stacked_column(measures(opts), opts.width)
end

-- opts:
--   width, height          available area in pixels
--   scale                  UI scale
--   library                true while the Library is docked here
--   library_width          remembered Library width, unscaled
--   library_minimum        measured Library minimum width in pixels
--   library_min_height     the docked Library's height with its list showing
--   library_keep_height    the same with its waveform at the user's height
--   block_width            measured minimum card width in pixels
--   card_minimum           the card's smallest height
--   card_natural           the card's height when it is not stretched
--   card_height            the card's dragged height above the Library,
--                          unscaled; nil for its natural height
-- Returns the regions relative to the area's top-left corner. `placement` is
-- 'side', 'top', 'stacked' (card above the Library) or 'beside_library'.
function layout.resolve(opts)
  local m, scale = measures(opts)
  local w, h, gap = opts.width, opts.height, m.gap
  local result = { gap = gap, height = h }

  if opts.library then
    -- Stacked: the card sits above the Library and shares its width, when the
    -- Library below still shows its list.
    local column = stacked_column(m, w)
    local room = h - gap - (opts.library_min_height or 0)
    if room >= m.card_natural then
      -- The dragged height, from the card's minimum (it folds) up to what
      -- leaves the Library its list and its waveform's own height, though
      -- never short of the natural height. Whether to stack still follows
      -- the natural height, so dragging never switches the arrangement.
      local keep = h - gap - (opts.library_keep_height or opts.library_min_height or 0)
      local card_h = opts.card_height
        and clamp(opts.card_height * scale, m.card_min, math.max(keep, m.card_natural))
        or m.card_natural
      result.placement = 'stacked'
      result.width = math.max(w, column + gap + m.panels_min)
      result.strip = rect(0, 0, column, card_h)
      result.reference = rect(0, 0, column, card_h)
      result.library = rect(0, card_h + gap, column, h - card_h - gap)
      result.resize_x = column
      result.resize_y = card_h
      result.panels = rect(column + gap, 0, result.width - column - gap, h)
      return result
    end

    -- Otherwise the Library, then the card, then the panels, all full height.
    -- The card keeps its own width and the Library narrows first, so the
    -- panels keep theirs.
    local strip_w = m.block_min
    local library = clamp(math.min(m.column, w - 2 * gap - strip_w - m.panels_min), m.lib_min, m.lib_max)
    local strip_x = library + gap
    local card_h = math.max(h, m.card_min)
    result.placement = 'beside_library'
    result.width = math.max(w, strip_x + strip_w + gap + m.panels_min)
    result.library = rect(0, 0, library, card_h)
    result.strip = rect(strip_x, 0, strip_w, h)
    result.reference = rect(strip_x, 0, strip_w, card_h)
    result.resize_x = library
    result.panels = rect(strip_x + strip_w + gap, 0, result.width - strip_x - strip_w - gap, h)
    return result
  end

  -- On the side whenever the panels keep their minimum width beside it.
  -- Narrower windows put the card across the top when the panels below keep a
  -- useful height; otherwise the side still wins and the view scrolls.
  local side_fits = w - m.block_min - gap >= m.panels_min
  if not side_fits and h - m.card_natural - gap >= m.panels_min_h then
    result.placement = 'top'
    result.width = math.max(w, m.block_min, m.panels_min)
    result.strip = rect(0, 0, result.width, m.card_natural)
    result.reference = rect(0, 0, result.width, m.card_natural)
    result.panels = rect(0, m.card_natural + gap, result.width, h - m.card_natural - gap)
    return result
  end
  -- The panels share the whole area with the card at its left edge (shared):
  -- the card covers some of their top rows, and the panels' own layout decides
  -- which (core/layout_prototype.lua's measure_with_card). The card's height
  -- here is the full-height column it falls back to.
  local strip_w = m.block_min
  result.placement = 'side'
  result.shared = true
  result.width = math.max(w, strip_w + gap + m.panels_min)
  result.strip = rect(0, 0, strip_w, h)
  result.reference = rect(0, 0, strip_w, math.max(h, m.card_min))
  result.panels = rect(0, 0, result.width, h)
  return result
end

-- The smallest area that shows the card, the Library when docked, and the
-- panels; used for the floating window's floor. A short window puts the
-- Library beside the card, so that arrangement sets the width.
function layout.minimum(opts)
  local m, scale = measures(opts)
  if not opts.library then return m.block_min + m.gap + m.panels_min, m.card_min end
  local library = math.max(LIBRARY_MIN * scale, opts.library_minimum or 0)
  return library + m.gap + m.block_min + m.gap + m.panels_min, m.card_min
end

return layout
