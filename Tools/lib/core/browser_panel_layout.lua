-- Compact Library decisions use the panel's outer width, including its padding.
local layout = {}

-- The audition row is ten equal cells: play, pause, stop and loop joined in
-- four; mono, pitch and auto-audition joined in three; the volume in the last
-- three.
-- Everything stretches with the panel the way the Reference card's rows do.
local CELLS = 10

local function snap(v) return math.floor(v + 0.5) end

-- Keep a useful share for the name; fit whole facts, never partial values.
function layout.preview_heading(width, name_width, detail_widths, gap, name_minimum)
  width = math.max(0, width)
  local reserved = math.min(name_width, width, math.max(name_minimum, width * 0.6))
  for count = #detail_widths, 1, -1 do
    if reserved + gap + detail_widths[count] <= width then
      return width - gap - detail_widths[count], count
    end
  end
  return width, 0
end

-- Narrowest content that keeps every button a full control square and the
-- whole volume readout inside its three cells.
local function content_minimum(control_height, volume_width, gap)
  local cell = math.max(control_height, volume_width / 3)
  return math.ceil(CELLS * cell + 2 * gap) + 1
end

function layout.minimum_width(control_height, volume_width, metrics)
  local pad = metrics.WINDOW_PAD * 2
  local width = content_minimum(control_height, volume_width, metrics.BROWSER_PANEL_TIGHT_GAP) + pad
  if width >= metrics.BROWSER_PANEL_TIGHT_W then
    width = content_minimum(control_height, volume_width, metrics.STRIP_GROUP_GAP) + pad
  end
  return width
end

-- The docked Library has two forms:
--   'list'    category row, list, name, readings, waveform, ruler, audition row
--   'picker'  below the list's minimum, the list becomes a picker whose list
--             holds the category and search; below it the Library mirrors the
--             Reference card row for row (core/card_plan.lua)

-- The height the form with a list needs, in pixels. s holds measured sizes:
--   control, gap         control height and the vertical gap between rows
--   inset                the first row's distance from the top
--   list                 the list's smallest height (header and minimum rows)
--   readings             the readings block under the name, 0 for none
--   wave, ruler          the waveform and its ruler
--   frame_pad            space between the preview and the audition row's gap
--   bottom_pad           space below the audition row, inside the outline
-- Fills and returns h when given, so a caller can reuse one table.
function layout.form_heights(s, h)
  local c, g = s.control, s.gap
  -- The audition row and the space below it, inside the outline.
  local audition = s.frame_pad + g + c + (s.bottom_pad or 0)
  local core = c + g + s.list + g + c + (s.readings or 0) + g + s.wave + s.ruler + audition
  h = h or {}
  h.list = s.inset + core
  return h
end

-- The form for `height`, given form_heights' result.
function layout.form(height, heights)
  return height >= heights.list and "list" or "picker"
end

-- Group edges are relative to the content's left edge. `cell` is the Reference
-- card's button width when the Library is docked beside it: the buttons take
-- that width and the volume takes the rest, but the buttons never grow past
-- an equal share, so the volume keeps at least its three cells. Without it,
-- all ten cells share the width equally.
-- The separate window's audition row: as wide as the content up to
-- `max_width`, centred in what is left. Returns the row's width and its
-- offset from the content's left edge.
function layout.capped_row(content_width, max_width)
  local width = math.min(content_width, max_width)
  return width, snap((content_width - width) / 2)
end

function layout.geometry(content_width, control_height, metrics, cell)
  local panel_width = content_width + metrics.WINDOW_PAD * 2
  local gap = panel_width < metrics.BROWSER_PANEL_TIGHT_W
    and metrics.BROWSER_PANEL_TIGHT_GAP or metrics.STRIP_GROUP_GAP
  local equal = (content_width - 2 * gap) / CELLS
  cell = math.max(control_height, cell and math.min(cell, equal) or equal)
  local playback_end = snap(4 * cell)
  local listening_x = playback_end + gap
  local listening_end = snap(7 * cell + gap)
  local volume_x = listening_end + gap
  return {
    loudness = panel_width >= metrics.BROWSER_PANEL_LOUD_W,
    channels = panel_width >= metrics.BROWSER_PANEL_CHANNELS_W,
    gap = gap,
    playback_end = playback_end,
    listening_x = listening_x,
    listening_end = listening_end,
    volume_x = volume_x,
    volume_width = math.max(1, content_width - volume_x),
  }
end

return layout
