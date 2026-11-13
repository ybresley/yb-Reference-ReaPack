-- imgui_label: makes arbitrary text safe to show as a ReaImGui widget label.
--
-- ImGui reads "##" in a label as "stop drawing here, the rest is the id", so a
-- sound named "Hit ##2" would show as "Hit ". A space between the hashes keeps
-- every character visible.
--
-- Pure Lua.

local imgui_label = {}

function imgui_label.visible(text)
  -- One pass leaves "###" as "# ##", so repeat until no pair is left.
  while text:find("##", 1, true) do text = text:gsub("##", "# #") end
  return text
end

return imgui_label
