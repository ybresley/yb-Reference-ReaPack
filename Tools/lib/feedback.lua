-- REAPER-facing feedback delivery. A request is saved before its one hidden
-- POST starts, and success requires the receiver to echo the exact request ID
-- with the Sheet's report ID.

local fb_core = require("core.feedback")
local store = require("core.library_store")

local feedback = {}

local SEP = package.config:sub(1, 1)

feedback.URL = "https://script.google.com/macros/s/AKfycbyO_6OjXKDv8kUfqImqqBYz7L1hjy51jn1Ux4_iCBCP8I9wLpt3-evxQq-vGdZ7VqCB/exec"
feedback.ADDRESS = "yoni.ybtools@gmail.com"

local SEND_WATCH = 31
local CURL_SECS = 30

local S = { phase = nil, saved = false }
feedback.state = S

local P = {
  base = nil,
  payload = nil,
  reply = nil,
  vbs = nil,
  pending = nil,
  receipt = nil,
  current = nil,
  flip = 0,
  deadline = 0,
}

local function send_files(n)
  return P.base .. "_payload" .. n .. ".json",
    P.base .. "_reply" .. n .. ".txt",
    P.base .. "_send" .. n .. ".vbs"
end

local function select_files(n)
  P.payload, P.reply, P.vbs = send_files(n)
end

local function read_file(path)
  local f = path and io.open(path, "rb")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

local function write_file(path, text)
  local f = io.open(path, "wb")
  if not f then return false end
  local wrote = f:write(text)
  local closed = f:close()
  if not wrote or not closed then
    os.remove(path)
    return false
  end
  return true
end

local function clean_parity(n)
  local payload, reply, vbs = send_files(n)
  os.remove(payload)
  os.remove(reply)
  os.remove(vbs)
end

local function clean_attempt()
  os.remove(P.payload)
  os.remove(P.reply)
  os.remove(P.vbs)
end

local function recover_atomic(path)
  local ok, err = pcall(store.recover, path)
  return ok, err
end

local function save_pending(record)
  fb_core.encode_pending(record)
  store.save(P.pending, record)
end

local function save_receipt(receipt)
  fb_core.encode_saved_receipt(receipt)
  store.save(P.receipt, {
    version = fb_core.RECEIPT_VERSION,
    request_id = receipt.request_id,
    report_id = receipt.report_id,
  })
end

local function read_saved_receipt()
  local text = read_file(P.receipt)
  if not text then return nil end
  local ok, receipt = pcall(fb_core.decode_saved_receipt, text)
  return ok and receipt or nil
end

local function request_id()
  local raw = reaper.genGuid("")
  if type(raw) ~= "string" then return nil end
  local id = raw:gsub("[{}-]", ""):lower()
  if #id ~= 32 or not id:match("^[0-9a-f]+$") then return nil end
  return id
end

local function curl_cmd()
  return 'curl -s -L --max-time ' .. CURL_SECS
    .. ' -H "Content-Type: application/json"'
    .. ' -d @"' .. P.payload .. '" -o "' .. P.reply .. '" "' .. feedback.URL .. '"'
end

local function write_shim()
  return write_file(P.vbs, 'On Error Resume Next\r\n'
    .. 'Set sh = CreateObject("WScript.Shell")\r\n'
    .. 'sh.Run "' .. curl_cmd():gsub('"', '""') .. '", 0, True\r\n')
end

local function current_matches(message, email)
  return P.current and P.current.delivery_version == 2
    and P.current.message == message and P.current.email == email
end

local function fail(reason)
  clean_attempt()
  S.phase = "failed"
  S.failure_reason = reason or "Delivery unconfirmed."
end

local function finish_success(receipt)
  S.failure_reason = nil
  if receipt.legacy then
    clean_attempt()
    os.remove(P.pending)
    P.current = nil
    S.saved = false
    S.report_id = nil
    S.phase = "sent"
    return
  end

  -- Keep the pending record and reply if this small save fails. On the next
  -- launch they can prove the same success again without sending another POST.
  local saved = pcall(save_receipt, receipt)
  S.report_id = receipt.report_id
  S.saved = true
  S.phase = "sent"
  if saved then
    clean_attempt()
    os.remove(P.pending)
    P.current = nil
    S.saved = false
  end
end

