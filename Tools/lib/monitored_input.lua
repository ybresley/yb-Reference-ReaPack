local input = {}
local SCAN_BUDGET, SCAN_INTERVAL = 64, 0.25

function input.new(R)
  local project, candidate, index, next_scan

  local function monitored(track)
    if not track or R.GetMediaTrackInfo_Value(track, 'B_RECMON_IN_EFFECT') ~= 1 then return false end
    if R.GetMediaTrackInfo_Value(track, 'B_MAINSEND') == 1 then return true end
    local sends = math.tointeger(R.GetTrackNumSends(track, 0))
    if sends and sends>0 then return true end
    local outputs=math.tointeger(R.GetTrackNumSends(track,1))
    return outputs~=nil and outputs>0
  end

  return function(current)
    if not current or not R.CountTracks or not R.GetTrack or not R.GetTrackNumSends
        or not R.GetMediaTrackInfo_Value or not R.time_precise then return false end
    if project ~= current then project, candidate, index, next_scan = current, nil, 0, nil end
    local count, now = math.tointeger(R.CountTracks(project)), R.time_precise()
    if not count or count < 0 then return false end
    -- Effective monitoring can change without a project edit. Check a known
    -- input immediately and bound the search for newly monitored tracks.
    if candidate and candidate < count and monitored(R.GetTrack(project, candidate)) then return true end
    if candidate then candidate, index, next_scan = nil, 0, nil end
    if next_scan and now < next_scan then return false end
    for i = index, math.min(count, index + SCAN_BUDGET) - 1 do
      if monitored(R.GetTrack(project, i)) then candidate = i; return true end
    end
    index = index + SCAN_BUDGET
    if index >= count then index, next_scan = 0, now + SCAN_INTERVAL end
    return false
  end
end

return input
