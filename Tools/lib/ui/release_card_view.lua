-- A private Reference View for release demonstrations: the production
-- Reference card beside the analysis panels, placed by the same layout code as
-- the live view and drawn from demonstration state built here.
--
-- Any release renderer can use it:
--   local view = require('ui.release_card_view')
--   local v = view.new()                    -- once per topic
--   view.update(v, audio_seconds, playing)  -- each frame: playhead and panels
--   view.paint(ctx, res, v, x, y, w, h)     -- the whole Reference View
--   view.paint_card(ctx, res, v, x, y, w, h)  -- or just the card in a rectangle
--
-- The card's state carries `showcase`, so the production controls take no input
-- and leave the live picker, menus, Settings and drags alone; their motion runs
-- on private trackers. Nothing here reaches playback, preferences or Library
-- data, and anything the controls return is discarded.
local theme = require('ui.theme')
local widgets = require('ui.widgets')
local controls = require('ui.reference_controls')
local readings = require('ui.readings')
local spectrum = require('ui.spectrum')
local spectrum_axis = require('ui.spectrum_axis')
local level_axis = require('ui.spectrum_level_axis')
local stereo = require('ui.stereo')
local meter_panel = require('ui.meter_panel')
local panel_data = require('ui.release_layout_panels')
local wave_signal = require('ui.release_layout_wave')
local spectrum_signal = require('ui.release_layout_spectrum')
local source = require('ui.release_card_source')
local layout = require('core.layout_prototype')
local sidebar = require('core.reference_sidebar_layout')
local surfaces = require('core.panel_surface_layout')
local axis_geometry = require('core.spectrum_axis')
local techfacts = require('core.techfacts')
local duration_text = require('core.duration_text')
local wave_view = require('core.wave_view')
local T, M = theme.tokens, theme.metrics

local view = {}

-- The sample reference is the fourth of seven pins.
local PIN_COUNT, PIN_INDEX = 7, 4
local SOUND_ID = 'p' .. PIN_INDEX
local CHILD_FLAGS = reaper.ImGui_ChildFlags_AlwaysUseWindowPadding
  and reaper.ImGui_ChildFlags_AlwaysUseWindowPadding() or 0
local INERT = reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
  | reaper.ImGui_WindowFlags_NoInputs() | reaper.ImGui_WindowFlags_NoNav()
local IDLE_CAPTURE = {highlight=0, opacity=0}
local PASSIVE = {}
local STEREO_PRESENTATION = {hovered=false}

local function card_state()
  local pins = {}
  for i = 1, PIN_COUNT do pins[i] = {id='p' .. i} end
  local selected = {id=SOUND_ID, name=source.name, channels=source.channels,
    duration=source.duration, trim_db=0}
  for key, value in pairs(source.readings) do selected[key] = value end
  local tech = techfacts.parts({rate=source.rate, bits=source.bits, format=source.format,
    channels=source.channels})
  tech.duration = duration_text.format(source.duration)
  local wave = wave_view.new()
  wave_view.configure(wave, source.duration, source.rate)
  return {
    showcase=true,
    selected_id=SOUND_ID, selected=selected, selected_tech=tech,
    pins={data={pins=pins}, session='release_card'},
    waveform={sound_id=SOUND_ID, channels=wave_signal.channels},
    wave_view=wave,
    preview={playing=false, slot='main', sound_id=SOUND_ID, position=0,
      length=source.duration, paused={}, start_serial=1, channels=source.channels},
    reference={latched=false}, deps={drag_out=false},
    loop=true, mono=false, pitch={main=0}, reading_extra='true_peak',
  }
end

function view.new()
  return {
    state=card_state(),
    panels=panel_data.new(),
    model=layout.new(),
    -- Reused every frame (frame-allocation rule).
    card_g={strip={}, reference={}}, card_info={}, sidebar_opts={}, panel_opts={},
    ruler_users={}, plan={},
  }
end

