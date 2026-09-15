-- Pure display maths for the spectrum analyser.
--
-- The audio-side helper publishes decibel values. This module owns the display
-- response, power average, peak hold and graph mapping so the JSFX stays small
-- and predictable. It has no REAPER dependency and is covered by focused specs.

local spectrum_math = {}

local LN10 = math.log(10)
local LN2 = math.log(2)
local FINITE_AVERAGE_FALLOFF_RATE = math.log(100)

local function clamp(value, low, high)
  if value < low then return low end
  if value > high then return high end
  return value
end

function spectrum_math.db_to_power(db)
  return math.exp((tonumber(db) or -120) * LN10 / 10)
end

function spectrum_math.power_to_db(power, floor_db)
  floor_db = tonumber(floor_db) or -120
  if type(power) ~= "number" or power <= 0 or power ~= power then return floor_db end
  return math.max(floor_db, 10 * math.log(power) / LN10)
end

-- Convert a readable decibel-fall target into the power-domain time constant
-- used by the Live response. This keeps Speed choices predictable even though
-- the graph itself is displayed in decibels.
function spectrum_math.power_release_seconds(fall_db, duration_seconds)
  fall_db = math.max(0.001, tonumber(fall_db) or 20)
  duration_seconds = math.max(0.001, tonumber(duration_seconds) or 1)
  return duration_seconds * 10 / (fall_db * LN10)
end

function spectrum_math.new(bin_count, floor_db)
  bin_count = math.max(1, math.floor(tonumber(bin_count) or 1))
  floor_db = tonumber(floor_db) or -120
  local state = {
    bin_count = bin_count,
    floor_db = floor_db,
    live = {},
    live_power = {},
    live_motion_mode = nil,
    average_power = {},
    peak = {},
    peak_display = {},
    peak_scratch = {},
    peak_age = {},
    ready = false,
    average_ready = false,
    average_elapsed = 0,
    peak_ready = false,
  }
  local floor_power = spectrum_math.db_to_power(floor_db)
  for i = 1, bin_count do
    state.live[i] = floor_db
    state.live_power[i] = floor_power
    state.average_power[i] = floor_power
    state.peak[i] = floor_db
    state.peak_display[i] = floor_db
    state.peak_scratch[i] = floor_db
    state.peak_age[i] = 0
  end
  return state
end

local function smooth_neighbours(source, destination, count)
  if count == 1 then
    destination[1] = source[1]
    return
  end

  destination[1] = (source[1] * 3 + source[2]) * 0.25
  for i = 2, count - 1 do
    destination[i] = (source[i - 1] + source[i] * 2 + source[i + 1]) * 0.25
  end
  destination[count] = (source[count - 1] + source[count] * 3) * 0.25
end

local function update_peak_display(state)
  -- Peak timers are independent per frequency. Two bounded neighbour passes
  -- soften the one-bin steps where adjacent holds expire on different frames,
  -- without feeding the softened result back into the measured peak history.
  smooth_neighbours(state.peak, state.peak_scratch, state.bin_count)
  smooth_neighbours(state.peak_scratch, state.peak_display, state.bin_count)
end

-- Rebuild a stopped trace from one fixed audio snapshot. Using total elapsed
-- time instead of chaining interface frames makes the result independent of
-- redraw rate and catches up immediately after a closed audio device returns.
function spectrum_math.decay_power_trace(source, destination, count, floor_db,
    elapsed_seconds, release_seconds)
  local elapsed = math.max(0, tonumber(elapsed_seconds) or 0)
  local release = math.max(0.001, tonumber(release_seconds) or 1)
  local floor_power = spectrum_math.db_to_power(floor_db)
  local retained = math.exp(-elapsed / release)
  for i = 1, count do
    local source_power = spectrum_math.db_to_power(source[i] or floor_db)
    destination[i] = spectrum_math.power_to_db(
      floor_power + (source_power - floor_power) * retained, floor_db)
  end
end

-- Peak Hold keeps a separate age for every frequency. Only the part of the
-- stopped interval beyond that frequency's remaining hold time releases it.
function spectrum_math.decay_peak_trace(source, ages, raw_destination,
    display_destination, scratch, count, floor_db, elapsed_seconds,
    hold_seconds, release_seconds)
  local elapsed = math.max(0, tonumber(elapsed_seconds) or 0)
  local hold = math.max(0, tonumber(hold_seconds) or 0)
  local release = math.max(0.01, tonumber(release_seconds) or 1.2)
  for i = 1, count do
    local age = math.max(0, tonumber(ages[i]) or 0)
    local before = math.max(0, age - hold)
    local after = math.max(0, age + elapsed - hold)
    local releasing = after - before
    local source_db = source[i] or floor_db
    raw_destination[i] = floor_db
      + (source_db - floor_db) * math.exp(-releasing / release)
  end
  smooth_neighbours(raw_destination, scratch, count)
  smooth_neighbours(scratch, display_destination, count)
