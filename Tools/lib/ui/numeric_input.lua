-- Text entry filters for numeric controls. ReaImGui's CharsDecimal flag also
-- permits arithmetic operators, so these callbacks keep each control's text
-- limited to the characters its value parser can use.
local numeric_input = {}

local FILTERS = {
  digits = "EventChar < '0' || EventChar > '9' ? EventChar = 0;",
  signed_decimal = [[
    !(EventChar >= '0' && EventChar <= '9') && EventChar != '.'
      && EventChar != '+' && EventChar != '-' ? EventChar = 0;
  ]],
}

local callbacks = {}

-- Called with the rest of the ImGui resources, before the defer loop starts.
function numeric_input.init(ctx)
  for mode, code in pairs(FILTERS) do
    local fn = assert(reaper.ImGui_CreateFunctionFromEEL(code),
      "Couldn't create the numeric text filter.")
    reaper.ImGui_Attach(ctx, fn)
    callbacks[mode] = fn
  end
end

-- `signed_decimal` permits signs and decimal points for values such as pitch
-- and loudness. `digits` is for whole-Hz filter boundaries.
function numeric_input.text(ctx, id, value, mode, extra_flags)
  local fn = assert(callbacks[mode], "Numeric text filters weren't initialised.")
  return reaper.ImGui_InputText(ctx, id, value or "",
    reaper.ImGui_InputTextFlags_CallbackCharFilter() | (extra_flags or 0), fn)
end

return numeric_input
