-- Guided tour over the real interface. Highlights are paint-only; the card
-- is a separate window so navigation clicks cannot reach the controls below.
-- Card actions are handled by the entry script. Position stays stable per step.

local wt    = require("core.walkthrough")
local placement = require("core.walkthrough_layout")
local theme = require("ui.theme")
local widgets = require("ui.widgets")
local T = theme.tokens
local M = theme.metrics

local walkthrough = {}

-- Feature detection, once at load (the house idiom). The card degrades in
-- steps: without TopMost it can slip behind a clicked window (rare, accepted on
-- old builds); without the core flag set it isn't drawn at all — a naked
-- titled window flashing up would look broken, worse than no card.
local CARD_FLAGS, CARD_OK = 0, true
for _, name in ipairs({ "NoTitleBar", "NoResize", "NoScrollbar", "NoCollapse",
                        "NoMove", "NoSavedSettings", "NoFocusOnAppearing", "NoNav",
                        "AlwaysAutoResize" }) do
  local fn = reaper["ImGui_WindowFlags_" .. name]
  if fn then CARD_FLAGS = CARD_FLAGS | fn() else CARD_OK = false end
end
if reaper.ImGui_WindowFlags_NoDocking then
  CARD_FLAGS = CARD_FLAGS | reaper.ImGui_WindowFlags_NoDocking()
end
-- TopMost is what keeps the card over the window it annotates even after that
-- window is clicked — which stop 1 explicitly asks the user to do.
if reaper.ImGui_WindowFlags_TopMost then
  CARD_FLAGS = CARD_FLAGS | reaper.ImGui_WindowFlags_TopMost()
end
local HAS_FG_LIST = reaper.ImGui_GetForegroundDrawList ~= nil

-- Whether a card can be drawn at all on this ReaImGui. The entry script asks
-- BEFORE starting the tour and writing the seen-mark: that mark is one-shot, so
-- starting a tour whose card can never appear would silently spend the user's
-- only first run on nothing (Codex, 2026-08-10). Every flag in the list above
-- is ancient, so this is a guard against a build nobody has rather than a
-- known case — but the failure it prevents is invisible and permanent.
function walkthrough.can_draw()
  return CARD_OK
end

-- Per-frame target geometry, keyed by stop id. Stamped with the frame count so
-- yesterday's rect can never place today's ring: a window that stopped drawing
-- (the browser mid-close) simply stops noting, and its entry goes stale.
local rects = {}
-- Host-window rects, recorded by wash() so card() can anchor and clamp without
-- being inside either window's Begin scope.
local hosts = {}
local card_position

-- The stop the ring and card belong to right now. While frozen the target is
-- the LIBRARY BUTTON — the card parks on the main window asking for a reopen,
-- and ringing the button that does it is the whole hint.
local function effective_target(ws)
  local cur = wt.current(ws)
  if not cur then return nil, cur end
  if wt.is_frozen(ws) then return "library_button", cur end
  return cur.id, cur
end

-- Whether the current stop wants a rect under this id: as its ringed TARGET,
-- or as its CONTEXT — a second region kept bright without a ring (the sidebar
-- stop keeps the sound list visible so a category click visibly filters).
local function wants(ws, id)
  local target, cur = effective_target(ws)
  if target == id then return true end
  return type(cur) == "table" and not wt.is_frozen(ws) and cur.context == id
end

-- Record the LAST SUBMITTED ITEM as (part of) target `id`. Called by the
-- windows right after they submit the real control. Two notes for one id in
-- one frame UNION into one rect.
function walkthrough.note(ctx, ws, id)
  if not ws or not ws.active then return end
  if not wants(ws, id) then return end
  local x1, y1 = reaper.ImGui_GetItemRectMin(ctx)
  local x2, y2 = reaper.ImGui_GetItemRectMax(ctx)
  walkthrough.note_rect(ctx, ws, id, x1, y1, x2, y2)
end