end

-- Update without allocating. Average time and peak hold may be math.huge for an
-- accumulating trace that lasts until the user resets it.
function spectrum_math.update(state, target_db, dt, options)
  options = options or {}
  dt = clamp(tonumber(dt) or 0, 0, 0.5)
  local attack_seconds = math.max(0.001, tonumber(options.attack_seconds) or 0.012)
  local release_seconds = math.max(0.001, tonumber(options.release_seconds) or 0.20)
  local motion_mode = options.motion_mode == "power" and "power" or "db"
  local average_seconds = options.average_seconds
  if average_seconds ~= nil and average_seconds ~= math.huge then
    average_seconds = math.max(0.01, tonumber(average_seconds) or 1)
  end
  local peak_hold_seconds = options.peak_hold_seconds
  if peak_hold_seconds ~= nil and peak_hold_seconds ~= math.huge then
    peak_hold_seconds = math.max(0, tonumber(peak_hold_seconds) or 1)
  end
  local peak_release_seconds = math.max(0.01,
    tonumber(options.peak_release_seconds) or 1.2)

  if not state.ready then
    for i = 1, state.bin_count do
      local target = target_db[i] or state.floor_db
      state.live[i] = target
      state.live_power[i] = spectrum_math.db_to_power(target)
    end
    state.ready = true
  else
    if motion_mode == "power" and state.live_motion_mode ~= "power" then
      for i = 1, state.bin_count do
        state.live_power[i] = spectrum_math.db_to_power(state.live[i])
      end
    end
    for i = 1, state.bin_count do
      local target = target_db[i] or state.floor_db
      local current = state.live[i]
      local seconds = target > current and attack_seconds or release_seconds
      local amount = 1 - math.exp(-dt / seconds)
      if motion_mode == "power" then
        local current_power = state.live_power[i]
        local target_power = spectrum_math.db_to_power(target)
        local next_power = current_power + (target_power - current_power) * amount
        state.live_power[i] = next_power
        state.live[i] = spectrum_math.power_to_db(next_power, state.floor_db)
      else
        state.live[i] = current + (target - current) * amount
      end
    end
  end
  state.live_motion_mode = motion_mode

  if average_seconds ~= nil then
    if not state.average_ready then
      for i = 1, state.bin_count do
        state.average_power[i] = spectrum_math.db_to_power(target_db[i] or state.floor_db)
      end
      state.average_ready = true
      state.average_elapsed = math.max(dt, 1 / 60)
    elseif average_seconds == math.huge then
      local elapsed = state.average_elapsed
      local next_elapsed = elapsed + dt
      local amount = next_elapsed > 0 and dt / next_elapsed or 0
      for i = 1, state.bin_count do
        local target_power = spectrum_math.db_to_power(target_db[i] or state.floor_db)
        local current = state.average_power[i]
        state.average_power[i] = current + (target_power - current) * amount
      end
      state.average_elapsed = next_elapsed
    else
      -- Professional spectrum ballistics commonly define Average time as the
      -- time required to fall by 20 dB. The same power-domain coefficient makes
      -- a rising step reach 99% within the selected period.
      local amount = 1 - math.exp(
        -dt * FINITE_AVERAGE_FALLOFF_RATE / average_seconds)
      for i = 1, state.bin_count do
        local target_power = spectrum_math.db_to_power(target_db[i] or state.floor_db)
        local current = state.average_power[i]
        state.average_power[i] = current + (target_power - current) * amount
      end
    end
  end

  if peak_hold_seconds ~= nil then
    if not state.peak_ready then
      for i = 1, state.bin_count do
        state.peak[i] = target_db[i] or state.floor_db
        state.peak_age[i] = 0
      end
      state.peak_ready = true
    else
      for i = 1, state.bin_count do
        local target = target_db[i] or state.floor_db
        if target >= state.peak[i] then
          state.peak[i] = target
          state.peak_age[i] = 0
        else
          local age = state.peak_age[i] + dt
          state.peak_age[i] = age
          if peak_hold_seconds ~= math.huge and age > peak_hold_seconds then
            -- A fixed dB-per-second fall makes the captured outline descend as
            -- one rigid shape. Returning each point toward its current live
            -- target keeps the hold legible without the mechanical motion.
            local amount = 1 - math.exp(-dt / peak_release_seconds)
            local released = state.peak[i] + (target - state.peak[i]) * amount
            state.peak[i] = math.max(target, released)
          end
        end
      end
    end
    update_peak_display(state)
  end
