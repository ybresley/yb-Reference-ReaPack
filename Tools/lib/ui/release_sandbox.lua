-- Private copies of production UI modules for release demonstrations.
--
-- The Library keeps a lot of module-level memory: browser.lua its keyboard
-- navigation, search field and waveform splitter, widgets.lua and
-- icon_motion.lua their motion. A demonstration drawn through the live modules
-- would share all of it with the Library on screen, and the two would restart
-- and overwrite each other.
--
-- A sandbox runs its own copy of every module named in `private`. Those copies
-- require each other inside the sandbox; every other module stays the shared
-- one, which is safe because none of them is asked to do more than paint here.
-- The copies see a `reaper` that never reports input:
--   * no hover, click, edit, drag, wheel, key or focus, so nothing reacts to
--     the user's pointer or keyboard, and nothing can take keyboard focus;
--   * every child window they open takes no input or keyboard navigation;
--   * no popup ever opens, so none can sit over the What's New window and
--     swallow the user's next click there;
--   * tables keep no saved settings, so nothing is written to ImGui's ini.
-- The demonstration reads the real positions of a few controls through
-- `watch` so its guide pointer lands on them.

local sandbox = {}

local sources = {} -- module name -> { path, text }, read from disk once

local function source(name)
  local found = sources[name]
  if found then return found end
  local path = assert(package.searchpath(name, package.path))
  local file = assert(io.open(path, 'rb'))
  local text = file:read('a')
  file:close()
  found = { path = path, text = text }
  sources[name] = found
  return found
end

local NO = function() return false end
local NOTHING = function() end
local FAR = function() return -1e9, -1e9 end
local STILL = function() return 0, 0 end

-- Answers that would otherwise come from the user's mouse and keyboard.
local QUIET = {
  ImGui_IsWindowFocused = NO, ImGui_IsWindowHovered = NO,
  ImGui_IsItemHovered = NO, ImGui_IsItemClicked = NO, ImGui_IsItemActive = NO,
  ImGui_IsItemActivated = NO, ImGui_IsItemDeactivated = NO,
  ImGui_IsItemDeactivatedAfterEdit = NO, ImGui_IsItemFocused = NO,
  ImGui_IsItemEdited = NO, ImGui_IsItemToggledOpen = NO,
  ImGui_IsAnyItemActive = NO, ImGui_IsAnyItemHovered = NO, ImGui_IsAnyItemFocused = NO,
  ImGui_IsMouseClicked = NO, ImGui_IsMouseDown = NO, ImGui_IsMouseReleased = NO,
  ImGui_IsMouseDragging = NO, ImGui_IsMouseDoubleClicked = NO,
  ImGui_IsMouseHoveringRect = NO, ImGui_IsMousePosValid = NO,
  ImGui_IsKeyPressed = NO, ImGui_IsKeyDown = NO, ImGui_IsKeyReleased = NO,
  ImGui_IsKeyChordPressed = NO, ImGui_Shortcut = NO,
  ImGui_GetMousePos = FAR, ImGui_GetMouseClickedPos = FAR,
  ImGui_GetMouseDragDelta = STILL, ImGui_GetMouseDelta = STILL, ImGui_GetMouseWheel = STILL,
  ImGui_GetKeyMods = function() return 0 end,
  ImGui_GetMouseClickedCount = function() return 0 end,
  ImGui_BeginDragDropSource = NO, ImGui_BeginDragDropTarget = NO,
  ImGui_AcceptDragDropPayload = NO, ImGui_AcceptDragDropPayloadFiles = NO,
  ImGui_GetDragDropPayload = NO, ImGui_GetDragDropPayloadFile = NO,
  ImGui_OpenPopup = NOTHING, ImGui_OpenPopupOnItemClick = NOTHING, ImGui_IsPopupOpen = NO,
  ImGui_BeginPopup = NO, ImGui_BeginPopupModal = NO, ImGui_CloseCurrentPopup = NOTHING,
  ImGui_BeginPopupContextItem = NO, ImGui_BeginPopupContextWindow = NO,
  ImGui_BeginPopupContextVoid = NO,
  ImGui_SetKeyboardFocusHere = NOTHING, ImGui_SetItemDefaultFocus = NOTHING,
  ImGui_SetWindowFocus = NOTHING, ImGui_SetNextWindowFocus = NOTHING,
  ImGui_SetMouseCursor = NOTHING, ImGui_SetClipboardText = NOTHING,
  ImGui_SetNextFrameWantCaptureKeyboard = NOTHING, ImGui_SetNextFrameWantCaptureMouse = NOTHING,
  ImGui_SetDragDropPayload = NO,
}

