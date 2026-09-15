-- Pure state for the first-open guided tour.

local walkthrough = {}

walkthrough.STOPS = {
  { id = "library", window = "browser", button = "Next",
    title = "YOUR LIBRARY",
    body = "Drop audio files here to add them to your Library. Preview sounds and organise them with categories. Your Library is shared across all your Reaper projects." },
  { id = "pin", window = "main", button = "Next",
    title = "PIN A REFERENCE",
    body = "Drag a sound onto this window to pin it to the project. Pinned references are saved with the project so they stay available when it is reopened.",
    note = "You can drag a sound from the Library, Reaper, or a folder on your computer." },
  { id = "layout", window = "main", button = "Next",
    title = "WAVEFORM & SPECTRUM",
    body = "View your audio's waveform and frequency content here. The tool automatically adds a helper to your Monitor FX chain so the spectrum analyser can display both your references and Reaper's audio.",
    note = "Drag the divider in between the displays to resize them. Auto layout rearranges them when you resize the window; lock the layout in Settings → Appearance." },
  { id = "latch", window = "main", button = "Next",
    title = "PLAY & REFERENCE MODE",
    body = "Play references directly in yb-Reference, or enable Latch to trigger them with Reaper's playback. Latch mutes your project so you hear the selected reference instead.",
    note = "Turn Latch off to hear your project again." },
  { id = "transport", window = "main", button = "Done",
    title = "REFERENCE CONTROLS",
    body = "Use these controls to switch between references, change playback settings, inspect loudness measurements and adjust the reference level. Hover over a control to see what it does.",
    note = "Replay the tutorial anytime from Settings → Help." },
}

walkthrough.FROZEN_BODY = "Reopen the Library to continue."
walkthrough.FROZEN_BUTTON = "Open"
walkthrough.FROZEN_ACT = "open_browser"

function walkthrough.new()
  return { active = false, pos = nil, browser_open = false }
end

-- Kept for the existing entry-script call. The tour now starts on its first
-- card so the Library can be opened automatically by the caller.
function walkthrough.begin_welcome(s)
  walkthrough.begin_stops(s)
end

function walkthrough.begin_stops(s)
  s.active = true
  s.pos = 1
end

function walkthrough.skip(s)
  s.active = false
  s.pos = nil
end

function walkthrough.next(s)
  if not s.active then return end
  if s.pos >= #walkthrough.STOPS then
    walkthrough.skip(s)
  else
    s.pos = s.pos + 1
  end
end

function walkthrough.previous(s)
  if not s.active or not s.pos or s.pos <= 1 then return end
  s.pos = s.pos - 1
end

-- Browser state remains useful to keep the Library card parked safely if the
-- window is closed while the tour is active. These events never advance cards.
function walkthrough.event(s, name)
  if name == "browser_opened" then
    s.browser_open = true
  elseif name == "browser_closed" then
    s.browser_open = false
  end
end

function walkthrough.current(s)
  if not s.active then return nil end
  return walkthrough.STOPS[s.pos]
end

function walkthrough.is_frozen(s)
  if not s.active or not s.pos then return false end
  local stop = walkthrough.STOPS[s.pos]
  return stop and stop.window == "browser" and not s.browser_open or false
end

return walkthrough
