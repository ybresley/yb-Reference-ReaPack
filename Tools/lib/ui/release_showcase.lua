-- The browser owns presentation state. Demonstrations never receive app state.
local theme = require('ui.theme')
local tour = require('core.release_tour')
local content = require('ui.release_content')
local navigation = require('ui.release_navigation')
local T, M = theme.tokens, theme.metrics
local showcase = { version = content.version }
local selection = tour.new()
local demo, demo_key, renderers
local generation = 0

function showcase.available(installed, releases)
  return tour.available(content, installed, releases)
end

function showcase.supplements(releases)
  return tour.supplements(content, releases)
end

function showcase.reset()
  selection, demo, demo_key = tour.new(), nil, nil
  generation = generation + 1
  navigation.reset()
end

local function demonstration(ctx, res)
  local _, topic = tour.current(selection, content)
  local width = reaper.ImGui_GetContentRegionAvail(ctx)
  if demo_key ~= topic.id then
    demo_key = topic.id
    demo = renderers[topic.renderer or 'other'].new()
  end
  local elapsed = tour.tick(selection, reaper.ImGui_GetTime(ctx), theme.motion.enabled)
  local _, room = reaper.ImGui_GetContentRegionAvail(ctx)
  local height = math.max(1, room - M.ITEM_SPACING_Y)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
  local visible = reaper.ImGui_BeginChild(ctx, 'release_demonstration', width, height, 0,
    reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse())
  reaper.ImGui_PopStyleVar(ctx)
  if visible then
    reaper.ImGui_SetCursorPos(ctx, M.WINDOW_PAD, M.WINDOW_PAD)
    renderers[topic.renderer or 'other'].draw(ctx, res, demo, topic.id, elapsed,
      math.max(1, width - M.WINDOW_PAD * 2), math.max(1, height - M.WINDOW_PAD * 2))
    reaper.ImGui_EndChild(ctx)
  end
end

function showcase.draw(ctx, res, preview)
  if not renderers then
    renderers = { spectrum = require('ui.release_spectrum'), other = require('ui.release_examples'),
      helper = require('ui.release_helper') }
  end
  local bold = theme.push_release_bold_font(ctx)
  reaper.ImGui_TextColored(ctx, T.ACCENT, 'v' .. content.version)
  if bold then reaper.ImGui_PopFont(ctx) end
  if preview then
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextColored(ctx, T.TEXT_TERTIARY, 'Development Preview')
  end
  local namespace = 'release_navigation_' .. generation
  local width, room = reaper.ImGui_GetContentRegionAvail(ctx)
  local cards_h = navigation.feature_height(width, #content.features, selection.feature)
  local viewport_h = math.min(cards_h, math.max(1, room * .44))
  local scroll = cards_h > viewport_h
  local flags = scroll and 0 or
    reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
  local visible = reaper.ImGui_BeginChild(ctx, 'release_features', width, viewport_h, 0, flags)
  reaper.ImGui_PopStyleVar(ctx)
  if visible then
    local choice = navigation.features(ctx, content.features, selection.feature, namespace)
    if choice and tour.select_feature(selection, content, choice) then
      reaper.ImGui_SetScrollY(ctx, 0)
    end
    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_Dummy(ctx, 0, M.ITEM_SPACING_Y)
  width, room = reaper.ImGui_GetContentRegionAvail(ctx)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), T.BG_WINDOW)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), T.STROKE_SECONDARY)
  visible = reaper.ImGui_BeginChild(ctx, 'release_topic_and_demo', width,
    math.max(1, room - M.ITEM_SPACING_Y), reaper.ImGui_ChildFlags_Borders(),
    reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse())
  reaper.ImGui_PopStyleColor(ctx, 2)
  reaper.ImGui_PopStyleVar(ctx)
  if visible then
    local choice = navigation.topics(ctx, content, selection.feature,
      selection.topics[selection.feature] or 1, namespace)
    if choice then tour.select_topic(selection, content, choice) end
    local divider_x, divider_y = reaper.ImGui_GetCursorScreenPos(ctx)
    local divider_w = reaper.ImGui_GetContentRegionAvail(ctx)
    local opacity = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_Alpha())
    divider_y = divider_y - M.ITEM_SPACING_Y * .5
    reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(ctx),
      divider_x, divider_y, divider_x + divider_w, divider_y,
      theme.fade(T.STROKE_SECONDARY, opacity), theme.scale)
    demonstration(ctx, res)
    reaper.ImGui_EndChild(ctx)
  end
end

return showcase
