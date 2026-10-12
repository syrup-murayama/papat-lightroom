--[[
  lib/capture.lua — a photo's capture time for the gallery manifest (`datetime`)

  The gallery sorts and groups by this string and shows its "HH:MM", so it is the camera's
  wall-clock time as "YYYY-MM-DDTHH:MM:SS" without a zone. Preference: the time Lightroom
  shows (adjusted capture time, which the photographer sets to line two cameras up), then the
  original, then the digitized time. Photos without any capture time (scans, composites) get ''.
]]

local text = dofile(_PLUGIN.path .. '/lib/text.lua')

local M = {}

local ISO_KEYS = { 'dateTimeISO8601', 'dateTimeOriginalISO8601', 'dateTimeDigitizedISO8601' }
local NUMBER_KEYS = { 'dateTime', 'dateTimeOriginal', 'dateTimeDigitized' }

--- @param get function(key) -> value
--- @return string "YYYY-MM-DDTHH:MM:SS" or ''
function M.datetimeFrom(get)
  for _, key in ipairs(ISO_KEYS) do
    local value = text.isoWallTime(get(key))
    if value then return value end
  end
  for _, key in ipairs(NUMBER_KEYS) do
    local value = text.cocoaToWallTime(get(key))
    if value then return value end
  end
  return ''
end

return M
