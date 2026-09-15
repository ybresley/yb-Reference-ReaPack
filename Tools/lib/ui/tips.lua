-- tips: the app's one tooltip. Every tip in the UI goes through here, so they
-- all wait the same beat before appearing (user's ask, 2026-08-07 — showing
-- instantly meant tips flashing up while the cursor merely crossed the bar).
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
local placement = require("core.picker_layout")
local tips = {}

tips.DELAY = 0.15 -- seconds of continuous hover before a tip appears

-- Without both clock functions, show the tip immediately. This also supports
-- callers using a partial API stand-in outside REAPER.
local HAS_CLOCK = reaper.ImGui_GetTime ~= nil and reaper.ImGui_GetFrameCount ~= nil

-- Identity defaults to the tooltip TEXT: moving onto a control that says
-- something else restarts the wait. A frame in which nobody calls this means the
-- cursor is over nothing, so the next hover starts from zero instead of
-- appearing instantly — that is what `frame` is for.
local key_now, since, last_frame = nil, 0, -2

-- Anchored tips avoid the entire control row, not just the pointer. Measure
-- before opening so even the first visible frame has a safe screen position.
local function draw(ctx, text, anchor)
  if not anchor then
    reaper.ImGui_SetTooltip(ctx, text)
    return
  end
  local m, work = theme.metrics, anchor.work
  local padding, gap, margin = m.WINDOW_PAD, m.PICK_ANCHOR_GAP, m.PICK_SCREEN_MARGIN
  local available = work.right - work.left - margin * 2
  if available <= padding * 2 then return end
  local text_w = reaper.ImGui_CalcTextSize(ctx, text)
  local width = math.min(math.ceil(text_w) + padding * 2, m.PICK_LIST_MAX_W, available)
  local wrap_w = width - padding * 2
  local _, text_h = reaper.ImGui_CalcTextSize(ctx, text, nil, nil, false, wrap_w)
  local height = math.ceil(text_h) + padding * 2
  local box = placement.place(anchor, work, width, height, height, gap, margin)
  -- Follow the pointer horizontally while keeping the whole row clear vertically.
  local mouse_x = reaper.ImGui_GetMousePos(ctx)
  box.x = math.max(work.left + margin,
    math.min(math.floor(mouse_x - box.w * 0.5), work.right - margin - box.w))
  -- On an exceptionally small screen, omit a tip that cannot fit rather than
  -- cover the control it explains or show a clipped instruction.
  if box.h < height or (box.y < anchor.bottom and box.y + box.h > anchor.top) then return end
  reaper.ImGui_SetNextWindowPos(ctx, box.x, box.y)
  reaper.ImGui_SetNextWindowSize(ctx, box.w, box.h)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), padding, padding)
  local opened = reaper.ImGui_BeginTooltip(ctx)
  reaper.ImGui_PopStyleVar(ctx, 1)
  if opened then
    reaper.ImGui_PushTextWrapPos(ctx, reaper.ImGui_GetCursorPosX(ctx) + wrap_w)
    reaper.ImGui_Text(ctx, text)
    reaper.ImGui_PopTextWrapPos(ctx)
    reaper.ImGui_EndTooltip(ctx)
  end
end

-- `hovered` is the caller's own answer, not re-derived here. A nil or empty
-- text is normal (a control with nothing to say this frame) and does nothing,
-- including not disturbing anyone else's timer.
--
-- `key` is for a tip whose TEXT changes while the cursor stays on the same
-- thing — the waveform's time readout rewrites itself every pixel, and keyed on
-- its text it would restart the wait forever and never appear. Give those a
-- fixed key and the wait runs on the control, not on the words.
-- Optional `anchor` supplies the row rectangle and its monitor work area in
-- the same coordinates. Other callers retain normal pointer-based placement.
function tips.show(ctx, hovered, text, key, anchor)
  if not hovered or not text or text == "" then return end
  if not HAS_CLOCK then
    draw(ctx, text, anchor)
    return
  end
  key = key or text
  local now, frame = reaper.ImGui_GetTime(ctx), reaper.ImGui_GetFrameCount(ctx)
  if key ~= key_now or frame > last_frame + 1 then
    key_now, since = key, now
  end
  last_frame = frame
  if now - since >= tips.DELAY then draw(ctx, text, anchor) end
end

return tips
