-- tips: the app's one tooltip. Every tip in the UI goes through here, so they
-- all wait the same beat before appearing (user's ask, 2026-08-07 — showing
-- instantly meant tips flashing up while the cursor merely crossed the bar).
--
-- Tips are pinned to the control or area they explain rather than following
-- the pointer: a tip that chased the cursor across a meter or plot was hard to
-- read and covered the very thing being looked at. core/tooltip_place decides
-- where the pinned tip sits.
--
-- Its own module rather than a function in widgets.lua because icons.lua needs
-- it too, and widgets.lua already requires icons — one more edge there would be
-- a cycle. Nothing requires this file back.
--
-- The wait is timed HERE rather than handed to ImGui's own hover delay flag:
-- most callers already know they are hovered (a row works it out once, for its
-- hover fill and its tip together), and asking ImGui again at tooltip time
-- would answer about whatever item was submitted LAST — which inside an
-- edit-mode row is a different control entirely.
--
-- A ui/ module: it may call reaper.ImGui_* only.

local theme = require("ui.theme")
local anchored_panel = require("ui.anchored_panel")
local placement = require("core.tooltip_place")
local tips = {}

tips.DELAY = 0.5 -- seconds of continuous hover before a tip appears
local TOOLTIP_WRAP_W = 360

local function tooltip_wrap_width()
  return TOOLTIP_WRAP_W * theme.scale
end

-- Use the current native descriptions so modifiers and multiple assignments
-- match Settings without giving unrelated controls the Reference View shortcut.
local shortcut_snapshot, shortcut_content = nil, {}
function tips.with_shortcut(state, id, text)
  local snapshot = state.hotkeys
  if not snapshot or not snapshot.available or not id then return text end
  -- The adapter replaces its snapshot on refresh. Keep only that snapshot's
  -- display data so idle frames neither scan commands nor allocate tables.
  if snapshot ~= shortcut_snapshot then
    shortcut_snapshot, shortcut_content = snapshot, {}
    for _, command in ipairs(snapshot.commands or {}) do
      local lines = {}
      for _, shortcut in ipairs(command.shortcuts or {}) do
        if shortcut.description and shortcut.description ~= "" then
          lines[#lines + 1] = shortcut.description
        end
      end
      if #lines > 0 then
        shortcut_content[command.id] = {
          shortcuts = lines, key = "hotkey_" .. command.id,
        }
      end
    end
  end
  local content = shortcut_content[id]
  if content then
    content.text = text
    return content
  end
  return text
end

-- Without both clock functions, show the tip immediately. This also supports
-- callers using a partial API stand-in outside REAPER.
local HAS_CLOCK = reaper.ImGui_GetTime ~= nil and reaper.ImGui_GetFrameCount ~= nil

-- Identity defaults to the tooltip TEXT: moving onto a control that says
-- something else restarts the wait. A frame in which nobody calls this means the
-- cursor is over nothing, so the next hover starts from zero instead of
-- appearing instantly — that is what `frame` is for.
local key_now, since, last_frame = nil, 0, -2

local MODIFIERS = { Ctrl = true, Shift = true, Alt = true, Win = true,
  Cmd = true, Opt = true, Control = true, Command = true, Option = true }

function tips.shortcut_keys(description)
  local keys, remaining = {}, description
  while true do
    local modifier, rest = remaining:match("^([^+]+)%+(.*)$")
    if not modifier or not MODIFIERS[modifier] or rest == "" then break end
    keys[#keys + 1] = modifier
    remaining = rest
  end
  -- Only split known modifiers. The final key may itself be '+' or a MIDI name.
  if remaining ~= "" then keys[#keys + 1] = remaining end
  return keys
end

-- Measure (and, with `draw`, paint) a shortcut tip: one row of key caps per
-- assigned shortcut, then the explanation. Measuring and painting share this
-- one walk so the pinned window is sized to exactly what gets drawn.
local function shortcut_layout(ctx, content, wrap_w, draw)
  local m, t = theme.metrics, theme.tokens
  local _, spacing = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing())
  local cap_gap = m.FRAME_PAD_Y
  local dl, ox, oy, rounding, alpha
  if draw then
    dl = reaper.ImGui_GetWindowDrawList(ctx)
    ox, oy = reaper.ImGui_GetCursorScreenPos(ctx)
    rounding = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding())
    alpha = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
  end
  local y, max_w = 0, 0
  for _, description in ipairs(content.shortcuts) do
    local x, row_h = 0, 0
    for _, label in ipairs(tips.shortcut_keys(description)) do
      local tw, th = reaper.ImGui_CalcTextSize(ctx, label)
      local width, height = tw + m.FRAME_PAD_X * 2, th + m.FRAME_PAD_Y
      if width > wrap_w then
        -- Long native MIDI/OSC descriptions stay readable instead of truncating.
        if x > 0 then y, x, row_h = y + row_h + spacing, 0, 0 end
        local _, wrapped_h = reaper.ImGui_CalcTextSize(ctx, label, nil, nil, false, wrap_w)
        if draw then
          reaper.ImGui_SetCursorScreenPos(ctx, ox, oy + y)
          reaper.ImGui_PushTextWrapPos(ctx, reaper.ImGui_GetCursorPosX(ctx) + wrap_w)
          reaper.ImGui_Text(ctx, label)
          reaper.ImGui_PopTextWrapPos(ctx)
        end
        max_w, y = wrap_w, y + wrapped_h + spacing
      else
        if x > 0 then
          if x + cap_gap + width <= wrap_w then x = x + cap_gap
          else y, x, row_h = y + row_h + spacing, 0, 0 end
        end
        if draw then
          local cx, cy = ox + x, oy + y
          reaper.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + width, cy + height,
            theme.fade(t.FILL_TERTIARY, alpha), rounding)
          reaper.ImGui_DrawList_AddRect(dl, cx + 0.5, cy + 0.5,
            cx + width - 0.5, cy + height - 0.5,
            theme.fade(t.STROKE_PRIMARY, alpha), rounding, 0, 1)
          reaper.ImGui_DrawList_AddText(dl, cx + m.FRAME_PAD_X, cy + m.FRAME_PAD_Y * 0.5,
            theme.fade(t.TEXT_PRIMARY, alpha), label)
        end
        x = x + width
        if height > row_h then row_h = height end
        if x > max_w then max_w = x end
      end
    end
    if row_h > 0 then y = y + row_h + spacing end
  end
  local tw, th = reaper.ImGui_CalcTextSize(ctx, content.text, nil, nil, false, wrap_w)
  if draw then
    reaper.ImGui_SetCursorScreenPos(ctx, ox, oy + y)
    reaper.ImGui_PushTextWrapPos(ctx, reaper.ImGui_GetCursorPosX(ctx) + wrap_w)
    reaper.ImGui_TextColored(ctx, t.TEXT_SECONDARY, content.text)
    reaper.ImGui_PopTextWrapPos(ctx)
  end
  if tw > max_w then max_w = tw end
  return max_w, y + th
