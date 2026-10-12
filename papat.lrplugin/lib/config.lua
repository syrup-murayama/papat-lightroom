--[[
  lib/config.lua — constants and preferences
]]

local LrPrefs = import 'LrPrefs'

local info = dofile(_PLUGIN.path .. '/Info.lua')

local M = {}

M.PLUGIN_ID = info.LrToolkitIdentifier
M.CLIENT_ID = 'papat-lrc'

local v = info.VERSION
M.VERSION = string.format('%d.%d.%d', v.major, v.minor, v.revision)

M.BASE_URL = 'https://papat.app'
M.API_BASE = M.BASE_URL .. '/api/v1'
M.DASHBOARD_URL = M.BASE_URL .. '/app'
M.HELP_URL = M.BASE_URL .. '/lightroom/'
M.SUPPORT_MAIL = 'hello@papat.app'

-- Export: long edge 2048 px, sRGB, JPEG quality 80.
M.EXPORT_LONG_EDGE = 2048
M.EXPORT_QUALITY = 0.8

-- Parent keyword for client tags (created on demand, not exported).
M.KEYWORD_PARENT = 'papat'

--- Preferences (Plug-in Manager). Pick flag, memo -> caption (appended) and tag ->
--- keyword are ON unless switched off (unset = on); star sub-collections are OFF
--- unless switched on. The star rating and color label are never written.
function M.settings()
  local prefs = LrPrefs.prefsForPlugin()
  return {
    applyPick = prefs.applyPick ~= false,
    applyMemo = prefs.applyMemo ~= false,
    applyTags = prefs.applyTags ~= false,
    starCollections = prefs.starCollections == true,
    -- experimental: take the 2048px JPEG from Lightroom's preview instead of exporting
    fastMode = prefs.fastMode == true,
    -- show the photographer's stars in the gallery ("撮影者"); on unless switched off
    showRating = prefs.showRating ~= false,
    -- copyright / creator / contact details in the image; on unless switched off
    embedRights = prefs.embedRights ~= false,
  }
end

function M.prefs()
  return LrPrefs.prefsForPlugin()
end

return M
