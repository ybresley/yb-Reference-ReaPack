-- Shell bodies quote data separately from REAPER's process command line.
local mac_process = {}

function mac_process.is_mac()
  local name = reaper.GetOS and reaper.GetOS() or ""
  return name:match("^OSX") ~= nil or name:match("^macOS") ~= nil
end

function mac_process.quote(value)
  return "'" .. value:gsub("'", "'\"'\"'") .. "'"
end

function mac_process.command(path)
  -- ExecProcess does not document escaping inside quoted arguments. Refuse
  -- ambiguous paths instead of interpreting part of a filename as a command.
  if path:find('["`$\\\r\n]') then return nil end
  return '/bin/sh "' .. path .. '"'
end

return mac_process