-- Same, for a region that isn't one item (a child window, the drop area).
function walkthrough.note_rect(ctx, ws, id, x1, y1, x2, y2)
  if not ws or not ws.active then return end
  if not wants(ws, id) then return end
  local frame = reaper.ImGui_GetFrameCount(ctx)
  local r = rects[id]
  if r and r.frame == frame then
    r.x1, r.y1 = math.min(r.x1, x1), math.min(r.y1, y1)
    r.x2, r.y2 = math.max(r.x2, x2), math.max(r.y2, y2)
  else
    rects[id] = { frame = frame, x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
  end
end

-- Inflate a noted rect by the ring pad and clamp it INSIDE the window: a
-- target flush against an edge (the sidebar's left is the window's own left)
-- would otherwise push the ring outside the viewport, where the foreground
-- list clips it and the border simply vanishes (round 2 fix).
local function inflate_clamped(r, wx, wy, ww, wh)
  local p = M.WALK_RING_PAD
  return {
    x1 = math.max(r.x1 - p, wx + 1), y1 = math.max(r.y1 - p, wy + 1),
    x2 = math.min(r.x2 + p, wx + ww - 1), y2 = math.min(r.y2 + p, wy + wh - 1),
  }
end

-- The spotlight, drawn from INSIDE a window's Begin scope. Foreground draw
-- list, not the window's own: the browser is built of child windows, which
-- render over anything their parent painted — the wash has to land on top of
-- everything, hole and ring included. Also records the window's rect for the
-- card's anchoring below.
--
-- A stop may keep up to TWO regions bright: its ringed target, and an unringed
-- `context` region (the sidebar stop's sound list). The wash is therefore cut
-- band by band around however many holes this window carries, instead of the
-- fixed four-rects-around-one-hole shape.
function walkthrough.wash(ctx, ws, win)
  if not ws or not ws.active then return end
  local wx, wy = reaper.ImGui_GetWindowPos(ctx)
  local ww, wh = reaper.ImGui_GetWindowSize(ctx)
  hosts[win] = { x = wx, y = wy, w = ww, h = wh,
    frame = reaper.ImGui_GetFrameCount(ctx) }
  if not HAS_FG_LIST then return end

  local dl = reaper.ImGui_GetForegroundDrawList(ctx)
  local frame = reaper.ImGui_GetFrameCount(ctx)
  local id, cur = effective_target(ws)
  local target_win = "main"
  if cur and not wt.is_frozen(ws) then target_win = cur.window end

  local holes, ring = {}, nil
  if id and win == target_win then
    local r = rects[id]
    if r and r.frame == frame then
      ring = inflate_clamped(r, wx, wy, ww, wh)
      holes[#holes + 1] = ring
    end
    local ctx_id = type(cur) == "table" and cur.context or nil
    if ctx_id then
      local c = rects[ctx_id]
      if c and c.frame == frame then
        holes[#holes + 1] = inflate_clamped(c, wx, wy, ww, wh)
      end
    end
  end

  if #holes == 0 then
    reaper.ImGui_DrawList_AddRectFilled(dl, wx, wy, wx + ww, wy + wh, T.WALK_DIM)
  else
    -- Horizontal bands at every hole edge; inside each band, fill the x-gaps
    -- between the holes that span it. Handles one or two holes identically,
    -- and holes never double-dim anything because fills never overlap.
    local ys = { wy, wy + wh }
    for i = 1, #holes do
      ys[#ys + 1] = holes[i].y1; ys[#ys + 1] = holes[i].y2
    end
    table.sort(ys)
    for i = 1, #ys - 1 do
      local y1, y2 = ys[i], ys[i + 1]
      if y2 > y1 and y1 >= wy and y2 <= wy + wh then
        local spanning = {}
        for j = 1, #holes do
          local h = holes[j]
          if h.y1 <= y1 and h.y2 >= y2 then spanning[#spanning + 1] = h end
        end
        table.sort(spanning, function(a, b) return a.x1 < b.x1 end)
        local x = wx
        for j = 1, #spanning do
          local h = spanning[j]
          if h.x1 > x then
            reaper.ImGui_DrawList_AddRectFilled(dl, x, y1, h.x1, y2, T.WALK_DIM)
          end
          x = math.max(x, h.x2)
        end
        if x < wx + ww then
          reaper.ImGui_DrawList_AddRectFilled(dl, x, y1, wx + ww, y2, T.WALK_DIM)
        end
      end
    end
    -- Only the TARGET wears the ring — a ringed context would make two
    -- subjects out of one stop.
    if ring then
      local radius = M.WALK_RING_RADIUS
      if wt.is_frozen(ws) or (type(cur) == 'table' and cur.act) then
        reaper.ImGui_DrawList_AddRect(dl, ring.x1, ring.y1, ring.x2, ring.y2,
          theme.fade(T.ACCENT, 0.5), radius, 0, M.BORDER_GLOW_WIDTH)
        widgets.draw_border_glow(ctx, dl, ring.x1, ring.y1, ring.x2, ring.y2,
          radius, T.ACCENT)
      else
        widgets.draw_border_halo(ctx, dl, ring.x1, ring.y1, ring.x2, ring.y2,
          radius, T.ACCENT)
      end
    end
  end
end

-- Where the card may stand. The card is a real WINDOW, so a card over the stop's
-- target doesn't merely hide it — it swallows the click, and a stop that asks
-- for that click can never be finished (user-reported 2026-08-10: stop 1's
-- Library button was unpressable on the short docked strip, where the old
-- "clamp into the host window" rule parked the card straight over the bar).
--
-- Side placement is tried across the host and screen before above or below.
-- The whole Library is an obstacle, even when only its sound list is highlighted.
local HAS_VIEWPORT = reaper.ImGui_GetMainViewport ~= nil
  and reaper.ImGui_Viewport_GetWorkPos ~= nil and reaper.ImGui_Viewport_GetWorkSize ~= nil

local function clamp(v, lo, hi)
  return math.max(lo, math.min(math.max(lo, hi), v))
end

-- A text-styled control (the Back and Skip links): an InvisibleButton with the words
-- painted over it, dim at rest and bright under the cursor. `h` makes the hit
-- area a full control height with the words centred in it — that is what
-- keeps the footer on ONE line with no cursor nudging (SameLine would undo
-- any nudge when the next control joins the line).
local function text_button(ctx, label, h, disabled)
  local tw, th = reaper.ImGui_CalcTextSize(ctx, label)
  h = h or th
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local clicked = reaper.ImGui_InvisibleButton(ctx, "##" .. label, tw, h)
  local hovered = not disabled and reaper.ImGui_IsItemHovered(ctx)
  local colour = disabled and T.TEXT_QUATERNARY
    or (hovered and T.TEXT_SECONDARY or T.TEXT_TERTIARY)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_AddText(dl, x, y + (h - th) / 2,
    colour, label)
  return not disabled and clicked
end

-- The card's height, worked out BEFORE the window is submitted.
--
-- It used to be last frame's `GetWindowSize`, and that is what made a stop
-- change flicker (user-reported 2026-08-10, stepping off the pin stop, where
-- the card also crosses the window's edge): the card is POSITIONED before it is
-- drawn, so the new stop was placed with the old stop's height, and an
-- auto-resizing window only takes its new size the frame AFTER its content
-- changed — two frames of wrong geometry, seen as a jump. Measuring instead of
-- remembering makes the first frame correct and deletes the settle entirely.
--
-- Every line below mirrors one submitted by the drawing code, in the same font
-- and the same order, so the two can't drift: the title/progress row, body,
-- optional note, the 2px spacer, the footer's control-height line, plus
-- ItemSpacing between each and the window's own padding around the lot.
local function measure_card(ctx, title, body, note)
  local pad = M.WALK_CARD_PAD
  local wrap = M.WALK_CARD_W - pad * 2
  local sp = select(2, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing()))
  local hd = theme.push_heading_font(ctx)
  local h = select(2, reaper.ImGui_CalcTextSize(ctx, title))
  if hd then reaper.ImGui_PopFont(ctx) end
  -- CalcTextSize's two OUT slots are real Lua arguments, passed as nil — the
  -- wrap width is the SIXTH argument, not the fourth (verified 2026-08-11
  -- against ReaImGui's own author's scripts after this crashed live: the C
  -- signature reads `ctx, text, wOut, hOut, hide…, wrap…`, and the Lua binding
  -- keeps the out params in the list instead of dropping them).
  h = h + sp + select(2, reaper.ImGui_CalcTextSize(ctx, body, nil, nil, false, wrap))
  if note then
    h = h + sp + select(2, reaper.ImGui_CalcTextSize(ctx, note, nil, nil, false, wrap))
  end
  return h + sp + 2 + sp + reaper.ImGui_GetFrameHeight(ctx) + pad * 2
end

-- The card, drawn ONCE per frame at app level (outside both hosts' scopes —
-- it is its own window). Returns a { type = "walkthrough", ev = ... } action
-- or nil; the entry script runs the state machine.
function walkthrough.card(ctx, ws)
  local active = (ws and ws.active) or false
  if not active or not CARD_OK then
    card_position = nil
    return nil
  end
  local cur = wt.current(ws)
  if not cur then return nil end

  local frozen = wt.is_frozen(ws)
  local frame = reaper.ImGui_GetFrameCount(ctx)

  -- A frozen Library step points to the reopen button in the main window. A host that didn't draw this frame (browser
  -- mid-close) falls back to main; no host at all (main hidden) = no card.
  local host_key = "main"
  if not frozen and cur.window == "browser" then host_key = "browser" end
  local host = hosts[host_key]
  if not (host and host.frame == frame) then host = hosts.main end
  if not (host and host.frame == frame) then return nil end

  local cw = M.WALK_CARD_W
  local margin = M.WINDOW_PAD

  -- This stop's copy, settled here so the measurement and the drawing below
  -- read from one place (a card measured from different words than it draws is
  -- the flicker again, wearing a different hat).
  local title = cur.title
  local body = frozen and wt.FROZEN_BODY or cur.body
  local note = not frozen and cur.note or nil
  local card_h = measure_card(ctx, title, body, note)

  -- The screen's usable area: the card is allowed to leave the tool window (see
  -- the placement helpers above), so this — not the host rect — is the outer
  -- fence. Without the viewport calls the host window is the whole world, which
  -- is what the old rule assumed.
  local vx, vy, vw, vh = host.x, host.y, host.w, host.h
  if HAS_VIEWPORT then
    local vp = reaper.ImGui_GetMainViewport(ctx)
    local px, py = reaper.ImGui_Viewport_GetWorkPos(vp)
    local pw, ph = reaper.ImGui_Viewport_GetWorkSize(vp)
    -- UNION with the host window, never the work area alone: that area is one
    -- monitor's, and with REAPER on a second screen a bare clamp would fling the
    -- card onto the other one, chasing the user away from the thing it points at.
    vx, vy = math.min(vx, px), math.min(vy, py)
    vw = math.max(host.x + host.w, px + pw) - vx
    vh = math.max(host.y + host.h, py + ph) - vy
  end

  local r = rects[frozen and "library_button" or cur.id]
  if r and r.frame ~= frame then r = nil end

  local browser = hosts.browser
  local library_rect = browser and browser.frame == frame and {
    x1 = browser.x, y1 = browser.y,
    x2 = browser.x + browser.w, y2 = browser.y + browser.h,
  } or nil
  local x, y
  if r then
    -- Beside its target — inside the host if it fits there, otherwise anywhere
    -- on screen that clears the ring. The pin stop needs no exception any more:
    -- its ring IS the whole main window, so nothing fits inside and the card
    -- steps out beside it, leaving the drop area it talks about fully visible.
    local ring = { x1 = r.x1 - M.WALK_RING_PAD, y1 = r.y1 - M.WALK_RING_PAD,
                   x2 = r.x2 + M.WALK_RING_PAD, y2 = r.y2 + M.WALK_RING_PAD }
    -- Browser stops sit outside the entire Library, including its title bar.
    -- Avoiding only the highlighted list lets the Library cover the card.
    if host_key == "browser" and library_rect then
      ring = library_rect
    end
    x, y = placement.place(ring, cw, card_h,
      { host, { x = vx, y = vy, w = vw, h = vh } },
      library_rect and { library_rect } or {}, M.WALK_RING_PAD * 2, margin)
    if not x then
      -- Nowhere clears it (a tiny screen): below the target, on screen. Overlap
      -- is unavoidable here, and a reachable card beats a hidden one.
      x = clamp(ring.x2 - cw, vx + margin, vx + vw - margin - cw)
      y = clamp(ring.y2 + M.WALK_RING_PAD * 2, vy + margin, vy + vh - margin - card_h)
    end
  else
    -- A stop whose target did not draw this frame (a
    -- narrow dock clipped it): centred on the tool, kept on screen — the tour
    -- never silently disappears.
    x = clamp(host.x + (host.w - cw) / 2, vx + margin, vx + vw - margin - cw)
    y = clamp(host.y + (host.h - card_h) / 2, vy + margin, vy + vh - margin - card_h)
  end

  card_position = placement.stabilize(card_position, ws.pos, x, y, cw, card_h,
    { x = vx, y = vy, w = vw, h = vh }, library_rect and { library_rect } or {}, margin,
    { id = host_key, x = host.x, y = host.y })
  x, y = card_position.x, card_position.y

  -- On a screen too small to avoid overlap, keep the tutorial controls reachable.
  -- Only raise the card in that fallback, so normal Library input retains focus.
  if library_rect and placement.overlaps(x, y, cw, card_h, library_rect)
      and reaper.ImGui_SetNextWindowFocus then
    reaper.ImGui_SetNextWindowFocus(ctx)
  end
  reaper.ImGui_SetNextWindowPos(ctx, x, y, reaper.ImGui_Cond_Always())
  reaper.ImGui_SetNextWindowSize(ctx, cw, card_h, reaper.ImGui_Cond_Always())
  if reaper.ImGui_SetNextWindowSizeConstraints ~= nil
    and reaper.ImGui_NumericLimits_Float ~= nil then
    local _, flt_max = reaper.ImGui_NumericLimits_Float()
    reaper.ImGui_SetNextWindowSizeConstraints(ctx, cw, 0, cw, flt_max)
  end

  -- Popup dressing, popped the moment Begin has taken it (the Begin-time-push
  -- rule): held across the contents these would restyle the card's own
  -- tooltips too.
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), T.BG_POPUP)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), T.STROKE_PRIMARY)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 8)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowBorderSize(), 1)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(),
    M.WALK_CARD_PAD, M.WALK_CARD_PAD)
  local visible = reaper.ImGui_Begin(ctx, "##yb_walkthrough", nil, CARD_FLAGS)
  reaper.ImGui_PopStyleVar(ctx, 3)
  reaper.ImGui_PopStyleColor(ctx, 2)
  if not visible then return nil end

  local action

  -- A compact count leaves room for the heading as the tour gains stops.
  local title_x, title_y = reaper.ImGui_GetCursorScreenPos(ctx)
  local title_avail = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local hd = theme.push_heading_font(ctx)
  local title_h = select(2, reaper.ImGui_CalcTextSize(ctx, title))
  reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, title)
  if hd then reaper.ImGui_PopFont(ctx) end
  do
    local progress = string.format('%d / %d', ws.pos, #wt.STOPS)
    local progress_w, progress_h = reaper.ImGui_CalcTextSize(ctx, progress)
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    reaper.ImGui_DrawList_AddText(dl, title_x + title_avail - progress_w,
      title_y + (title_h - progress_h) / 2, T.TEXT_TERTIARY, progress)
  end

  -- Body, wrapped to the card. Frozen replaces the stop's own lesson with the
  -- one thing that matters right now: how to get it back.
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.TEXT_SECONDARY)
  reaper.ImGui_TextWrapped(ctx, body)
  reaper.ImGui_PopStyleColor(ctx)

  -- The dim aside line (the finale's replay pointer; the drop and pin stops'
  -- library-vs-project facts).
  if note then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.TEXT_TERTIARY)
    reaper.ImGui_TextWrapped(ctx, note)
    reaper.ImGui_PopStyleColor(ctx)
  end

  reaper.ImGui_Dummy(ctx, 0, 2)

  -- Footer: Back on the left, then Skip and one button hugging the right edge.
  -- Back remains in place on stop 1 but disables there, so moving between stops
  -- changes state without changing geometry.
  local avail = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local x0 = reaper.ImGui_GetCursorPosX(ctx)
  local frame_h = reaper.ImGui_GetFrameHeight(ctx)

  -- A closed Library offers Open; otherwise the button advances the tour.
  local btn_label, act
  if frozen then btn_label, act = wt.FROZEN_BUTTON, wt.FROZEN_ACT
  else btn_label, act = cur.button, cur.act end

  local skip_label = "Skip"
  local skip_w = select(1, reaper.ImGui_CalcTextSize(ctx, skip_label))

  do
    if text_button(ctx, "Back", frame_h, ws.pos <= 1) then
      action = { type = "walkthrough", ev = "back" }
    end
  end

  -- Skip sits just left of the button; both hug the card's right edge.
  local skip_x = x0 + avail - M.POPUP_BTN_W - M.ITEM_SPACING_X * 2 - skip_w
  reaper.ImGui_SameLine(ctx, skip_x)
  if text_button(ctx, skip_label, frame_h) then
    action = { type = "walkthrough", ev = "skip" }
  end

  reaper.ImGui_SameLine(ctx, x0 + avail - M.POPUP_BTN_W)
  if reaper.ImGui_Button(ctx, btn_label, M.POPUP_BTN_W) then
    -- Reopening the Library keeps the current step; Next advances it.
    action = act and { type = act } or { type = "walkthrough", ev = "next" }
  end

  reaper.ImGui_End(ctx)
  return action
end

return walkthrough
