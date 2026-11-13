-- Silent Surround examples. Overview and Phase show the real Stereo panel in
-- its Surround Field view beside the real Loudness meter, driven by a measured
-- 5.1 passage through the production meter session. Speaker Setup draws the
-- real Project Speakers section of Settings > Audio from private state.
-- Nothing here reaches live audio, saved settings or the project's speaker
-- layout.
local theme = require('ui.theme')
local layout = require('core.layout_prototype')
local surfaces = require('core.panel_surface_layout')
local session = require('core.meter_session')
local preferences = require('core.meter_preferences')
local meter_scale = require('core.meter_scale')
local stereo_preferences = require('core.stereo_preferences')
local channels = require('core.analysis_channels')
local arrangements = require('core.speaker_arrangements')
local outline = require('core.surround_outline')
local diagram = require('core.speaker_diagram')
local tooltip_place = require('core.tooltip_place')
local story = require('core.release_surround_demo')
local stereo = require('ui.stereo')
local field = require('ui.surround_field')
local meter_panel = require('ui.meter_panel')
local notice = require('ui.analysis_notice')
local tips = require('ui.tips')
local pointer = require('ui.release_pointer')
local scope = require('ui.release_preview_scope')
local signal = require('ui.release_surround_signal')
local sandbox = require('ui.release_sandbox')
local adapter = require('analysis_channels')

local T, M = theme.tokens, theme.metrics
local surround = {}

local source = story.decode(signal)
local _, SUGGESTED_ORDER = arrangements.get('5.1')
local ASSIGNED = assert(channels.profile(6, {roles=SUGGESTED_ORDER.roles, view='surround',
  pair_left=1, pair_right=2}))
-- Speaker Setup: an eight-channel master starts unassigned and recommends 7.1,
-- exactly as the channel adapter does. Choosing an arrangement of up to eight
-- channels then assigns its first order and starts on its front pair.
local MASTER_CHANNELS = 8
local function setup_profile(item)
  local _, order = arrangements.get(item.id)
  return assert(channels.profile(item.count, {roles=order.roles,
    view=item.count > 2 and 'surround' or 'pair', pair_left=1, pair_right=math.min(2, item.count)}))
end
local SETUP_PROFILES = {unassigned=assert(channels.profile(MASTER_CHANNELS))}
for _, item in ipairs(arrangements.list(MASTER_CHANNELS, true)) do
  SETUP_PROFILES[item.id] = setup_profile(item)
end
local SETUP_SUGGESTION = {arrangement=story.SETUP_START,
  order=(select(2, arrangements.get(story.SETUP_START))).id, profile=SETUP_PROFILES[story.SETUP_START]}
