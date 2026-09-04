-- Shared sizing and text entry for compact popups. Callers own pending edits.

local theme = require("ui.theme")
local widgets = require("ui.widgets")
local T = theme.tokens
local M = theme.metrics

local popups = {}
local question_cache

-- Split before drawing coloured runs: SameLine after a wrapped text item
-- returns to its first line, which would strand the final question mark.
function popups.name_question(ctx, name, color)
  local prefix, suffix = "Delete ", "?"
  local text = prefix .. name .. suffix
  local width = reaper.ImGui_GetContentRegionAvail(ctx)
  local font_size = reaper.ImGui_GetFontSize(ctx)
  local key = text .. "\0" .. width .. "\0" .. font_size
  if not question_cache or question_cache.key ~= key then
    local lines, first = {}, 1
    while first <= #text do
      local rest = text:sub(first)
      local ends = {}
      for byte in utf8.codes(rest) do ends[#ends + 1] = byte end
      ends[#ends + 1] = #rest + 1
      local lo, hi, count = 1, #ends - 1, 1
      while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if reaper.ImGui_CalcTextSize(ctx, rest:sub(1, ends[mid + 1] - 1)) <= width then
          count, lo = mid, mid + 1
        else hi = mid - 1 end
      end
      local last = ends[count + 1] - 1
      if last < #rest then
        local space = rest:sub(1, last):match(".*()%s")
        if space and space > 1 then last = space end
      end
      lines[#lines + 1] = {first, first + last - 1}
      first = first + last
    end
    question_cache = {key=key, lines=lines}
  end
  for _, line in ipairs(question_cache.lines) do
    local first, last = line[1], line[2]
    local wrote = false
    local function run(a, b, tint)
      a, b = math.max(a, first), math.min(b, last)
      if a > b then return end
      if wrote then reaper.ImGui_SameLine(ctx, 0, 0) end
      reaper.ImGui_TextColored(ctx, tint, text:sub(a, b))
      wrote = true
    end
    run(1, #prefix, T.TEXT_PRIMARY)
    run(#prefix + 1, #prefix + #name, color)
    run(#prefix + #name + 1, #text, T.TEXT_PRIMARY)
  end
end

-- Measure before BeginPopup so the opening frame fits too. Long names wrap;
-- text-entry fields retain a useful width instead of resizing while typing.
function popups.fit_width(ctx, heading, body, min_content_w)
  local text_w = math.max(reaper.ImGui_CalcTextSize(ctx, heading),
    (reaper.ImGui_CalcTextSize(ctx, body or "")))
  local content_w = math.max(min_content_w or 0, M.POPUP_BTN_W * 2 + M.ITEM_SPACING_X,
    math.min(math.ceil(text_w), M.POPUP_MAX_W - M.WINDOW_PAD * 2))
  local width = content_w + M.WINDOW_PAD * 2
  if reaper.ImGui_SetNextWindowSizeConstraints then
    reaper.ImGui_SetNextWindowSizeConstraints(ctx, width, 0, width, 10000)
  else
    reaper.ImGui_SetNextWindowSize(ctx, width, 0, reaper.ImGui_Cond_Always())
  end
end

-- Returns the entered text on submit, else nil. Focuses the field when the
-- popup first opens and submits on the OK button. `opts.allow_empty` lets an
-- empty string through (a pin's label popup uses this: empty clears the label,
-- rather than "" being read as "nothing typed yet, cancel").
function popups.edit_popup(ctx, edit, id, title, key, opts)
  if not reaper.ImGui_IsPopupOpen(ctx, id) then return nil end
  opts = opts or {}
  local submitted
  local heading = tostring(title):upper()
  popups.fit_width(ctx, heading, nil, M.FIELD_W)
  if reaper.ImGui_BeginPopup(ctx, id) then
    -- Text entry needs the normal panel rhythm, even when opened by the sidebar.
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),
      M.ITEM_SPACING_X, M.ITEM_SPACING_Y)
    reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, heading)
    if reaper.ImGui_IsWindowAppearing(ctx) then reaper.ImGui_SetKeyboardFocusHere(ctx) end
    reaper.ImGui_SetNextItemWidth(ctx, (reaper.ImGui_GetContentRegionAvail(ctx)))
    -- Plain InputText (NOT EnterReturnsTrue): with that flag ReaImGui only returns
    -- the edited text on the frame Enter is pressed, so an OK click would read a
    -- stale value and clear the box. Without it the returned buffer is always the
    -- current text, so it accumulates correctly and OK can read it.
    local _, val = reaper.ImGui_InputText(ctx, "##" .. id, edit[key] or "")
    edit[key] = val
    local cancel, ok = widgets.action_pair(ctx, "Cancel", "OK")
    if ok and (opts.allow_empty or edit[key] ~= "") then
      submitted = edit[key]
      reaper.ImGui_CloseCurrentPopup(ctx)
    elseif cancel then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_EndPopup(ctx)
  end
  return submitted
end

return popups
