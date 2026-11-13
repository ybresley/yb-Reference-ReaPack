-- Docked Library release demonstration: the production Library moving from
-- its separate window to beside the Reference card, being resized there and
-- auditioning a sound, drawn from a small sample Library.
--
-- The Library is the real browser.lua, in its separate-window form first and
-- then docked, laid out by the same arithmetic as ui/library_host.lua. The
-- Reference card and panels beside it are ui/release_card_view.lua, placed by
-- the live layout with or without the docked Library. The Library runs as a
-- private copy inside a sandbox (ui/release_sandbox.lua), so its navigation,
-- search and motion are its own and never the live Library's, and it cannot
-- see the user's mouse or keyboard. Clicks happen by changing the sample state
-- the way the entry script would after the matching click. Whatever the
-- drawers return is discarded. Nothing here reaches playback, preferences, the
-- Library folder or Library data.
local theme = require('ui.theme')
local story = require('core.release_library_demo')
local sandbox = require('ui.release_sandbox')
local view = require('ui.release_card_view')
local controls = require('ui.reference_controls')
local readings = require('ui.readings')
local scope = require('ui.release_preview_scope')
local pointer = require('ui.release_pointer')
local wave_signal = require('ui.release_layout_wave')
local source = require('ui.release_card_source')
local card_plan = require('core.card_plan')
local panel_layout = require('core.browser_panel_layout')
local sidebar = require('core.reference_sidebar_layout')
local T, M = theme.tokens, theme.metrics
local library = {}

-- The Library, the card and the panels share one sample: the measured passage
-- whose waveform ui.release_layout_wave holds.
assert(source.duration == story.SOUND_SECONDS and wave_signal.duration == story.SOUND_SECONDS,
  'the Library sample and its waveform must cover the same passage')

-- Every module that keeps memory a live Library would share, or that submits
-- controls or reads input. ui/focus.lua and ui/pitchwin.lua are left out on
-- purpose: the copies get a stand-in that does nothing, so the demonstration
-- never registers focus zones or opens the live Pitch panel.
local PRIVATE = {'ui.browser', 'ui.browser_shortcuts', 'ui.dropzone', 'ui.popups',
  'ui.analysis_panel', 'ui.leftover_panel', 'ui.status_card', 'ui.transport', 'ui.waveform',
  'ui.wave_navigation', 'ui.readings', 'ui.widgets', 'ui.numeric_input', 'ui.icon_motion',
  'ui.icons'}
local NOOP = function() end
local INERT_MODULE = setmetatable({}, {__index = function() return NOOP end})
local STUBS = {['ui.focus'] = INERT_MODULE, ['ui.pitchwin'] = INERT_MODULE}

-- The simulated Reference View is the default floating window's content
-- width at 100% UI Size; a narrower example crops its panels at the right
-- rather than squeezing it. The example shows it at TARGET_WIDTH's share of
-- the area, between MIN_RATIO and full size, so the Library stays readable.
local LIVE_WIDTH, TARGET_WIDTH, MIN_RATIO = 1104, 1000, .85
-- The separate Library window's share of the example's width, and its margin.
local WINDOW_SHARE, WINDOW_MARGIN = .62, 16
local TITLE = 'LIBRARY'
local INERT = reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
  | reaper.ImGui_WindowFlags_NoInputs() | reaper.ImGui_WindowFlags_NoNav()
local OVERLAY = INERT | reaper.ImGui_WindowFlags_NoBackground()
local PADDED = reaper.ImGui_ChildFlags_AlwaysUseWindowPadding
  and reaper.ImGui_ChildFlags_AlwaysUseWindowPadding() or 0
local ROUND_TOP = reaper.ImGui_DrawFlags_RoundCornersTop and reaper.ImGui_DrawFlags_RoundCornersTop() or 0

local SAMPLE = {name = source.name, duration = source.duration, channels = source.channels,
  readings = source.readings}

local function sample_state(lib)
  local lib_view, visible, counts = story.view(lib)
  local sound
  for _, s in ipairs(lib.sounds) do
    if s.id == story.SAMPLE_ID then sound = s end
  end
  return {
    library = lib, view = lib_view, query = '', visible_sounds = visible,
    sort = {col = 'name', asc = true}, col_gen = 0, sidebar_counts = counts, counts = counts,
    -- The sample sound is also the Reference card's reference.
    pins = {by_origin = {[story.SAMPLE_ID] = true}},
    deps = {drag_out = false, imgui_drop = false},
    browse_ids = {},
    browse_info = {rate = source.rate, bits = source.bits, format = source.format,
      channels = source.channels},
    browse_waveform = {sound_id = nil, channels = wave_signal.channels},
    preview = {playing = false, sound_id = nil, position = 0, length = 0, channels = 0,
      slot = nil, trim_db = 0, start_serial = 0, paused = {}},
    browser_open = true, library_placement = 'floating',
    auto_audition = true, loop = false, mono = false, master_db = 0,
    pitch = {main = 0, browse = 0}, reading_extra = 'true_peak', loud_unit = 'lufs_i',
    reveal_seq = 0, showcase = true,
  }, sound
