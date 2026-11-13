local channels=require('core.analysis_channels')
local json=require('vendor.json')
local routing={}
local function integer(value,low,high)
  return type(value)=='number' and math.tointeger(value)~=nil and value>=low and value<=high
end

local function validate(outputs,count,available,partial)
  if type(outputs)~='table' or #outputs~=count or not integer(count,1,8) then
    return nil,'Choose one output channel for every speaker.'
  end
  local copy,seen={},{}
  for i=1,count do
    local output=outputs[i]
    if not integer(output,partial and 0 or 1,128) then return nil,'Choose output channels between 1 and 128.' end
    if output~=0 and seen[output] then return nil,'Choose a different output channel for each speaker.' end
    if available and output>available then return nil,'A selected output channel is unavailable. Choose an available channel.' end
    seen[output],copy[i]=true,output
  end
  return copy
end
function routing.map(outputs,count,available) return validate(outputs,count,available,false) end
function routing.selection(outputs,count) return validate(outputs,count,nil,true) end

function routing.automatic(count,sends,available)
  if type(sends)~='table' then return nil,'output_routing_unknown' end
  local sources,destinations={},{}
  for _,send in ipairs(sends) do
    local src,dst=send.source,send.destination
    if not integer(src,-1,(64<<10)|1023) then return nil,'output_routing_unknown' end
    if src~=-1 then
      if not integer(dst,0,2047) or (send.mono~=0 and send.mono~=1) then return nil,'output_routing_unknown' end
      local width=src>>10
      width=width==0 and 2 or width==1 and 1 or width*2
      local first,output=(src&1023)+1,(dst&1023)+1
      local summed=(dst&1024)~=0
      -- A mono source with a stereo destination does not establish one
      -- speaker output. Require an explicit choice rather than infer a side.
      local mono_to_stereo=width==1 and not summed
      local output_width=summed and 1 or math.max(2,width)
      if first+width-1>128 or output+output_width-1>128 then return nil,'output_routing_unknown' end
      for lane=0,width-1 do
        local source=first+lane
        sources[source]=sources[source] or {}
        -- Mono mixing combines both inputs on every destination lane. Even
        -- an extra send outside the layout can contaminate a selected output.
        local low,high=output+(summed and 0 or lane),output+(summed and 0 or lane)
        if send.mono==1 or mono_to_stereo then low,high=output,output+output_width-1 end
        for destination=low,high do
          sources[source][#sources[source]+1]=destination
          destinations[destination]=(destinations[destination] or 0)+1
        end
      end
    end
  end
  local outputs={}
  for i=1,count do
    local mapped=sources[i]
    if not mapped then return nil,'routing_incomplete' end
    if #mapped~=1 or destinations[mapped[1]]~=1 then return nil,'routing_mismatch' end
    if mapped[1]>available then return nil,'routing_incomplete' end
    outputs[i]=mapped[1]
  end
  return outputs
end

function routing.profile(layout,outputs)
  local map,err=routing.map(outputs,layout.count)
  if not map then return nil,err end
  local profile=assert(channels.profile(layout.count,channels.setting(layout)))
  profile.outputs=map
  profile.signature=profile.signature..':outputs:'..table.concat(map,',')
  return profile
end

function routing.partial(layout,available,sends,previous)
  if not integer(available,1,128) then return nil end
  -- Establish speaker/output pairs before discarding unavailable outputs.
  local full=routing.automatic(layout.count,sends,128) or routing.map(previous,layout.count)
  local roles,outputs,retained={},{},{}
  if full then
    for index,output in ipairs(full) do
      if output<=available then
        outputs[#outputs+1],roles[#roles+1]=output,layout.roles[index]
        retained[index]=#outputs
      end
    end
  end
  if #outputs==0 then
    -- Without an established association, only the output numbers are known.
    for index=1,math.min(layout.count,available) do
      outputs[index],roles[index]=index,'unknown'
    end
  end
  local left,right=retained[layout.pair_left],retained[layout.pair_right]
  local capture=assert(channels.profile(#outputs,{roles=roles,
    pair_left=left or 1,pair_right=right or math.min(2,#outputs),view=layout.view}))
  local profile=assert(routing.profile(capture,outputs))
  profile.pair_available=left~=nil and right~=nil
  profile.pair_signature='selected_pair:'..layout.pair_left..','..layout.pair_right
    ..':retained_pair:'..tostring(left or 0)..','..tostring(right or 0)
    ..':pair_available:'..tostring(profile.pair_available)
  return profile,full
end

function routing.effective(layout,available,mode,manual,sends)
  if not integer(available,0,128) then return nil,'output_routing_unknown' end
  if available==0 then return nil,'outputs_unavailable' end
  -- Availability includes Monitor FX channels beyond the physical device.
  -- Narrow only when that available mix is mono/stereo; keep saved speakers.
  if available<=2 and layout.count>available then
    local outputs={1}; if available==2 then outputs[2]=2 end
    return routing.profile(assert(channels.profile(available)),outputs),'device_fallback'
  end
  if mode=='manual' then
    local selected={}
    if type(manual)=='table' then for i=1,layout.count do selected[i]=manual[i] end end
    local outputs=routing.map(selected,layout.count,available)
    if not outputs then return nil,'output_selection_unavailable' end
    return routing.profile(layout,outputs)
  end
  local outputs,err=routing.automatic(layout.count,sends,available)
  if not outputs then
    -- Monitor FX receives the routed mix even when master sends duplicate or
    -- combine channels. Ambiguity limits inference, not the available capture.
    if available<layout.count then return nil,'outputs_unavailable' end
    outputs=routing.map(manual,layout.count,available)
    if not outputs then
      outputs={}
      for i=1,layout.count do outputs[i]=i end
    end
    return routing.profile(layout,outputs),'automatic_fallback'
  end
  return routing.profile(layout,outputs)
end

function routing.encode(identity,mode,outputs)
  if mode~='auto' and mode~='manual' then return nil,'This output selection is unavailable.' end
  local map,err=routing.selection(outputs,type(outputs)=='table' and #outputs or 0)
  if not map then return nil,err end
  return json.encode({version=1,identity=identity,mode=mode,outputs=map})
end

function routing.decode(text,identity)
  if not text or text=='' then return {mode='auto'} end
  local ok,record=pcall(json.decode,text)
  if not ok or type(record)~='table' then return nil,'Saved output settings are damaged. Reset the output selection.' end
  if record.version~=1 then return nil,'This version cannot read the saved output settings. Reset the output selection to replace them.' end
  if record.identity~=identity then return nil,'The saved output settings belong to another project.' end
  if record.mode~='auto' and record.mode~='manual' then return nil,'Saved output settings are damaged. Reset the output selection.' end
  local outputs=type(record.outputs)=='table' and routing.selection(record.outputs,#record.outputs)
  if not outputs then return nil,'Saved output settings are damaged. Reset the output selection.' end
  return {mode=record.mode,outputs=outputs}
end

function routing.evidence_valid(evidence)
  if type(evidence)~='table' or evidence.verified~=true
      or not integer(evidence.source_channels,1,128) then return false end
  if type(evidence.outputs)=='table' then return routing.map(evidence.outputs,#evidence.outputs)~=nil end
  return integer(evidence.output_first,1,128)
    and evidence.output_count==math.max(2,evidence.source_channels)
    and evidence.output_first+evidence.output_count-1<=128
end
function routing.evidence_overlaps(profile,evidence,available)
  if not routing.evidence_valid(evidence) then return false end
  local actual={}
  if evidence.outputs then for _,output in ipairs(evidence.outputs) do actual[output]=true end
  else for i=evidence.output_first,evidence.output_first+evidence.output_count-1 do actual[i]=true end end
  local selected={}
  for _,output in ipairs(profile.outputs) do selected[output]=true end
  for output in pairs(actual) do
    if (not available or output<=available) and not selected[output] then return false end
  end
  return true
end
return routing