end

-- Without the window-placement calls (a partial API stand-in outside REAPER),
-- fall back to ImGui's own pointer-following tooltip.
local function draw_unpinned(ctx, text)
  if type(text) == "table" then
    text = table.concat(text.shortcuts, "\n") .. "\n\n" .. text.text
  end
  if not reaper.ImGui_BeginTooltip(ctx) then return end
  reaper.ImGui_PushTextWrapPos(ctx, reaper.ImGui_GetCursorPosX(ctx) + tooltip_wrap_width())
  reaper.ImGui_Text(ctx, text)
  reaper.ImGui_PopTextWrapPos(ctx)
  reaper.ImGui_EndTooltip(ctx)
end

local function can_pin()
  return reaper.ImGui_SetNextWindowPos ~= nil and reaper.ImGui_SetNextWindowSize ~= nil
    and reaper.ImGui_GetMousePos ~= nil and reaper.ImGui_CalcTextSize ~= nil
    and reaper.ImGui_GetStyleVar ~= nil
end

-- REAPER's monitor lookup, handed over once at startup (native calls belong to
-- the adapter). Shaped like the `res` table anchored_panel expects.
local monitor = {}
function tips.set_monitor_lookup(lookup) monitor.monitor_work_area = lookup end

local UNBOUNDED = { left = -math.huge, top = -math.huge, right = math.huge, bottom = math.huge }

local function work_area(ctx, anchor)
  if anchor.work then return anchor.work end
  if monitor.monitor_work_area and reaper.ImGui_PointConvertNative then
    return anchored_panel.work_area(ctx, monitor, anchor)
  end
  if reaper.ImGui_GetWindowViewport and reaper.ImGui_Viewport_GetWorkPos then
    local viewport = reaper.ImGui_GetWindowViewport(ctx)
    local x, y = reaper.ImGui_Viewport_GetWorkPos(viewport)
    local w, h = reaper.ImGui_Viewport_GetWorkSize(viewport)
    return { left = x, top = y, right = x + w, bottom = y + h }
  end
  return UNBOUNDED
end

-- The pin: which tip is showing, the rectangle it belongs to, and where the
-- pointer was when it appeared. Fields are copied, never the caller's table,
-- so callers may reuse one table every frame.
local pin = { key = nil, left = 0, top = 0, right = 0, bottom = 0, px = 0, py = 0, work = UNBOUNDED }

local function same_rect(anchor)
  return math.abs(pin.left - anchor.left) < 1 and math.abs(pin.top - anchor.top) < 1
    and math.abs(pin.right - anchor.right) < 1 and math.abs(pin.bottom - anchor.bottom) < 1