-- The rows of the Speaker Arrangement list, in the order the control draws them.
-- The real list's rows, copied so the demonstration can lay them out itself.
local MENU_ROWS = {}
for _, row in ipairs(require('ui.analysis_channels').arrangement_rows(MASTER_CHANNELS)) do
  MENU_ROWS[#MENU_ROWS + 1] = {kind=row.kind, text=row.text, id=row.id}
end
local MENU_VISIBLE_ROWS = 8 -- ImGui's default for a combo list before it scrolls
local MENU = {}
-- R and Rs share the side that turns red when Rs is inverted.
local SIDE_A, SIDE_B = 2, 6
-- Room at 100% UI Size for a square-ish field beside six full-size channel
-- bars; a smaller area scales the whole example down instead of squeezing it.
local NATURAL_W, NATURAL_H = 770, 300
local FIELD_ASPECT = 1.25
-- The Settings pane at 100% UI Size: the 632 px window less its 140 px section
-- list, the pane's padding and its two scroll rails. The height is only a
-- first guess: the drawn section measures itself, and the example then scales
-- to the tallest state seen, so nothing at the bottom is cut off.
local SETTINGS_W, SETTINGS_H = 436, 330
local SETTINGS_MARGIN = 8
-- Controls whose place the guide pointer needs: target name -> sandbox key.
local WATCHED = {recommendation='recommendation', combo='combo'}
local INERT = reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
  | reaper.ImGui_WindowFlags_NoInputs() | reaper.ImGui_WindowFlags_NoNav()
-- Private copies of the modules that draw the section, so nothing they draw
-- can answer the user's mouse or share motion state with the real Settings.
local PRIVATE = {'ui.analysis_channels', 'ui.widgets', 'ui.tips'}
local PANELS = {mode='row', enabled={'stereo', 'loudness'}, order={'stereo', 'loudness'},
  shares={x=.5, y=.5}}
-- Phase is about the field alone, as when Stereo is the only panel shown.
local FIELD_ONLY = {mode='row', enabled={'stereo'}, order={'stereo'}, shares={x=1, y=.5}}
local FIELD_ONLY_W = math.ceil(NATURAL_H * FIELD_ASPECT)

local function meter_model()
  local model = session.new()
  model.prefs = preferences.defaults()
  -- A compact Loudness panel: bars only, without the optional history,
  -- extra readings column or LRA bracket that the passage cannot fill.
  model.prefs.show_history = false
  model.prefs.extra_readings = false
  model.prefs.show_lra = false
  model.prefs.peak_measurement = 'Sample Peak'
  return model
end

function surround.new()
  local box = sandbox.new(PRIVATE)
  sandbox.watch(box, 'Use Recommendation', 'recommendation')
  sandbox.watch(box, '##channels_arrangement', 'combo')
  local value = {model=meter_model(), store=field.new_store(), scene={}, targets={},
    presentation={hovered=false}, field_values={}, last_index=0, sequence=0, box=box,
    settings=sandbox.require(box, 'ui.analysis_channels'),
    settings_state={analysis_channel_available_count=MASTER_CHANNELS,
      analysis_channel_suggestion=SETUP_SUGGESTION}}
  value.presentation.store = value.store
  value.state = {
    stereo={frozen=false}, stereo_view='lissajous', stereo_preferences=stereo_preferences.defaults(),
    monitor_filter={system={available=true}}, metering=value.model,
    analysis_channels=ASSIGNED,
    surround_outline_points=adapter.new_outline_points(reaper),
  }
  return value
end

-- Restarting playback starts a fresh measurement, as the meter adapter does
-- for a new run.
local function restart(value)
  session.reset(value.model)
  value.last_index, value.sequence = 0, 0
  value.state.surround_channels = nil
end

-- The field reads the meter's newest channel energies and pair correlations,
-- copied in the same shape the channel adapter publishes.
local function publish_field(value)
  local model, state = value.model, value.state
  local values = model.field_channels
  if not values or #values == 0 then state.surround_channels = nil; return end
  local copy = value.field_values
  for index = 1, #values do
    local entry = copy[index] or {}
    entry.rms, entry.peak = values[index].field_rms or values[index].rms, values[index].warning_peak
    copy[index] = entry
  end
  copy.correlations = values.correlations
  state.surround_channels = copy
end

function surround.update(value, topic, elapsed)
  value = value or surround.new()
  local scene = story.sample(topic, elapsed, value.scene, not theme.motion.enabled)
  local restarted = value.topic ~= topic or value.cycle ~= scene.cycle
    or (value.last_elapsed and elapsed < value.last_elapsed)
  if restarted then
    restart(value)
    value.store = field.new_store()
    value.presentation.store = value.store
  end
  local model = value.model
  model.channel_profile = ASSIGNED
  model.loudness_available = ASSIGNED.known
  model.measured_channel_count = ASSIGNED.count
  local dt = value.last_elapsed and not restarted and math.max(0, elapsed - value.last_elapsed) or 0
  value.topic, value.cycle, value.last_elapsed = topic, scene.cycle, elapsed

  local index = story.frame_index(source, scene.time)
  -- After a long gap (hidden window) only the latest few publications matter.
  local first = math.max(value.last_index + 1, index - 8)
  for frame = first, index do
    value.sequence = value.sequence + 1
    session.update(model, story.snapshot(source, frame, value.sequence, scene.inverted, ASSIGNED.known),
      frame == first and value.last_index == 0 and 0 or source.step)
  end
  value.last_index = math.max(value.last_index, index)
  session.animate(model, theme.motion.enabled and dt or .25, (meter_scale.loudness(model.prefs)))
  publish_field(value)
  return value
end

local function mix(a, b, amount)
  return a + (b - a) * amount
end

-- The middle of the R–Rs side, from the same layout and outline the field draws.
local function side_point(ctx, value, fx, fy, fw, fh)
  local values = value.state.surround_channels
  if not values or not values[SIDE_A] or not values[SIDE_B] then return end
  local key = table.concat({fw, fh, theme.scale, reaper.ImGui_GetFontSize(ctx)}, ':')
  if value.side_key ~= key then
    value.side_key = key
    value.side_layout = diagram.layout(ASSIGNED, {x=0, y=0, width=fw, height=fh},
      function(text) return reaper.ImGui_CalcTextSize(ctx, text) end, theme.scale, 7)
    value.side_points = {}
    for _, point in ipairs(value.side_layout.points) do value.side_points[point.channel] = point end
  end
  local diagram_layout, points = value.side_layout, value.side_points
  local cx, cy = fx + diagram_layout.cx, fy + diagram_layout.cy
  local a, b = values[SIDE_A], values[SIDE_B]
  local amount_a, amount_b = outline.amount(a.rms), outline.amount(b.rms)
  local ax = cx + (points[SIDE_A].x - diagram_layout.cx) * amount_a
  local ay = cy + (points[SIDE_A].y - diagram_layout.cy) * amount_a
  local bx = cx + (points[SIDE_B].x - diagram_layout.cx) * amount_b
  local by = cy + (points[SIDE_B].y - diagram_layout.cy) * amount_b
  local reading = values.correlations and outline.phase(
    values.correlations[outline.pair_index(SIDE_A, SIDE_B, ASSIGNED.count)], a.rms, b.rms)
  local qx, qy = outline.bend(ax, ay, bx, by, cx, cy, reading or nil)
  return outline.curve_point(ax, ay, qx, qy, bx, by, .5)
end

local function resolve(value, name, home)
  if name == 'side' then return value.targets.side or home end
  return home
end

local function guide_position(value, home)
  local scene = value.scene
  local from, to = resolve(value, scene.from, home), resolve(value, scene.to, home)
  return mix(from.x, to.x, scene.progress or 1), mix(from.y, to.y, scene.progress or 1)
end

-- The tooltip as tips.lua pins it: centred below the field, else above,
-- else beside it, kept inside the example's area as if that were the screen.
local function paint_tip(ctx, dl, text, anchor_x, anchor_y, anchor_w, anchor_h, px, py, area)
  local pad = M.WINDOW_PAD
  local margin = M.PICK_SCREEN_MARGIN
  local wrap = math.min(360 * theme.scale, area.right - area.left - margin * 2 - pad * 2)
  if wrap <= 0 then return end
  local tw, th = reaper.ImGui_CalcTextSize(ctx, text, nil, nil, false, wrap)
  local w, h = math.ceil(tw) + pad * 2, math.ceil(th) + pad * 2
  local anchor = tips.rect(anchor_x, anchor_y, anchor_w, anchor_h)
  local x, y = tooltip_place.place(anchor, area, w, h, px, py, M.PICK_ANCHOR_GAP, margin,
    16 * theme.scale)
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + w, y + h, T.BG_POPUP, 8)
  reaper.ImGui_DrawList_AddRect(dl, x, y, x + w, y + h, T.STROKE_SECONDARY, 8)
  reaper.ImGui_DrawList_AddTextEx(dl, nil, reaper.ImGui_GetFontSize(ctx), x + pad, y + pad,
    T.TEXT_SECONDARY, text, wrap)
