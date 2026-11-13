-- text_fold: case-insensitive keys for search, name sorting and import names.
--
-- Lua's lower() only folds the unaccented A-Z, so "École" and "école" would
-- never meet. Sound names in a reference library are mostly Latin-script, so a
-- small table covering Latin-1 and Latin Extended-A (À-Þ, Ā-ž) handles the
-- names people actually type without pulling in a full Unicode library.
-- Anything outside that range is left exactly as it is.
--
-- Pure Lua.

local fold = {}

local LOWER = {}

local function pair(upper, lower)
  LOWER[utf8.char(upper)] = utf8.char(lower)
end

-- Latin-1: À-Þ map 32 code points down, except the multiplication sign.
for cp = 0xC0, 0xDE do
  if cp ~= 0xD7 then pair(cp, cp + 0x20) end
end
-- Latin Extended-A alternates upper/lower in pairs. The two runs below start
-- on an even code point; the other two start on an odd one.
for cp = 0x100, 0x12F, 2 do pair(cp, cp + 1) end
for cp = 0x132, 0x137, 2 do pair(cp, cp + 1) end
for cp = 0x139, 0x148, 2 do pair(cp, cp + 1) end
for cp = 0x14A, 0x177, 2 do pair(cp, cp + 1) end
pair(0x178, 0xFF) -- Ÿ -> ÿ, which lives back in Latin-1
for cp = 0x179, 0x17E, 2 do pair(cp, cp + 1) end

-- Lead bytes 0xC3-0xC5 start every character in the table above.
local CANDIDATE = "[\195-\197][\128-\191]"

-- Lower-case `text` for comparison. Never use the result for display.
function fold.lower(text)
  local lowered = text:lower()
  if not lowered:find("[\195-\197]") then return lowered end
  return (lowered:gsub(CANDIDATE, LOWER))
end

-- A search query without the spaces a user cannot see, folded for matching.
-- "" means no search.
function fold.query(query)
  return fold.lower((query or ""):match("^%s*(.-)%s*$"))
end

return fold
