-- Missing-library recovery window. This module only draws and reports intent;
-- folder picking, validation, creation and restart stay in the entry script.

local theme = require("ui.theme")
local popups = require("ui.popups")

local recovery = {}
local ui = { typed_path = nil, path_source = nil }

local HAS_VIEWPORT = reaper.ImGui_GetMainViewport ~= nil
  and reaper.ImGui_Viewport_GetCenter ~= nil
local HAS_READONLY = reaper.ImGui_InputTextFlags_ReadOnly ~= nil

local function path_field(ctx, state, editable)
  if ui.path_source ~= state.path then
    ui.path_source = state.path
    ui.typed_path = state.path or ""
  end
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  if editable then
    local _, value = reaper.ImGui_InputText(ctx, "##library_recovery_path", ui.typed_path)
    ui.typed_path = value
    return
  end
  if HAS_READONLY then
    reaper.ImGui_InputText(ctx, "##library_recovery_path", state.path or "",
      reaper.ImGui_InputTextFlags_ReadOnly())
  else
    reaper.ImGui_BeginDisabled(ctx)
    reaper.ImGui_InputText(ctx, "##library_recovery_path", state.path or "")
    reaper.ImGui_EndDisabled(ctx)
  end
end

local function status_area(ctx, state)
  local T = theme.tokens
  if state.status and state.status ~= "" then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
      state.error and T.DANGER_RED or T.TEXT_TERTIARY)
    reaper.ImGui_TextWrapped(ctx, state.status)
    reaper.ImGui_PopStyleColor(ctx)
  end
end

local function action_row(ctx, items)
  local M = theme.metrics
  local gap = M.ITEM_SPACING_X
  local avail = reaper.ImGui_GetContentRegionAvail(ctx)
  local width = math.floor((avail - gap * (#items - 1)) / #items)
  local action
  for i, item in ipairs(items) do
    if i > 1 then reaper.ImGui_SameLine(ctx, 0, gap) end
    local button_w = i == #items and avail - (width + gap) * (i - 1) or width
    if reaper.ImGui_Button(ctx, item.label, button_w) then action = item.action end
  end
  return action
end

-- Returns whether the recovery window remains open and at most one action.
function recovery.frame(ctx, state)
  local M, T = theme.metrics, theme.tokens
  local nc, nv, nf = theme.apply(ctx)
  local action

  local mode = state.mode or "missing"
  local heading, body, editable, items
  if mode == "existing_default" then
    heading = "LIBRARY ALREADY EXISTS"
    body = "Use the default library below or create one elsewhere."
    editable = false
    items = {
      { label = "Back", action = { type = "back" } },
      { label = "Use This Library", action = { type = "use_default" } },
      { label = "Create Elsewhere", action = { type = "create_elsewhere" } },
    }
  elseif mode == "create_elsewhere" then
    heading = "CREATE NEW LIBRARY"
    body = "Enter an empty folder for the new library."
    editable = true
    items = {
      { label = "Back", action = { type = "back" } },
      { label = "Create", action = { type = "create_at", typed_dir = true } },
    }
  else
    heading = "LIBRARY NOT FOUND"
    body = "Choose an existing library or create a new one."
    editable = not state.folder_picker
    items = {
      { label = "Choose Folder", action = { type = "choose", typed_dir = not state.folder_picker } },
      { label = "Create New", action = { type = "new" } },
    }
  end

  local visible_title = state.copy_label
    and (heading .. "  [" .. state.copy_label .. "]") or heading
  local win_title = visible_title .. "###yb_library_recovery"

  local flags = reaper.ImGui_WindowFlags_NoResize()
    | reaper.ImGui_WindowFlags_AlwaysAutoResize()
    | reaper.ImGui_WindowFlags_NoCollapse()
    | reaper.ImGui_WindowFlags_NoScrollbar()
    | reaper.ImGui_WindowFlags_NoScrollWithMouse()
  if reaper.ImGui_WindowFlags_NoDocking then
    flags = flags | reaper.ImGui_WindowFlags_NoDocking()
  end
  local button_w = M.POPUP_BTN_W
  for _, item in ipairs(items) do
    button_w = math.max(button_w,
      math.ceil(reaper.ImGui_CalcTextSize(ctx, item.label)) + M.FRAME_PAD_X * 2)
  end
  local action_w = button_w * #items + M.ITEM_SPACING_X * (#items - 1)
  -- Keep the missing-library instruction on one line across its status states.
  local body_w = mode == "missing"
    and math.ceil(reaper.ImGui_CalcTextSize(ctx, body)) + M.ITEM_SPACING_X or 0
  popups.fit_width(ctx, heading, body, math.max(M.FIELD_W, action_w, body_w))
  if HAS_VIEWPORT then
    local cx, cy = reaper.ImGui_Viewport_GetCenter(reaper.ImGui_GetMainViewport(ctx))
    reaper.ImGui_SetNextWindowPos(ctx, cx, cy, reaper.ImGui_Cond_FirstUseEver(), 0.5, 0.5)
  end

  local visible, open = theme.begin_window(ctx, win_title, true, flags, true)
  if visible then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.TEXT_SECONDARY)
    reaper.ImGui_TextWrapped(ctx, body)
    reaper.ImGui_PopStyleColor(ctx)
    path_field(ctx, state, editable)
    action = action_row(ctx, items)
    -- Messages grow below the controls without reserving space or moving them.
    status_area(ctx, state)
    if action and action.typed_dir then
      action.typed_dir = nil
      action.dir = ui.typed_path
    end

    reaper.ImGui_End(ctx)
  end

  theme.unapply(ctx, nc, nv, nf)
  return open, action
end

return recovery