local function recover_pending(raw)
  local ok, record, migrated = pcall(fb_core.decode_pending, raw)
  if not ok then
    S.last_message = raw
    S.recovered_message = raw
    S.saved = true
    S.failure_reason = "Saved feedback could not be read."
    S.phase = "failed"
    return
  end

  P.current = record
  P.flip = record.parity
  select_files(record.parity)

  if record.delivery_version == 1 and migrated then
    local staged = read_file(P.payload)
    if staged then
      local identity_ok, message, email = pcall(fb_core.payload_identity, staged)
      if identity_ok and message == record.message then
        record.payload = staged
        record.email = email
        pcall(save_pending, record)
      end
    end
  end

  S.last_message = record.message
  S.recovered_message = record.message
  S.recovered_email = record.email
  S.saved = true

  if record.delivery_version == 2 then
    local saved_receipt = read_saved_receipt()
    if saved_receipt and saved_receipt.request_id == record.request_id then
      finish_success(saved_receipt)
      return
    end
  end

  local reply = read_file(P.reply)
  local receipt = fb_core.receipt(reply, record.request_id, record.delivery_version == 1)
  if receipt then
    finish_success(receipt)
    return
  end

  clean_parity(1 - record.parity)
  local staged = read_file(P.payload)
  if staged and (record.delivery_version == 1 or staged == record.payload) then
    P.deadline = reaper.time_precise() + SEND_WATCH
    S.failure_reason = nil
    S.phase = "sending"
  else
    clean_attempt()
    S.failure_reason = "Delivery unconfirmed."
    S.phase = "failed"
  end
end

function feedback.init()
  P.base = reaper.GetResourcePath() .. SEP .. "yb_reference_feedback"
  P.pending = P.base .. "_pending.txt"
  P.receipt = P.base .. "_receipt.json"

  local ok = recover_atomic(P.pending)
  recover_atomic(P.receipt)
  if not ok then
    local raw = read_file(P.pending) or read_file(P.pending .. ".bak") or ""
    S.last_message = raw
    S.recovered_message = raw
    S.saved = raw ~= ""
    S.failure_reason = "Saved feedback could not be restored."
    S.phase = "failed"
    return
  end

  local raw = read_file(P.pending)
  if raw then
    recover_pending(raw)
    return
  end

  clean_parity(0)
  clean_parity(1)
  local receipt = read_saved_receipt()
  if receipt then
    S.phase = "sent"
    S.report_id = receipt.report_id
    S.saved = false
  end
end

function feedback.start(payload_json, message)
  if S.phase == "sending" or type(payload_json) ~= "string" then return end

  local identity_ok, payload_message, email = pcall(fb_core.payload_identity, payload_json)
  message = type(message) == "string" and message or payload_message or ""
  S.last_message = message
  S.recovered_message = nil
  S.recovered_email = nil
  S.report_id = nil
  S.failure_reason = nil
  if not identity_ok then
    S.saved = false
    S.failure_reason = "Feedback could not be prepared."
    S.phase = "failed"
    return
  end

  local delivered, id
  if current_matches(payload_message, email) then
    delivered = P.current.payload
    id = P.current.request_id
  else
    id = request_id()
    local prepared_ok
    prepared_ok, delivered = pcall(fb_core.add_delivery, payload_json, id)
    if not prepared_ok then
      S.saved = false
      S.failure_reason = "Feedback could not be prepared."
      S.phase = "failed"
      return
    end
  end

  local parity = 1 - P.flip
  clean_parity(parity)
  local record = {
    version = fb_core.PENDING_VERSION,
    delivery_version = 2,
    parity = parity,
    payload = delivered,
    message = payload_message,
    email = email,
    request_id = id,
  }

  local saved = pcall(save_pending, record)
  if not saved then
    S.saved = current_matches(payload_message, email)
    S.failure_reason = "Couldn’t save your message."
    S.phase = "failed"
    return
  end

  P.current = record
  P.flip = parity
  select_files(parity)
  S.saved = true
  os.remove(P.receipt)
  clean_parity(1 - parity)

  if not write_file(P.payload, delivered) or not write_shim() then
    fail("Delivery couldn’t start.")
    return
  end

  S.phase = "sending"
  local launched = reaper.ExecProcess('wscript.exe //B "' .. P.vbs .. '"', -1) ~= nil
  if not launched then
    fail("Delivery couldn’t start.")
    return
  end
  P.deadline = reaper.time_precise() + SEND_WATCH
end

function feedback.tick()
  if S.phase ~= "sending" then return end

  local reply = read_file(P.reply)
  local receipt = fb_core.receipt(reply, P.current and P.current.request_id,
    P.current and P.current.delivery_version == 1)
  if receipt then
    finish_success(receipt)
    return
  end

  if reaper.time_precise() >= P.deadline then
    fail("Delivery unconfirmed.")
  end
end

return feedback
