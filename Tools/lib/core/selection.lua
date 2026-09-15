-- selection: pure Library row-selection and action-target rules.

local selection = {}

local function copy_set(source)
  local out = {}
  for id, selected in pairs(source or {}) do
    if selected then out[id] = true end
  end
  return out
end

local function category_set(view)
  if view.scope == "categories" then return copy_set(view.ids) end
  if view.scope == "category" then return { [view.id] = true } end
  return {}
end

local function range_ids(rows, from_id, to_id)
  if not from_id then return nil end
  local from, to
  for i, row in ipairs(rows) do
    if row.id == from_id then from = i end
    if row.id == to_id then to = i end
  end
  if not from or not to then return nil end

  local ids = {}
  for i = math.min(from, to), math.max(from, to) do
    if rows[i].id then ids[rows[i].id] = true end
  end
  return ids
end

function selection.sidebar_entries(lib)
  local out = { { scope = "all" }, { scope = "uncategorised" } }
  for _, category in ipairs(lib.categories or {}) do
    out[#out + 1] = { scope = "category", id = category.id }
  end
  return out
end

function selection.click_category(lib, view, scope, id, ctrl, shift)
  if not ctrl and not shift then return { scope = scope, id = id } end

  local anchor = view.scope == "categories" and view.anchor or view.id
  if shift then
    local range = range_ids(selection.sidebar_entries(lib), anchor, id)
    if not range then return { scope = scope, id = id } end
    local ids = ctrl and category_set(view) or {}
    for range_id in pairs(range) do ids[range_id] = true end
    return { scope = "categories", ids = ids, anchor = id }
  end

  local ids = category_set(view)
  if ids[id] then ids[id] = nil else ids[id] = true end
  if next(ids) == nil then return { scope = "all" } end
  return { scope = "categories", ids = ids, anchor = id }
end

function selection.click_sound(sounds, current_ids, anchor, id, ctrl, shift)
  if not ctrl and not shift then return { ids = { [id] = true }, anchor = id } end

  if shift then
    local range = range_ids(sounds, anchor, id)
    if not range then return { ids = { [id] = true }, anchor = id } end
    local ids = ctrl and copy_set(current_ids) or {}
    for range_id in pairs(range) do ids[range_id] = true end
    return { ids = ids, anchor = id }
  end

  local ids = copy_set(current_ids)
  if ids[id] then ids[id] = nil else ids[id] = true end
  return { ids = ids, anchor = id }
end

function selection.category_targets(categories, view, clicked_id)
  local selected = view.scope == "categories" and view.ids
  if not (selected and selected[clicked_id]) then return { clicked_id } end

  local ids = {}
  for _, category in ipairs(categories or {}) do
    if selected[category.id] then ids[#ids + 1] = category.id end
  end
  return ids
end

function selection.sound_targets(sounds, selected, clicked_id)
  if not (selected and selected[clicked_id]) then return { clicked_id } end

  local ids = {}
  for _, sound in ipairs(sounds or {}) do
    if selected[sound.id] then ids[#ids + 1] = sound.id end
  end
  return #ids > 0 and ids or { clicked_id }
end

function selection.selected_categories(categories, view)
  local ids = {}
  for _, category in ipairs(categories or {}) do
    if (view.scope == "category" and view.id == category.id)
      or (view.scope == "categories" and view.ids and view.ids[category.id]) then
      ids[#ids + 1] = category.id
    end
  end
  return ids
end

function selection.selected_sounds(sounds, selected)
  local ids, first = {}, nil
  for _, sound in ipairs(sounds or {}) do
    if selected and selected[sound.id] then
      ids[#ids + 1] = sound.id
      first = first or sound
    end
  end
  return ids, first
end

function selection.all_categories(categories, view)
  if not categories or #categories == 0 then return nil end
  local ids = {}
  for _, category in ipairs(categories) do ids[category.id] = true end
  local anchor = view.scope == "categories" and view.anchor or view.id
  return {
    scope = "categories",
    ids = ids,
    anchor = ids[anchor] and anchor or categories[1].id,
  }
end

function selection.all_sounds(sounds, anchor)
  if not sounds or #sounds == 0 then return nil end
  local ids = {}
  for _, sound in ipairs(sounds) do ids[sound.id] = true end
  return { ids = ids, anchor = ids[anchor] and anchor or sounds[1].id }
end

function selection.step_sounds(sounds, current_id, step)
  if not sounds or #sounds == 0 then return nil end
  local index
  if current_id then
    for i, sound in ipairs(sounds) do
      if sound.id == current_id then index = i; break end
    end
  end
  local to = index and index + step or (step > 0 and 1 or #sounds)
  if to < 1 then to = 1 elseif to > #sounds then to = #sounds end
  if index == to then return nil end
  return { id = sounds[to].id, row = to - 1 }
end

function selection.step_sidebar(lib, view, step)
  local entries = selection.sidebar_entries(lib)
  local index
  local anchor = view.scope == "categories" and view.anchor or view.id
  for i, entry in ipairs(entries) do
    if view.scope == "categories" then
      if entry.id == anchor then index = i; break end
    elseif entry.scope == view.scope and entry.id == view.id then
      index = i
      break
    end
  end

  local to = index and index + step or 1
  if to < 1 then to = 1 elseif to > #entries then to = #entries end
  if index == to then return nil end
  local entry = entries[to]
  return {
    entry = { scope = entry.scope, id = entry.id },
    view = { scope = entry.scope, id = entry.id },
  }
end

function selection.prune_sounds(sounds, selected, anchor)
  local visible = {}
  for _, sound in ipairs(sounds or {}) do visible[sound.id] = true end
  local kept = {}
  for id, is_selected in pairs(selected or {}) do
    if is_selected and visible[id] then kept[id] = true end
  end
  return { ids = kept, anchor = visible[anchor] and anchor or nil }
end

function selection.prune_category_view(lib, view)
  if view.scope == "category" then
    for _, category in ipairs(lib.categories or {}) do
      if category.id == view.id then return view end
    end
    return { scope = "all" }
  end
  if view.scope ~= "categories" then return view end

  local existing = {}
  for _, category in ipairs(lib.categories or {}) do existing[category.id] = true end
  local kept = {}
  for id, selected in pairs(view.ids or {}) do
    if selected and existing[id] then kept[id] = true end
  end
  if next(kept) == nil then return { scope = "all" } end
  return {
    scope = "categories",
    ids = kept,
    anchor = kept[view.anchor] and view.anchor or next(kept),
  }
end

function selection.category_delete(categories, counts, ids)
  if not ids or #ids == 0 then return nil end
  local first
  local sound_count = 0
  for _, id in ipairs(ids) do
    sound_count = sound_count + ((counts and counts[id]) or 0)
    if not first then
      for _, category in ipairs(categories or {}) do
        if category.id == id then first = category; break end
      end
    end
  end
  return {
    ids = ids,
    count = #ids,
    name = first and first.name,
    color = first and first.color,
    confirmation_required = sound_count > 0,
  }
end

function selection.sound_delete(ids, name)
  if not ids or #ids == 0 then return nil end
  return {
    ids = ids,
    count = #ids,
    name = name,
    confirmation_required = true,
  }
end

return selection
