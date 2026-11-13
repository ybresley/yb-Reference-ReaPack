-- What a docked card shows at a given height: the Reference card, and the
-- docked Library's picker form, which mirrors it row for row.
--
-- A card always has its top row (picker) and bottom row (transport). Between
-- them, fullest first:
--   details line, readings in 3 rows, waveform with its ruler
--   readings in 3, 2 or 1 rows, waveform
--   waveform alone
--   no waveform: the details line centred between the rows, with the spacing
--   tightening as height runs out, then the two rows alone
-- The waveform takes every spare pixel, so the card always fills its height.
-- Pure: no reaper.* calls.
local plan = {}

-- The readings block: a hairline with a gap either side, then the rows. nil
-- when that number of rows does not fit the card's width.
local function readings_h(s, n)
  local rows = s.rows[n]
  if not rows then return nil end
  return 2 * s.gap + s.stroke + rows
end
plan.readings_height = readings_h

-- s holds measured sizes in pixels:
--   ctrl                      control height
--   pad, gap                  card padding and the gap between rows
--   tight_pad                 the smallest padding, for short cards; the gap
--   facts_h                   the details line
--   ruler                     the waveform's time ruler
--   stroke                    hairline thickness
--   rows[1..3]                height of 1, 2 or 3 rows of readings, or false
--                             when that form does not fit the width
--   wave_facts                smallest waveform (without ruler) that keeps the details line
--   wave_readings             smallest waveform that keeps any readings
--   wave_min                  smallest waveform at all
--   wave_natural              the waveform's height when the card is not stretched
-- Fills `out` (reused by callers) with:
--   facts      whether the details line shows
--   readings   0 to 3 rows
--   wave       the waveform's height including its ruler, 0 for none
--   pad        top and bottom padding
--   height     the card's height: h, or its minimum when h is smaller
function plan.fit(h, s, out)
  out = out or {}
  local top, bottom = s.pad + s.ctrl, s.gap + s.ctrl + s.pad
  out.pad, out.height = s.pad, h

  local r3 = readings_h(s, 3)
  if r3 then
    local wave = h - top - (s.gap + s.facts_h) - r3 - s.gap - bottom
    if wave - s.ruler >= s.wave_facts then
      out.facts, out.readings, out.wave = true, 3, wave
      return out
    end
  end
  for n = 3, 1, -1 do
    local rh = readings_h(s, n)
    if rh then
      local wave = h - top - rh - s.gap - bottom
      if wave - s.ruler >= s.wave_readings then
        out.facts, out.readings, out.wave = false, n, wave
        return out
      end
    end
  end
  local wave = h - top - s.gap - bottom
  if wave - s.ruler >= s.wave_min then
    out.facts, out.readings, out.wave = false, 0, wave
    return out
  end

  -- No waveform. The rows stay at the padding from each edge.
  out.readings, out.wave = 0, 0
  local natural = 2 * s.pad + 2 * s.ctrl + 2 * s.gap + s.facts_h
  local tight = 2 * s.tight_pad + 2 * s.ctrl + 2 * s.gap + s.facts_h
  if h >= natural then
    out.facts = true
  elseif h >= tight then
    out.facts = true
    out.pad = s.tight_pad + (s.pad - s.tight_pad) * (h - tight) / (natural - tight)
  else
    out.facts = false
    local minimum = plan.minimum(s)
    out.height = math.max(h, minimum)
    out.pad = math.max(s.tight_pad, math.min(s.pad, (out.height - 2 * s.ctrl - s.gap) / 2))
  end
  return out
end

-- The shortest card: both rows at the tightest padding, still a full gap apart.
function plan.minimum(s)
  return 2 * s.tight_pad + 2 * s.ctrl + s.gap
end

-- The card at its unstretched height: details, three rows of readings and the
-- waveform at its natural height. Used where the card sits above other content.
function plan.natural(s)
  local r3 = readings_h(s, 3) or 0
  return s.pad + s.ctrl + s.gap + s.facts_h + r3 + s.gap + s.wave_natural + s.ruler
    + s.gap + s.ctrl + s.pad
end

-- The most reading rows, up to `limit`, that fit the width.
function plan.rows_up_to(s, limit)
  for n = limit or 3, 1, -1 do
    if s.rows[n] then return n end
  end
  return 0
end

return plan
