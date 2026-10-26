-- Pure state for the first-open guided tour.

local walkthrough = {}

walkthrough.STOPS = {
  { id = "welcome", window = "main", button = "Start Tutorial",
    title = "WELCOME",
    body = "Take a short tour of the main controls." },
  { id = "library", window = "browser", button = "Next",
    title = "YOUR LIBRARY",
    body = "Drop audio files here to add them to your Library. Preview sounds and organise them with categories. Your Library is shared across all your Reaper projects.",
    reopen = { body = "Reopen the Library to continue.", button = "Open",
      act = "open_browser", target = "library_button" } },
  { id = "pin", window = "main", button = "Next",
    title = "REFERENCE VIEW",
    body = "Drag a sound here to pin it to the project. The panels show waveform, spectrum, stereo image, loudness readings and history.",
    note = "Pins are saved with the project. Drag the gaps to resize panels." },
  { id = "latch", window = "main", button = "Next",
    title = "PLAY & REFERENCE MODE",
    body = "Play references directly in yb-Reference, or enable Latch to trigger them with Reaper's playback. Latch mutes your project so you hear the selected reference instead.",
    note = "Turn Latch off to hear your project again." },
  { id = "transport", window = "main", button = "Next",
    title = "REFERENCE CONTROLS",
    body = "Use these controls to switch between references, change playback settings, inspect loudness measurements and adjust the reference level. Hover over a control to see what it does." },
  { id = "feedback", window = "settings", button = "Done",
    title = "SEND FEEDBACK",
    body = "I'm always looking to improve this tool, so please send through any bug reports or feature requests you have!",
    note = "Replay the tutorial anytime from Settings → Help.",
    reopen = { body = "Reopen Settings → Feedback to continue.", button = "Open",
      act = "open_feedback", target = "settings_button" } },
}

function walkthrough.new()
  return { active = false, pos = nil, browser_open = false, feedback_open = false }
end

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

-- Closed tutorial windows offer a way back without advancing the lesson.
function walkthrough.event(s, name)
  if name == "browser_opened" then
    s.browser_open = true
  elseif name == "browser_closed" then
    s.browser_open = false
  elseif name == "feedback_opened" then
    s.feedback_open = true
  elseif name == "feedback_closed" then
    s.feedback_open = false
  end
end

function walkthrough.current(s)
  if not s.active then return nil end
  return walkthrough.STOPS[s.pos]
end

function walkthrough.is_frozen(s)
  if not s.active or not s.pos then return false end
  local stop = walkthrough.STOPS[s.pos]
  if not stop then return false end
  return stop.window == "browser" and not s.browser_open
    or stop.window == "settings" and not s.feedback_open
end

return walkthrough
