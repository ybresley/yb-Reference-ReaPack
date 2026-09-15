-- Selection and demonstration time are local to one release window.
local tour = {}

function tour.available(content, installed, releases)
  if installed ~= content.version then return false end
  for _, release in ipairs(releases or {}) do
    if release.version == content.version then return true end
  end
  return false
end

function tour.new()
  return { feature = 1, topics = {}, elapsed = 0 }
end

function tour.reset_clock(value)
  value.elapsed, value.last_time = 0, nil
end

function tour.select_feature(value, content, index)
  if not content.features[index] or value.feature == index then return false end
  value.feature = index
  tour.reset_clock(value)
  return true
end

function tour.select_topic(value, content, index)
  local feature = content.features[value.feature]
  if not feature or not feature.topics[index] then return false end
  if (value.topics[value.feature] or 1) == index then return false end
  value.topics[value.feature] = index
  tour.reset_clock(value)
  return true
end

function tour.current(value, content)
  local feature = content.features[value.feature]
  return feature, feature.topics[value.topics[value.feature] or 1]
end

function tour.tick(value, now, animate)
  -- A hidden window must resume where it stopped, without skipping a demo step.
  if value.last_time and animate ~= false then
    value.elapsed = value.elapsed + math.max(0, math.min(0.1, now - value.last_time))
  end
  -- Keep the wall clock current while paused so re-enabling cannot jump ahead.
  value.last_time = now
  return value.elapsed
end

return tour
