local core=require('core.analysis_channels')
local layout_memory=require('core.analysis_layout_memory')
local arrangements=require('core.speaker_arrangements')
local route_status=require('core.analysis_route_status')
local audio_device=require('audio_device')
local output_routing=require('core.output_routing')
local channels={}
local SECTION='yb-Reference'
local AUDIO_PAUSE_NOTICE_DELAY=1

local function legacy_key(identity)
  -- Keep arbitrary filenames out of the INI key; verify the stored identity
  -- before using its settings, so a hash collision cannot mislabel speakers.
  local hash=0xcbf29ce484222325
  for i=1,#identity do hash=(hash ~ identity:byte(i))*0x100000001b3 end
  return 'analysis_channels_v1_'..string.format('%016x',hash)
end
local function key(identity)
  return legacy_key(identity):gsub('analysis_channels_v1_','analysis_channels_v3_')
end
local function same_profile(first,second)
  return first and second and first.signature==second.signature
    and first.pair_left==second.pair_left and first.pair_right==second.pair_right
    and first.view==second.view
end
local function same_outputs(first,second)
  if not first or not second or first.mode~=second.mode then return false end
  if first.mode=='auto' then return true end
  if #(first.outputs or {})~=#(second.outputs or {}) then return false end
  for index,value in ipairs(first.outputs or {}) do
    if value~=second.outputs[index] then return false end
  end
  return true
end

-- The Surround Field's filled outline needs a native point buffer; UI modules
-- make no non-ImGui REAPER calls, so the live field and the release
-- demonstration both get theirs here.
function channels.new_outline_points(R)
  return R.new_array and R.new_array(256) or nil
end

