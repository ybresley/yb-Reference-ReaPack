-- duration_text: how a sound's length reads in the Library and the Reference
-- Picker. Most game sounds are well under ten seconds, where whole seconds
-- cannot tell a 0.2 s click from a 0.4 s one, so short sounds show tenths.
--
-- Pure Lua.

local duration_text = {}

function duration_text.format(seconds)
  local sec = math.max(0, tonumber(seconds) or 0)
  -- An unreadable length can arrive as infinity, which has no whole-number form.
  if sec == math.huge then sec = 0 end
  local tenths = math.floor(sec * 10 + 0.5)
  if tenths < 100 then return string.format("%d.%d s", tenths // 10, tenths % 10) end
  local whole = math.floor(sec + 0.5)
  return string.format("%d:%02d", whole // 60, whole % 60)
end

return duration_text
