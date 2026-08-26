-- browser_memory: validates the Library browser state carried between launches.
-- Storage lives in reaper_api; this pure layer decides what still makes sense
-- against the Library that actually opened.

local categories = require("core.categories")
local search = require("core.search")

local memory = {}

local VALID_SORT = {
  name = true,
  dur = true,
  ch = true,
  loud = true,
  pin = true,
}

local function default_view()
  return { scope = "all" }
end

local function normalise_view(saved, lib)
  if type(saved) ~= "table" then return default_view() end
  if saved.scope == "uncategorised" then return { scope = "uncategorised" } end

  if saved.scope == "category" and categories.get(lib, saved.id) then
    return { scope = "category", id = saved.id }
  end

  if saved.scope == "categories" then
    local kept = {}
    local first
    for _, category in ipairs(lib.categories or {}) do
      if saved.ids and saved.ids[category.id] then
        kept[category.id] = true
        first = first or category.id
      end
    end
    if first then
      local anchor = kept[saved.anchor] and saved.anchor or first
      return { scope = "categories", ids = kept, anchor = anchor }
    end
  end

  return default_view()
end

local function visible_sound_id(lib, view, wanted)
  if type(wanted) ~= "string" or wanted == "" then return nil end
  for _, sound in ipairs(search.filter(lib, view, "")) do
    if sound.id == wanted then return wanted end
  end
  return nil
end

function memory.normalise(saved, lib)
  saved = type(saved) == "table" and saved or {}
  local view = normalise_view(saved.view, lib)

  local sort = { col = "name", asc = true }
  if type(saved.sort) == "table" and VALID_SORT[saved.sort.col] then
    sort.col = saved.sort.col
    if type(saved.sort.asc) == "boolean" then sort.asc = saved.sort.asc end
  end

  return {
    view = view,
    sort = sort,
    sound_id = visible_sound_id(lib, view, saved.sound_id),
  }
end

return memory
