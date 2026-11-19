-- @description yb-Reference: Show / Hide Reference

local path = debug.getinfo(1, "S").source:sub(2)
local root = path:match("^(.*)[/\\][^/\\]+$") or "."
local sep = package.config:sub(1, 1)
dofile(root .. sep .. "lib" .. sep .. "hotkeys.lua").send(root, "panel_reference")
