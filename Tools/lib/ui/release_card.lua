-- Reference Card release demonstrations: the production card beside the
-- analysis panels (ui/release_card_view.lua), playing its sample reference.
-- The overview tours Play, seek, trim and Stop; the resizing topic drags
-- a window's bottom edge so the card folds as core/card_plan.lua decides.
local theme = require('ui.theme')
local story = require('core.release_card_demo')
local view = require('ui.release_card_view')
local controls = require('ui.reference_controls')
local widgets = require('ui.widgets')
local match = require('core.match')
local scope = require('ui.release_preview_scope')
local pointer = require('ui.release_pointer')
local T, M = theme.tokens, theme.metrics
local card = {}

-- The demo shows a smaller window than the live default (1104 px of content
-- at 100% UI Size) so the card's text stays readable: full UI Size from
-- FULL_WIDTH of area upward, shrinking no further than MIN_RATIO below that.
-- The panels beside the card get whatever width remains.
local FULL_WIDTH, MIN_RATIO = 900, .85

function card.new()
  return {view=view.new(), scene={}, stages={}, holds={}, plan={}, anchors={
    home={}, seek={}, edge={}, play={}, stop={}, trim={}, trim_far={}}, row={}}
end

local function ratio_for(width)
  return math.max(.1, math.min(1, math.max(MIN_RATIO, width / (FULL_WIDTH * theme.scale))))
end

local function paint_pointer(ctx, demo, x, y, width, height)
  local scene, anchors = demo.scene, demo.anchors
  local from, to = anchors[scene.from], anchors[scene.to]
  if not from or not to or not from.x or not to.x then return end
  local px = from.x + (to.x - from.x) * scene.progress
  local py = from.y + (to.y - from.y) * scene.progress
  local dl = reaper.ImGui_GetForegroundDrawList(ctx)
  reaper.ImGui_DrawList_PushClipRect(dl, x, y, x + width, y + height, true)
  if scene.resize_axis then
    pointer.paint_click(dl, px, py, scene.pulse)
    pointer.paint_resize_ns(dl, px, py)
  else
    pointer.paint(dl, px, py, scene.pulse)
  end
  reaper.ImGui_DrawList_PopClipRect(dl)
end

local function set(point, px, py) point.x, point.y = px, py end

local function overview(ctx, res, demo, elapsed, x, y, width, height)
  local scene = story.sample('card_overview', elapsed, demo.scene, not theme.motion.enabled)
  view.apply(demo.view, scene,
    widgets.taper_db(story.trim_t(scene.trim_drag), match.TRIM_MAX, match.TRIM_SILENCE))
  local g = view.paint(ctx, res, demo.view, x, y, width, height)
  local strip, anchors = g.strip, demo.anchors
  local sx, sy = x + strip.x, y + strip.y
  local right = sx + strip.w
  set(anchors.home, right + (x + width - right) * .42, y + height * .78)
  local x0, y0, x1, y1 = view.wave_rect(ctx, sx, sy, strip.w, g.reference.h)
  local row = view.bottom_row(ctx, sx, sy, strip.w, g.reference.h, demo.row)
  if x0 then
    set(anchors.seek, x0 + story.SEEK_FRACTION * (x1 - x0), (y0 + y1) * .5)
  else
    set(anchors.seek, anchors.home.x, anchors.home.y)
  end
  set(anchors.play, row.play_x, row.cy)
  set(anchors.stop, row.stop_x, row.cy)
  set(anchors.trim, row.trim_x + story.trim_t(0) * row.trim_w, row.cy)
  set(anchors.trim_far, row.trim_x + story.trim_t(1) * row.trim_w, row.cy)
  paint_pointer(ctx, demo, x, y, width, height)
end

-- The fold stages for a window whose content is `w` wide, measured once per
-- width and UI Size by walking the production layout and card plan. A tall
-- window lets the panels put the card over their top row only, where it is
-- already shorter than the window; shrinking from there would show the card
-- grow back when the panels rearrange. The drag starts instead at the tallest
-- height where the card fills the window's height, so every step folds it.
local function fold_stages(ctx, demo, w, high, low)
  local key = demo.stage_key or {}
  demo.stage_key = key
  local font = reaper.ImGui_GetFontSize(ctx)
  if key.w == w and key.high == high and key.scale == theme.scale and key.font == font then
    return demo.stages, demo.holds
  end
  key.w, key.high, key.scale, key.font = w, high, theme.scale, font
  local v = demo.view
  -- The scan shrinks the view as the drag does, so the panels' remembered
  -- arrangement carries from one height to the next; the demo's own memory is
  -- put back afterwards.
  local mode, hidden = v.previous_mode, v.stereo_hidden
  v.previous_mode, v.stereo_hidden = nil, false
  local plan = demo.plan
  local start = math.floor(high)
  for h = start, math.ceil(low), -1 do
    if view.measure(ctx, v, w, h).reference.h >= h - 1 then start = h break end
  end
  local function fit(h)
    local g = view.measure(ctx, v, w, h)
    return controls.plan(ctx, g.reference.h, g.reference.w, plan)
  end
  story.fold_stages(fit, start, low, demo.stages)
  story.fold_holds(demo.stages, demo.holds)
  v.previous_mode, v.stereo_hidden = mode, hidden
  return demo.stages, demo.holds
end

local function resize(ctx, res, demo, elapsed, x, y, width, height)
  local s, pad = theme.scale, M.WINDOW_PAD
  local w = math.max(1, width - 2 * pad)
  local floor = controls.measure(ctx).card_minimum
  local _, holds = fold_stages(ctx, demo, w, math.max(floor, height - 2 * pad), floor)
  local scene = story.sample('card_resize', elapsed, demo.scene, not theme.motion.enabled, #holds)
  view.update(demo.view, elapsed, true)
  local from, to = holds[scene.height_from], holds[scene.height_to]
  local content_h = math.floor(from + (to - from) * scene.height_progress + .5)
  local frame_h = content_h + 2 * pad
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + width, y + frame_h, T.BG_WINDOW)
  reaper.ImGui_DrawList_AddRect(dl, x, y, x + width, y + frame_h, T.STROKE_PRIMARY, 0, 0, s)
  view.paint(ctx, res, demo.view, x + pad, y + pad, w, content_h)
  if scene.resize_axis then
    reaper.ImGui_DrawList_AddLine(dl, x, y + frame_h, x + width, y + frame_h,
      scene.resizing and T.ACCENT or T.STROKE_PRIMARY, 2 * s)
  end
  set(demo.anchors.home, x + width * .62, y + height * .8)
  set(demo.anchors.edge, x + width * .55, y + frame_h)
  paint_pointer(ctx, demo, x, y, width, height)
end

function card.draw(ctx, res, demo, topic, elapsed, width, height)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_PushClipRect(dl, x, y, x + width, y + height, true)
  scope.paint(ctx, ratio_for(width), function()
    if topic == 'card_resize' then
      resize(ctx, res, demo, elapsed, x, y, width, height)
    else
      overview(ctx, res, demo, elapsed, x, y, width, height)
    end
  end)
  reaper.ImGui_DrawList_PopClipRect(dl)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_Dummy(ctx, width, height)
end

return card