end

function library.new()
  local box = sandbox.new(PRIVATE, STUBS)
  local state, sound = sample_state(story.library(SAMPLE))
  sandbox.watch(box, '##embed_library', 'dock')
  sandbox.watch(box, '###' .. story.SAMPLE_ID, 'row')
  sandbox.watch(box, '##waveform', 'wave')
  local card = view.new()
  -- The Library is open throughout, so the card's Library button shows open.
  -- Loop is a shared setting; the audition plays once, so it is off for both.
  card.state.browser_open, card.state.loop = true, false
  return {
    box = box, browser = sandbox.require(box, 'ui.browser'),
    state = state, sound = sound, card = card, scene = {},
    anchors = {home = {}, dock = {}, edge = {}, row = {}, wave = {}},
    -- Reused every frame (frame-allocation rule).
    opts = {embedded = true}, plan = {}, reading_sizes = {rows = {}}, form_sizes = {},
    forms = {}, docked = {}, stack_opts = {},
  }
end

local function ratio_for(width)
  return math.max(MIN_RATIO, math.min(1, width / (TARGET_WIDTH * theme.scale)))
end

-- The sample state for this moment, changed the way the entry script changes
-- it after the matching click.
local function apply(demo, scene)
  local s, sound = demo.state, demo.sound
  s.library_placement = scene.docked and 'embedded' or 'floating'
  local selected = scene.selected
  s.browse = selected and sound or nil
  s.browse_id = selected and sound.id or nil
  s.browse_anchor_id = s.browse_id
  s.browse_ids[sound.id] = selected or nil
  s.browse_waveform.sound_id = s.browse_id
  local p = s.preview
  p.playing = scene.playing
  p.slot = scene.playing and 'browse' or nil
  p.sound_id = scene.playing and sound.id or nil
  p.position = scene.position
  p.length = scene.playing and sound.duration or 0
  p.channels = scene.playing and sound.channels or 0
  p.start_serial = scene.start_serial
end

-- library_host.lua's height for the Library form with a list, from live sizes.
local function list_heights(ctx, demo, rows)
  local s = demo.form_sizes
  local cell_padding = select(2, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_CellPadding()))
  s.control, s.gap = reaper.ImGui_GetFrameHeight(ctx), M.ITEM_SPACING_Y
  s.inset = M.STRIP_PAD
  s.list = (reaper.ImGui_GetTextLineHeight(ctx) + 2 * cell_padding) * (M.BROWSER_LIST_MIN_ROWS + 1)
    + theme.scale
  s.readings = readings.section_height(rows)
  s.wave, s.ruler = M.BROWSER_PANEL_WAVE_H, M.RULER_H
  s.frame_pad = M.FRAME_PAD_Y
  s.bottom_pad = M.STRIP_PAD
  return panel_layout.form_heights(s, demo.forms)
end

-- The most rows of readings, up to `limit`, that fit a Library `width` wide.
local function reading_rows(ctx, demo, width, limit)
  local sizes = demo.reading_sizes
  readings.rows_for_width(ctx, width - 2 * M.WINDOW_PAD, sizes.rows)
  return card_plan.rows_up_to(sizes, limit)
end

-- The docked Library's part of library_host.lua's layout options, for a
-- Reference View `width` by `height`.
local function docked_options(ctx, demo, scene, width, height)
  local sizes = controls.measure(ctx)
  local pad_x = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding())
  local volume_w = reaper.ImGui_CalcTextSize(ctx, '-60.0 dB') + 2 * pad_x
  local d, o = demo.docked, demo.stack_opts
  d.library_width = scene.library_width
  d.library_minimum = panel_layout.minimum_width(reaper.ImGui_GetFrameHeight(ctx), volume_w, M)
    + 2 * M.WINDOW_PAD
  -- Stacking needs the Library to show its list with its readings below, at
  -- the width it would have there.
  o.width, o.height, o.scale, o.library = width, height, theme.scale, true
  o.library_width, o.library_minimum = d.library_width, d.library_minimum
  o.block_width, o.card_minimum, o.card_natural = sizes.block_width, sizes.card_minimum,
    sizes.card_natural
  local forms = list_heights(ctx, demo, reading_rows(ctx, demo, sidebar.stacked_width(o), 3))
  -- The waveform is at its default height, so keeping it costs nothing extra.
  d.library_min_height, d.library_keep_height = forms.list, forms.list
  return d
