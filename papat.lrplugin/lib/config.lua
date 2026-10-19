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
--- 1.1.0 made the preview ("速さ優先") the default. A preference that an earlier version stored
--- (1.0.x had it off unless switched on) is dropped once, so everybody starts from the new default;
--- what is chosen afterwards in the Plug-in Manager is kept.
function M.migrate()
  local prefs = LrPrefs.prefsForPlugin()
  if prefs.fastModeDefaultV110 ~= true then
    prefs.fastMode = nil
    prefs.fastModeDefaultV110 = true
  end
end

function M.settings()
  M.migrate()
  local prefs = LrPrefs.prefsForPlugin()
  return {
    applyPick = prefs.applyPick ~= false,
    applyMemo = prefs.applyMemo ~= false,
    applyTags = prefs.applyTags ~= false,
    starCollections = prefs.starCollections == true,
    -- take the JPEG from Lightroom's preview instead of exporting (default since 1.1.0; the
    -- create dialog can still export "this time only")
    fastMode = prefs.fastMode ~= false,
    -- the small versions for the gallery's overview (thumbs/); on unless switched off. No screen:
    -- there is no reason for a photographer to turn them off, this is for troubleshooting.
    thumbs = prefs.thumbs ~= false,
    -- show the photographer's stars in the gallery ("撮影者"); on unless switched off
    showRating = prefs.showRating ~= false,
    -- copyright / creator / contact details in the image; on unless switched off
    embedRights = prefs.embedRights ~= false,
  }
end

function M.prefs()
  return LrPrefs.prefsForPlugin()
end

--- "送信の記録" (1.2.1): asked once (CreateGallery.lua, the first gallery created after
--- updating); the Plug-in Manager checkbox can change the choice afterwards. `asked` on its
--- own tells whether the one-time dialog is still owed; it stays true forever once shown (or
--- once the Plug-in Manager checkbox is touched directly, which counts as having decided).
function M.reportStatus()
  local prefs = LrPrefs.prefsForPlugin()
  return { asked = prefs.reportAsked == true, consent = prefs.reportConsent == true }
end

function M.setReportConsent(consent)
  local prefs = LrPrefs.prefsForPlugin()
  prefs.reportAsked = true
  prefs.reportConsent = consent == true
end

return M
