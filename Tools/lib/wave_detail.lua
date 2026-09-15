-- wave_detail: keeps one PCM source open and reads only the visible waveform slice.

local SAMPLE_COUNT_MASK = 0xFFFFF
local OUTPUT_MODE_MASK = 0xF00000
local OUTPUT_MODE_SHIFT = 20
local PEAKS_MODE = 0
local WAVEFORM_MODE = 1
local CAPACITY = 4096
local NATIVE_GUARD = 3
local READ_ERROR = "Waveform detail couldn't be read."

local function columns(width)
  return math.max(1, math.min(CAPACITY, math.floor(width or 1)))
end

local function new_reader()
  local reader = {}
  local current

  local function close_current()
    if current then
      reaper.PCM_Source_Destroy(current.source)
      current = nil
    end
  end

  function reader.close()
    close_current()
  end

  function reader.current()
    return current and current.sound_id
  end

  function reader.info()
    if not current then return nil end
    return { duration = current.duration, sample_rate = current.sample_rate }
  end

  reader.columns = columns

  function reader.open(sound_id, path)
    close_current()
    local source = reaper.PCM_Source_CreateFromFile(path)
    if not source then return false end
    local duration = reaper.GetMediaSourceLength(source) or 0
    local channel_count = reaper.GetMediaSourceNumChannels(source) or 0
    local sample_rate = type(reaper.GetMediaSourceSampleRate) == "function"
      and (reaper.GetMediaSourceSampleRate(source) or 0) or 0
    if duration <= 0 or channel_count < 1 then
      reaper.PCM_Source_Destroy(source)
      return false
    end
    current = {
      sound_id = sound_id, source = source, duration = duration,
      channel_count = channel_count, sample_rate = sample_rate,
      buffer = reaper.new_array(channel_count * (CAPACITY + NATIVE_GUARD) * 2),
      channels = {}, count = 0, t0 = nil, t1 = nil, cols = 0, metadata = nil,
    }
    for channel = 1, channel_count do
      current.channels[channel] = { mins = {}, maxs = {} }
    end
    return true
  end

  local function request_for(source, t0, t1, cols)
    local span_seconds = (t1 - t0) * source.duration
    if source.sample_rate > 0 and span_seconds * source.sample_rate <= cols then
      local first_sample = math.max(0,
        math.floor(t0 * source.duration * source.sample_rate) - 1)
      local last_sample = math.ceil(t1 * source.duration * source.sample_rate)
      return {
        rate = source.sample_rate,
        start = first_sample / source.sample_rate,
        count = math.min(CAPACITY + NATIVE_GUARD,
          last_sample - first_sample + 1),
      }
    end
    return {
      rate = cols / span_seconds,
      start = t0 * source.duration,
      count = cols,
    }
  end

  local function unpack(source, request, got)
    local min_base = source.channel_count * request.count
    local single_values = true
    for sample = 0, got - 1 do
      for channel = 0, source.channel_count - 1 do
        local index = sample * source.channel_count + channel
        local high = source.buffer[index + 1] or 0
        local low = source.buffer[min_base + index + 1] or 0
        if low ~= high then single_values = false end
        local output = source.channels[channel + 1]
        output.maxs[sample + 1], output.mins[sample + 1] = high, low
      end
    end
    if source.count > got then
      for channel = 1, source.channel_count do
        for sample = got + 1, source.count do
          source.channels[channel].maxs[sample] = nil
          source.channels[channel].mins[sample] = nil
        end
      end
    end
    return single_values
  end

  function reader.read(sound_id, t0, t1, cols)
    local source = current
    if not source or source.sound_id ~= sound_id then return nil end
    cols = columns(cols)
    if source.t0 == t0 and source.t1 == t1 and source.cols == cols then
      return source.channels, source.count, nil, source.metadata
    end
    if t1 - t0 <= 0 then return nil end

    local request = request_for(source, t0, t1, cols)
    source.buffer.clear()
    local packed = reaper.PCM_Source_GetPeaks(source.source, request.rate,
      request.start, source.channel_count, request.count, 0, source.buffer)
    if type(packed) ~= "number" or packed < 0 then
      return nil, nil, READ_ERROR
    end

    local got = packed & SAMPLE_COUNT_MASK
    local output_mode = (packed & OUTPUT_MODE_MASK) >> OUTPUT_MODE_SHIFT
    if got < 1 or got > request.count
      or (output_mode ~= PEAKS_MODE and output_mode ~= WAVEFORM_MODE) then
      return nil, nil, READ_ERROR
    end

    -- The waveform flag describes a drawing mode, not the number of source
    -- samples represented by each point. Never discard a returned peak range.
    local single_values = unpack(source, request, got)
    local samples = output_mode == WAVEFORM_MODE and source.sample_rate > 0
      and request.rate == source.sample_rate and single_values
    local metadata = {
      mode = samples and "samples" or "peaks",
      t0 = request.start / source.duration,
      step = 1 / (request.rate * source.duration),
      sample_rate = source.sample_rate,
    }
    source.t0, source.t1, source.cols = t0, t1, cols
    source.count, source.metadata = got, metadata
    return source.channels, got, nil, metadata
  end

  return reader
end

local detail = new_reader()
detail.new = new_reader

return detail