end

local function draw_docked(ctx, res, demo, g, x, y, height)
  local l, opts = g.library, demo.opts
  -- What a card of the Library's height shows; beside the card the Library's
  -- picker form matches it row for row.
  opts.plan = controls.plan(ctx, l.h, g.placement == 'beside_library' and g.reference.w or l.w,
    demo.plan)
  local rows = reading_rows(ctx, demo, l.w, opts.plan.readings)
  opts.form = panel_layout.form(l.h, list_heights(ctx, demo, rows))
  opts.readings, opts.bottom_pad = rows, M.STRIP_PAD
  opts.cell_w = controls.cell_width(ctx, g.reference.w)
  reaper.ImGui_SetCursorScreenPos(ctx, x + l.x, y + l.y)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), M.WINDOW_PAD, 0)
  local visible = reaper.ImGui_BeginChild(ctx, 'release_docked_library', l.w,
    math.min(l.h, height - l.y), PADDED, INERT)
  reaper.ImGui_PopStyleVar(ctx)
  if not visible then return end
  local ok, failure = xpcall(demo.browser.draw, debug.traceback, ctx, demo.state, res, opts)
  reaper.ImGui_EndChild(ctx)
  if not ok then error(failure, 0) end
end

-- The separate Library window over Reference View, as REAPER shows a floating
-- ReaImGui window with this theme: rounded and outlined, the title centred in
-- its bar with a hairline below, and the tool's own quiet close mark at the
-- right (theme.begin_window).
local function paint_window_frame(dl, ctx, wx, wy, w, h, bar)
  reaper.ImGui_DrawList_AddRectFilled(dl, wx, wy, wx + w, wy + h, T.BG_WINDOW, 8)
  reaper.ImGui_DrawList_AddRectFilled(dl, wx, wy, wx + w, wy + bar, T.BG_CHROME, 8, ROUND_TOP)
  reaper.ImGui_DrawList_AddLine(dl, wx + 1, wy + bar - .5, wx + w - 1, wy + bar - .5,
    T.STROKE_SECONDARY, 1)
  reaper.ImGui_DrawList_AddRect(dl, wx, wy, wx + w, wy + h, T.STROKE_SECONDARY, 8, 0, 1)
  local tw, th = reaper.ImGui_CalcTextSize(ctx, TITLE)
  reaper.ImGui_DrawList_AddText(dl, math.floor(wx + (w - tw) / 2 + .5),
    math.floor(wy + (bar - th) / 2 + .5), T.TEXT_SECONDARY, TITLE)
  local side = math.floor(bar) - 4
  local x2, y1 = math.floor(wx + w) - 2, math.floor(wy) + 2
  local cx, cy, arm = x2 - side / 2, y1 + side / 2, side * .21
  reaper.ImGui_DrawList_AddLine(dl, cx - arm, cy - arm, cx + arm, cy + arm, T.TEXT_TERTIARY, 1.2)
  reaper.ImGui_DrawList_AddLine(dl, cx - arm, cy + arm, cx + arm, cy - arm, T.TEXT_TERTIARY, 1.2)
end

local function draw_window(ctx, res, demo, x, y, width, height)
  local margin = math.floor(WINDOW_MARGIN * theme.scale)
  local w = math.floor(math.max(M.BROWSER_MIN_W, math.min(width * WINDOW_SHARE, M.BROWSER_WIN_W)))
  local h = math.floor(math.max(M.MIN_WIN_H + M.RULER_H, height - 2 * margin))
  local wx, wy = x + math.max(margin, width - w - 2 * margin), y + margin
  local bar = reaper.ImGui_GetFrameHeight(ctx)
  reaper.ImGui_SetCursorScreenPos(ctx, wx, wy)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
  local visible = reaper.ImGui_BeginChild(ctx, 'release_library_window', w, h, 0, OVERLAY)
  if not visible then
    reaper.ImGui_PopStyleVar(ctx)
    return
  end
  paint_window_frame(reaper.ImGui_GetWindowDrawList(ctx), ctx, wx, wy, w, h, bar)
  -- The content sits inside the window's outline, as ImGui insets it.
  reaper.ImGui_SetCursorScreenPos(ctx, wx + 1, wy + bar)
  local content = reaper.ImGui_BeginChild(ctx, 'release_library_content', w - 2, h - bar - 1, 0,
    OVERLAY)
  reaper.ImGui_PopStyleVar(ctx)
  local ok, failure = true, nil
  if content then
    ok, failure = xpcall(demo.browser.draw, debug.traceback, ctx, demo.state, res)
    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_EndChild(ctx)
  if not ok then error(failure, 0) end
