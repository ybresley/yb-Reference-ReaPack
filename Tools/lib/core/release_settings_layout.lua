-- Anchor beside the button while keeping the whole example inside its canvas.
local layout = {}

function layout.content_height(groups, frame, text, pad, spacing)
  -- Window padding, tabs and the gap above the first group.
  local height = frame + pad * 4
  for index, group in ipairs(groups) do
    if index > 1 then height = height + spacing * 2 end
    local rows = #group.items
    height = height + text + spacing + pad * 2
      + rows * frame + math.max(0, rows - 1) * spacing
  end
  return height + pad
end

function layout.place(canvas, button, width, height, gap)
  local right = button.right + gap
  local scale = math.min(1,
    math.max(1, canvas.right - gap - right) / width,
    math.max(1, canvas.bottom - canvas.top - gap * 2) / height)
  local top = math.max(canvas.top + gap,
    math.min(button.bottom, canvas.bottom - gap) - height * scale)
  return {
    x = right, y = top, width = width * scale, height = height * scale, scale = scale,
  }
end

return layout