function channels.new(R,preview_adapter)
  local self={}
  local has_monitored_input=require('monitored_input').new(R)
  local current,pause_project,pause_started
  local unsaved_settings={}
  local unsaved_outputs={}
  local sessions,latest_layouts={},{}
  local function output_key(identity) return legacy_key(identity):gsub('analysis_channels_v1_','analysis_outputs_v1_') end
  local function read_settings(identity,persist)
    if not persist then return unsaved_settings[identity] or '' end
    local text=R.GetExtState(SECTION,key(identity))
    -- Older copies share ExtState but cannot read this format. Keep their last
    -- choice intact, and never hide an unreadable newer record behind it.
    if text=='' then text=R.GetExtState(SECTION,legacy_key(identity)) end
    return text
  end
  local function clear_field(state)
    state.surround_channels,state.surround_channel_signature=nil,nil
  end
  local function unassigned(count)
    count=type(count)=='number' and count==count and count<math.huge
      and math.max(1,math.min(8,math.floor(count))) or 2
    local roles={}
    for i=1,count do roles[i]='unknown' end
    return assert(core.profile(count,{roles=roles}))
  end
  local function publish_status(state,profile,err,explicit_count,preserve_capture)
    current.explicit_count=explicit_count
    local limited=current.project and current.detected_count>8
    local missing=current.project and profile.count>current.detected_count
    state.analysis_channels=profile
    state.analysis_channel_error=err
    current.profile_blocked=err~=nil or missing or (limited and not explicit_count)
    state.analysis_channel_profile_blocked=current.profile_blocked
    state.analysis_channel_blocked=current.profile_blocked
    state.analysis_channel_route_only=false
    state.analysis_channel_limit_warning=missing
      and string.format('The saved arrangement uses %d channels; this project now has %d. Choose an arrangement that fits the project output.',profile.count,current.detected_count)
      or limited and state.analysis_channel_blocked
        and string.format('Analysis is paused. This project has %d channels; choose a speaker arrangement of up to eight channels.',current.detected_count)
      or profile.count<current.detected_count
        and string.format('The selected layout uses the first %d of the master’s %d channels.',profile.count,current.detected_count) or nil
    state.analysis_channel_suggestion=nil
    local unassigned=true
    for _,role in ipairs(profile.roles) do if role~='unknown' then unassigned=false; break end end
    if not err and unassigned and current.detected_count<=8 then
      local suggestion=latest_layouts[current.detected_count]
      if not suggestion then
        local item,order=arrangements.get(({[4]='quad',[6]='5.1',[8]='7.1'})[current.detected_count])
        if item then suggestion=assert(core.profile(item.count,{roles=order.roles})) end
      end
      if suggestion then
        local item,order=arrangements.identify(suggestion.roles)
        state.analysis_channel_suggestion={arrangement=item.id,order=order.id,
          profile=assert(core.profile(suggestion.count,core.setting(suggestion)))}
      end
    end
    if not preserve_capture then clear_field(state) end
  end
  local function remember(profile,count)
    if profile and profile.known and profile.count==count and arrangements.identify(profile.roles) then
      latest_layouts[count]=assert(core.profile(profile.count,{roles=profile.roles}))
    end
  end
  local function retire_changed_transfer(session,text)
    if session.transfer_text and text~='' and text~=session.transfer_text then
      session.transfer_memory,session.transfer_error,session.transfer_text=nil,nil,nil
      return true
    end
    return false
  end
  local function load(state,identity,count,title,project,persist,session,force)
    if current and current.identity==identity and current.detected_count==count
        and current.session==session and not force then return end
    local text=read_settings(identity,persist)
    retire_changed_transfer(session,text)
    local memory,err=layout_memory.decode(text,identity)
    if session.transfer_memory and not err then memory=session.transfer_memory end
    local profile,explicit_count
    if memory then profile,err,explicit_count=layout_memory.profile(memory,count) end
    local output_text=persist and R.GetExtState(SECTION,output_key(identity)) or unsaved_outputs[identity]
    local output_setting,output_error=output_routing.decode(output_text,identity)
    local previous=current
    -- Saving a live project changes its filename, not the audio we measured.
    local preserve_capture=previous and previous.identity~=identity and previous.session==session
      and previous.detected_count==count and not err and not output_error and not previous.output_error
      and not state.analysis_channel_blocked and state.analysis_output_profile~=nil
      and same_profile(state.analysis_channels,profile) and same_outputs(previous.output_setting,output_setting)
    current={identity=identity,detected_count=count,title=title,project=project,persist=persist,
      memory=memory,session=session}
    session.memory,session.error=memory,err
    current.output_setting,current.output_error=output_setting,output_error
    if preserve_capture then
      current.last_output_map,current.last_output_map_known=previous.last_output_map,previous.last_output_map_known
      current.output_project,current.output_master=previous.output_project,previous.output_master
    end
    -- Audio closure can return before routing runs. Never retain another
    -- context's output geometry while waiting for the device to return.
    if not preserve_capture then
      state.analysis_output_profile,state.analysis_output_map,state.analysis_output_notice=nil,nil,nil
      state.analysis_output_reason=nil
      state.analysis_output_mode=current.output_setting and current.output_setting.mode or 'auto'
      state.analysis_output_error=current.output_error
      state.analysis_output_available_count=0
      state.preview_analysis_profile,state.analysis_preview_partial=nil,nil
      state.analysis_preview_output_notice,state.analysis_preview_mixed=nil,nil
      state.analysis_channel_route_warning,state.analysis_channel_route_reason=nil,nil
      state.analysis_channel_route_checking=false
      state.analysis_live_input,state.analysis_project_stopped=false,false
    end
    state.analysis_channel_save_error=session.transfer_error
    publish_status(state,profile or unassigned(count),err,explicit_count,preserve_capture)
    if explicit_count and not err then remember(profile,count) end
    state.analysis_channel_source=title
    state.analysis_channel_project=project
    state.analysis_channel_available_count=count
  end
  local function update_outputs(state,master,project,available)
    local layout=state.analysis_channels
    local setting=current.output_setting or {mode='auto'}
    if current.output_project~=project or current.output_master~=master then
      current.last_output_map,current.last_output_map_known=nil,nil
      current.output_project,current.output_master=project,master
    end
    state.analysis_output_mode=setting.mode
    state.analysis_output_error=current.output_error
    state.analysis_output_available_count=type(available)=='number' and math.tointeger(available) and available>=0 and available<=128 and available or 0
    local revision
    if R.GetProjectStateChangeCount then
      local ok,value=pcall(R.GetProjectStateChangeCount,project)
      if ok and type(value)=='number' and math.tointeger(value) and value>=0 then revision=value end
    end
    local cached=current.output_cache
    local measured,why,partial
    if revision and cached and cached.revision==revision and cached.available==available
        and cached.project==project and cached.master==master
        and cached.layout==layout and cached.setting==setting then
      measured,why,partial=cached.profile,cached.reason,cached.partial
    else
      local sends
      if setting.mode=='auto' and master and R.GetTrackNumSends and R.GetTrackSendInfo_Value then
        local ok,result=pcall(function()
          local count=R.GetTrackNumSends(master,1)
          if type(count)~='number' or not math.tointeger(count) or count<0 or count>128 then return end
          local found={}
          for index=0,count-1 do
            found[#found+1]={source=R.GetTrackSendInfo_Value(master,1,index,'I_SRCCHAN'),
              destination=R.GetTrackSendInfo_Value(master,1,index,'I_DSTCHAN'),
              mono=R.GetTrackSendInfo_Value(master,1,index,'B_MONO')}
          end
          return found
        end)
        if ok then sends=result end
      end
      local selected=setting.mode=='auto' and current.last_output_map or setting.outputs
      local previous_known=setting.mode=='auto' and current.last_output_map_known and selected~=nil
      measured,why=output_routing.effective(layout,available,setting.mode,selected,sends)
      if measured and measured.count==layout.count then
        current.last_output_map=measured.outputs
        current.last_output_map_known=setting.mode=='auto' and (why==nil or previous_known)
      elseif why=='outputs_unavailable' and setting.mode=='auto' then
        local full
        partial,full=output_routing.partial(layout,available,sends,previous_known and selected or nil)
        if full then current.last_output_map,current.last_output_map_known=full,true end
      end
      current.output_cache=revision and {revision=revision,available=available,layout=layout,
        project=project,master=master,setting=setting,profile=measured,reason=why,partial=partial} or nil
    end
    if current.output_error then measured,why=nil,'output_settings_unreadable' end
    state.analysis_output_profile=measured
    state.analysis_output_reason=why
    state.analysis_output_map=setting.mode=='manual' and setting.outputs or measured and measured.outputs
    state.analysis_output_notice=why=='device_fallback' and (measured.count==2
      and 'Measuring Stereo Output (2 Channels)' or 'Measuring Mono Output (1 Channel)')
      or why=='automatic_fallback' and 'Output routing is mixed or unavailable. Measuring outputs '..table.concat(measured.outputs,', ')..'. Choose outputs in Audio settings if needed.' or nil
    if measured then return measured end
    return nil,why=='output_routing_unknown' and 'routing_unknown' or why,partial
  end
  local function check_routing(state,master,project,preparing_preview,evidence,refresh_suspended)
    local profile=state.analysis_channels
    state.analysis_audio_suspended=audio_device.suspended(R)
    state.analysis_audio_pause_notice=false
    local play_state=project and R.GetPlayStateEx and R.GetPlayStateEx(project)
    local playback_known=type(play_state)=='number' and play_state>=0
      and play_state<math.huge and play_state==math.floor(play_state)
    local transport_active=playback_known and (play_state&5)~=0
    local preview_active=preparing_preview or state.preview and state.preview.playing
    local reference_latched=state.reference and state.reference.latched
    if state.analysis_audio_suspended then
      if transport_active or preview_active or (not reference_latched and has_monitored_input(project)) then
        local now=R.time_precise()
        if pause_project~=project or not pause_started then pause_project,pause_started=project,now end
        state.analysis_audio_pause_notice=now-pause_started>=AUDIO_PAUSE_NOTICE_DELAY
      else pause_project,pause_started=nil,nil end
      -- The audio engine cannot publish new readings while closed. Keep the
      -- last measured profile, field and routing status for the unchanged source.
      if not refresh_suspended then return end
    end
    if not state.analysis_audio_suspended then pause_project,pause_started=nil,nil end
    state.analysis_preview_mixed=nil
    state.analysis_preview_output_notice=nil
    state.analysis_live_input=false
    state.analysis_project_stopped=false
    state.analysis_channel_route_checking=false
    -- Capture the selected outputs without requiring an unchanged master mix.
    local project_source=not preview_active and not reference_latched
    state.analysis_project_stopped=project_source and play_state==0
    state.analysis_live_input=project_source and playback_known and not transport_active
      and has_monitored_input(project)
    -- This count includes the configured Monitor FX width. It does not prove
    -- how many channels the physical device can play.
    -- An explicit edit can change capture meaning while the engine is closed.
    -- Reuse its last verified availability, including fallback and partial lanes.
    local outputs=state.analysis_audio_suspended and refresh_suspended and state.analysis_output_available_count
      or R.GetNumAudioOutputs and R.GetNumAudioOutputs()
    local measured,reason,partial=update_outputs(state,master,project,outputs)
    local ok=measured~=nil
    if project_source and not playback_known then ok,reason=nil,'routing_unknown' end
    state.analysis_channel_route_warning=not ok and (current.output_error or route_status.project[reason]
      or 'The selected outputs are unavailable. Choose an available output for every speaker in Audio settings.') or nil
    state.analysis_channel_route_reason=not ok and reason or nil
    state.analysis_channel_route_checking=reason=='routing_checking'
    state.analysis_channel_blocked=current.profile_blocked or not ok
    state.analysis_channel_route_only=project_source and not current.profile_blocked and not ok
    state.preview_analysis_profile,state.analysis_preview_partial=nil,nil
    if not preparing_preview and state.preview and state.preview.playing
        and preview_adapter and preview_adapter.analysis_evidence then
      evidence=preview_adapter.analysis_evidence()
    end
    local ref=state.reference or {}
    local verified_master_muted=ref.latched and ref.live and not ref.pending and master
      and R.GetMediaTrackInfo_Value(master,'B_MUTE')==1
    if not current.profile_blocked and preview_active and (preview_adapter or evidence) then
      local outputs_known=type(outputs)=='number' and outputs>=0 and outputs<=128
        and outputs==math.floor(outputs)
      local reference_reason,warning
      if current.output_error or reason=='output_selection_unavailable' then
        reference_reason=reason
        warning=current.output_error or 'The selected outputs are unavailable. Choose an available output for every speaker in Audio settings.'
      elseif not playback_known or ref.latched and not verified_master_muted then
        reference_reason=playback_known and 'reference_not_isolated' or 'routing_unknown'
      elseif not outputs_known or not output_routing.evidence_valid(evidence) then
        reference_reason='reference_route_unverified'
      elseif outputs==0 then
        reference_reason='outputs_unavailable'
      else
        -- Other projects and direct outputs may be audible at any time. A
        -- stereo reference must not hide them on the selected rear outputs.
        local capture=measured or partial
        if not capture then reference_reason=reason or 'outputs_unavailable'
        else
          state.analysis_preview_mixed=true
          state.analysis_output_profile=capture
          state.analysis_output_map=capture.outputs
          if capture.count<profile.count then
            state.preview_analysis_profile,state.analysis_preview_partial=capture,true
          end
          if not output_routing.evidence_overlaps(capture,evidence) then
            state.analysis_preview_output_notice='Some reference channels are outside the measured outputs.'
          end
        end
      end
      state.analysis_channel_blocked=reference_reason~=nil
      state.analysis_channel_route_reason=reference_reason
      state.analysis_channel_route_checking=reference_reason=='routing_checking'
      state.analysis_channel_route_warning=warning or route_status.reference[reference_reason]
        or route_status.project[reference_reason]
    end
  end
  local function load_project(state,preparing_preview,evidence,refresh_suspended)
    local project,path=R.EnumProjects(-1)
    path=path or ''
    local master=project and R.GetMasterTrack(project)
    local count=master and R.GetMediaTrackInfo_Value(master,'I_NCHAN') or 2
    local identity='project:'..(path~='' and path or tostring(project))
    -- Only a still-open project with the same master can carry choices through
    -- Save As. A closed tab's handle may later belong to a different project.
    local open={}
    for index=0,1023 do
      local item=R.EnumProjects(index)
      if not item then break end
      open[item]=true
    end
    open[project or false]=true
    for handle,session in pairs(sessions) do
      if not open[handle] or R.ValidatePtr2 and not R.ValidatePtr2(0,handle,'ReaProject*') then
        unsaved_settings[session.identity],unsaved_outputs[session.identity]=nil,nil
        sessions[handle]=nil
      end
    end
    local handle=project or false
    local session=sessions[handle]
    if session and session.master~=master then
      unsaved_settings[session.identity],unsaved_outputs[session.identity]=nil,nil
      session=nil
    end
    if not session then session={identity=identity,master=master,persist=path~=''}; sessions[handle]=session end
    local transition_error
    if session.identity~=identity then
      if session.transfer_memory then
        local previous=read_settings(session.identity,session.persist)
        if retire_changed_transfer(session,previous) then
          session.memory,session.error=layout_memory.decode(previous,session.identity)
        end
      end
      local source=session.memory
      local destination=read_settings(identity,path~='')
      if source and (not session.error or session.transfer_memory) and next(source.layouts) and destination=='' then
        local text,memory=layout_memory.encode(source,identity)
        session.transfer_memory,session.transfer_error,session.transfer_text=nil,nil,nil
        if path~='' then
          R.SetExtState(SECTION,key(identity),text,true)
          if R.GetExtState(SECTION,key(identity))~=text then
            transition_error="Couldn't save channel settings."
            session.transfer_memory,session.transfer_error=memory,transition_error
            session.transfer_text=text
          end
        else unsaved_settings[identity]=text end
      else session.transfer_memory,session.transfer_error,session.transfer_text=nil,nil,nil end
      if not session.persist then
        unsaved_settings[session.identity],unsaved_outputs[session.identity]=nil,nil
      end
      session.identity=identity
      session.persist=path~=''
    end
    load(state,identity,count,'Project Output',true,path~='',session,transition_error)
    check_routing(state,master,project,preparing_preview,evidence,refresh_suspended)
  end
  function self:prepare(state,evidence)
    -- Preview preparation runs before audio starts. Its file width must not
    -- replace the project's speaker layout or its saved scope choices.
    load_project(state,true,evidence)
    clear_field(state)
  end
  function self:tick(state)
    load_project(state)
  end
  function self:capture(state)
    local model=state.metering
    local profile=state.preview_analysis_profile or state.analysis_output_profile or state.analysis_channels
    local signature=current and tostring(current.session)..':'..(profile and profile.signature or '')
      ..':'..tostring(model and model.source_key or '')
    if signature~=state.surround_channel_signature then clear_field(state) end
    if state.analysis_audio_suspended then return end
    if not profile or state.analysis_channel_blocked then clear_field(state); return end
    if state.stereo and state.stereo.frozen then return end
    local values=model and (model.field_channels or model.values and model.values.channels)
    if not values or model.error then state.surround_channels=nil return end
    -- The field's filled outline needs a native point buffer. Allocate it once
    -- here because UI modules make no non-ImGui REAPER calls.
    if not state.surround_outline_points then
      state.surround_outline_points=channels.new_outline_points(R)
    end
    local copy={}
    for i=1,profile.count do
      copy[i]={rms=values[i] and (values[i].field_rms or values[i].rms),
        peak=values[i] and values[i].warning_peak}
    end
    -- Pairs are numbered for a channel count. During a layout change the meter
    -- can still report the previous count; those pairs would land on the wrong sides.
    local pairs_in=values.correlations
    if pairs_in and #pairs_in==profile.count*(profile.count-1)//2 then copy.correlations=pairs_in end
    state.surround_channels,state.surround_channel_signature=copy,signature
  end
  function self:apply(state,action)
    if not current then return nil,'No analysis source is available.' end
    local session=current.session
    if session.transfer_memory and retire_changed_transfer(session,read_settings(current.identity,current.persist)) then
      -- A new destination record owns this path. Refresh before interpreting
      -- the queued action so it cannot overwrite choices from another copy.
      load(state,current.identity,current.detected_count,current.title,current.project,current.persist,session,true)
      load_project(state)
      return nil,'The saved channel settings changed. Your last change was not applied.'
    end
    if action.key=='save_retry' then
      if not session.transfer_memory or not session.transfer_text then
        return nil,'No channel settings are waiting to be saved.'
      end
      local text=session.transfer_text
      R.SetExtState(SECTION,key(current.identity),text,true)
      session.transfer_error=R.GetExtState(SECTION,key(current.identity))~=text
        and "Couldn't save channel settings." or nil
      state.analysis_channel_save_error=session.transfer_error
      if session.transfer_error then return nil,session.transfer_error end
      session.transfer_memory,session.transfer_text=nil,nil
      return true
    end
    if action.key=='output_mode' or action.key=='output' or action.key=='output_reset' then
      if current.output_error and action.key~='output_reset' then return nil,current.output_error end
      if action.key=='output_reset' then
        if current.persist then
          local destination=output_key(current.identity)
          R.SetExtState(SECTION,destination,'',true)
          if R.GetExtState(SECTION,destination)~='' then return nil,"Couldn't save output settings." end
        else unsaved_outputs[current.identity]=nil end
        current.output_setting,current.output_error,current.last_output_map={mode='auto'},nil,nil
        load_project(state,nil,nil,true)
        return true
      end
      local previous=current.output_setting or {mode='auto'}
      local mode=action.key=='output_mode' and action.value or previous.mode
      local outputs={}
      local count=state.analysis_channels.count
      local initial=previous.outputs or state.analysis_output_map or {}
      local stored_count=math.max(count,#initial)
      for i=1,stored_count do outputs[i]=initial[i] or 0 end
      if action.key=='output' then
        if type(action.channel)~='number' or math.tointeger(action.channel)==nil
            or action.channel<1 or action.channel>count then return nil,'This speaker is unavailable.' end
        if type(action.value)~='number' or math.tointeger(action.value)==nil
            or action.value<0 or action.value>128 then return nil,'Choose output channels between 1 and 128.' end
        mode='manual'
        -- Swap assigned outputs so changing order never creates a temporary duplicate.
        for i=1,stored_count do
          if action.value~=0 and i~=action.channel and outputs[i]==action.value then outputs[i]=outputs[action.channel] end
        end
        outputs[action.channel]=action.value
      end
      local text,err=output_routing.encode(current.identity,mode,outputs)
      if not text then return nil,err end
      if current.persist then
        local destination=output_key(current.identity)
        R.SetExtState(SECTION,destination,text,true)
        if R.GetExtState(SECTION,destination)~=text then return nil,"Couldn't save output settings." end
      else unsaved_outputs[current.identity]=text end
      current.output_setting,current.output_error={mode=mode,outputs=outputs},nil
      load_project(state,nil,nil,true)
      return true
    end
    if state.analysis_channel_error and action.type~='analysis_channels_reset' then
      return nil,state.analysis_channel_error
    end
    if current.profile_blocked and not state.analysis_channel_error
        and action.key~='count' and action.key~='arrangement' and action.key~='suggestion'
        and action.type~='analysis_channels_reset' then
      return nil,'Choose a speaker arrangement before assigning individual channels.'
    end
    local old=state.analysis_channels
    local setting=core.setting(old)
    local count=old.count
    if action.type=='analysis_channels_reset' then
      setting={} count=math.min(8,current.detected_count)
    elseif action.key=='suggestion' then
      local suggestion=state.analysis_channel_suggestion
      if not suggestion or suggestion.profile.count~=current.detected_count then
        return nil,'This speaker arrangement or channel order is unavailable.'
      end
      setting=core.setting(suggestion.profile)
      count=suggestion.profile.count
      setting.view=old.view
      setting.pair_left,setting.pair_right=1,math.min(2,count)
      for index,role in ipairs(setting.roles) do
        if role=='L' then setting.pair_left=index end
        if role=='R' then setting.pair_right=index end
      end
    elseif action.key=='arrangement' or action.key=='order' then
      local item,order
      if action.key=='arrangement' then item,order=arrangements.get(action.value)
      else
        local previous=arrangements.identify(old.roles)
        if previous then item,order=arrangements.get(previous.id,action.value) end
      end
      if not item then return nil,'This speaker arrangement or channel order is unavailable.' end
      if (not current.project and item.count~=current.detected_count)
          or (current.project and item.count>current.detected_count) then
        return nil,'This arrangement does not match the available source channels.'
      end
      count=item.count
      setting.roles=order.roles
      -- Follow the same inspected speakers when an order changes. A new
      -- arrangement starts with its front pair, even in Film order.
      local left=action.key=='order' and old.roles[old.pair_left] or 'L'
      local right=action.key=='order' and old.roles[old.pair_right] or 'R'
      setting.pair_left,setting.pair_right=1,math.min(2,count)
      for i,role in ipairs(order.roles) do
        if role==left then setting.pair_left=i end
        if role==right then setting.pair_right=i end
      end
      if count~=old.count then setting.view=count>2 and 'surround' or 'pair' end
    elseif action.key=='preset' then setting.roles=action.value
    elseif action.key=='role' then
      count=current.project and math.min(current.detected_count,8) or count
      if type(action.channel)~='number' or action.channel~=math.floor(action.channel)
          or action.channel<1 or action.channel>count then
        return nil,'This source channel is unavailable.'
      end
      -- Custom assignments cover the master, including channels outside a
      -- selected preset. Unassigned roles keep the extra channels explicit.
      for i=old.count+1,count do setting.roles[i]='unknown' end
      -- Swapping assignments avoids a transient duplicate and lets channel
      -- order be corrected without first unassigning every speaker.
      for i=1,count do
        if i~=action.channel and setting.roles[i]==action.value and action.value~='unknown' then
          setting.roles[i]=setting.roles[action.channel]
        end
      end
      setting.roles[action.channel]=action.value
    elseif action.key=='count' and current.project then
      if type(action.value)~='number' or action.value>current.detected_count then
        return nil,'The custom arrangement exceeds the available source channels.'
      end
      count=action.value setting={}
    elseif action.key=='pair_left' or action.key=='pair_right' or action.key=='view' then
      setting[action.key]=action.value
    else return nil,'This channel setting is unavailable.' end
    local profile,err=core.profile(count,setting)
    if not profile then return nil,err end
    local reset=action.type=='analysis_channels_reset'
    local memory=current.memory or assert(layout_memory.decode('',current.identity))
    local text,next_memory
    text,next_memory=layout_memory.encode(memory,current.identity,current.detected_count,not reset and profile or nil)
    err=not text and next_memory or nil
    if not text then return nil,err end
    if current.persist then
      R.SetExtState(SECTION,key(current.identity),text,true)
      if R.GetExtState(SECTION,key(current.identity))~=text then return nil,"Couldn't save channel settings." end
    else unsaved_settings[current.identity]=text end
    current.memory=next_memory
    current.session.memory,current.session.error=next_memory,nil
    current.session.transfer_memory,current.session.transfer_error,current.session.transfer_text=nil,nil,nil
    state.analysis_channel_save_error=nil
    remember(not reset and profile or nil,current.detected_count)
    publish_status(state,profile,nil,not reset)
    load_project(state,nil,nil,true)
    return true
  end
  return self
end
return channels
