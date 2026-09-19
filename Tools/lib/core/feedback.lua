-- Pure feedback rules: compose the public report, add delivery identity, and
-- validate the small records used to recover an interrupted send.

local json = require("vendor.json")

local feedback = {}

feedback.MAX_MESSAGE = 1000
feedback.MAX_EMAIL = 200
feedback.PENDING_VERSION = 2
feedback.RECEIPT_VERSION = 1

local function utf8_clip(text, max_chars)
  if utf8.len(text) then
    if utf8.len(text) <= max_chars then return text end
    return text:sub(1, utf8.offset(text, max_chars + 1) - 1)
  end
  return text:sub(1, max_chars)
end

local function decode_json(text, what)
  if type(text) ~= "string" or text == "" then
    error(what .. " is empty")
  end
  local ok, value = pcall(json.decode, text)
  if not ok or type(value) ~= "table" then
    error(what .. " is not valid JSON")
  end
  return value
end

local function valid_request_id(value)
  return type(value) == "string" and #value == 32
    and value:match("^[0-9a-f]+$") ~= nil
end

local function valid_report_id(value)
  return type(value) == "string"
    and value:match("^YBR%-%d%d%d%d%d%d%d%d%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

function feedback.clip(text)
  if type(text) ~= "string" then return "" end
  return utf8_clip(text, feedback.MAX_MESSAGE)
end

function feedback.count(text)
  if type(text) ~= "string" then return 0 end
  return utf8.len(text) or #text
end

function feedback.reaper_version(raw)
  if type(raw) ~= "string" then return "?" end
  local v = raw:match("^([^/]+)")
  return (v and v ~= "") and v or "?"
end

function feedback.install_kind(enabled, disabled_reason)
  if enabled or disabled_reason == "repo_off" then return "ReaPack install" end
  return "manual copy"
end

-- This payload has no request identity yet. The adapter adds that immediately
-- before saving the attempt, because only the adapter can ask REAPER for a GUID.
function feedback.payload(fields)
  local msg = feedback.clip(fields.message)
  if msg:match("^%s*$") then return nil end
  return json.encode({
    message = msg,
    email = utf8_clip(tostring(fields.email or ""), feedback.MAX_EMAIL),
    tool = tostring(fields.tool or "?"),
    reaper = tostring(fields.reaper or "?"),
    install = tostring(fields.install or "?"),
  })
end

function feedback.payload_identity(payload)
  local value = decode_json(payload, "feedback payload")
  if type(value.message) ~= "string" or value.message:match("^%s*$") then
    error("feedback payload has no message")
  end
  if type(value.email) ~= "string" then
    error("feedback payload has no email")
  end
  return value.message, value.email
end

function feedback.add_delivery(payload, request_id)
  if not valid_request_id(request_id) then error("feedback request ID is invalid") end
  local value = decode_json(payload, "feedback payload")
  feedback.payload_identity(payload)
  value.delivery_version = 2
  value.request_id = request_id
  return json.encode(value)
end

-- A v2 send succeeds only when the receiver echoes this exact request and
-- supplies its durable Sheet report ID. Plain "ok" is accepted solely while
-- recovering a courier created by the old sender.
function feedback.receipt(reply, request_id, allow_legacy_ok)
  if type(reply) ~= "string" then return nil end
  if allow_legacy_ok and reply:match("^%s*(.-)%s*$") == "ok" then
    return { legacy = true }
  end
  if not valid_request_id(request_id) then return nil end
  local ok, value = pcall(json.decode, reply)
  if not ok or type(value) ~= "table" then return nil end
  if value.status ~= "ok" or value.request_id ~= request_id
      or not valid_report_id(value.report_id) then
    return nil
  end
  return { request_id = value.request_id, report_id = value.report_id }
end

local function validate_current_pending(value)
  if value.version ~= feedback.PENDING_VERSION then
    error("feedback recovery version is unsupported")
  end
  if value.parity ~= 0 and value.parity ~= 1 then
    error("feedback recovery parity is invalid")
  end
  if type(value.message) ~= "string" or type(value.email) ~= "string" then
    error("feedback recovery draft is invalid")
  end
  if value.delivery_version ~= 1 and value.delivery_version ~= 2 then
    error("feedback recovery delivery version is invalid")
  end
  if value.payload ~= nil and type(value.payload) ~= "string" then
    error("feedback recovery payload is invalid")
  end
  if value.delivery_version == 2 then
    if not valid_request_id(value.request_id) or type(value.payload) ~= "string" then
      error("feedback recovery request is invalid")
    end
    local message, email = feedback.payload_identity(value.payload)
    local delivered = decode_json(value.payload, "feedback payload")
    if delivered.delivery_version ~= 2 or delivered.request_id ~= value.request_id
        or message ~= value.message or email ~= value.email then
      error("feedback recovery payload does not match its draft")
    end
  end
  return value
end

function feedback.encode_pending(value)
  validate_current_pending(value)
  return json.encode(value)
end

-- The original sender used a three-line record. Decode it into the current
-- in-memory shape without discarding its message; the adapter can then attach
-- the separately staged payload if it still exists.
function feedback.decode_pending(text)
  if type(text) ~= "string" or text == "" then
    error("feedback recovery data is empty")
  end
  local parity, message = text:match("^version=1\nparity=([01])\n(.*)$")
  if parity then
    return {
      version = feedback.PENDING_VERSION,
      delivery_version = 1,
      parity = tonumber(parity),
      message = message,
      email = "",
    }, true
  end
  return validate_current_pending(decode_json(text, "feedback recovery data")), false
end

function feedback.encode_saved_receipt(value)
  if type(value) ~= "table" or not valid_request_id(value.request_id)
      or not valid_report_id(value.report_id) then
    error("saved feedback receipt is invalid")
  end
  return json.encode({
    version = feedback.RECEIPT_VERSION,
    request_id = value.request_id,
    report_id = value.report_id,
  })
end

function feedback.decode_saved_receipt(text)
  local value = decode_json(text, "saved feedback receipt")
  if value.version ~= feedback.RECEIPT_VERSION
      or not valid_request_id(value.request_id)
      or not valid_report_id(value.report_id) then
    error("saved feedback receipt is invalid")
  end
  return value
end

return feedback
