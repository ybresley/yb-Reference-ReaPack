-- Release pictures use measured stereo pairs without opening audio capture.
local stereo = require('core.stereo')

local demo = {}
demo.duration = 4
demo.clear_at = 1.2
demo.customization_duration = 5.4

local alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local decode = {}
for i = 1, #alphabet do decode[alphabet:byte(i)] = i - 1 end

local function ease(value)
  value = math.max(0, math.min(1, value))
  return value * value * (3 - 2 * value)
end

local function mix(a, b, amount)
  return a + (b - a) * amount
end

local function packets_from_source(source)
  assert(type(source) == 'table' and type(source.sample_rate) == 'number'
    and source.sample_rate > 0 and type(source.packets) == 'table'
    and #source.packets > 0 and type(source.samples_per_packet) == 'number',
    'The stereo demonstration needs measured source packets.')
  local count = source.samples_per_packet
  local packets, previous_at = {}, -1
  for _, encoded in ipairs(source.packets) do
    assert(type(encoded.at) == 'number' and encoded.at > previous_at
      and encoded.at < demo.duration and type(encoded.data) == 'string'
      and #encoded.data == count * 4,
      'The stereo demonstration has an invalid capture.')
    local packet = {left={}, right={}, count=count, at=encoded.at}
    for i = 1, count do
      local first = (i - 1) * 4 + 1
      local a, b, c, d = encoded.data:byte(first, first + 3)
      assert(decode[a] and decode[b] and decode[c] and decode[d],
        'The stereo demonstration has an invalid sample.')
      packet.left[i] = ((decode[a] * 64 + decode[b]) - 2048) / 2047
      packet.right[i] = ((decode[c] * 64 + decode[d]) - 2048) / 2047
    end
    packets[#packets+1] = packet
    previous_at = encoded.at
  end
  return packets
end

function demo.new(source)
  return {packets=packets_from_source(source), sample_rate=source.sample_rate,
    model=stereo.new(), polar_model=stereo.new(), cycle=-1, last_packet=0, cleared=false}
end

function demo.scene(topic, elapsed)
  local duration = topic == 'stereo_customization' and demo.customization_duration or demo.duration
  local phase = math.max(0, elapsed or 0) % duration
  local result = {
    view=topic == 'stereo_polar' and 'polar_sample' or 'lissajous',
    phase=phase,
  }
  if topic == 'stereo_customization' then
    local from, to, start, travel
    if phase < .8 then from, to, start, travel = 'home', 'show_correlation', 0, .8
    elseif phase < 2.3 then from, to = 'show_correlation', 'show_correlation'
    elseif phase < 3 then from, to, start, travel = 'show_correlation', 'brightness_100', 2.3, .7
    elseif phase < 3.9 then from, to, start, travel = 'brightness_100', 'brightness_150', 3, .9
    else from, to = 'brightness_150', 'brightness_150' end
    result.from, result.to = from, to
    result.progress = from == to and 1 or ease((phase - start) / travel)
    result.show_correlation = phase >= .8
    if phase < 3 then result.brightness = 1
    elseif phase < 3.9 then result.brightness = mix(1, 1.5, result.progress)
    else result.brightness = 1.5 end
    result.brightness = math.floor(result.brightness*20+.5)/20
    result.grab = phase >= 3 and phase < 3.9
    if phase >= .8 and phase < 1.1 then
      result.click = (phase - .8) / .3
    end
    return result
  end
  if topic ~= 'stereo_clear' then return result end
  local start_x, start_y = .84, .81
  local target_x, target_y = .57, .55
  local amount
  if phase < .7 then amount = ease(phase / .7)
  elseif phase < 2.6 then amount = 1
  elseif phase < 3.35 then amount = 1 - ease((phase - 2.6) / .75)
  else amount = 0 end
  result.pointer_x = mix(start_x, target_x, amount)
  result.pointer_y = mix(start_y, target_y, amount)
  result.click = phase >= demo.clear_at and phase < demo.clear_at + .28
    and (phase - demo.clear_at) / .28 or nil
  return result
end

function demo.advance(value, topic, elapsed)
  elapsed = math.max(0, elapsed or 0)
  local cycle = math.floor(elapsed / demo.duration)
  local scene = demo.scene(topic, elapsed)
  if value.last_elapsed and elapsed < value.last_elapsed then
    value.model = stereo.new()
    value.polar_model = stereo.new()
    value.cycle, value.last_packet, value.cleared = -1, 0, false
  end
  if cycle ~= value.cycle then
    -- Replaying the same source keeps the scope's fading history across loops.
    value.cycle, value.last_packet, value.cleared = cycle, 0, false
  end
  value.last_elapsed = elapsed

  for index = value.last_packet + 1, #value.packets do
    local packet = value.packets[index]
    local at = packet.at + cycle * demo.duration
    -- Bootstrap the first picture immediately; later captures keep source time.
    if index > 1 and at > elapsed then break end
    if topic == 'stereo_clear' and not value.cleared
        and scene.phase >= demo.clear_at and packet.at >= demo.clear_at then
      stereo.clear_display(value.model)
      stereo.clear_display(value.polar_model)
      value.cleared = true
    end
    local capture = {
      count=packet.count, left=packet.left, right=packet.right,
      sequence=cycle * #value.packets + index, epoch=1, at=at,
      sample_rate=value.sample_rate,
    }
    local source = {
      source_key='release_stereo', epoch=1, playing=true,
      status='ready', now=at,
    }
    stereo.update(value.model, capture, source)
    if topic == 'stereo_overview' then stereo.update(value.polar_model, capture, source) end
    value.last_packet = index
  end
  if topic == 'stereo_clear' and scene.phase >= demo.clear_at
      and not value.cleared then
    stereo.clear_display(value.model)
    stereo.clear_display(value.polar_model)
    value.cleared = true
  end
  value.model.now = math.max(elapsed, value.packets[1].at + cycle * demo.duration)
  value.polar_model.now = value.model.now
  return scene
end

return demo
