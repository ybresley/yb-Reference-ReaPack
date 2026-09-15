-- Temporary inspection state belongs to the graph, not the saved analyser history.
local hover = require('core.spectrum_hover')
local mathx = require('core.spectrum_math')
local curve_shape = require('core.spectrum_curve')
local label_tracks = require('core.spectrum_labels')
local label_layout = require('core.spectrum_label_layout')
local theme = require('ui.theme')
local T, M = theme.tokens, theme.metrics
local spectrum_hover = {}
local capture, input = hover.new(), {}
local mode = 'hold'
local last_frame, last_model, last_history, last_smoothing, last_resolution
local candidates, draw_order = {}, {}
local space = label_layout.new()
local labels = label_tracks.new()
local bounds, trial = {}, {}
local label_gx, label_gy, label_width, label_height, label_bottom

local function clear_labels()
  label_tracks.reset(labels)
end

function spectrum_hover.get_mode() return mode end

function spectrum_hover.set_mode(value)
  assert(value == 'hold' or value == 'off')
  mode = value
  hover.reset(capture)
  clear_labels()
end

function spectrum_hover.prepare(ctx, model, data, eligible, gx, gy, width)
  local frame = reaper.ImGui_GetFrameCount(ctx)
  -- Hiding the graph or replacing its measurements must discard an old capture,
  -- even when the pointer returns to the same place on the very next frame.
  if last_frame and frame ~= last_frame + 1 or last_model ~= model
      or last_history ~= model.history_epoch or last_smoothing ~= model.prefs.smoothing
      or last_resolution ~= model.prefs.resolution then
    hover.reset(capture)
    clear_labels()
  end
  last_frame, last_model = frame, model
  last_history, last_smoothing = model.history_epoch, model.prefs.smoothing
  last_resolution = model.prefs.resolution
  local mx, my = reaper.ImGui_GetMousePos(ctx)
  input.now, input.eligible = reaper.ImGui_GetTime(ctx), eligible
  input.x, input.y = (mx - gx) / theme.scale, (my - gy) / theme.scale
  input.values, input.count = data, model.count or 0
  input.fmin, input.fmax = model.fmin, model.fmax
  input.source_key, input.epoch = model.source_key, model.epoch
  input.mode, input.tilt, input.width = mode, model.prefs.tilt, width / theme.scale
  local generation = capture.generation
  hover.update(capture, input)
  capture.highlight = hover.highlight_amount(capture)
  if capture.generation ~= generation then clear_labels() end
  return capture
end

local function label(hz)
  if hz >= 1000 then return string.format('%.2f kHz', hz / 1000) end
  return string.format('%.0f Hz', hz)
end

local function position_label(ctx, rect, index, owner)
  local width, height = bounds.x1 - bounds.x0, bounds.y1 - bounds.y0
  local pad_x, pad_y, gap = M.SPECTRUM_TAG_PAD_X, M.SPECTRUM_TAG_PAD_Y, M.ITEM_SPACING_Y
  local hz = mathx.bin_frequency(index, capture.count, input.fmin, input.fmax)
  local xx = bounds.x0 + (index - 0.5) / capture.count * width
  local db = curve_shape.sample_drawn(capture.outline, capture.count, index, width)
  local yy = bounds.y0 + mathx.db_fraction(db, 6, label_bottom) * height
  local text = label(hz)
  local tw, th = reaper.ImGui_CalcTextSize(ctx, text)
  local w, h = tw + pad_x * 2, th + pad_y * 2
  if db < label_bottom or w > width or h + gap > height then return end
  rect.x0 = math.max(bounds.x0, math.min(bounds.x1 - w, xx - w / 2))
  rect.x1 = rect.x0 + w
  rect.y0 = yy - h - gap
  rect.y1 = yy - gap
  if label_layout.fits(space, rect, owner) then return text, xx, yy end
end

local function visible_layout(item)
  return item.opacity > 0 and item.has_layout and item.layout_id == item.id
end

local function reserve_visible()
  label_layout.reset(space, bounds, M.SPECTRUM_BAND_GAP)
  for _, item in ipairs(labels.items) do
    if visible_layout(item) then label_layout.reserve(space, item, item.rect) end
  end
end

local function candidate_priority(a, b)
  if (a.owner ~= nil) ~= (b.owner ~= nil) then return a.owner ~= nil end
  if a.owner and b.owner then return a.owner.id < b.owner.id end
  return a.order < b.order
end

local function draw_priority(a, b)
  local a_visible, b_visible = a.layout_incumbent == true, b.layout_incumbent == true
  if a_visible ~= b_visible then return a_visible end
  return a.id < b.id
end

