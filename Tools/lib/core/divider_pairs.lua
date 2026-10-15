local divider_pairs = {}

local TOUCH_EPSILON = 0.01

local function effective_rect(panel)
  local header = panel.header
  if header then
    local top = header.y or panel.y
    return { x = panel.x, y = top, w = panel.w, h = panel.y + panel.h - top }
  end
  return panel
end

local function valid_rect(rect)
  return rect.w > 0 and rect.h > 0
end

local function close(a, b)
  return math.abs(a - b) <= TOUCH_EPSILON
end

local function divider_signature(divider)
  return table.concat({ divider.axis, divider.x, divider.y, divider.w, divider.h }, ":")
end

local function segment_key(divider, axis, start, finish)
  return table.concat({ tostring(divider.key), axis, tostring(start), tostring(finish) }, ":")
end

function divider_pairs.measure(panels, dividers)
  local pairs = {}
  local seen_dividers = {}

  for _, divider in ipairs(dividers) do
    local signature = divider_signature(divider)
    if not seen_dividers[signature] and valid_rect(divider) then
      seen_dividers[signature] = true
      for i = 1, #panels do
        local a = panels[i]
        local rect_a = effective_rect(a)
        if not a.hidden and a.visible ~= false and valid_rect(rect_a) then
          for j = 1, #panels do
            if i ~= j then
              local b = panels[j]
              local rect_b = effective_rect(b)
              if not b.hidden and b.visible ~= false and valid_rect(rect_b) then
                local start, finish, touches
                if divider.axis == "x" then
                  touches = close(rect_a.x + rect_a.w, divider.x)
                    and close(rect_b.x, divider.x + divider.w)
                  start = math.max(rect_a.y, rect_b.y, divider.y)
                  finish = math.min(rect_a.y + rect_a.h, rect_b.y + rect_b.h,
                    divider.y + divider.h)
                elseif divider.axis == "y" then
                  touches = close(rect_a.y + rect_a.h, divider.y)
                    and close(rect_b.y, divider.y + divider.h)
                  start = math.max(rect_a.x, rect_b.x, divider.x)
                  finish = math.min(rect_a.x + rect_a.w, rect_b.x + rect_b.w,
                    divider.x + divider.w)
                end

                if touches and finish and finish > start then
                  local out
                  if divider.axis == "x" then
                    out = { key = segment_key(divider, "x", start, finish), axis = "x",
                      a = a.id, b = b.id, x = divider.x, y = start,
                      w = divider.w, h = finish - start }
                  else
                    out = { key = segment_key(divider, "y", start, finish), axis = "y",
                      a = a.id, b = b.id, x = start, y = divider.y,
                      w = finish - start, h = divider.h }
                  end
                  out.divider = divider
                  pairs[#pairs + 1] = out
                end
              end
            end
          end
        end
      end
    end
  end

  table.sort(pairs, function(left, right) return left.key < right.key end)
  return pairs
end

return divider_pairs
