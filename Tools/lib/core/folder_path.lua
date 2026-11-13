-- folder_path: do two folder paths name the same folder?
--
-- Windows ignores letter case in paths and accepts either slash, so "d:/refs"
-- and "D:\Refs\" are one folder there. macOS and Linux paths are compared as
-- written. A trailing separator never makes a difference.
--
-- Pure Lua.

local folder_path = {}

local WINDOWS = package.config:sub(1, 1) == "\\"

local function normalise(path, windows)
  if windows then path = path:gsub("/", "\\"):lower() end
  return (path:gsub("[\\/]+$", ""))
end

-- `windows` defaults to this computer's rules; tests pass it explicitly.
function folder_path.same(a, b, windows)
  if type(a) ~= "string" or type(b) ~= "string" then return false end
  if windows == nil then windows = WINDOWS end
  return normalise(a, windows) == normalise(b, windows)
end

return folder_path
