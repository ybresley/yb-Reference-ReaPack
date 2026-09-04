-- wave_detail: keeps one PCM source for the selected Reference View waveform and reads
-- only the visible slice at roughly one peak pair per screen column.

local detail = {}

local SAMPLE_COUNT_MASK = 0xFFFFF
local CAPACITY = 4096
local current

local function close_current()
  if current then
    reaper.PCM_Source_Destroy(current.source)
    current = nil
  end
end

function detail.close()
  close_current()
end

function detail.open(sound_id, path)
  close_current()
  local source = reaper.PCM_Source_CreateFromFile(path)
  if not source then return false end
  local duration = reaper.GetMediaSourceLength(source) or 0
  local channel_count = reaper.GetMediaSourceNumChannels(source) or 0
  if duration <= 0 or channel_count < 1 then
    reaper.PCM_Source_Destroy(source)
    return false
  end
  current = {
    sound_id = sound_id, source = source, duration = duration,
    channel_count = channel_count, capacity = CAPACITY,
    buffer = reaper.new_array(channel_count * CAPACITY * 2),
    channels = {}, count = 0, t0 = nil, t1 = nil, cols = 0,
  }
  for c = 1, channel_count do current.channels[c] = { mins = {}, maxs = {} } end
  return true
end

function detail.read(sound_id, t0, t1, cols)
  local source = current
  if not source or source.sound_id ~= sound_id then return nil end
  cols = math.max(1, math.min(source.capacity, math.floor(cols or 1)))
  if source.t0 == t0 and source.t1 == t1 and source.cols == cols then
    return source.channels, source.count
  end
  local span = t1 - t0
  if span <= 0 then return nil end
  source.buffer.clear()
  local packed = reaper.PCM_Source_GetPeaks(source.source, cols / (span * source.duration),
    t0 * source.duration, source.channel_count, cols, 0, source.buffer)
  if type(packed) ~= "number" or packed < 0 then
    return nil, nil, "Waveform detail couldn't be read."
  end
  local got = packed & SAMPLE_COUNT_MASK
  if got < 1 then return nil, nil, "Waveform detail couldn't be read." end
  local min_base = source.channel_count * cols
  local previous = source.cols
  for sample = 0, cols - 1 do
    for channel = 0, source.channel_count - 1 do
      local hi, lo = 0, 0
      if sample < got then
        local index = sample * source.channel_count + channel
        hi = source.buffer[index + 1] or 0
        lo = source.buffer[min_base + index + 1] or 0
      end
      local out = source.channels[channel + 1]
      out.maxs[sample + 1], out.mins[sample + 1] = hi, lo
    end
  end
  if previous > cols then
    for channel = 1, source.channel_count do
      for sample = cols + 1, previous do
        source.channels[channel].maxs[sample] = nil
        source.channels[channel].mins[sample] = nil
      end
    end
  end
  source.t0, source.t1, source.cols, source.count = t0, t1, cols, got
  return source.channels, got
end

return detail
