--[[
  lib/photoinfo.lua — what the gallery needs to know about each selected photo

    datetime   capture time (lib/capture.lua)
    rating     the photographer's star rating (0-5), shown as "撮影者" in the gallery;
               separate from the stars the client gives. Never written back to the catalog.
    fields     copyright / creator / contact details registered in Lightroom (lib/rights.lua)

  Values are read in two batch calls, not photo by photo.
]]

local capture = dofile(_PLUGIN.path .. '/lib/capture.lua')
local rights = dofile(_PLUGIN.path .. '/lib/rights.lua')

local M = {}

local RAW_KEYS = {
  'dateTimeISO8601', 'dateTimeOriginalISO8601', 'dateTimeDigitizedISO8601',
  'dateTime', 'dateTimeOriginal', 'dateTimeDigitized',
  'rating', 'copyrightState',
}

local function formattedKeys()
  local keys = {}
  for _, k in ipairs(rights.KEYS) do
    if not k.raw then keys[#keys + 1] = k.key end
  end
  return keys
end

--- @return table infos  [photo] = { datetime, rating, fields }
function M.gather(catalog, photos)
  local raw = catalog:batchGetRawMetadata(photos, RAW_KEYS) or {}
  local formatted = catalog:batchGetFormattedMetadata(photos, formattedKeys()) or {}

  local infos = {}
  for _, photo in ipairs(photos) do
    local r, f = raw[photo] or {}, formatted[photo] or {}
    local stars = math.floor(tonumber(r.rating) or 0)
    infos[photo] = {
      datetime = capture.datetimeFrom(function(key) return r[key] end),
      rating = math.max(0, math.min(5, stars)),
      fields = rights.collect(function(key, isRaw)
        if isRaw then return r[key] end
        return f[key]
      end),
    }
  end
  return infos
end

--- Group the photos by what they would say about their author.
--- @return table distinct  array of { fields, signature, count }, most photos first
function M.distinctRights(photos, infos)
  local bySignature, list = {}, {}
  for _, photo in ipairs(photos) do
    local fields = infos[photo].fields
    if not rights.isEmpty(fields) then
      local sig = rights.signature(fields)
      local entry = bySignature[sig]
      if not entry then
        entry = { fields = fields, signature = sig, count = 0 }
        bySignature[sig] = entry
        list[#list + 1] = entry
      end
      entry.count = entry.count + 1
    end
  end
  table.sort(list, function(a, b) return a.count > b.count end)
  return list
end

return M
