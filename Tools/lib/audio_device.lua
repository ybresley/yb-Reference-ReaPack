-- Only an explicit stopped audio engine proves suspension. Output counts and
-- window focus cannot distinguish a closed device from an actual routing limit.
local device = {}
function device.suspended(R)
  return type(R.Audio_IsRunning)=='function' and R.Audio_IsRunning()==0
end
return device