end

function spectrum_math.average_db(state, index)
  return spectrum_math.power_to_db(state.average_power[index], state.floor_db)
end

function spectrum_math.reset_average(state)
  state.average_ready = false
  state.average_elapsed = 0
end

function spectrum_math.reset_peak(state)
  state.peak_ready = false
end

function spectrum_math.reset_history(state)
  spectrum_math.reset_average(state)
  spectrum_math.reset_peak(state)
end

function spectrum_math.reset_all(state)
  state.ready = false
  spectrum_math.reset_history(state)
end

function spectrum_math.bin_frequency(index, bin_count, low_hz, high_hz)
  bin_count = math.max(1, math.floor(tonumber(bin_count) or 1))
  index = clamp(tonumber(index) or 1, 1, bin_count)
  low_hz = math.max(0.001, tonumber(low_hz) or 20)
  high_hz = math.max(low_hz * 1.001, tonumber(high_hz) or 20000)
  return low_hz * (high_hz / low_hz) ^ ((index - 0.5) / bin_count)
end

local function monotone_slope(before, after)
  if before * after <= 0 then return 0 end
  return 2 * before * after / (before + after)
end

-- Interpolate between real FFT measurements without inventing peaks above or
-- below the neighbouring bins. This removes the plateaus caused by assigning
-- several logarithmic display points to the same FFT bin.
function spectrum_math.interpolate_power(power_bins, position)
  local count = #power_bins
  if count == 0 then return 0 end
  if count == 1 then return math.max(0, tonumber(power_bins[1]) or 0) end

  position = clamp(tonumber(position) or 1, 1, count)
  if position >= count then return math.max(0, tonumber(power_bins[count]) or 0) end

  local left = math.floor(position)
  local right = left + 1
  local p0 = tonumber(power_bins[math.max(1, left - 1)]) or 0
  local p1 = tonumber(power_bins[left]) or 0
  local p2 = tonumber(power_bins[right]) or 0
  local p3 = tonumber(power_bins[math.min(count, right + 1)]) or 0
  local before = p1 - p0
  local across = p2 - p1
  local after = p3 - p2
  local left_slope = monotone_slope(before, across)
  local right_slope = monotone_slope(across, after)
  local t = position - left
  local t2 = t * t
  local t3 = t2 * t
  local value = (2 * t3 - 3 * t2 + 1) * p1
    + (t3 - 2 * t2 + t) * left_slope
    + (-2 * t3 + 3 * t2) * p2
    + (t3 - t2) * right_slope
  return clamp(value, math.max(0, math.min(p1, p2)), math.max(p1, p2))
end

local TONE_CONTRAST_START_DB = 12
local TONE_CONTRAST_FULL_DB = 18
local TONE_BACKGROUND_OFFSETS = { -4, -3, -2, 2, 3, 4 }

local function smoothstep(value)
  value = clamp(value, 0, 1)
  return value * value * (3 - 2 * value)
end

local function raw_power(power_bins, index)
  if index < 1 or index > #power_bins then return nil end
  return math.max(0, tonumber(power_bins[index]) or 0)
end