end

local function paint_panels(ctx, res, value, topic, x, y, width, height, area)
  local s = theme.scale
  local model, state = value.model, value.state
  local profile = state.analysis_channels
  local pad = M.WINDOW_PAD
  local px0, py0, pw, ph = x + pad, y + pad, math.max(1, width - pad * 2), math.max(1, height - pad * 2)
  local field_only = topic == 'surround_phase'
  if field_only then
    -- Centre a field-shaped panel rather than stretching it across the area.
    local fw = math.min(pw, math.max(180 * s, (ph - M.RULER_H) * FIELD_ASPECT))
    px0, pw = px0 + (pw - fw) / 2, fw
  end
  -- Give the meter the width its normal bars need and the field the rest,
  -- like a user dragging the divider until the meter stops compacting.
  local key = s .. ':' .. reaper.ImGui_GetFontSize(ctx)
  if value.meter_key ~= key then
    value.meter_key = key
    value.meter_minimum = meter_panel.measure(4000 * s, ph, model.prefs, nil, nil, M.RULER_H, ctx,
      ASSIGNED).minimum or 0
  end
  local usable = math.max(1, pw - M.SPECTRUM_SPLIT_GAP)
  local field_w = math.max(180 * s, math.min(usable - value.meter_minimum, (ph - M.RULER_H) * FIELD_ASPECT))
  PANELS.shares.x = math.max(0, math.min(1, field_w / usable))
  local geometry = layout.measure(pw, ph, field_only and FIELD_ONLY or PANELS, {scale=s, gap=M.SPECTRUM_SPLIT_GAP,
    min_width=M.SPECTRUM_PANE_MIN_W, min_height=M.REFERENCE_PANE_MIN_H,
    stereo_hide_height=M.STEREO_HIDE_H, loudness_min_height=200 * s})
  local users = value.ruler_users or {}
  value.ruler_users = users
  users.spectrum, users.loudness = true, true
  local frames = surfaces.measure(geometry.panels, 0, M.RULER_H, M.WAVE_MIN_H, users)
  local meter_pane, meter_geometry
  for _, pane in ipairs(geometry.panels) do
    if pane.id == 'loudness' then
      meter_pane = pane
      meter_geometry = meter_panel.measure(pane.w, pane.h, model.prefs, nil, nil,
        frames.loudness.footer_height, ctx, profile)
      users.loudness = not meter_geometry.numeric
    end
  end
  frames = surfaces.measure(geometry.panels, 0, M.RULER_H, M.WAVE_MIN_H, users)
  if meter_pane then
    meter_geometry = meter_panel.measure(meter_pane.w, meter_pane.h, model.prefs, nil, nil,
      frames.loudness.footer_height, ctx, profile)
    meter_geometry.surface_painted = true
  end

  local notice_frames, field_rect = {}, nil
  for _, pane in ipairs(geometry.panels) do
    local display = frames[pane.id]
    local frame = {id=pane.id, x=px0 + display.x, y=py0 + display.y, w=display.w,
      h=math.max(0, display.h - (display.footer_height or 0))}
    if pane.id == 'loudness' and meter_geometry then
      frame.setup_rect, frame.setup_button_rect = meter_panel.setup_regions(meter_geometry, frame.x, frame.y)
    end
    if pane.id == 'stereo' then field_rect = frame end
    notice_frames[#notice_frames + 1] = frame
  end
  local plan = notice.plan(ctx, state, notice_frames, {x=px0, y=py0, w=pw, h=ph}, nil)
  local card = plan.cards[1]

  local home
  if field_rect then
    local below = field_rect.y + field_rect.h
    home = {x=field_rect.x + field_rect.w * (topic == 'surround_phase' and .8 or .66),
      y=math.min(below + 6 * s, area.bottom - 20 * s)}
  else
    home = {x=x + width * .5, y=y + height - 20 * s}
  end
  if topic == 'surround_phase' and field_rect then
    local sx, sy = side_point(ctx, value, field_rect.x, field_rect.y, field_rect.w, field_rect.h)
    if sx then
      local side = value.targets.side
      if not side or not theme.motion.enabled then
        value.targets.side = {x=sx, y=sy}
      else
        -- Follow the moving side smoothly, as a resting hand would.
        local amount = 1 - math.exp(-(value.frame_dt or 0) / .12)
        side.x, side.y = mix(side.x, sx, amount), mix(side.y, sy, amount)
      end
    end
  end
  local gx, gy = guide_position(value, home)
  value.guide = value.guide or {}
  value.guide.x, value.guide.y = gx, gy
  local presentation = value.presentation
  presentation.hovered = field_rect ~= nil and gx >= field_rect.x and gx <= field_rect.x + field_rect.w
    and gy >= field_rect.y and gy <= field_rect.y + field_rect.h
  presentation.pointer = topic == 'surround_phase' and value.scene.resting and value.guide or nil

  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local hover_text
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_DisabledAlpha(), 1)
  reaper.ImGui_BeginDisabled(ctx)
  for _, pane in ipairs(geometry.panels) do
    local display = frames[pane.id]
    if display.w < 1 or display.h < 1 then goto next_panel end
    local px, py = px0 + display.x, py0 + display.y
    local picture_h = display.h - (display.footer_height or 0)
    reaper.ImGui_PushID(ctx, 'release_surround_' .. pane.id)
    -- Arranged panels paint their own surface, as Reference View does.
    reaper.ImGui_DrawList_AddRectFilled(dl, px, py, px + display.w, py + picture_h, T.STEREO_BG, 3 * s)
    reaper.ImGui_SetCursorScreenPos(ctx, px, py)
    if pane.id == 'stereo' then
      local _, text = stereo.draw(ctx, state, display.w, picture_h, res, card, px, display.w, presentation)
      hover_text = text
    elseif pane.id == 'loudness' then
      meter_panel.paint(ctx, model, meter_geometry, px0 + pane.x, py0 + pane.y, {}, plan.channel_layout)
    end
    reaper.ImGui_PopID(ctx)
    ::next_panel::
  end
  notice.draw(ctx, plan)
  reaper.ImGui_EndDisabled(ctx)
  reaper.ImGui_PopStyleVar(ctx)

  -- The pointer is painted last, after this frame's drawing moved the targets.
  gx, gy = guide_position(value, home)

  if hover_text and value.scene.resting and value.scene.resting >= tips.DELAY and field_rect then
    paint_tip(ctx, dl, hover_text, field_rect.x, field_rect.y, field_rect.w, field_rect.h, gx, gy, area)
  end
  if topic ~= 'surround_overview' then
    local foreground = reaper.ImGui_GetForegroundDrawList(ctx)
    reaper.ImGui_DrawList_PushClipRect(foreground, x, y, x + width, y + height, true)
    pointer.paint(foreground, gx, gy, value.scene.pulse)
    reaper.ImGui_DrawList_PopClipRect(foreground)
  end
