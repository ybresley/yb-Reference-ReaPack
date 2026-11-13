-- new_category_drop: decides what dropping files on "+ New Category" does.
--
-- The category must only be created when an import will really follow, so every
-- refusal is worked out here before anything is added or saved.
--
-- Pure Lua.

local new_category_drop = {}

new_category_drop.FALLBACK_NAME = "New Category"
new_category_drop.BUSY = "Sounds are still being added. Wait for this import to finish, then add more."
new_category_drop.NO_AUDIO = "Drop audio files onto + New Category. Folders can't start a category."

-- The folder the file sits in, or nil when that is no useful name: a file at a
-- drive root has "C:" for a parent, and a bare file name has none.
local function parent_folder(path)
  local name = path:match("([^/\\]+)[/\\][^/\\]*$")
  if not name or name:match("^%a:$") then return nil end
  return name
end

-- Returns { name = ... } when a category should be created for these paths, or
-- nil plus the message to show. `is_audio` tests a file name.
function new_category_drop.plan(paths, is_audio, import_running)
  if import_running then return nil, new_category_drop.BUSY end
  for _, path in ipairs(paths or {}) do
    if is_audio(path:match("([^/\\]+)$") or path) then
      return { name = parent_folder(path) or new_category_drop.FALLBACK_NAME }
    end
  end
  return nil, new_category_drop.NO_AUDIO
end

return new_category_drop
