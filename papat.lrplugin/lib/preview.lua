--[[
  lib/preview.lua — "speed first" mode: take the JPEG from Lightroom's own preview
  (photo:requestJpegThumbnail) instead of running a full export.

  Experimental. It is much faster, but the image is the cached preview rendered
  to the requested size, not a fresh export: quality, sharpening and the exact colour
  conversion can differ, and the size is limited by the catalog's standard preview
  size. Callers fall back to a normal export when this returns nil.

  Yields (waits for the callback) — call from an async task, not inside pcall.
]]

local LrTasks = import 'LrTasks'

local M = {}

local JPEG_SIGNATURE = '\255\216\255'

--- @return string|nil jpeg, string|nil reason
function M.jpeg(photo, edge, timeoutSeconds)
  local result = { done = false }
  -- The request object must stay referenced until the callback fires.
  local request = photo:requestJpegThumbnail(edge, edge, function(data, reason)
    result.data = data
    result.reason = reason
    result.done = true
  end)

  local waited = 0
  local limit = timeoutSeconds or 30
  while not result.done and waited < limit do
    LrTasks.sleep(0.05)
    waited = waited + 0.05
  end
  local _ = request

  if not result.done then return nil, 'timeout' end
  local data = result.data
  if type(data) ~= 'string' or #data < 4 or data:sub(1, 3) ~= JPEG_SIGNATURE then
    return nil, tostring(result.reason or 'no data')
  end
  return data
end

return M