end

-- The pointer rests below and right of the section, in the pane's empty corner.
local function settings_home(col_x, col_y, col_w, col_h, area)
  local s = theme.scale
  return {x=col_x + col_w * .72, y=math.min(col_y + col_h + 4 * s, area.bottom - 16 * s)}
end

-- Where ImGui lays out the open Speaker Arrangement list: below the closed
-- control, as wide as it, tall enough for eight rows, then scrolling. Row
-- tops are measured from the top of the list's content.
local function menu_geometry(ctx, combo)
  local fs, spacing = reaper.ImGui_GetFontSize(ctx), M.ITEM_SPACING_Y
  local pad_y = M.WINDOW_PAD
  local content = 0
  for _, row in ipairs(MENU_ROWS) do
    row.top = content
    row.height = row.kind == 'separator' and 1 or fs
    content = content + row.height + spacing
  end
  content = content - spacing
  local g = MENU
  g.h = math.min(content + pad_y * 2, (fs + spacing) * MENU_VISIBLE_ROWS - spacing + pad_y * 2)
  g.x, g.y, g.w = combo.x0, combo.y1, combo.x1 - combo.x0
  g.pad_x, g.pad_y, g.fs, g.spacing = M.FRAME_PAD_X, pad_y, fs, spacing
  g.view = g.h - pad_y * 2
  g.max_scroll = math.max(0, content - g.view)
  return g