-- Records the rectangle of the item just drawn when its label ends with a
-- watched suffix.
local function record(ctx, box, label)
  local key
  for suffix, name in pairs(box.watch) do
    if #label >= #suffix and label:find(suffix, #label - #suffix + 1, true) then key = name end
  end
  if not key then return end
  local rect = box.rects[key]
  if not rect then
    rect = {}
    box.rects[key] = rect
  end
  rect.x0, rect.y0 = reaper.ImGui_GetItemRectMin(ctx)
  rect.x1, rect.y1 = reaper.ImGui_GetItemRectMax(ctx)
  rect.frame = box.frame
end

local function overrides(box)
  local o = {}
  for name, fn in pairs(QUIET) do o[name] = fn end
  local inert = reaper.ImGui_WindowFlags_NoInputs() | reaper.ImGui_WindowFlags_NoNav()

  function o.ImGui_BeginChild(ctx, id, w, h, child_flags, window_flags)
    return reaper.ImGui_BeginChild(ctx, id, w or 0, h or 0, child_flags or 0,
      (window_flags or 0) | inert)
  end

  function o.ImGui_BeginTable(ctx, id, columns, flags, w, h, inner_w)
    if reaper.ImGui_TableFlags_NoSavedSettings then
      flags = (flags or 0) | reaper.ImGui_TableFlags_NoSavedSettings()
    end
    return reaper.ImGui_BeginTable(ctx, id, columns, flags, w, h, inner_w)
  end

  -- The controls are drawn as usual, but none of them ever reports a click or
  -- an edit, even if one somehow reached it.
  function o.ImGui_Button(ctx, label, w, h)
    reaper.ImGui_Button(ctx, label, w, h)
    record(ctx, box, label)
    return false
  end
  function o.ImGui_InvisibleButton(ctx, id, w, h, flags)
    reaper.ImGui_InvisibleButton(ctx, id, w, h, flags)
    record(ctx, box, id)
    return false
  end
  function o.ImGui_Selectable(ctx, label, selected, flags, w, h)
    reaper.ImGui_Selectable(ctx, label, selected, flags, w, h)
    record(ctx, box, label)
    return false, selected
  end
  -- A combo never opens here; the demonstration paints its list itself. Its
  -- closed face is still recorded for `watch`.
  function o.ImGui_BeginCombo(ctx, label, preview, flags)
    if reaper.ImGui_BeginCombo(ctx, label, preview, flags) then reaper.ImGui_EndCombo(ctx) end
    record(ctx, box, label)
    return false
  end
  function o.ImGui_ColorButton(ctx, id, col, flags, w, h)
    reaper.ImGui_ColorButton(ctx, id, col, flags, w, h)
    return false
  end
  function o.ImGui_Checkbox(ctx, label, value)
    reaper.ImGui_Checkbox(ctx, label, value)
    return false, value
  end
  function o.ImGui_MenuItem(ctx, label, shortcut, selected, enabled)
    reaper.ImGui_MenuItem(ctx, label, shortcut, selected, enabled)
    return false, selected
  end
  function o.ImGui_InputText(ctx, label, text, flags, callback)
    reaper.ImGui_InputText(ctx, label, text, flags, callback)
    return false, text
  end
  function o.ImGui_InputTextWithHint(ctx, label, hint, text, flags, callback)
    reaper.ImGui_InputTextWithHint(ctx, label, hint, text, flags, callback)
    return false, text
  end

  return o
end

-- `private`: module names to copy. `stubs`: module name -> table standing in
-- for that module (for modules whose job is live focus or live windows).
function sandbox.new(private, stubs)
  local box = {
    private = {}, stubs = stubs or {}, loaded = {}, loading = {},
    rects = {}, watch = {}, frame = 0,
  }
  for _, name in ipairs(private) do box.private[name] = true end
  local o = overrides(box)
  box.reaper = setmetatable({}, { __index = function(_, key)
    local real = reaper[key]
    if real ~= nil and o[key] then return o[key] end
    return real
  end })
  box.env = setmetatable({ reaper = box.reaper }, { __index = _G })
  box.env.require = function(name) return sandbox.require(box, name) end
  return box
end

function sandbox.require(box, name)
  local loaded = box.loaded[name]
  if loaded ~= nil then return loaded end
  local stub = box.stubs[name]
  if stub then return stub end
  if not box.private[name] then return require(name) end
  assert(not box.loading[name], 'release sandbox: require cycle through ' .. name)
  box.loading[name] = true
  local found = source(name)
  local chunk = assert(load(found.text, '@' .. found.path, 't', box.env))
  local result = chunk(name, found.path)
  box.loading[name] = nil
  if result == nil then result = true end
  box.loaded[name] = result
  return result
end

-- Call at the start of each demonstration frame.
function sandbox.begin_frame(box)
  box.frame = box.frame + 1
end

-- The last rectangle drawn for `key` this frame, or nil.
function sandbox.rect(box, key)
  local rect = box.rects[key]
  if rect and rect.frame == box.frame then return rect end
  return nil
end

-- Record the rectangle of the button, invisible button or selectable whose
-- label or id ends with `suffix`, under `key`.
function sandbox.watch(box, suffix, key) box.watch[suffix] = key end

return sandbox
