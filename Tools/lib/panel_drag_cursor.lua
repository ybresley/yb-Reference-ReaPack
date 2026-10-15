-- Native cursor ownership stays outside the UI. Load once and restore the
-- pointer when a drag ends, the window closes, or the script exits.
local cursor = {}
local hand, arrow, active, load_error

function cursor.prepare(path)
  cursor.shutdown()
  hand, arrow, load_error = nil, nil, nil
  for _, name in ipairs({'JS_Mouse_LoadCursorFromFile','JS_Mouse_LoadCursor','JS_Mouse_SetCursor'}) do
    if not reaper.APIExists(name) then
      load_error = 'Closed-hand cursor unavailable: install or update js_ReaScriptAPI.'
      return false, load_error
    end
  end
  hand = reaper.JS_Mouse_LoadCursorFromFile(path)
  arrow = reaper.JS_Mouse_LoadCursor(32512)
  if not hand or not arrow then
    load_error = 'The closed-hand cursor could not be loaded.'
    return false, load_error
  end
  return true
end

function cursor.update(requested)
  if requested then
    if not hand or not arrow then return false, load_error or 'The closed-hand cursor is unavailable.' end
    -- REAPER may replace the cursor between frames, so renew it while held.
    reaper.JS_Mouse_SetCursor(hand)
    active = true
  elseif active then
    reaper.JS_Mouse_SetCursor(arrow)
    active = false
  end
  return true
end

function cursor.shutdown()
  return cursor.update(false)
end

return cursor