end

local function menu_item_row(id)
  for _, row in ipairs(MENU_ROWS) do
    if row.id == id then return row end
  end
end

-- The list as ImGui paints a combo's popup: the popup colours, rounding and
-- border, text and separators in the control's own colours, the current
-- arrangement and the row under the pointer highlighted, and a scroll rail
-- once the list is longer than eight rows.
local function paint_menu(ctx, g, scroll, selected, hover_y, clip)
  local fg = reaper.ImGui_GetForegroundDrawList(ctx)
  local s = theme.scale
  local x, y, w, h = g.x, g.y, g.w, g.h
  local rounding = (reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_PopupRounding()))
  reaper.ImGui_DrawList_PushClipRect(fg, clip.left, clip.top, clip.right, clip.bottom, true)
  reaper.ImGui_DrawList_AddRectFilled(fg, x, y, x + w, y + h, T.BG_POPUP, rounding)
  reaper.ImGui_DrawList_AddRect(fg, x, y, x + w, y + h, T.STROKE_SECONDARY, rounding)
  local rail = g.max_scroll > 0 and 14 * s or 0
  reaper.ImGui_DrawList_PushClipRect(fg, x + 1, y + 1, x + w - 1 - rail, y + h - 1, true)
  local left, right = x + g.pad_x, x + w - g.pad_x - rail
  local top = y + g.pad_y - scroll
  local half_x, half_y = math.floor(M.ITEM_SPACING_X * .5), math.floor(g.spacing * .5)
  for _, row in ipairs(MENU_ROWS) do
    local ry = top + row.top
    if ry + row.height >= y and ry <= y + h then
      if row.kind == 'separator' then
        reaper.ImGui_DrawList_AddLine(fg, left, ry, right, ry, T.STROKE_TERTIARY, 1)
      elseif row.kind == 'heading' then
        reaper.ImGui_DrawList_AddTextEx(fg, nil, g.fs, left, ry, T.TEXT_QUATERNARY, row.text)
      else
        local fill
        if hover_y and hover_y >= ry - half_y and hover_y < ry + row.height + g.spacing - half_y then
          fill = T.FILL_TERTIARY
        elseif row.id == selected then
          fill = T.FILL_SECONDARY
        end
        if fill then
          reaper.ImGui_DrawList_AddRectFilled(fg, left - half_x, ry - half_y,
            right + (M.ITEM_SPACING_X - half_x), ry + row.height + (g.spacing - half_y), fill)
        end
        reaper.ImGui_DrawList_AddTextEx(fg, nil, g.fs, left, ry, T.TEXT_SECONDARY, row.text)
      end
    end
  end
  reaper.ImGui_DrawList_PopClipRect(fg)
  if rail > 0 then
    local track = h - 2
    local grab_h = math.max(10 * s, track * g.view / (g.view + g.max_scroll))
    local grab_y = y + 1 + (track - grab_h) * (scroll / g.max_scroll)
    reaper.ImGui_DrawList_AddRectFilled(fg, x + w - 1 - rail, y + 1, x + w - 1, y + h - 1, T.BG_CHROME)
    reaper.ImGui_DrawList_AddRectFilled(fg, x + w - 1 - rail + 2 * s, grab_y, x + w - 3 * s, grab_y + grab_h,
      reaper.ImGui_GetStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrab()), 6 * s)
  end
  reaper.ImGui_DrawList_PopClipRect(fg)
