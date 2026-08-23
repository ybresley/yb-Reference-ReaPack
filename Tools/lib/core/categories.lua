-- Flat categories, each with a permanent id so renaming a category never
-- touches sound records.
--
-- Pure Lua. Operates in place on a library table (see core/schema.lua). A sound
-- references a category by id, so display names can change freely.

local categories = {}

-- Auto-assign colours by cycling this palette (swatch values from the UI tokens,
-- 0xRRGGBBAA). The chosen colour is copied onto the category when it's created,
-- so it stays stable even if this list is later reordered.
-- Gray is deliberately absent: in the sidebar gray text means "a view" (All
-- sounds / Uncategorised), so no category may ever wear it (decided 2026-07-27).
categories.PALETTE = {
  0xE18881FF, -- red
  0xBAA44DFF, -- yellow
  0x77B779FF, -- green
  0x35B9C0FF, -- teal
  0x74A7E8FF, -- blue
  0xAF95DFFF, -- purple
}

local function in_palette(color)
  for _, c in ipairs(categories.PALETTE) do
    if c == color then return true end
  end
  return false
end

-- Give every category a real palette colour. The earliest libraries stored a
-- gray default, and gray is the sidebar's "this row is a view" signal (All
-- sounds / Uncategorised) — a category wearing it reads as one of those instead
-- of as a category, which is exactly what the user saw.
--
-- A replacement takes the first colour NOBODY else is wearing, so fixing one
-- category can't hand it the colour of the category sitting right beside it (a
-- position-based cycle did exactly that on the user's own library: the gray
-- category was given the palette's first colour, which its neighbour already
-- had). Only once the palette is used up does it fall back to the position
-- cycle `add` uses. Colours already in the palette are left alone — repeats
-- among those are `add`'s normal wrap-around, not damage.
--
-- Returns how many categories were changed.
function categories.normalise_colors(lib)
  local taken = {}
  for _, c in ipairs(lib.categories) do
    if in_palette(c.color) then taken[c.color] = true end
  end
  local changed = 0
  for i, c in ipairs(lib.categories) do
    if not in_palette(c.color) then
      local pick
      for _, p in ipairs(categories.PALETTE) do
        if not taken[p] then pick = p break end
      end
      c.color = pick or categories.PALETTE[((i - 1) % #categories.PALETTE) + 1]
      taken[c.color] = true
      changed = changed + 1
    end
  end
  return changed
end

local function blank(name)
  return type(name) ~= "string" or name:match("^%s*$") ~= nil
end

local function next_id(lib)
  lib.seq.category = lib.seq.category + 1
  return "c" .. lib.seq.category
end

-- Find a category record by id. Returns the record or nil.
function categories.get(lib, id)
  for _, c in ipairs(lib.categories) do
    if c.id == id then return c end
  end
  return nil
end

-- Add a category and return its record.
function categories.add(lib, name)
  if blank(name) then
    error("category name cannot be empty")
  end
  local color = categories.PALETTE[(#lib.categories % #categories.PALETTE) + 1]
  local record = {
    id = next_id(lib),
    name = name,
    color = color,
  }
  table.insert(lib.categories, record)
  return record
end

-- Rename a category in place. Id and colour are untouched, so sound records and
-- swatches are unaffected.
function categories.rename(lib, id, new_name)
  if blank(new_name) then
    error("category name cannot be empty")
  end
  local c = categories.get(lib, id)
  if not c then error("category does not exist: " .. tostring(id)) end
  c.name = new_name
  return c
end

-- Change a category to one of the product palette colours. The UI only offers
-- these values, and the core checks them too so a stale or malformed action
-- cannot store an unsupported colour in the library.
function categories.set_color(lib, id, color)
  if not in_palette(color) then
    error("category colour is not in the palette")
  end
  local c = categories.get(lib, id)
  if not c then error("category does not exist: " .. tostring(id)) end
  c.color = color
  return c
end

-- Change one palette colour on several categories as one mutation. Validate
-- every id before changing any record, so a stale selection cannot leave a
-- partially recoloured library.
function categories.set_color_many(lib, ids, color)
  if type(ids) ~= "table" or #ids == 0 then
    error("no categories selected")
  end
  if not in_palette(color) then
    error("category colour is not in the palette")
  end

  local selected = {}
  for _, id in ipairs(ids) do
    if not categories.get(lib, id) then
      error("category does not exist: " .. tostring(id))
    end
    selected[id] = true
  end

  local changed = 0
  for _, c in ipairs(lib.categories) do
    if selected[c.id] then
      if c.color ~= color then changed = changed + 1 end
      c.color = color
    end
  end
  return changed
end

-- Where a category sits in the stored sidebar order (1-based), or nil when it
-- is not present.
function categories.index_of(lib, id)
  for i, c in ipairs(lib.categories) do
    if c.id == id then return i end
  end
  return nil
end

-- Move a category to another position in the stored sidebar order. The target
-- is clamped so a drop beyond either end means first or last. Returns the
-- original position for undo, or nil when it was already there.
function categories.reorder(lib, id, to_index)
  local from = categories.index_of(lib, id)
  if not from then
    error("category \"" .. tostring(id) .. "\" doesn't exist")
  end
  if type(to_index) ~= "number" then
    error("a category's new position must be a number")
  end
  to_index = math.floor(to_index)
  local n = #lib.categories
  if to_index < 1 then to_index = 1 elseif to_index > n then to_index = n end
  if to_index == from then return nil end
  table.insert(lib.categories, to_index, table.remove(lib.categories, from))
  return from
end

-- Turn an insertion gap (1 = above the first row, #categories + 1 = below the
-- last) into the final position accepted by `categories.reorder`. A downward
-- drag leaves its old slot behind, so the target index is one less than the
-- hovered gap. Returns nil for a no-op drop.
function categories.drop_target(from, gap)
  if type(from) ~= "number" or type(gap) ~= "number" then return nil end
  local to = (gap > from) and (gap - 1) or gap
  if to == from then return nil end
  return to
end

-- Remove several categories in one mutation. Every requested id is validated
-- before anything changes, so one stale selection can never leave a half-deleted
-- result. Sounds filed in any removed category become Uncategorised; records
-- and audio stay.
function categories.remove_many(lib, ids)
  if type(ids) ~= "table" or #ids == 0 then
    error("no categories selected")
  end

  local removed = {}
  for _, id in ipairs(ids) do
    if not categories.get(lib, id) then
      error("category does not exist: " .. tostring(id))
    end
    removed[id] = true
  end

  for _, s in ipairs(lib.sounds) do
    if removed[s.category] then
      s.category = nil
    end
  end

  for i = #lib.categories, 1, -1 do
    if removed[lib.categories[i].id] then
      table.remove(lib.categories, i)
    end
  end
end

-- The single-category path shares the exact same safety and uncategorising
-- behaviour as bulk deletion.
function categories.remove(lib, id)
  categories.remove_many(lib, { id })
end

-- Sidebar/header totals: how many sounds sit in the whole library, how many
-- have no category, and how many sit under each category id.
--
-- One pass over the sounds, one over the categories: O(sounds + categories),
-- never O(sounds * categories).
--
-- A sound whose `category` no longer names a real category is folded into
-- `uncat` rather than raising — this is a display total, not a data gate.
-- Category deletion clears those ids normally, so a dangling id means the file
-- was hand-edited or damaged.
function categories.counts(lib)
  local by_id = {}
  for _, c in ipairs(lib.categories) do
    by_id[c.id] = 0
  end

  local all, uncat = 0, 0
  for _, s in ipairs(lib.sounds) do
    all = all + 1
    if s.category == nil or by_id[s.category] == nil then
      uncat = uncat + 1
    else
      by_id[s.category] = by_id[s.category] + 1
    end
  end

  return { all = all, uncat = uncat, by_id = by_id }
end

return categories
