-- Installs the meter's JSFX without replacing an unknown or edited file.
local installer = {}

local FILENAME = "yb-Reference_Meter.jsfx"

local function read_file(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local data = file:read("*a")
  file:close()
  return data
end

local function write_file(R, directory, path, data)
  local file = io.open(path, "wb")
  if not file then
    -- The actual write decides whether the directory is usable.
    R.RecursiveCreateDirectory(directory, 0)
    file = io.open(path, "wb")
  end
  if not file then return false end
  local written = file:write(data) ~= nil
  local closed = file:close()
  return written and closed and read_file(path) == data
end

local function promote(R, directory, staged, destination)
  if os.rename(staged, destination) then return true end
  R.RecursiveCreateDirectory(directory, 0)
  return os.rename(staged, destination) ~= nil
end

function installer.install(R, source)
  local data = read_file(source)
  if not data then return false, "crest_source_unreadable" end

  local resource = R.GetResourcePath()
  local effects_dir = resource .. "/Effects/yb-Reference"
  local data_dir = resource .. "/Data/yb-Reference"
  local destination = effects_dir .. "/" .. FILENAME
  local baseline = data_dir .. "/" .. FILENAME .. ".installed"
  local staged = data_dir .. "/" .. FILENAME .. ".pending"
  local backup = data_dir .. "/" .. FILENAME .. ".backup"
  local baseline_staged = baseline .. ".pending"
  local baseline_backup = baseline .. ".backup"
  local previous = read_file(destination)
  local known = read_file(baseline)

  if previous and previous ~= data and known ~= previous then
    return false, "crest_install_conflict"
  end
  if not previous and known then return false, "crest_install_conflict" end
  if known and known ~= previous and previous ~= data then return false, "crest_install_conflict" end
  if previous == data and known == data then return true end
  if read_file(staged) or read_file(backup) or read_file(baseline_staged)
    or read_file(baseline_backup) then
    return false, "crest_install_conflict"
  end

  if not write_file(R, data_dir, baseline_staged, data) then
    os.remove(baseline_staged)
    return false, "crest_install_failed"
  end
  if previous == data then
    -- ReaPack may have installed this exact release before its first launch.
    -- Refresh our baseline without rewriting the already matching effect.
    if known and not os.rename(baseline, baseline_backup) then
      os.remove(baseline_staged)
      return false, "crest_install_failed"
    end
    if not promote(R, data_dir, baseline_staged, baseline) then
      local restored = not known or os.rename(baseline_backup, baseline)
      os.remove(baseline_staged)
      return false, restored and "crest_install_failed" or "crest_restore_failed"
    end
    if known then os.remove(baseline_backup) end
    return true
  end
  if not write_file(R, data_dir, staged, data) then
    os.remove(staged)
    os.remove(baseline_staged)
    return false, "crest_install_failed"
  end

  if previous and not os.rename(destination, backup) then
    os.remove(staged)
    os.remove(baseline_staged)
    return false, "crest_install_failed"
  end
  if not promote(R, effects_dir, staged, destination) then
    local restored = not previous or os.rename(backup, destination)
    os.remove(staged)
    os.remove(baseline_staged)
    return false, restored and "crest_install_failed" or "crest_restore_failed"
  end

  if known and not os.rename(baseline, baseline_backup) then
    os.remove(baseline_staged)
    local removed = os.remove(destination)
    local restored = removed and (not previous or os.rename(backup, destination))
    return false, restored and "crest_install_failed" or "crest_restore_failed"
  end
  if not promote(R, data_dir, baseline_staged, baseline) then
    local marker_restored = not known or os.rename(baseline_backup, baseline)
    local removed = os.remove(destination)
    local effect_restored = removed and (not previous or os.rename(backup, destination))
    os.remove(baseline_staged)
    return false, marker_restored and effect_restored
      and "crest_install_failed" or "crest_restore_failed"
  end

  if previous then os.remove(backup) end
  if known then os.remove(baseline_backup) end
  return true
end

return installer