end

local function paint_settings(ctx, value, scene, x, y, width, height, area)
  local s = theme.scale
  local col_w, col_h = SETTINGS_W * s, (value.settings_h or SETTINGS_H) * s
  local col_x = x + math.max(0, (width - col_w) / 2)
  local col_y = y + math.max(0, (height - col_h) / 2)
  local state = value.settings_state
  state.analysis_channels = SETUP_PROFILES[scene.arrangement]
  sandbox.begin_frame(value.box, ctx)
  reaper.ImGui_SetCursorScreenPos(ctx, col_x, col_y)
  -- The real Audio page's own scrolling child: no padding of its own.
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
  local opened = reaper.ImGui_BeginChild(ctx, 'release_speaker_settings', col_w, col_h, 0, INERT)
  reaper.ImGui_PopStyleVar(ctx)
  if opened then
    local ok, failure = xpcall(value.settings.draw_content, debug.traceback, ctx, state)
    if ok then
      local _, end_y = reaper.ImGui_GetCursorScreenPos(ctx)
      local drawn = (end_y - col_y) / s
      value.settings_h = math.max(value.settings_h or 0, math.ceil(drawn))
    end
    reaper.ImGui_EndChild(ctx)
    if not ok then error(failure, 0) end
  end
  -- Controls that exist only in some states keep their last place, so the
  -- pointer can still leave from them.
  local targets = value.targets
  for name, key in pairs(WATCHED) do
    local rect = sandbox.rect(value.box, key)
    if rect then
      targets[name] = targets[name] or {}
      targets[name].x, targets[name].y = (rect.x0 + rect.x1) / 2, (rect.y0 + rect.y1) / 2
    end
  end
  local combo = sandbox.rect(value.box, 'combo')
  local g, scroll
  if scene.menu and combo then
    g = menu_geometry(ctx, combo)
    local row = menu_item_row(scene.menu_item)
    local wanted = math.max(0, math.min(g.max_scroll, row.top - g.view * .5 + g.fs * .5))
    scroll = wanted * (scene.scroll or 0)
    targets.item = targets.item or {}
    targets.item.x = g.x + g.w * .4
    targets.item.y = g.y + g.pad_y + row.top - scroll + g.fs * .5
  end
  local home = settings_home(col_x, col_y, col_w, col_h, area)
  local a = targets[scene.from] or home
  local b = targets[scene.to] or home
  local amount = scene.progress or 1
  local px, py = mix(a.x, b.x, amount), mix(a.y, b.y, amount)
  if g then
    local inside = px >= g.x and px <= g.x + g.w and py >= g.y and py <= g.y + g.h
    paint_menu(ctx, g, scroll, scene.arrangement ~= 'unassigned' and scene.arrangement or nil,
      inside and py or nil, area)
  end
  local foreground = reaper.ImGui_GetForegroundDrawList(ctx)
  reaper.ImGui_DrawList_PushClipRect(foreground, x, y, x + width, y + height, true)
  pointer.paint(foreground, px, py, scene.pulse)
  reaper.ImGui_DrawList_PopClipRect(foreground)