local function band_mean_power(power_bins, lower_hz, upper_hz, center_hz,
    bin_hz)
  -- Interpolation is more informative than repeating one raw FFT value across
  -- the many display cells that can fit inside a low-frequency FFT interval.
  if upper_hz - lower_hz < bin_hz then
    return spectrum_math.interpolate_power(power_bins, center_hz / bin_hz)
  end

  local first = math.max(1, math.ceil(lower_hz / bin_hz - 0.5))
  local last = math.min(#power_bins, math.floor(upper_hz / bin_hz + 0.5))
  local weighted_power, covered_hz = 0, 0
  for fft_bin = first, last do
    local overlap_lower = math.max(lower_hz, (fft_bin - 0.5) * bin_hz)
    local overlap_upper = math.min(upper_hz, (fft_bin + 0.5) * bin_hz)
    local overlap_hz = math.max(0, overlap_upper - overlap_lower)
    weighted_power = weighted_power
      + (raw_power(power_bins, fft_bin) or 0) * overlap_hz
    covered_hz = covered_hz + overlap_hz
  end

  if covered_hz > 0 then return weighted_power / covered_hz end
  return spectrum_math.interpolate_power(power_bins, center_hz / bin_hz)
end

local function tone_cluster_power(power_bins, fft_bin, window_enbw)
  local power = 0
  for index = fft_bin - 1, fft_bin + 1 do
    power = power + (raw_power(power_bins, index) or 0)
  end
  return power / window_enbw
end

local function tone_background_power(power_bins, fft_bin)
  local power, count = 0, 0
  for _, offset in ipairs(TONE_BACKGROUND_OFFSETS) do
    local value = raw_power(power_bins, fft_bin + offset)
    if value then
      power = power + value
      count = count + 1
    end
  end
  return count > 0 and power / count or 0
end

-- Reduce the linear FFT to finite logarithmic display cells. Broadband energy
-- is averaged by the frequency span each FFT bin contributes, so wider treble
-- cells do not rise merely because they contain more chances for a random peak.
-- A clearly concentrated three-bin Hann-window cluster is treated as a tone and
-- retains its calibrated level. This is mirrored exactly by the JSFX helper.
function spectrum_math.reduce_power_bands(power_bins, sample_rate, fft_size,
    bin_count, low_hz, high_hz)
  sample_rate = math.max(1, tonumber(sample_rate) or 48000)
  fft_size = math.max(2, tonumber(fft_size) or 4096)
  bin_count = math.max(1, math.floor(tonumber(bin_count) or 512))
  low_hz = math.max(0.001, tonumber(low_hz) or 10)
  high_hz = math.max(low_hz * 1.001,
    math.min(tonumber(high_hz) or 22050, sample_rate * 0.5))
  local bin_hz = sample_rate / fft_size
  local band_ratio = (high_hz / low_hz) ^ (1 / bin_count)
  local window_enbw = 1.5 * fft_size / (fft_size - 1)
  local lower_hz = low_hz
  local bands = {}

  for display_index = 1, bin_count do
    local upper_hz = lower_hz * band_ratio
    local center_hz = math.sqrt(lower_hz * upper_hz)
    local baseline = band_mean_power(
      power_bins, lower_hz, upper_hz, center_hz, bin_hz)
    local display_power = baseline
    local first = math.max(1, math.ceil(lower_hz / bin_hz))
    local last = math.min(#power_bins, math.floor(upper_hz / bin_hz))
    for fft_bin = first, last do
      local cluster = tone_cluster_power(power_bins, fft_bin, window_enbw)
      local background = tone_background_power(power_bins, fft_bin)
      local contrast_db = cluster > 0 and 180 or 0
      if background > 1e-30 then
        contrast_db = 10 * math.log(cluster / background) / LN10
      end
      local tone_weight = smoothstep((contrast_db - TONE_CONTRAST_START_DB)
        / (TONE_CONTRAST_FULL_DB - TONE_CONTRAST_START_DB))
      local candidate = baseline + (cluster - baseline) * tone_weight
      display_power = math.max(display_power, candidate)
    end
    bands[display_index] = display_power
    lower_hz = upper_hz
  end
  return bands
end

local function triangle_integral(value, half_width)
  if value <= -half_width then return -half_width * 0.5 end
  if value < 0 then return value + value * value / (2 * half_width) end
  if value < half_width then return value - value * value / (2 * half_width) end
  return half_width * 0.5
end

-- Apply triangular smoothing after logarithmic reduction. Integrating the
-- kernel across each finite cell makes the selected octave width mean the same
-- thing at every frequency and keeps very narrow settings effective.
function spectrum_math.smooth_log_power(power_bands, width_octaves,
    low_hz, high_hz)
  local count = #power_bands
  if count == 0 then return {} end
  width_octaves = math.max(0, tonumber(width_octaves) or 0)
  if width_octaves == 0 then
    local copy = {}
    for index = 1, count do copy[index] = power_bands[index] end
    return copy
  end

  low_hz = math.max(0.001, tonumber(low_hz) or 10)
  high_hz = math.max(low_hz * 1.001, tonumber(high_hz) or 22050)
  local step_octaves = math.log(high_hz / low_hz) / LN2 / count
  local half_width = width_octaves * 0.5
  local smoothed = {}

  for index = 1, count do
    local first = math.max(1,
      math.ceil(index - half_width / step_octaves - 0.5))
    local last = math.min(count,
      math.floor(index + half_width / step_octaves + 0.5))
    local weighted_power = 0
    local weight_total = 0
    for source_index = first, last do
      local distance = (source_index - index) * step_octaves
      local lower_distance = distance - step_octaves * 0.5
      local upper_distance = distance + step_octaves * 0.5
      local weight = triangle_integral(upper_distance, half_width)
        - triangle_integral(lower_distance, half_width)
      if weight > 0 then
        weighted_power = weighted_power
          + math.max(0, tonumber(power_bands[source_index]) or 0) * weight
        weight_total = weight_total + weight
      end
    end
    smoothed[index] = weight_total > 0
      and weighted_power / weight_total
      or math.max(0, tonumber(power_bands[index]) or 0)
  end
  return smoothed
end

function spectrum_math.tilted_db(db, frequency, slope_db_per_octave, pivot_hz)
  db = tonumber(db) or -120
  frequency = math.max(0.001, tonumber(frequency) or 1000)
  slope_db_per_octave = tonumber(slope_db_per_octave) or 0
  pivot_hz = math.max(0.001, tonumber(pivot_hz) or 1000)
  return db + slope_db_per_octave * math.log(frequency / pivot_hz) / LN2
end

function spectrum_math.frequency_fraction(frequency, low_hz, high_hz)
  low_hz = math.max(0.001, tonumber(low_hz) or 20)
  high_hz = math.max(low_hz * 1.001, tonumber(high_hz) or 20000)
  frequency = clamp(tonumber(frequency) or low_hz, low_hz, high_hz)
  return math.log(frequency / low_hz) / math.log(high_hz / low_hz)
end

-- Grid subdivisions fade in order within each decimal frequency decade. The
-- next decade starts at full prominence again.
function spectrum_math.frequency_grid_prominence(multiplier)
  multiplier = clamp(math.floor(tonumber(multiplier) or 1), 1, 9)
  return 1 - (multiplier - 1) * 0.70 / 8
end

function spectrum_math.fraction_frequency(fraction, low_hz, high_hz)
  fraction = clamp(tonumber(fraction) or 0, 0, 1)
  low_hz = math.max(0.001, tonumber(low_hz) or 20)
  high_hz = math.max(low_hz * 1.001, tonumber(high_hz) or 20000)
  return low_hz * (high_hz / low_hz) ^ fraction
end

-- Sample the same straight segment the graph draws between logarithmic display
-- points. The hover readout therefore agrees with the visible curve.
function spectrum_math.sample_log_values(values, count, frequency, low_hz, high_hz)
  count = math.min(#values, math.max(0, math.floor(tonumber(count) or #values)))
  if count == 0 then return nil end
  if count == 1 then return tonumber(values[1]) end

  local fraction = spectrum_math.frequency_fraction(frequency, low_hz, high_hz)
  local position = clamp(fraction * count + 0.5, 1, count)
  local left = math.floor(position)
  local right = math.min(count, left + 1)
  local amount = position - left
  local left_value = tonumber(values[left]) or 0
  local right_value = tonumber(values[right]) or left_value
  return left_value + (right_value - left_value) * amount
end

local NOTE_NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }

function spectrum_math.frequency_note(frequency)
  frequency = math.max(0.001, tonumber(frequency) or 440)
  local midi = math.floor(69 + 12 * math.log(frequency / 440) / LN2 + 0.5)
  local name = NOTE_NAMES[(midi % 12) + 1]
  local octave = math.floor(midi / 12) - 1
  return name .. octave, midi
end

function spectrum_math.db_fraction(db, top_db, bottom_db)
  top_db = tonumber(top_db) or 6
  bottom_db = math.min(top_db - 0.001, tonumber(bottom_db) or -96)
  db = clamp(tonumber(db) or bottom_db, bottom_db, top_db)
  return (top_db - db) / (top_db - bottom_db)
end

-- Keep only the part of a graph segment at or above the visible floor. The
-- crossing point is interpolated so a curve ends at the boundary instead of
-- becoming a horizontal shelf along it.
function spectrum_math.clip_segment_to_floor(x1, db1, x2, db2, floor_db)
  local first_visible = db1 >= floor_db
  local second_visible = db2 >= floor_db
  if not first_visible and not second_visible then return nil end
  if first_visible and second_visible then return x1, db1, x2, db2 end

  local amount = (floor_db - db1) / (db2 - db1)
  local crossing_x = x1 + (x2 - x1) * amount
  if first_visible then return x1, db1, crossing_x, floor_db end
  return crossing_x, floor_db, x2, db2
end

return spectrum_math
