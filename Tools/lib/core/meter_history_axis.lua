local axis={}

-- Ticks belong to elapsed audio time, so their positions travel with the trace.
function axis.each(start,duration,width,visit)
  if duration<=0 or width<=0 then return end
  local interval=2
  local first=math.ceil(start/interval)
  local last=math.floor((start+duration)/interval)
  for index=first,last do
    local time=index*interval
    visit(time,(time-start)/duration*width)
  end
end

return axis