end

local function draw_settings(ctx, value, topic, elapsed, width, height)
  local scene = story.sample(topic, elapsed, value.scene, not theme.motion.enabled)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_PushClipRect(dl, x, y, x + width, y + height, true)
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + width, y + height, T.BG_WINDOW)
  local ratio = math.max(.1, math.min(1, width / ((SETTINGS_W + SETTINGS_MARGIN * 2) * theme.scale),
    height / (((value.settings_h or SETTINGS_H) + SETTINGS_MARGIN * 2) * theme.scale)))
  local area = {left=x, top=y, right=x + width, bottom=y + height}
  scope.paint(ctx, ratio, function()
    paint_settings(ctx, value, scene, x, y, width, height, area)
  end)
  reaper.ImGui_DrawList_PopClipRect(dl)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_Dummy(ctx, width, height)
end

function surround.draw(ctx, res, value, topic, elapsed, width, height)
  if topic == 'surround_speakers' then
    draw_settings(ctx, value or surround.new(), topic, elapsed, width, height)
    return
  end
  local previous = value and value.last_elapsed
  value = surround.update(value or surround.new(), topic, elapsed)
  value.frame_dt = previous and math.max(0, elapsed - previous) or 0
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_PushClipRect(dl, x, y, x + width, y + height, true)
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + width, y + height, T.BG_WINDOW)
  local natural_w = topic == 'surround_phase' and FIELD_ONLY_W or NATURAL_W
  local ratio = math.max(.1, math.min(1, width / (natural_w * theme.scale),
    height / (NATURAL_H * theme.scale)))
  local area = {left=x, top=y, right=x + width, bottom=y + height}
  scope.paint(ctx, ratio, function()
    paint_panels(ctx, res, value, topic, x, y, width, height, area)
  end)
  reaper.ImGui_DrawList_PopClipRect(dl)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_Dummy(ctx, width, height)
end

return surround
