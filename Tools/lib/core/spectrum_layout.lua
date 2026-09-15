-- Working-view geometry depends on space, never playback or filter state.
local layout = {}

function layout.measure(width, height, bar_height, gap, ruler_height, min_wave_height,
    hide_height, pane_min_width, split_gap, split, stack_split,
    stack_wave_min, stack_spectrum_min, prefs, last_mode)
  local available = math.max(0, height - bar_height - gap)
  local mode = 'single'
  local horizontal_fits = width >= pane_min_width * 2 + split_gap
    and available >= hide_height
  local vertical_fits = width >= pane_min_width
    and available >= stack_wave_min + split_gap + stack_spectrum_min
  local requested = type(prefs) == 'table' and prefs.mode or 'auto'
  if requested == 'horizontal' then
    if horizontal_fits then mode = 'horizontal' end
  elseif requested == 'vertical' then
    if vertical_fits then mode = 'vertical' end
  elseif horizontal_fits and vertical_fits then
    local ratio = width / available
    if ratio >= 2 then
      mode = 'horizontal'
    elseif ratio <= 1.7 then
      mode = 'vertical'
    elseif last_mode == 'horizontal' or last_mode == 'vertical' then
      mode = last_mode
    else
      mode = 'horizontal'
    end
  elseif horizontal_fits then
    mode = 'horizontal'
  elseif vertical_fits then
    mode = 'vertical'
  end

  local wave_width, wave_total, spectrum_height = width, available, available
  local wave_x, wave_y, spectrum_x, spectrum_y = 0, 0, 0, 0
  local divider_x, divider_y = 0, 0
  local waveform_first = true
  if mode == 'horizontal' then
    local usable = width - split_gap
    local first_width = math.max(pane_min_width,
      math.min(usable - pane_min_width, math.floor(usable * (tonumber(split) or 0.45))))
    local second_width = usable - first_width
    waveform_first = not (type(prefs) == 'table' and prefs.horizontal_first == 'spectrum')
    divider_x = first_width
    if waveform_first then
      wave_width = first_width
      spectrum_x = first_width + split_gap
    else
      wave_width = second_width
      wave_x = first_width + split_gap
    end
  elseif mode == 'vertical' then
    local usable = available - split_gap
    -- The divider sizes two fixed frames. Either picture can occupy either frame,
    -- so the smaller useful picture height is the shared resize limit.
    local frame_min = math.min(stack_wave_min, stack_spectrum_min)
    local first_height = math.max(frame_min,
      math.min(usable - frame_min, math.floor(usable * (stack_split or 0.4))))
    local second_height = usable - first_height
    waveform_first = not (type(prefs) == 'table' and prefs.vertical_first == 'spectrum')
    divider_y = first_height
    if waveform_first then
      wave_total = first_height
      spectrum_height = second_height
      spectrum_y = first_height + split_gap
    else
      spectrum_height = first_height
      wave_total = second_height
      wave_y = first_height + split_gap
    end
  end
  local ruler = wave_total - ruler_height >= min_wave_height
  local picture = ruler and wave_total - ruler_height or wave_total
  if picture < hide_height then
    picture, available, wave_total, spectrum_height, ruler = 0, 0, 0, 0, false
  end
  return { mode = mode, both = mode ~= 'single', visual_h = available,
    wave_h = picture, wave_total_h = wave_total, ruler = ruler,
    wave_w = wave_width,
    spectrum_w = mode == 'horizontal' and width - wave_width - split_gap or width,
    spectrum_h = spectrum_height, spectrum_x = spectrum_x, spectrum_y = spectrum_y,
    wave_x = wave_x, wave_y = wave_y, divider_x = divider_x, divider_y = divider_y,
    waveform_first = waveform_first,
    bar_y = available > 0 and available + gap or 0 }
end

-- The caller removes the original grab offset so the gap stays under the mouse.
-- Different minimum heights keep room for the spectrum's labels and controls.
function layout.clamp_split(pointer, start, extent, gap, minimum, other_minimum)
  local usable = math.max(1, extent - gap)
  return math.max(0.2, minimum / usable,
    math.min(0.8, 1 - (other_minimum or minimum) / usable,
      (pointer - start - gap / 2) / usable))
end

return layout
