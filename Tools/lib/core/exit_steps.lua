-- exit_steps: run a script's shutdown steps so one failure cannot skip the rest.
--
-- Pure Lua. The entry script lists its exit cleanup in order (un-latch Reference
-- mode first, then the temporary drag item, then everything else). Every step
-- runs even if an earlier one throws: a failing destructor must not leave the
-- drag item in the user's project or the action marked as running. The first
-- error is raised once all steps have run, so the failure is still shown.

local exit_steps = {}

function exit_steps.run(steps)
  local first_error
  for i = 1, #steps do
    local ok, err = pcall(steps[i])
    if not ok and first_error == nil then first_error = err end
  end
  if first_error ~= nil then error(first_error, 0) end
end

return exit_steps
