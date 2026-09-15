-- Pane-local selection shortcuts. Return intent only; the browser owns warnings.
local focus = require("ui.focus")
local selection = require("core.selection")
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
    local view = state.view
    if delete then
      local ids = selection.selected_categories(state.library.categories, view)
      if #ids == 0 then return nil end
      return { type = "request_delete_categories", ids = ids }
    end
    local next_view = selection.all_categories(state.library.categories, view)
    return next_view and { type = "select_view", view = next_view } or nil
  end

  if delete then
    local ids, first = selection.selected_sounds(state.visible_sounds, state.browse_ids)
    if not first then return nil end
    return { type = "request_delete_sounds", ids = ids, name = first.name }
  end
  local selected = selection.all_sounds(state.visible_sounds, state.browse_anchor_id)
  return selected and { type = "select_browse_sounds",
    ids = selected.ids, anchor = selected.anchor } or nil
end

return shortcuts