end

-- Re-pin only for a different tip or a different rectangle. Within one meter
-- strip or plot the pointer can wander freely and the tip stays where it is.
-- The monitor lookup runs here, once per pin, not every frame.
local function pin_to(ctx, key, anchor)
  if pin.key == key and same_rect(anchor) then return end
  pin.key = key
  pin.left, pin.top, pin.right, pin.bottom = anchor.left, anchor.top, anchor.right, anchor.bottom
  pin.px, pin.py = reaper.ImGui_GetMousePos(ctx)
  pin.work = work_area(ctx, anchor)
end

local POINTER_OFFSET = 16 -- last resort only: how far below the pointer

local function draw(ctx, text, key, anchor)
  if not anchor or not can_pin() then return draw_unpinned(ctx, text) end
  pin_to(ctx, key, anchor)
  local m, work = theme.metrics, pin.work
  local margin, gap = m.PICK_SCREEN_MARGIN, m.PICK_ANCHOR_GAP
  local pad_x, pad_y = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding())
  local wrap_w = math.min(tooltip_wrap_width(), work.right - work.left - margin * 2 - pad_x * 2)
  if wrap_w <= 0 then return end
  local content_w, content_h
  if type(text) == "table" then
    content_w, content_h = shortcut_layout(ctx, text, wrap_w, false)
  else
    content_w, content_h = reaper.ImGui_CalcTextSize(ctx, text, nil, nil, false, wrap_w)
  end
  local w = math.ceil(content_w) + pad_x * 2
  local h = math.ceil(content_h) + pad_y * 2
  local x, y = placement.place(pin, work, w, h, pin.px, pin.py, gap, margin,
    POINTER_OFFSET * theme.scale)
  reaper.ImGui_SetNextWindowPos(ctx, x, y)
  reaper.ImGui_SetNextWindowSize(ctx, w, h)
  if not reaper.ImGui_BeginTooltip(ctx) then return end
  if type(text) == "table" then
    shortcut_layout(ctx, text, wrap_w, true)
  else
    reaper.ImGui_PushTextWrapPos(ctx, reaper.ImGui_GetCursorPosX(ctx) + wrap_w)
    reaper.ImGui_Text(ctx, text)
    reaper.ImGui_PopTextWrapPos(ctx)
  end
  reaper.ImGui_EndTooltip(ctx)
end

-- Reused for the common case: the tip belongs to the item just submitted.
local item_anchor = { left = 0, top = 0, right = 0, bottom = 0 }

-- Convenience for callers that already hold an {x, y, w, h} rectangle.
-- Returns one shared table, so pass it straight to tips.show.
local rect_anchor = { left = 0, top = 0, right = 0, bottom = 0 }
function tips.rect(x, y, w, h)
  rect_anchor.left, rect_anchor.top, rect_anchor.right, rect_anchor.bottom = x, y, x + w, y + h
  return rect_anchor
end

-- `hovered` is the caller's own answer, not re-derived here. A nil or empty
-- text is normal (a control with nothing to say this frame) and does nothing,
-- including not disturbing anyone else's timer.
--
-- `key` is for a tip whose TEXT changes while the cursor stays on the same
-- thing — the waveform's time readout rewrites itself every pixel, and keyed on
-- its text it would restart the wait forever and never appear. Give those a
-- fixed key and the wait runs on the control, not on the words.
--
-- `anchor` is the rectangle the tip explains, {left, top, right, bottom} in
-- screen coordinates (optionally with its monitor `work` area). Without one the
-- tip belongs to ImGui's last item, so call this straight after that item. A
-- caller whose hover comes from a drawn area, or from an item submitted
-- earlier, must pass the rectangle itself.
function tips.show(ctx, hovered, text, key, anchor)
  if not hovered or not text or text == "" then return end
  key = key or (type(text) == "table" and text.key or text)
  if not anchor and reaper.ImGui_GetItemRectMin and reaper.ImGui_GetItemRectMax then
    local x1, y1 = reaper.ImGui_GetItemRectMin(ctx)
    local x2, y2 = reaper.ImGui_GetItemRectMax(ctx)
    item_anchor.left, item_anchor.top, item_anchor.right, item_anchor.bottom = x1, y1, x2, y2
    anchor = item_anchor
  end
  if not HAS_CLOCK then
    draw(ctx, text, key, anchor)
    return
  end
  local now, frame = reaper.ImGui_GetTime(ctx), reaper.ImGui_GetFrameCount(ctx)
  if key ~= key_now or frame > last_frame + 1 then
    key_now, since = key, now
    pin.key = nil
  end
  last_frame = frame
  if now - since >= tips.DELAY then draw(ctx, text, key, anchor) end
end

return tips
