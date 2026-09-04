-- Pane-local selection shortcuts. Return intent only; the browser owns warnings.
local focus = require("ui.focus")
local shortcuts = {}

function shortcuts.read(ctx, state, pane, file_drag_active)
  -- Check the current child, not the Library root: text fields, the waveform,
  -- and the other pane must never inherit a stale deletion target.
  if not reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_ChildWindows()) then
    return nil
  end
  local mods = reaper.ImGui_GetKeyMods(ctx)
  -- Reserve the chord throughout a hold, including repeats and empty lists.
  if mods == reaper.ImGui_Mod_Ctrl() then focus.consume_key(reaper.ImGui_Key_A()) end
  if state.drag or file_drag_active or reaper.ImGui_IsAnyItemActive(ctx)
    or reaper.ImGui_IsPopupOpen(ctx, "",
      reaper.ImGui_PopupFlags_AnyPopupId() | reaper.ImGui_PopupFlags_AnyPopupLevel()) then
    return nil
  end
  for button = 0, 2 do
    if reaper.ImGui_IsMouseDown(ctx, button) then return nil end
  end

  local select_all = mods == reaper.ImGui_Mod_Ctrl()
    and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_A(), false)
  local delete = mods == 0 and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Delete(), false)
  if not select_all and not delete then return nil end

  if pane == "sidebar" then
    local ids, selected = {}, {}
    local view = state.view
    for _, cat in ipairs(state.library.categories) do
      if select_all or (view.scope == "category" and view.id == cat.id)
        or (view.scope == "categories" and view.ids[cat.id]) then
        ids[#ids + 1] = cat.id
        selected[cat.id] = true
      end
    end
    if #ids == 0 then return nil end
    if delete then return { type = "request_delete_categories", ids = ids } end
    local anchor = view.scope == "categories" and view.anchor or view.id
    return { type = "select_view", view = {
      scope = "categories", ids = selected,
      anchor = selected[anchor] and anchor or ids[1],
    } }
  end

  local ids, selected, first = {}, {}, nil
  for _, sound in ipairs(state.visible_sounds) do
    if select_all or (state.browse_ids and state.browse_ids[sound.id]) then
      ids[#ids + 1] = sound.id
      selected[sound.id] = true
      first = first or sound
    end
  end
  if not first then return nil end
  if delete then return { type = "request_delete_sounds", ids = ids, name = first.name } end
  return { type = "select_browse_sounds", ids = selected,
    anchor = selected[state.browse_anchor_id] and state.browse_anchor_id or first.id }
end

return shortcuts
