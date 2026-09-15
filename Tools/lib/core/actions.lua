-- Independent completed edits must survive a simultaneous playback action.
local actions = {}

function actions.combine(first, second)
  if not first then return second end
  if not second then return first end
  return { type = 'actions', items = { first, second } }
end

function actions.dispatch(action, handle)
  if not action then return end
  if action.type == 'actions' then
    for _, item in ipairs(action.items) do actions.dispatch(item, handle) end
  else
    handle(action)
  end
end

return actions
