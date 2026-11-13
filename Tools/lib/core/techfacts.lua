-- techfacts: one sound's technical facts as text — "48 kHz · 24-bit · WAV ·
-- stereo". Pure formatting, shared by the Library's headings and the
-- Reference card, so the wording cannot drift between them.
--
-- Core module: plain Lua, no reaper.*. The info table itself comes from
-- reaper_api.source_info — the caller passes it in as data.

local techfacts = {}

-- Facts are joined by a spaced middle dot.
local SEP = "  \u{00B7}  "
techfacts.SEP = SEP

-- info = { rate?, bits?, format?, channels? } (reaper_api.source_info's shape).
-- Every field is optional. Missing source information yields no facts.
function techfacts.parts(info, channels_first)
  local parts = {}
  if not info then return parts end
  if info.rate and info.rate > 0 then
    parts[#parts + 1] = string.format("%g kHz", info.rate / 1000)
  end
  if info.bits then parts[#parts + 1] = info.bits .. "-bit" end
  if info.format and info.format ~= "" then parts[#parts + 1] = info.format end
  -- Zero/absent channels is "no meaningful answer" (Codex, 2026-08-07): print
  -- nothing rather than a "0 ch" that reads as a fact.
  local ch = info.channels or 0
  if ch > 0 then
    local label = ch == 1 and "mono" or (ch == 2 and "stereo" or (ch .. " ch"))
    table.insert(parts, channels_first and 1 or #parts + 1, label)
  end
  return parts
end

-- The facts and an optional duration as one line, or nil when there are none.
function techfacts.line(parts, duration)
  local text = table.concat(parts, SEP)
  if duration then text = text ~= "" and (text .. SEP .. duration) or duration end
  return text ~= "" and text or nil
end

return techfacts