end

-- Where the pointer goes for each named step, from where the real controls
-- were drawn this frame. A control that isn't showing keeps its last place.
local function aim(demo, key, fx, fy)
  local rect = sandbox.rect(demo.box, key)
  if not rect then return end
  local a = demo.anchors[key]
  a.x, a.y = rect.x0 + (rect.x1 - rect.x0) * fx, rect.y0 + (rect.y1 - rect.y0) * fy
end

-- The edge's hover and drag highlight, as library_host.lua fills the gap, then
-- the pointer: the resize cursor over the edge, the arrow elsewhere.
local function paint_overlay(ctx, demo, scene, g, x, y, width, height)
  local anchors, s = demo.anchors, theme.scale
  local home = anchors.home
  home.x, home.y = x + width * .8, y + height * .7
  if g.library then
    anchors.edge.x, anchors.edge.y = x + g.resize_x + g.gap / 2, y + height * .42
  end
  local row = sandbox.rect(demo.box, 'row')
  if row then
    anchors.row.x = row.x0 + math.min(110 * s, (row.x1 - row.x0) * .4)
    anchors.row.y = (row.y0 + row.y1) * .5
  end
  aim(demo, 'dock', .5, .62)
  aim(demo, 'wave', story.SEEK_FRACTION, .4)
  local from, to = anchors[scene.from], anchors[scene.to]
  if not from.x then from = home end
  if not to.x then to = home end
  local px = from.x + (to.x - from.x) * scene.progress
  local py = from.y + (to.y - from.y) * scene.progress

  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
  local visible = reaper.ImGui_BeginChild(ctx, 'release_library_pointer', width, height, 0, OVERLAY)
  reaper.ImGui_PopStyleVar(ctx)
  if not visible then return end
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  if scene.edge and g.library then
    local gx = x + g.resize_x
    reaper.ImGui_DrawList_AddRectFilled(dl, gx, y, gx + g.gap, y + height,
      scene.edge == 'held' and T.FILL_PRIMARY or T.FILL_SECONDARY)
  end
  if scene.edge then
    pointer.paint_click(dl, px, py, scene.pulse)
    pointer.paint_resize_ew(dl, px, py)
  else
    pointer.paint(dl, px, py, scene.pulse)
  end
  reaper.ImGui_EndChild(ctx)
end

local function draw_scene(ctx, res, demo, scene, elapsed, x, y, width, height)
  reaper.ImGui_DrawList_AddRectFilled(reaper.ImGui_GetWindowDrawList(ctx), x, y, x + width,
    y + height, T.BG_WINDOW)
  local view_w = math.max(width, LIVE_WIDTH * theme.scale)
  -- One preview serves both: while the Library auditions, the card is stopped.
  -- The panels always follow the one sample passage on the demonstration's clock.
  view.update(demo.card, elapsed, not scene.playing)
  local docked = scene.docked and docked_options(ctx, demo, scene, view_w, height) or nil
  local g = view.paint(ctx, res, demo.card, x, y, view_w, height, docked)
  if docked then
    draw_docked(ctx, res, demo, g, x, y, height)
  else
    draw_window(ctx, res, demo, x, y, width, height)
  end
  paint_overlay(ctx, demo, scene, g, x, y, width, height)
end

function library.draw(ctx, res, demo, _, elapsed, width, height)
  local scene = story.sample(elapsed, demo.scene, not theme.motion.enabled)
  apply(demo, scene)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  sandbox.begin_frame(demo.box)
  -- One frame for the whole example, so the cropped Reference View and the
  -- separate window are clipped to the demonstration area.
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
  local visible = reaper.ImGui_BeginChild(ctx, 'release_library', width, height, 0, OVERLAY)
  reaper.ImGui_PopStyleVar(ctx)
  if visible then
    local ok, failure = pcall(scope.paint, ctx, ratio_for(width), function()
      draw_scene(ctx, res, demo, scene, elapsed, x, y, width, height)
    end)
    reaper.ImGui_EndChild(ctx)
    if not ok then error(failure, 0) end
  end
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  reaper.ImGui_Dummy(ctx, width, height)
end

return library
