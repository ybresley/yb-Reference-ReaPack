-- Display references only. Choosing one never changes the measurement algorithm.
local targets = {}
local youlean = 'https://youlean.co/loudness-standards-full-comparison-table/'
local fab = 'https://www.fabfilter.com/help/pro-l/using/loudnessmetering'

targets.groups = { 'Broadcast', 'Games', 'Music and Podcasts', 'Film and Streaming' }
targets.presets = {
  {id='ebu',name='EBU R128',group=1,target=-23,ceiling=-1,tolerance=.5,source=youlean,
    sources={youlean,fab}},
  {id='ebu_s1',name='EBU R128 S1',group=1,target=-23,ceiling=-1,tolerance=.5,s_max=-18,source=youlean},
  {id='atsc',name='ATSC A/85',group=1,target=-24,ceiling=-2,source=youlean,
    sources={youlean,fab},
    note='Full-mix reference for short-form content. Long-form dialogue measurement is unavailable.'},
  {id='op59',name='OP-59',group=1,target=-24,ceiling=-2,source=youlean},
  {id='arib',name='ARIB TR-B32',group=1,target=-24,ceiling=-1,source=youlean,
    sources={youlean,fab}},
  {id='agcom',name='AGCOM 219/09/CSP',group=1,target=-24,ceiling=-2,gate='relative8',source=youlean},
  {id='aswg_home',name='ASWG-R001 Home',group=2,target=-24,ceiling=-1,tolerance=2,source=youlean,
    note='For game output over representative gameplay, not an individual sound effect.'},
  {id='aswg_portable',name='ASWG-R001 Portable',group=2,target=-18,ceiling=-1,tolerance=2,source=youlean,
    note='For portable game output over representative gameplay, not an individual sound effect.'},
  {id='fab_cd',name='CD Reference',group=3,target=-9,source=fab,
    note='Pro-L 2 reference level, not a mandatory CD standard. Keeps your current true-peak ceiling.'},
  {id='spotify',name='Spotify',group=3,target=-14,ceiling=-1,source=youlean,
    sources={youlean,fab},
    note='Also covers Pro-L 2\'s -14 LUFS streaming reference.'},
  {id='spotify_loud',name='Spotify Loud',group=3,target=-11,ceiling=-2,source=youlean},
  {id='youtube',name='YouTube',group=3,target=-14,ceiling=-1,source=youlean},
  {id='apple_music',name='Apple Music',group=3,target=-16,ceiling=-1,tolerance=1,source=youlean},
  {id='apple_podcast',name='Apple Podcasts',group=3,target=-16,ceiling=-1,tolerance=1,source=youlean},
  {id='tidal',name='TIDAL',group=3,target=-14,ceiling=-1,source=youlean},
  {id='deezer',name='Deezer',group=3,target=-15,ceiling=-1,source=youlean},
  {id='amazon_music',name='Amazon Music',group=3,target=-14,ceiling=-2,source=youlean},
  {id='alexa',name='Amazon Alexa',group=3,target=-14,ceiling=-2,source=youlean},
  {id='aes',name='AES Streaming',group=4,target=-16,ceiling=-1,i_min=-20,i_max=-16,source=youlean,
    note='The target line uses the upper edge of the published integrated range.'},
  {id='netflix',name='Netflix',group=4,target=-27,ceiling=-2,gate='dialogue',source=youlean},
}

local by_id = {}
for _, preset in ipairs(targets.presets) do by_id[preset.id] = preset end
-- A shared reference appears once even when both products offer it.
local aliases = { fab_streaming='spotify', agcom_youlean='agcom', aes_youlean='aes', netflix_youlean='netflix' }

function targets.get(id) return by_id[aliases[id] or id] end

function targets.active(options)
  local preset = targets.get(options.preset)
  if preset and preset.target ~= nil and preset.target == options.target
    and (preset.ceiling == nil or preset.ceiling == options.ceiling) then return preset end
end

function targets.apply(options, id)
  local preset = targets.get(id)
  if not preset or preset.target == nil then return false end
  options.preset, options.target = preset.id, preset.target
  if preset.ceiling ~= nil then options.ceiling = preset.ceiling end
  return true
end

function targets.edit(options, key, value)
  options[key] = value
  if key == 'target' or key == 'ceiling' then options.preset = '' end
end

function targets.warning(preset)
  if not preset then return nil end
  if preset.gate == 'dialogue' then return 'Target only: dialogue measurement is unavailable.' end
  if preset.gate == 'relative8' then return 'Target only: the required -8 LU gate is unavailable.' end
  if preset.id == 'atsc' then return 'Full-mix target only: long-form dialogue measurement is unavailable.' end
end

function targets.details(preset)
  if not preset then return 'Custom loudness target and true-peak ceiling.' end
  local lines = {}
  if preset.tolerance then lines[#lines+1] = string.format('Preset tolerance: ±%g LU',preset.tolerance) end
  if preset.i_min then lines[#lines+1] = string.format('Integrated range: %g to %g LUFS',preset.i_min,preset.i_max) end
  if preset.s_max then lines[#lines+1] = string.format('Short-term ceiling: %g LUFS (reference only)',preset.s_max) end
  local warning = targets.warning(preset)
  if warning then
    lines[#lines+1] = warning
    lines[#lines+1] = 'Readings still measure the full mix with programme gating.'
  end
  if preset.note then lines[#lines+1] = preset.note end
  if preset.source == youlean then lines[#lines+1] = 'Source: Youlean preset table, March 2020.'
  elseif preset.source == fab then lines[#lines+1] = 'Source: Pro-L 2 manual.' end
  lines[#lines+1] = 'Display reference only. Tolerances and extra limits are not compliance checks.'
  return table.concat(lines,'\n')
end

return targets
