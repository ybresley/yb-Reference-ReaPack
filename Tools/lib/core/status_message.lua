-- status_message: the one on-screen message the app shows, and when it goes away.
--
-- Call sites say what happened (`info`, `problem`, `progress`); the windows ask
-- `view` each frame what to draw. An info message fades after a few seconds
-- unless the pointer rests on it, and its close mark clears it sooner. A
-- problem stays until the user closes it or a
-- newer message replaces it. Progress behaves like info but never times out, so
-- a long import keeps its counter on screen until the final summary replaces it.
--
-- The clock is passed in; this module never touches REAPER. `state.status`
-- stays the plain message text so older code that only reads it keeps working.

local status_message = {}

status_message.HOLD_SECONDS = 6
status_message.FADE_SECONDS = 0.6
status_message.MAX_LINES = 3

local function set(state, text, kind)
  if text == nil or text == "" then
    state.status, state.status_kind = nil, nil
    return
  end
  state.status = text
  state.status_kind = kind
  state.status_seq = (state.status_seq or 0) + 1
end

function status_message.info(state, text) set(state, text, "info") end

function status_message.problem(state, text) set(state, text, "problem") end

-- A running counter never hides a problem still on screen; the job's final
-- summary is what replaces it.
function status_message.progress(state, text)
  if state.status_kind == "problem" and state.status and state.status ~= "" then return end
  set(state, text, "progress")
end

-- For results that are good or bad depending on what the service answered.
function status_message.report(state, ok, text)
  set(state, text, ok and "info" or "problem")
end

function status_message.clear(state) set(state, nil) end

-- A problem that describes a condition, such as the helper needing an update,
-- goes once that condition clears. Only that exact problem is removed, so a
-- newer message on screen is never lost.
function status_message.resolve(state, text)
  if state.status_kind == "problem" and text ~= nil and state.status == text then set(state, nil) end
end

-- A standing notice describes something that lasts, such as audio files in the
-- Library folder that aren't part of the Library, and offers one button for it:
-- { text = ..., button = "Review Files", action = "review_leftovers" }, or nil
-- to remove it. It waits behind ordinary messages and returns once they have
-- gone, so the two never compete for the card. Closing it hides it until its
-- text changes.
function status_message.set_notice(state, notice)
  local old = state.status_notice
  if notice and old and old.text == notice.text and old.button == notice.button
    and old.action == notice.action then return end
  state.status_notice = notice
    and { text = notice.text, button = notice.button, action = notice.action } or nil
end

-- News and problems both carry a close mark, so the user can clear either at
-- once. A progress counter has none: its next update would only bring it back.
-- `notice` is true when the close mark clicked was the standing notice's; the
-- card says so because a message may have arrived since it was drawn.
function status_message.close(state, notice)
  if notice then
    if state.status_notice then state.status_notice.closed = true end
  elseif state.status_kind ~= "progress" then
    set(state, nil)
  end
end

-- Settings can ask for a closed notice again. An ordinary news message is
-- cleared so the notice shows at once; a problem stays in front of it, because
-- clearing it would lose something the user hasn't read.
function status_message.reopen_notice(state)
  local n = state.status_notice
  if not n then return end
  n.closed = nil
  if state.status_kind == "info" then set(state, nil) end
end

local function notice_view(state)
  local n = state.status_notice
  if not n or n.closed then return nil end
  return { text = n.text, kind = "problem", alpha = 1, closable = true,
    button = n.button, action = n.action, notice = true }
end

-- What to draw now, or nil: the current message, else the standing notice.
-- `hovered` holds an info message at full strength and
-- restarts its countdown once the pointer leaves. Safe to call from several
-- windows in the same frame: hovering only ever extends the deadline.
function status_message.view(state, now, hovered, animate)
  local text = state.status
  local card = state.status_card
  if text == nil or text == "" then
    state.status_card = nil
    return notice_view(state)
  end
  if not card then
    card = {}
    state.status_card = card
  end
  if card.text ~= text or card.seq ~= state.status_seq then
    -- Text changed without going through info/problem/progress: treat it as
    -- plain news rather than inheriting the previous message's kind.
    if card.seq == state.status_seq and card.text ~= nil then state.status_kind = "info" end
    card.text, card.seq = text, state.status_seq
    card.deadline = now + status_message.HOLD_SECONDS
  end
  local kind = state.status_kind or "info"
  if kind ~= "info" then
    return { text = text, kind = kind, alpha = 1, closable = kind == "problem" }
  end
  if hovered then card.deadline = math.max(card.deadline, now + status_message.HOLD_SECONDS) end
  local left = card.deadline - now
  if left <= 0 then
    set(state, nil)
    state.status_card = nil
    return notice_view(state)
  end
  local alpha = 1
  if animate and left < status_message.FADE_SECONDS then
    alpha = left / status_message.FADE_SECONDS
  end
  return { text = text, kind = "info", alpha = alpha, closable = true }
end

-- Cut `text` to fit `max_w` and end it with an ellipsis. `measure` returns the
-- width of a string.
local function cut_to_fit(text, max_w, measure)
  if measure(text) <= max_w then return text end
  local count = utf8.len(text)
  local function prefix(n)
    if not count then return text:sub(1, n) end
    local at = utf8.offset(text, n + 1)
    return text:sub(1, (at or (#text + 1)) - 1)
  end
  local lo, hi = 0, count or #text
  while lo < hi do
    local mid = math.ceil((lo + hi) / 2)
    if measure(prefix(mid):gsub("%s+$", "") .. "…") <= max_w then lo = mid else hi = mid - 1 end
  end
  return (prefix(lo):gsub("%s+$", "")) .. "…"
end

-- Word-wrap `text` into at most `max_lines` lines no wider than `max_w`. A word
-- wider than a whole line is broken by character. Text beyond the last line is
-- folded into it and ellipsised. Returns the lines and whether anything was cut.
function status_message.wrap(text, max_w, measure, max_lines)
  max_lines = max_lines or status_message.MAX_LINES
  local lines, line = {}, ""
  for word in text:gmatch("%S+") do
    while measure(word) > max_w and utf8.len(word) and utf8.len(word) > 1 do
      -- Too wide for any line: peel off the longest piece that fits.
      if line ~= "" then lines[#lines + 1], line = line, "" end
      local lo, hi = 1, utf8.len(word)
      while lo < hi do
        local mid = math.ceil((lo + hi) / 2)
        local at = utf8.offset(word, mid + 1)
        if measure(word:sub(1, at - 1)) <= max_w then lo = mid else hi = mid - 1 end
      end
      local at = utf8.offset(word, lo + 1)
      lines[#lines + 1] = word:sub(1, at - 1)
      word = word:sub(at)
    end
    local candidate = line == "" and word or line .. " " .. word
    if line ~= "" and measure(candidate) > max_w then
      lines[#lines + 1] = line
      line = word
    else
      line = candidate
    end
  end
  if line ~= "" or #lines == 0 then lines[#lines + 1] = line end
  if #lines <= max_lines then return lines, false end
  local tail = table.concat(lines, " ", max_lines)
  for k = #lines, max_lines + 1, -1 do lines[k] = nil end
  lines[max_lines] = cut_to_fit(tail, max_w, measure)
  return lines, true
end

return status_message
