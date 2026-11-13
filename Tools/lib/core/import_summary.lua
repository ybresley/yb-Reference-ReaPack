-- Import results keep ordinary non-audio extras quiet while preserving audio
-- problems and a useful notice when the whole selection is unsupported.
local import_summary = {}

function import_summary.describe(sum)
  local parts, detail = {}, {}
  if sum.added > 0 then
    parts[#parts + 1] = string.format("%d %s added", sum.added, sum.added == 1 and "sound" or "sounds")
  end
  if #sum.duplicates > 0 then
    parts[#parts + 1] = string.format("%d %s already in the Library",
      #sum.duplicates, #sum.duplicates == 1 and "sound" or "sounds")
  end
  if #sum.skipped > 0 then parts[#parts + 1] = #sum.skipped .. " skipped" end
  if #sum.errors > 0 then parts[#parts + 1] = #sum.errors .. " couldn't be added" end
  for _, message in ipairs(sum.skipped) do detail[#detail + 1] = message end
  for _, message in ipairs(sum.errors) do detail[#detail + 1] = message end

  -- A cancelled job may have inspected only non-audio files so far. It cannot
  -- claim the entire selection was unsupported until every path was checked.
  if #parts == 0 and (sum.ignored or 0) > 0 and sum.ignored == sum.total then
    return "No supported audio files were selected.", { "Choose audio files to add to the Library." }
  end
  return #parts > 0 and table.concat(parts, "  \u{00B7}  ") or "Nothing to add.", detail
end

return import_summary