-- `audio` is the demonstration's audio clock in seconds; it must not run
-- backwards. The playhead shows `audio` modulo the reference's length.
function view.update(v, audio, playing)
  local preview = v.state.preview
  preview.playing = playing ~= false
  preview.position = audio % source.duration
  panel_data.update(v.panels, audio)
end

-- Applies a tour scene (core/release_card_demo.lua's overview) the way the
-- entry script would after the clicks it shows: what is playing and from where,
-- and the reference's trim. Stopped means the playhead is back at the start.
function view.apply(v, scene, trim_db)
  view.update(v, scene.audio, scene.playing)
  local preview = v.state.preview
  if not scene.playing then preview.position = 0 end
  preview.start_serial = scene.plays or 1
  v.state.selected.trim_db = trim_db or 0
end

-- The card's measured sizes (ui/reference_controls.lua), in pixels.
function view.card_sizes(ctx)
  return controls.measure(ctx)
end

---------------------------------------------------------------- the card

local function draw_card(ctx, res, v, g)
  controls.draw(ctx, v.state, res, g)
end

-- Draws the production card for a strip at (x, y), `w` wide and `h` tall, the
-- card's own height `card_h` (defaults to h; the strip clips a taller card, as
-- a short docker does).
function view.paint_card(ctx, res, v, x, y, w, h, card_h)
  local g = v.card_g
  g.strip.x, g.strip.y, g.strip.w, g.strip.h = 0, 0, w, h
  g.reference.x, g.reference.y, g.reference.w = 0, 0, w
  g.reference.h = math.max(card_h or h, controls.measure(ctx).card_minimum)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
  local visible = reaper.ImGui_BeginChild(ctx, 'release_card_strip', math.max(1, w), math.max(1, h),
    CHILD_FLAGS, INERT)
  reaper.ImGui_PopStyleVar(ctx)
  if not visible then return end
  widgets.begin_private_motion()
  local ok, failure = xpcall(draw_card, debug.traceback, ctx, res, v, g)
  widgets.end_private_motion()
  reaper.ImGui_EndChild(ctx)
  if not ok then error(failure, 0) end
end

-- Where the card's waveform pictures sit inside a card at (x, y), `w` wide and
-- `h` tall, following reference_controls.draw's arithmetic: x0, y0, x1, y1 of
-- the bars (without the ruler), or nil when the card has no waveform.
function view.wave_rect(ctx, x, y, w, h)
  local p = controls.plan(ctx, h, w)
  if p.wave <= 0 then return nil end
  local snap = function(value) return math.floor(value + .5) end
  local gap = M.STRIP_FACTS_GAP
  local top = snap(y + p.pad) + reaper.ImGui_GetFrameHeight(ctx)
  if p.facts then top = top + gap + M.STRIP_FACTS_H end
  top = top + readings.section_height(p.readings) + gap
  local left = snap(x + M.STRIP_PAD)
  return left, top, left + snap(w - 2 * M.STRIP_PAD), top + p.wave - M.RULER_H
end

-- Where the card's bottom-row controls are, for the same card as wave_rect:
-- the Play, Stop cells' centres, the row's centre line and the trim bar's
-- left edge and width. Fills and returns `out`.
function view.bottom_row(ctx, x, y, w, h, out)
  out = out or {}
  local p = controls.plan(ctx, h, w)
  local snap = function(value) return math.floor(value + .5) end
  local ctrl = reaper.ImGui_GetFrameHeight(ctx)
  local left, inner = snap(x + M.STRIP_PAD), snap(w - 2 * M.STRIP_PAD)
  local cell = controls.cell_width(ctx, w)
  out.cy = snap(y + p.height - p.pad - ctrl) + ctrl * .5
  out.play_x, out.stop_x = left + cell * .5, left + cell * 2.5
  out.trim_x = left + 8 * cell + 2 * M.STRIP_GROUP_GAP
  out.trim_w = left + inner - out.trim_x
  return out
end

---------------------------------------------------------------- the panels

