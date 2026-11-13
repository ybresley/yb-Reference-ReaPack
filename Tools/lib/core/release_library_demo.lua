-- Timing and sample data for the Docked Library release demonstration.
-- Pure: no reaper.*.
--
-- The Library starts in its separate window over Reference View. The pointer
-- presses Dock to Reference View in that window's toolbar, and the Library
-- moves to the left of the Reference card. The pointer then drags the
-- Library's edge wider, narrower and back to a middle width, selects the
-- sample sound (which auditions it), clicks its waveform to jump back, and
-- returns home while the audition plays out.
local schema = require('core.schema')
local search = require('core.search')
local categories = require('core.categories')

local demo = {}

-- The sample sound is the measured 4 s passage the Reference card examples use.
demo.SOUND_SECONDS = 4
demo.SAMPLE_ID = 's4'
-- The live default for the docked Library's remembered width, unscaled
-- (reaper_api.get_library_panel_width).
demo.LIBRARY_WIDTH = 280
-- Where the pointer clicks the Library's waveform, as a share of its width.
demo.SEEK_FRACTION = .25

local DOCK, PRESS, RELEASE, SELECT, SEEK = 1.5, 3, 6.7, 8.15, 9.55
local SEEK_AT = demo.SEEK_FRACTION * demo.SOUND_SECONDS
-- The audition runs from SELECT, jumps back at SEEK, and then plays out.
local AUDITION_END = SEEK + demo.SOUND_SECONDS - SEEK_AT
local DURATION = AUDITION_END + .35
local PULSE = .25

-- The other rows are list entries only: a name, a category, a length, a channel
-- count and the integrated loudness the list shows. Only the sample sound is
-- ever selected, so only it needs a waveform and the full set of readings.
local ROWS = {
  {'Crowd Murmur Stadium Distant', 'Ambience', 24, 2, -24.6},
  {'Door Wood Creak Open', 'SFX', 2.8, 1, -21.3},
  {'Footsteps Gravel Walk', 'SFX', 9.6, 1, -26.1},
  false, -- the sample sound
  {'Menu Confirm Soft', 'UI', .6, 2, -15.8},
  {'Menu Hover Tick', 'UI', .2, 2, -19.4},
  {'Music Stinger Victory', 'Music', 6.5, 2, -11.2},
  {'Narrator Line Intro 01', 'Dialogue', 3.9, 1, -20.5},
  {'Rain on Leaves Light', 'Ambience', 30, 2, -29.7},
}

-- `sample`: { name, duration, channels, readings = { lufs_i, ... } }, the
-- measured sound the renderer supplies.
function demo.library(sample)
  local lib = schema.starter_library()
  local by_name = {}
  for _, c in ipairs(lib.categories) do by_name[c.name] = c.id end
  for i, row in ipairs(ROWS) do
    local s
    if row then
      s = {name = row[1], category = by_name[row[2]], duration = row[3], channels = row[4],
        lufs_i = row[5]}
    else
      s = {name = sample.name, category = by_name.Ambience, duration = sample.duration,
        channels = sample.channels}
      for key, value in pairs(sample.readings) do s[key] = value end
    end
    s.id, s.file, s.analysis = 's' .. i, s.name .. '.wav', 'done'
    lib.sounds[i] = s
  end
  lib.seq.sound = #ROWS
  return lib
end

-- The All view sorted by name, with its counts, as the entry script keeps them.
function demo.view(lib)
  local view, query = {scope = 'all'}, ''
  local visible = search.sort(search.filter(lib, view, query), 'name', true)
  local counts = categories.counts(lib, query)
  return view, visible, counts
end

function demo.duration() return DURATION end

-- With Interface Animations off a demo still plays its steps, but each move
-- lands at once instead of gliding there.
local function ease(value, still)
  value = math.max(0, math.min(1, value))
  if still then return value > 0 and 1 or 0 end
  return value * value * (3 - 2 * value)
end

-- The pointer: {start, from, to, travel seconds}; a step whose from and to
-- match is a rest. 'edge' is the gap at the Library's right edge, wherever the
-- Library's width puts it, so the pointer rides the edge while it drags.
local STEPS = {
  {0, 'home', 'home'}, {.35, 'home', 'dock', .85}, {1.2, 'dock', 'dock'},
  {1.85, 'dock', 'edge', .85}, {2.7, 'edge', 'edge'},
  {7, 'edge', 'row', .85}, {7.85, 'row', 'row'},
  {8.5, 'row', 'wave', .75}, {9.25, 'wave', 'wave'},
  {9.9, 'wave', 'home', .85}, {10.75, 'home', 'home'},
}
local CLICKS = {DOCK, PRESS, SELECT, SEEK}
-- The Library's width while the edge is held: {start, from, to, seconds}, in
-- unscaled pixels. The layout keeps it inside the Library's limits, as it does
-- for a live drag, so the narrowest request may stop short.
local DRAGS = {
  {PRESS, demo.LIBRARY_WIDTH, 420, 1}, {4.3, 420, 230, 1.2}, {5.8, 230, 320, .9},
}
-- The edge highlights while the pointer is over it, and more strongly while held.
local HOT = {{2.7, PRESS}, {RELEASE, 7}}

local function place(out, phase, still)
  local step = STEPS[1]
  for _, candidate in ipairs(STEPS) do
    if phase >= candidate[1] then step = candidate end
  end
  out.from, out.to = step[2], step[3]
  out.progress = (step[2] == step[3] or not step[4]) and 1
    or ease((phase - step[1]) / step[4], still)
end

local function library_width(phase, still)
  local width = demo.LIBRARY_WIDTH
  for _, drag in ipairs(DRAGS) do
    if phase >= drag[1] then
      width = drag[2] + (drag[3] - drag[2]) * ease((phase - drag[1]) / drag[4], still)
    end
  end
  return width
end

-- Fills `out` with the scene at `elapsed` seconds since the topic opened:
--   phase, loop          time within the loop, and which loop (from 1)
--   from, to, progress   the pointer's move between two named anchors
--   pulse                0..1 through the ring after a click or press, else nil
--   docked               the Library is docked beside the Reference card;
--                        before that it is in its separate window
--   library_width        the docked Library's requested width, unscaled
--   edge                 'hot' while the pointer rests on the Library's edge,
--                        'held' while it drags it, else nil
--   selected             the sample sound is the Library's selection
--   playing, position    the Library's audition and its playhead in seconds
--   start_serial         changes each time the audition starts from the top
function demo.sample(elapsed, out, still)
  out = out or {}
  for key in pairs(out) do out[key] = nil end
  local time = tonumber(elapsed) or 0
  if time ~= time or math.abs(time) == math.huge then time = 0 end
  time = math.max(0, time)
  local phase = time % DURATION
  out.phase, out.loop = phase, math.floor(time / DURATION) + 1
  place(out, phase, still)
  for _, click in ipairs(CLICKS) do
    if phase >= click and phase < click + PULSE then out.pulse = (phase - click) / PULSE end
  end

  out.docked = phase >= DOCK
  out.library_width = library_width(phase, still)
  if phase >= PRESS and phase < RELEASE then
    out.edge = 'held'
  else
    for _, span in ipairs(HOT) do
      if phase >= span[1] and phase < span[2] then out.edge = 'hot' end
    end
  end

  out.selected = phase >= SELECT
  out.playing = out.selected and phase < AUDITION_END
  if not out.playing then
    out.position = 0
  elseif phase < SEEK then
    out.position = phase - SELECT
  else
    out.position = SEEK_AT + phase - SEEK
  end
  out.start_serial = out.loop
  return out
end

return demo
