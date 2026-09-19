-- Playback policy above the preview engine and crash-safe Reference Mode adapter.
-- The entry script owns state and calls each frame step at its existing position.
local preview = require("preview")
local reference = require("reference")
local holders = require("holders")
local picker_preview = require("picker_preview")
local api = require("reaper_api")
local span = require("core.span")
local pitch = require("core.pitch")

local coordinator = {}
local REF_PLAYING_MSG = "Reference mode is playing. Stop the transport to audition here."

-- callbacks resolves records and paths from the current Library/project. The
-- startup alert is carried forward so an unresolved recovery is not announced twice.
function coordinator.new(state, callbacks, startup_alert)
  local playback = {}
  local reference_alerted = startup_alert
  local recovery, urgent

  function playback.play(s, position, slot, loop)
    if loop == nil then loop = state.loop end
    -- Exact positions belong to the user's seek or pause. Only an ordinary
    -- Reference View/picker start follows the sound's saved start point.
    if (slot == "main" or slot == "picker") and position == nil
      and type(s.span_start) == "number" and s.span_start > 0 then
      position = s.span_start
    end
    local trim_db = (slot == "browse") and 0 or (s.trim_db or 0)
    local ok = preview.play(callbacks.path(s), {
      db = trim_db + state.master_db, loop = loop, position = position,
      pitch = state.pitch[slot] or 0, channels = s.channels,
      before_start = callbacks.before_start and function()
        return callbacks.before_start(slot, s.id)
      end or nil,
    })
    -- Multichannel playback can disable Mono. Length comes from the actual
    -- source, because replacing a file can leave its recorded duration stale.
    state.mono = preview.is_mono()
    state.preview.playing = ok
    state.preview.sound_id = ok and s.id or nil
    state.preview.slot = ok and slot or nil
    state.preview.trim_db = ok and trim_db or 0
    state.preview.channels = ok and preview.channels() or 0
    state.preview.length = ok and preview.length() or 0
    state.preview.position = ok and (position or 0) or 0
    if ok then
      state.preview.start_serial = (state.preview.start_serial or 0) + 1
    end
    if not ok then
      local folder = holders.is_pin(s.id)
        and "the project's References folder" or "the Library folder"
      state.status = string.format(
        "\"%s\" couldn't be played. Its audio file is missing or can't be read from %s.", s.name, folder)
    end
    return ok
  end

  function playback.audition_browse()
    if not state.browse then return end
    if state.reference.active then state.status = REF_PLAYING_MSG; return end
    if state.auto_audition then playback.play(state.browse, 0, "browse") end
  end

  -- Play is a trigger, not a transport toggle. Repeating it replaces the
  -- current preview and starts this sound again from its normal start point.
  function playback.trigger(slot)
    local s = (slot == "browse") and state.browse or state.selected
    if slot == "browse" and state.reference.active then
      state.status = REF_PLAYING_MSG
    elseif s then
      local loop = slot == "main" and state.reference.active and true or nil
      if playback.play(s, nil, slot, loop) then holders.clear_pause(state, slot) end
    end
  end

  -- Pause owns the parked position. The same button resumes the sound this
  -- slot parked, even if its window's selection has moved in the meantime.
  function playback.toggle_pause(slot)
    if state.preview.playing and state.preview.slot == slot then
      holders.pause_playback(state, slot, state.preview.sound_id)
    elseif slot == "browse" and state.reference.active then
      state.status = REF_PLAYING_MSG
    else
      local parked = holders.pause_of(state, slot)
      local s = parked and callbacks.find(parked.sound_id) or nil
      local loop = slot == "main" and state.reference.active and true or nil
      if s and playback.play(s, parked.at or 0, slot, loop) then
        holders.clear_pause(state, slot)
      end
    end
  end

  function playback.stop(slot)
    -- A Stop button may clear its own parked position while another slot plays,
    -- but it must not silence that other slot's audio.
    if state.preview.playing and state.preview.slot == slot then
      holders.stop_playback(state, slot)
    else
      holders.clear_pause(state, slot)
    end
  end

  function playback.seek(fraction, slot)
    if slot == "browse" and state.reference.active then state.status = REF_PLAYING_MSG; return end
    local s
    if slot == "browse" then s = state.browse else s = state.selected end
    if not s then return end
    local parked = holders.paused_on(state, slot, s.id)
    if state.preview.playing and state.preview.slot == slot and state.preview.sound_id == s.id then
      local pos = fraction * (state.preview.length or 0)
      preview.seek(pos)
      state.preview.position = pos
    elseif slot == "main" then
      local requested = fraction * (s.duration or 0)
      if playback.play(s, requested, slot) then
        local pos = fraction * (state.preview.length or 0)
        preview.seek(pos)
        state.preview.position = pos
        holders.clear_pause(state, slot)
      end
    elseif parked then
      -- A Library waveform click moves its pause without resuming it.
      parked.at = fraction * (parked.length or 0)
    elseif playback.play(s, 0, slot) then
      local pos = fraction * (state.preview.length or 0)
      if pos > 0 then preview.seek(pos) end
      state.preview.position = pos
    end
  end

  function playback.toggle_loop()
    state.loop = not state.loop
    if not state.reference.active then preview.set_loop(state.loop) end
  end

  function playback.toggle_mono()
    local channels = state.preview.playing and (tonumber(state.preview.channels) or 0)
      or (state.selected and (tonumber(state.selected.channels) or 0) or 0)
    if channels > 2 then return end
    -- All routes already exist; changing their gain avoids restarting audio.
    preview.set_mono(not state.mono)
    state.mono = preview.is_mono()
  end

  function playback.set_pitch(slot, value)
    value = pitch.clamp(value)
    state.pitch[slot] = value
    local id = (slot == "browse") and state.browse_id or state.selected_id
    if state.preview.playing and state.preview.slot == slot and state.preview.sound_id == id then
      preview.set_pitch(value)
    end
  end

  function playback.set_master(db)
    state.master_db = db
    if state.preview.playing then preview.set_volume_db(state.preview.trim_db + db) end
  end

  -- Called after persistence has accepted the edit or restored the saved value.
  -- A Library audition remains untrimmed even if its record is the same sound.
  function playback.trim_changed(s)
    if state.preview.playing and state.preview.slot == "main" and state.preview.sound_id == s.id then
      state.preview.trim_db = s.trim_db
      preview.set_volume_db(s.trim_db + state.master_db)
    end
  end

  function playback.span_changed(s)
    if state.preview.playing and state.preview.slot == "main" and state.preview.sound_id == s.id then
      local s0, s1 = span.range(s, state.preview.length)
      local pos = state.preview.position
      if s1 > 0 and (pos >= s1 or pos < s0) then
        preview.seek(s0)
        state.preview.position = s0
      end
    end
  end

  local function show_view(view)
    local ref = state.reference
    ref.latched, ref.live, ref.pending = view.latched, view.live, view.pending
    ref.owner_name, ref.queued_count = view.owner_name, view.queued_count
  end

  function playback.toggle_reference()
    local ref = state.reference
    picker_preview.stop(state)
    -- Both latch edges stop audio. The Library's separate parked position stays.
    holders.stop_playback(state, "main")
    ref.active, ref.sound_id, ref.failed_id = false, nil, nil
    if ref.latched then
      ref.latched = false
      if reference.latch_off() then
        ref.live, ref.pending, ref.owner_name = false, false, nil
        state.status = "Reference mode is off. Your project plays normally again."
      else
        local view, recovered, needs_attention = reference.refresh()
        show_view(view)
        local message = recovered or reference.pending()
        if message then
          state.status = message
          if (needs_attention or view.pending) and message ~= reference_alerted then
            api.message(message, "yb-Reference · Reference Mode Needs Attention")
            reference_alerted = message
          end
        end
      end
    else
      -- Losing a target later must keep the latch: automatically unlatching
      -- could abruptly expose project audio. An empty initial latch is refused.
      if not state.selected then
        state.status = "Select a reference first. Choose a sound or pin, then turn on the Latch button."
        return
      end
      local ok, reason = reference.latch_on()
      if ok then
        local view = reference.refresh()
        show_view(view)
        state.status = "Reference mode is on for " .. (view.owner_name or "this project") ..
          ". Its master is muted. Press Play in Reaper to hear the selected reference."
      else
        state.status = reason
        api.message(reason, "yb-Reference · Reference Mode")
        if reference.pending() then reference_alerted = reason end
      end
    end
  end

  -- Run before refreshing pins: leaving a project's live latch must stop its
  -- old audio before ids can bind to records in the incoming project.
  function playback.refresh_reference()
    local ref = state.reference
    local was_current_latched = ref.latched
    local view, event
    view, recovery, urgent, event = reference.refresh()
    show_view(view)
    if (was_current_latched and not ref.latched) or event.live_ended then
      holders.stop_playback(state, "main")
      ref.active, ref.sound_id, ref.failed_id = false, nil, nil
    end
  end

  -- Run after pins/selection refresh. Recovery messages take precedence over
  -- pin warnings, and hotkey requests have the same path as the Latch button.
  function playback.sync_reference(pins_warning)
    if recovery then
      state.status = recovery
      if urgent and recovery ~= reference_alerted then
        api.message(recovery, "yb-Reference · Reference Mode Needs Attention")
        reference_alerted = recovery
      end
    elseif pins_warning then
      state.status = pins_warning
    end
    if not urgent then reference_alerted = nil end
    if reference.take_toggle_request() then playback.toggle_reference() end

    local ref = state.reference
    local wanted = ref.latched and reference.transport_preview_wanted() or false
    picker_preview.set_reference_running(state, wanted)
    if not ref.latched then return end
    if wanted and state.selected then
      local id = state.selected.id
      if ref.failed_id ~= id and (not ref.active or ref.sound_id ~= id) then
        -- Reading a pause does not consume it; transport controls own their
        -- existing stop behavior, while another frame must not restart audio.
        local parked = holders.paused_on(state, "main", id)
        local from = parked and parked.at or nil
        if playback.play(state.selected, from, "main", true) then
          ref.active, ref.sound_id, ref.failed_id = true, id, nil
        else
          ref.active, ref.sound_id, ref.failed_id = false, nil, id
          state.status = "That reference couldn't be played. Its audio file may be missing or unreadable."
        end
      end
    elseif ref.active or ref.failed_id then
      if ref.active then holders.stop_playback(state, "main") end
      ref.active, ref.sound_id, ref.failed_id = false, nil, nil
    end
  end

  function playback.advance()
    local ended = preview.poll()
    if not state.preview.playing then return end
    if ended then
      state.preview.playing = false
      state.preview.sound_id = nil
      state.preview.slot = nil
      state.preview.trim_db = 0
      state.preview.channels = 0
      state.preview.position = 0
      -- Engine failure must not reopen a broken file every frame. Keep the
      -- latch and independent pauses; retry follows stop/play or reselection.
      if state.reference.active then state.reference.failed_id = state.reference.sound_id end
      state.reference.active = false
      state.reference.sound_id = nil
      return
    end
    local pos = preview.position()
    if not pos then return end
    local prev = state.preview.position
    state.preview.position = pos
    if state.preview.slot == "main" or state.preview.slot == "picker" then
      local s = callbacks.find(state.preview.sound_id)
      if s and (s.span_start or s.span_end) then
        local s0, s1 = span.range(s, state.preview.length)
        -- Only crossings end playback: an explicit seek beyond the saved end
        -- remains playable until the actual file ends.
        if s1 > 0 and prev < s1 and pos >= s1 then
          if state.reference.active or state.loop then
            preview.seek(s0)
            state.preview.position = s0
          else
            holders.stop_playback(state, state.preview.slot)
          end
        elseif s0 > 0 and pos < prev and pos < s0 then
          preview.seek(s0)
          state.preview.position = s0
        end
      end
    end
  end

  return playback
end

return coordinator
