-- Retires unchanged project objects left by the removed meter connection.
-- Ownership is read from the old record; this module never creates a connection.
local M = {}
local json = require('vendor.json')
local MARKER = 'P_EXT:ybReferenceVirtualMaster'
local RECORD = 'P_EXT:ybReferenceVirtualMasterRecord'
local NAME = 'yb-Reference Virtual Master (session)'
local IDENT = 'yb-Reference/yb-Reference_Virtual_Master.jsfx'
local MAX_MASTER_SENDS = 16
local TRACK_VALUES = { B_MAINSEND=0, I_RECMODE=2, I_FXEN=1, B_SOLO_DEFEAT=1,
  D_VOL=1, D_PAN=0, B_MUTE=0, I_SOLO=0, I_FOLDERDEPTH=0 }
local RECORD_KEYS = {version=true,owner=true,marker=true,guid=true,fx_guid=true,token=true,
  start=true,width=true,count=true,armed=true,fx_name=true,fx_rename=true,envelope_signature=true}
local REASONS = {project_list_limit=true,inspection_failed=true,record_changed=true,
  track_unavailable=true,multiple_tracks=true,track_changed=true,effect_changed=true,
  unexpected_send=true,orphan_send=true,send_ambiguous=true,unmarked_send=true,send_changed=true,
  cleanup_interrupted=true,send_delete_failed=true,track_delete_failed=true,project_changed=true,
  send_limit=true}

local function integer(n) return type(n)=='number' and n==math.floor(n) and n<math.huge end
local function need(ok,reason) if not ok then error(reason,0) end end
local function string_value(R,t,key)
  local ok,value=R.GetSetMediaTrackInfo_String(t,key,'',false)
  need(type(value)=='string' and (ok or ((key==MARKER or key==RECORD) and value=='')),'inspection_failed')
  return value
end

