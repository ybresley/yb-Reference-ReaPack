-- Layout preferences have their own record so older builds can keep using the
-- existing two-panel settings without erasing the three-panel arrangement.
local core = require('core.reference_layout')
local api = require('reaper_api')
local panels = {}
local SECTION, KEY = 'yb-Reference', 'reference_panels_v1'

function panels.load(spectrum_prefs)
  local text = reaper.GetExtState(SECTION, KEY)
  if text and text ~= '' then
    local prefs, err = core.decode(text)
    return prefs or core.defaults(), err
  end
  return core.migrate(api.get_reference_layout(), spectrum_prefs.split,
    api.get_reference_stack_split(), spectrum_prefs.visual)
end

function panels.save(prefs, load_error)
  if load_error then return nil, load_error end
  local text, err = core.encode(prefs)
  if not text then return nil, err end
  reaper.SetExtState(SECTION, KEY, text, true)
  return true
end

return panels