-- The Spectrum panel's resting picture: the live trace over the grid and its
-- scales, on the panel backing the Reference View paints (spectrum.draw with
-- background_painted).
local function paint_spectrum(ctx, dl, data, x, y, w, h, footer)
  local gx, gy = x + M.SPECTRUM_PLOT_PAD, y
  local gw, gh = math.max(1, w - M.SPECTRUM_PLOT_PAD - M.SPECTRUM_LEVEL_W), math.max(1, h - footer)
  local bottom = -90
  spectrum.paint_grid(dl, gx, gy, gw, gh, bottom, 10, axis_geometry.MAX_HZ)
  reaper.ImGui_DrawList_PushClipRect(dl, gx, gy, gx + gw, gy + gh, true)
  spectrum.paint_inspection(dl, data.live, spectrum_signal.bins, gx, gy,
    axis_geometry.trace_width(gw, 10, 22050), gh, bottom, nil, IDLE_CAPTURE, true)
  reaper.ImGui_DrawList_PopClipRect(dl)
  local axes = data.axes or {}
  data.axes = axes
  axes.gx, axes.gy, axes.gw, axes.gh, axes.axis = gx, gy, gw, gh, footer
  axes.fmin, axes.fmax, axes.bottom, axes.eligible = 10, axis_geometry.MAX_HZ, bottom, false
  axes.level_right = x + w - M.SPECTRUM_BAND_GAP
  spectrum_axis.draw(ctx, dl, nil, axes)
  level_axis.draw(ctx, dl, axes)
end

-- The panels beside or below the card, as ui/window.lua draws the arrangeable
-- panels: a backing under each picture, the rulers only where a panel uses
-- one, and the loudness meters on that backing.
local function paint_panels(ctx, res, v, geometry, x, y)
  local data = v.panels
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local users = v.ruler_users
  users.spectrum, users.loudness = true, true
  local frames = surfaces.measure(geometry.panels, 0, M.RULER_H, M.WAVE_MIN_H, users)
  local meter_model, meter_frame, meter_geometry = data.meter.model
  for _, pane in ipairs(geometry.panels) do
    if pane.id == 'loudness' then
      meter_frame = pane
      meter_geometry = meter_panel.measure(pane.w, pane.h, meter_model.prefs, nil, nil,
        frames.loudness.footer_height, ctx)
      users.loudness = not meter_geometry.numeric
    end
  end
  frames = surfaces.measure(geometry.panels, 0, M.RULER_H, M.WAVE_MIN_H, users)
  if meter_frame then
    meter_geometry = meter_panel.measure(meter_frame.w, meter_frame.h, meter_model.prefs, nil, nil,
      frames.loudness.footer_height, ctx)
    meter_geometry.surface_painted = true
  end
  local stereo_state = data.stereo_state or {stereo_view='lissajous',
    stereo_preferences=data.stereo_preferences, monitor_filter={system={available=true}}}
  data.stereo_state = stereo_state
  stereo_state.stereo = data.scope.model
  for _, pane in ipairs(geometry.panels) do
    local frame = frames[pane.id]
    if frame.w >= 1 and frame.h >= 1 then
      local px, py = x + frame.x, y + frame.y
      local footer = frame.footer_height or 0
      reaper.ImGui_PushID(ctx, 'release_card_' .. pane.id)
      if geometry.temporary then
        reaper.ImGui_PushClipRect(ctx, x + pane.x, y + pane.y, x + pane.x + pane.w, y + pane.y + pane.h, true)
      end
      reaper.ImGui_DrawList_AddRectFilled(dl, px, py, px + frame.w, py + frame.h - footer,
        T.STEREO_BG, 3 * theme.scale)
      reaper.ImGui_SetCursorScreenPos(ctx, px, py)
      if pane.id == 'spectrum' then
        paint_spectrum(ctx, dl, data, px, py, frame.w, frame.h, footer)
      elseif pane.id == 'stereo' then
        local background_x = x + (pane.background_x or frame.x)
        local background_w = pane.background_w or frame.w
        reaper.ImGui_DrawList_AddRectFilled(dl, background_x, py, background_x + background_w,
          py + frame.h - footer, T.STEREO_BG, 3 * theme.scale)
        stereo.draw(ctx, stereo_state, frame.w, frame.h - footer, res, nil,
          background_x, background_w, STEREO_PRESENTATION)
      elseif meter_geometry then
        meter_panel.paint(ctx, meter_model, meter_geometry, px, py, PASSIVE)
      end
      if geometry.temporary then reaper.ImGui_PopClipRect(ctx) end
      reaper.ImGui_PopID(ctx)
    end
  end
