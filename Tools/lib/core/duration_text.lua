-- duration_text: how a sound's length reads in the Library, the Reference
-- card and the Reference Picker. One clock style for every length,
-- minutes:seconds.tenths ("0:02.3"), so a column of lengths reads the same
-- from top to bottom. Most game sounds are well under ten seconds, where
-- whole seconds cannot tell a 0.2 s click from a 0.4 s one, so every length
-- keeps its tenths.
--
-- Pure Lua.

local duration_text = {}

function duration_text.format(seconds)
  local sec = math.max(0, tonumber(seconds) or 0)
  -- An unreadable length can arrive as infinity, which has no whole-number form.
  if sec == math.huge then sec = 0 end
  local tenths = math.floor(sec * 10 + 0.5)
  return string.format("%d:%02d.%d", tenths // 600, (tenths // 10) % 60, tenths % 10)
end

return duration_text
