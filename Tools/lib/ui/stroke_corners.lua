-- Native polylines join segments with averaged-normal miters. On a sharp turn
-- the miter is capped, which squashes the short segments either side of it:
-- steep zig-zags then draw thinner than the stroke width or almost vanish, and
-- smaller turns poke pointed tips past the measured value. Lines that can turn
-- sharply end their stroke at the corner, start a new one from the same point,
-- and cover the join with a round dot.
local corners = {}

-- True for turns greater than 60 degrees between direction a and direction b,
-- including either end of a narrow flat-bottomed dip.
function corners.sharp(ax, ay, bx, by)
  local dot = ax * bx + ay * by
  return dot < 0 or dot * dot < .25 * (ax * ax + ay * ay) * (bx * bx + by * by)
end

function corners.join(R, dl, x, y, colour, thickness)
  R.ImGui_DrawList_AddCircleFilled(dl, x, y, thickness / 2, colour, 12)
end

return corners