function M.new(R)
  local self,finished,scan = {},{},nil
  local last_problem,grant_revoked,grant_attempted,grant_failure_problem
  local project_open
  local function problem(reason,s,t,number,send)
    local p={reason=reason,project=s and s.project,track=t,track_number=number,send_number=send}
    local checked,project_live=pcall(project_open,p.project)
    local track_live
    if checked and project_live and t then
      local ok,guid,valid=pcall(function()
        if R.ValidatePtr2(p.project,t,'MediaTrack*') then return R.GetTrackGUID(t),true end
      end)
      if ok then p.track_guid,track_live=guid,valid end
    end
    if checked and project_live and type(R.GetProjectName)=='function' then
      local ok,a,b=pcall(R.GetProjectName,p.project)
      if ok then p.project_name=type(b)=='string' and b or type(a)=='string' and a or nil end
    end
    if track_live and type(R.GetTrackName)=='function' then
      local ok,a,b=pcall(R.GetTrackName,t)
      if ok then p.track_name=type(b)=='string' and b or type(a)=='string' and a or nil end
    end
    return p
  end
  local function owner_free()
    local owner=R.GetExtState('yb-Reference','virtual_master_owner_v1')
    need(type(owner)=='string','inspection_failed')
    if owner~='' then
      -- A later legacy session can publish a new grant. Its departure needs
      -- a fresh revocation before any consumer may read the shared input again.
      grant_revoked,grant_attempted=nil,nil
      scan=nil
      if last_problem==grant_failure_problem then last_problem=nil end
      grant_failure_problem=nil
      return false
    end
    return true
  end
  local function open_projects()
    local projects={}
    for i=0,127 do
      local p=R.EnumProjects(i,'')
      if not p then return projects end
      projects[#projects+1]=p
    end
    -- A truncated project list cannot establish which retained pointers are live.
    error('project_list_limit',0)
  end
  project_open=function(project)
    for _,p in ipairs(open_projects()) do if p==project then return true end end
    return false
  end
  local function ready(s)
    return project_open(s.project) and owner_free() and R.GetPlayStateEx(s.project)==0
  end
  local function read_record(s)
    need(R.ValidatePtr2(s.project,s.track,'MediaTrack*'),'track_unavailable')
    local raw=string_value(R,s.track,RECORD)
    local ok,r=pcall(json.decode,raw)
    need(ok and type(r)=='table','record_changed')
    for key in pairs(r) do need(RECORD_KEYS[key],'record_changed') end
    need(r.version==1 and type(r.owner)=='string' and r.owner~=''
      and type(r.guid)=='string' and r.guid~='' and type(r.fx_guid)=='string' and r.fx_guid~=''
      and type(r.marker)=='string' and type(r.fx_name)=='string' and type(r.fx_rename)=='string'
      and type(r.armed)=='boolean' and type(r.envelope_signature)=='string' and r.envelope_signature~=''
      and integer(r.token) and r.token>0 and r.token<=999999999
      and integer(r.width) and r.width>=2 and r.width<=8 and r.width%2==0
      and integer(r.count) and r.count>=2 and r.count<=r.width
      and integer(r.start) and r.start>=768 and r.start%2==0 and r.start+r.width<=1024,'record_changed')
    local owner,guid,start,width=r.marker:match('^v1|([^|]+)|([^|]+)|([^|]+)|([^|]+)$')
    need(owner==r.owner and guid==r.guid and tonumber(start)==r.start and tonumber(width)==r.width
      and string_value(R,s.track,MARKER)==r.marker and R.GetTrackGUID(s.track)==r.guid,'record_changed')
    need(not s.raw or s.raw==raw,'record_changed')
    s.raw,s.record=raw,r
    return r
  end
  local function verify_track(s)
    local r=read_record(s)
    need(string_value(R,s.track,'P_NAME')==NAME,'track_changed')
    need(R.CountTrackMediaItems(s.track)==0 and R.CountTrackEnvelopes(s.track)==0,'track_changed')
    for _,category in ipairs({-1,0,1}) do
      need(R.GetTrackNumSends(s.track,category)==0,'track_changed')
    end
    for key,value in pairs(TRACK_VALUES) do
      need(R.GetMediaTrackInfo_Value(s.track,key)==value,'track_changed')
    end
    for key,value in pairs({I_NCHAN=r.width,I_RECINPUT=r.start|2048,
        I_RECARM=r.armed and 1 or 0,I_RECMON=r.armed and 1 or 0}) do
      need(R.GetMediaTrackInfo_Value(s.track,key)==value,'track_changed')
    end
    need(R.TrackFX_GetCount(s.track)==1 and R.TrackFX_GetRecCount(s.track)==0,'effect_changed')
    need(R.TrackFX_GetFXGUID(s.track,0)==r.fx_guid,'effect_changed')
    local ok,ident=R.TrackFX_GetNamedConfigParm(s.track,0,'fx_ident')
    local named,name=R.TrackFX_GetFXName(s.track,0,'')
    local renamed,rename=R.TrackFX_GetNamedConfigParm(s.track,0,'renamed_name')
    local token=R.TrackFX_GetParam(s.track,0,0)
    need(ok and ident==IDENT and named and name==r.fx_name and renamed and rename==r.fx_rename
      and (token==r.token or token==0) and R.TrackFX_GetParam(s.track,0,1)==1
      and R.TrackFX_GetEnabled(s.track,0) and not R.TrackFX_GetOffline(s.track,0),'effect_changed')
    for param=0,2 do
      for _,key in ipairs({'mod.active','plink.active','learn.midi1','learn.midi2','learn.osc'}) do
        local present,value=R.TrackFX_GetNamedConfigParm(s.track,0,'param.'..param..'.'..key)
        need(not present or value=='' or tonumber(value)==0,'effect_changed')
      end
    end
    for side=0,1 do for pin=0,7 do for bank=0,1 do
      local low,high=R.TrackFX_GetPinMappings(s.track,0,side,pin+bank*0x1000000)
      need(low==(bank==0 and pin<r.width and (1<<pin) or 0) and high==0,'effect_changed')
    end end end
  end
  local function envelope_signature(master,index)
    local fields={}
    for _,key in ipairs({'P_ENV:<VOLENV','P_ENV:<PANENV','P_ENV:<MUTEENV'}) do
      local env=R.GetTrackSendInfo_Value(master,1,index,key)
      if env==nil or env==false or env==0 then fields[#fields+1]='absent'
      else
        need(R.CountEnvelopePoints(env)==0 and R.CountAutomationItems(env)==0,'send_changed')
        for _,property in ipairs({'ACTIVE','ARM','VISIBLE','SHOWLANE'}) do
          local ok,value=R.GetSetEnvelopeInfo_String(env,property,'',false)
          need(ok and (value=='0' or value=='1'),'send_changed')
          need((property~='ACTIVE' and property~='VISIBLE') or value=='0','send_changed')
          fields[#fields+1]=value
        end
      end
    end
    return table.concat(fields,':')
  end
  local function verify_route(s)
    local r=s.record
    local master=R.GetMasterTrack(s.project)
    need(master and R.ValidatePtr2(s.project,master,'MediaTrack*'),'inspection_failed')
    s.master=master
    local count=R.GetTrackNumSends(master,1)
    need(integer(count) and count>=0,'inspection_failed')
    need(count<=MAX_MASTER_SENDS,'send_limit')
    local target
    for i=0,count-1 do
      s.send_number=i+1
      local marked,marker=R.GetSetTrackSendInfo_String(master,1,i,MARKER,'',false)
      if marker and marker~='' then
        need(marked and marker==r.marker,'orphan_send')
        need(target==nil,'send_ambiguous')
        target=i
      else
        -- An unmarked route into the private input may be the saved owned send
        -- with a lost tag. Its destination alone never grants deletion authority.
        local dst=R.GetTrackSendInfo_Value(master,1,i,'I_DSTCHAN')
        local src=R.GetTrackSendInfo_Value(master,1,i,'I_SRCCHAN')
        if integer(dst) and dst>=0 and dst<2048 and integer(src) and src>=-1 and src<=65535 then
          local width=(dst & 1024)~=0 and 1 or src==-1 and 1
            or (src >> 10)==0 and 2 or (src >> 10)==1 and 1 or (src >> 10)*2
          need(not ((dst & 1023)<r.start+r.width and r.start<(dst & 1023)+width),'unmarked_send')
        else error('inspection_failed',0) end
      end
    end
    if target~=nil then
      s.send_number=target+1
      for key,value in pairs({I_SRCCHAN=r.width==2 and 0 or (r.width//2)<<10,I_DSTCHAN=r.start,
          I_SENDMODE=0,D_VOL=1,D_PAN=0,D_PANLAW=1,B_MUTE=0,B_PHASE=0,B_MONO=0}) do
        need(R.GetTrackSendInfo_Value(master,1,target,key)==value,'send_changed')
      end
      need(envelope_signature(master,target)==r.envelope_signature,'send_changed')
    else s.send_number=nil end
    return target,count
  end
  local function inspect_track(s,track,number)
    need(track and R.ValidatePtr2(s.project,track,'MediaTrack*'),'track_unavailable')
    local marker,raw=string_value(R,track,MARKER),string_value(R,track,RECORD)
    if marker~='' or raw~='' then
      need(not s.track,'multiple_tracks')
      s.track,s.track_number=track,number
    end
    local count=R.GetTrackNumSends(track,1)
    need(integer(count) and count>=0 and count<=4096,'inspection_failed')
    if count>0 then s.hardware={track=track,number=number,count=count,cursor=0} end
  end
  local function inspect_hardware(s)
    local h=s.hardware
    need(R.ValidatePtr2(s.project,h.track,'MediaTrack*'),'track_unavailable')
    local _,value=R.GetSetTrackSendInfo_String(h.track,1,h.cursor,MARKER,'',false)
    if value and value~='' then
      s.track,s.track_number,s.send_number=h.track,h.number,h.cursor+1
      error('unexpected_send',0)
    end
    h.cursor=h.cursor+1
    if h.cursor==h.count then s.hardware=nil end
  end
  local function finish(s)
    if s.track then
      verify_track(s)
      local target,count=verify_route(s)
      if not ready(s) then return false end
      -- A completed attempt is never repeated during this run, even on failure.
      finished[s.project]=true
      R.Undo_BeginBlock2(s.project)
      local ok,reason=pcall(function()
        need(ready(s),'cleanup_interrupted')
        need(s.revision==R.GetProjectStateChangeCount(s.project),'project_changed')
        verify_track(s)
        local current,current_count=verify_route(s)
        need(current==target and current_count==count,'send_changed')
        need(ready(s),'cleanup_interrupted')
        if current~=nil then
          need(R.RemoveTrackSend(s.master,1,current),'send_delete_failed')
          local remaining,remaining_count=verify_route(s)
          need(remaining==nil and remaining_count==count-1,'send_delete_failed')
        end
        -- A send deletion callback must not turn a verified track into user data.
        need(ready(s),'cleanup_interrupted')
        verify_track(s)
        R.DeleteTrack(s.track)
        need(project_open(s.project),'cleanup_interrupted')
        need(not R.ValidatePtr2(s.project,s.track,'MediaTrack*'),'track_delete_failed')
      end)
      R.Undo_EndBlock2(s.project,'Remove obsolete yb-Reference meter track',-1)
      if not ok then error(reason,0) end
    else
      local master=R.GetMasterTrack(s.project)
      need(master and R.ValidatePtr2(s.project,master,'MediaTrack*'),'inspection_failed')
      local count=R.GetTrackNumSends(master,1)
      need(integer(count) and count>=0,'inspection_failed')
      need(count<=MAX_MASTER_SENDS,'send_limit')
      for i=0,count-1 do
        local _,marker=R.GetSetTrackSendInfo_String(master,1,i,MARKER,'',false)
        if marker and marker~='' then
          s.track,s.track_number,s.send_number=master,0,i+1
          error('orphan_send',0)
        end
      end
      finished[s.project]=true
    end
    return true
  end
  function self:tick()
    local active=scan
    local ok,result=pcall(function()
      if not owner_free() then return end
      if not grant_revoked then
        if grant_attempted then return end
        grant_attempted=true
        if type(R.gmem_attach)=='function' and type(R.gmem_write)=='function' then
          need(R.gmem_attach('yb_reference_monitor_filter_v1')~=false,'inspection_failed')
          for _,offset in ipairs({10,6,7,2}) do
            need(R.gmem_write(1400000+offset,0)~=false,'inspection_failed')
          end
          if type(R.gmem_read)=='function' then
            for _,offset in ipairs({10,6,7,2}) do
              need(R.gmem_read(1400000+offset)==0,'inspection_failed')
            end
          end
        end
        grant_revoked=true
      end
      local projects=open_projects()
      if scan and not project_open(scan.project) then scan=nil end
      if not scan then
        for _,p in ipairs(projects) do
          if not finished[p] and R.GetPlayStateEx(p)==0 then
            scan={project=p,cursor=0,count=R.CountTracks(p),revision=R.GetProjectStateChangeCount(p)}
            break
          end
        end
      end
      if not scan then return end
      local s=scan
      active=s
      if R.GetPlayStateEx(s.project)~=0 then scan=nil; return end
      if s.revision~=R.GetProjectStateChangeCount(s.project) or s.count~=R.CountTracks(s.project) then
        scan=nil; return
      end
      -- Leave room for the candidate's immediate safety rechecks in this tick.
      for _=1,60 do
        if s.hardware then inspect_hardware(s)
        else
          if s.cursor>=s.count then break end
          local number=s.cursor+1
          inspect_track(s,R.GetTrack(s.project,s.cursor),number)
          s.cursor=s.cursor+1
        end
      end
      if s.cursor==s.count and not s.hardware then
        need(s.revision==R.GetProjectStateChangeCount(s.project),'project_changed')
        if finish(s) then scan=nil end
      end
    end)
    if not ok then
      if active then finished[active.project]=true end
      last_problem=problem(REASONS[result] and result or 'inspection_failed',active,
        active and active.track,active and active.track_number,active and active.send_number)
      if grant_attempted and not grant_revoked then grant_failure_problem=last_problem end
      scan=nil
      return last_problem
    end
    return last_problem
  end
  function self:input_ready()
    return self:input_status()==nil
  end
  function self:input_status()
    local ok,free=pcall(owner_free)
    if not ok then return 'inspection_failed' end
    if not free then return 'old_owner' end
    if not grant_revoked then return 'inspection_failed' end
  end
  function self:show_track(p)
    local ok,shown=pcall(function()
      if type(p)~='table' or not p.project or not project_open(p.project)
          or type(R.SelectProjectInstance)~='function' or type(R.SetOnlyTrackSelected)~='function' then
        return false
      end
      local track=p.track or R.GetMasterTrack(p.project)
      if not track or not R.ValidatePtr2(p.project,track,'MediaTrack*') then return false end
      if p.track and (not p.track_guid or R.GetTrackGUID(track)~=p.track_guid) then return false end
      R.SelectProjectInstance(p.project)
      R.SetOnlyTrackSelected(track)
      if type(R.SetMixerScroll)=='function' then R.SetMixerScroll(track) end
      return true
    end)
    return ok and shown or false
  end
  return self
end
return M
