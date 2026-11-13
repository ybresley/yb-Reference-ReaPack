-- Windows Script Host reads a .vbs file with no byte-order mark as the machine's
-- ANSI code page, which mangles any accented or non-Latin character in a path.
-- A UTF-16LE file with a BOM is read as Unicode, so scripts that embed a
-- REAPER folder path are written through this.

local wsh_script = {}

local BOM = "\255\254"

local function unit(n)
  return string.char(n % 256, n // 256)
end

-- Text that is not valid UTF-8 is carried through byte by byte rather than
-- dropped, so a damaged path still reaches the script as close to as written.
local function code_points(text)
  if utf8.len(text) then
    return utf8.codepoint(text, 1, -1)
  end
  return text:byte(1, -1)
end

function wsh_script.encode(text)
  if text == "" then return BOM end
  local out = { BOM }
  local points = { code_points(text) }
  for _, cp in ipairs(points) do
    if cp >= 0x10000 then
      cp = cp - 0x10000
      out[#out + 1] = unit(0xD800 + (cp >> 10)) .. unit(0xDC00 + (cp & 0x3FF))
    else
      out[#out + 1] = unit(cp)
    end
  end
  return table.concat(out)
end

return wsh_script