end

-- Places the card and the panels in a Reference View `w` by `h` as the live
-- host does (core/reference_sidebar_layout.lua, then
-- core/layout_prototype.lua). Returns the sidebar result: `strip` and
-- `reference` for the card, and `panel_geometry` for the panels.
-- `docked`, when given, places a docked Library as the live host does, from
-- its library_width, library_minimum, library_min_height and
-- library_keep_height; the caller draws the Library into the result's `library`.
function view.measure(ctx, v, w, h, docked)
  local sizes = controls.measure(ctx)
  local o = v.sidebar_opts
  o.width, o.height, o.scale, o.library = w, h, theme.scale, docked ~= nil
  if docked then
    o.library_width, o.library_minimum = docked.library_width, docked.library_minimum
    o.library_min_height, o.library_keep_height = docked.library_min_height, docked.library_keep_height
  end
  o.block_width, o.card_minimum, o.card_natural = sizes.block_width, sizes.card_minimum, sizes.card_natural
  local g = sidebar.resolve(o)
  local options = v.panel_opts
  options.scale, options.gap = theme.scale, M.SPECTRUM_SPLIT_GAP
  options.min_width, options.min_height = M.SPECTRUM_PANE_MIN_W, M.REFERENCE_PANE_MIN_H
  options.header_height = 0
  options.stereo_hide_height, options.stereo_restore_height = M.STEREO_HIDE_H, M.STEREO_RESTORE_H
  options.stereo_hidden = v.stereo_hidden or false
  options.loudness_min_height = 228 * theme.scale
  options.previous_mode = v.previous_mode
  options.stereo_side_width = v.panels.stereo_preferences.show_correlation and M.STEREO_CORRELATION_W or 0
  local prefs = layout.current(v.model)
  local geometry
  if g.shared then
    local card = v.card_info
    card.width, card.natural, card.minimum = g.strip.w + g.gap, sizes.card_natural, sizes.card_minimum
    card.column = false
    geometry = layout.measure_with_card(g.panels.w, g.panels.h, prefs, options, card)
    g.reference.h = math.max(geometry.card_h, sizes.card_minimum)
    g.strip.h = math.min(g.strip.h, geometry.card_h)
  else
    geometry = layout.measure(g.panels.w, g.panels.h, prefs, options)
  end
  if not geometry.temporary then v.previous_mode = geometry.mode end
  v.stereo_hidden = geometry.hidden and geometry.hidden.stereo or false
  g.panel_geometry = geometry
  return g
end

local function draw_view(ctx, res, v, x, y, g)
  paint_panels(ctx, res, v, g.panel_geometry, x + g.panels.x, y + g.panels.y)
  local s = g.strip
  view.paint_card(ctx, res, v, x + s.x, y + s.y, s.w, s.h, g.reference.h)
end

-- Draws the whole Reference View into (x, y, w, h) and returns its placement
-- (view.measure's result, valid until the next call). `docked` as for view.measure.
function view.paint(ctx, res, v, x, y, w, h, docked)
  local g = view.measure(ctx, v, w, h, docked)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
  local visible = reaper.ImGui_BeginChild(ctx, 'release_card_view', math.max(1, w), math.max(1, h),
    0, INERT)
  reaper.ImGui_PopStyleVar(ctx)
  if not visible then return g end
  local ok, failure = xpcall(draw_view, debug.traceback, ctx, res, v, x, y, g)
  reaper.ImGui_EndChild(ctx)
  if not ok then error(failure, 0) end
  return g
end

return view