local function match_visible_owners(association)
  for _ = 1, #candidates do
    local nearest, owner, distance
    for _, candidate in ipairs(candidates) do
      if not candidate.owner then
        for _, item in ipairs(labels.items) do
          if item.layout_incumbent and not item.layout_claimed then
            local delta = math.abs(item.target_index - candidate.index)
            if delta <= association and (not distance or delta < distance)
                and curve_shape.same_crest(capture.outline, capture.count, item.target_index, candidate.index)
                and curve_shape.same_crest(capture.outline, capture.count, item.index, candidate.index) then
              nearest, owner, distance = candidate, item, delta
            end
          end
        end
      end
    end
    if not owner then break end
    nearest.owner, owner.layout_claimed = owner, true
  end
  table.sort(candidates, candidate_priority)
end

function spectrum_hover.draw_labels(ctx, dl, gx, gy, width, height, bottom, excluded, controls, clear)
  if gx ~= label_gx or gy ~= label_gy or width ~= label_width
      or height ~= label_height or bottom ~= label_bottom then clear_labels() end
  label_gx, label_gy, label_width, label_height, label_bottom = gx, gy, width, height, bottom
  bounds.x0, bounds.y0, bounds.x1, bounds.y1 = gx, gy, gx + width, gy + height
  bounds.excluded, bounds.controls, bounds.clear = excluded, controls, clear
  local small = theme.push_small_font(ctx)
  local pad = M.SPECTRUM_BAND_GAP
  local radius = M.UPDATE_DOT_R * 0.9
  local right, lower = gx + width, gy + height
  local association = capture.active and hover.label_association_distance(
    input.count, input.fmin, input.fmax, input.width) or 0
  for _, item in ipairs(labels.items) do
    item.layout_incumbent, item.layout_claimed = visible_layout(item), false
  end
  local peak_count = capture.active and capture.opacity > 0 and #capture.peaks or 0
  for peak_index = 1, peak_count do
    local peak = capture.peaks[peak_index]
    local candidate = candidates[peak_index] or { rect = {} }
    candidates[peak_index] = candidate
    candidate.index, candidate.order, candidate.owner = peak.index, peak_index, nil
  end
  for i = #candidates, peak_count + 1, -1 do candidates[i] = nil end
  match_visible_owners(association)
  reserve_visible()
  -- Existing visible tags get first choice of space. A newcomer must keep a
  -- usable position throughout confirmation before it can begin its fade.
  for _, candidate in ipairs(candidates) do
    local owner = candidate.owner or candidate
    candidate.placeable = position_label(ctx, candidate.rect, candidate.index, owner) ~= nil
    if candidate.placeable then
      label_layout.reserve(space, owner, candidate.rect)
    end
  end
  label_tracks.update(labels, candidates, input.now, capture.active, association,
    capture.outline, capture.count, input.width)

  for i, item in ipairs(labels.items) do draw_order[i] = item end
  for i = #draw_order, #labels.items + 1, -1 do draw_order[i] = nil end
  table.sort(draw_order, draw_priority)
  reserve_visible()
  for _, item in ipairs(draw_order) do
    if item.layout_id ~= item.id then
      item.has_layout, item.layout_id = false, item.id
    end
    local alpha = item.opacity
    local rect = item.rect
    if alpha > 0 and item.matched and capture.active and capture.opacity > 0 then
      local text, xx, yy = position_label(ctx, trial, item.index, item)
      if text then
        rect = rect or {}
        item.rect, item.text, item.xx, item.yy, item.has_layout = rect, text, xx, yy, true
        rect.x0, rect.y0, rect.x1, rect.y1 = trial.x0, trial.y0, trial.x1, trial.y1
      end
    end
    -- Reserve the resolved placement before considering another tag. Fading
    -- incumbents retain their last usable rectangles until they are invisible.
    item.draw_label = alpha > 0 and item.has_layout and label_layout.fits(space, rect, item)
    if item.draw_label then label_layout.reserve(space, item, rect) end
  end
  reaper.ImGui_DrawList_PushClipRect(dl, gx, gy, right, lower, true)
  for _, item in ipairs(draw_order) do
    if item.draw_label then
      local alpha, rect = item.opacity, item.rect
      local colour = theme.fade(T.TEXT_PRIMARY, alpha)
      reaper.ImGui_DrawList_AddCircleFilled(dl, item.xx, item.yy, radius * 2,
        theme.fade(T.ACCENT, alpha * 0.25))
      reaper.ImGui_DrawList_AddCircleFilled(dl, item.xx, item.yy, radius, colour)
      reaper.ImGui_DrawList_AddRectFilled(dl, rect.x0, rect.y0, rect.x1, rect.y1,
        theme.fade(T.BG_POPUP, alpha), pad)
      reaper.ImGui_DrawList_AddText(dl, rect.x0 + M.SPECTRUM_TAG_PAD_X,
        rect.y0 + M.SPECTRUM_TAG_PAD_Y, colour, item.text)
    end
  end
  reaper.ImGui_DrawList_PopClipRect(dl)
  if small then reaper.ImGui_PopFont(ctx) end
end

return spectrum_hover
