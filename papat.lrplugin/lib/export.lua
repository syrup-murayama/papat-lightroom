--[[
  lib/export.lua — render selected photos to small JPEGs with Lightroom's own exporter

  Uses LrExportSession (so develop settings, crops and colour management apply):
  long edge 2048 px, sRGB, JPEG quality 80, location removed.
  Whatever Lightroom embeds is stripped by lib/jpeg.lua before upload and only the copyright /
  creator / contact details are written back (lib/rights.lua).
  Output goes to a fresh temp folder. Must run inside an async task.
]]

local LrExportSession = import 'LrExportSession'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'

local config = dofile(_PLUGIN.path .. '/lib/config.lua')
local ids = dofile(_PLUGIN.path .. '/lib/ids.lua')
local log = dofile(_PLUGIN.path .. '/lib/log.lua')

local M = {}

function M.newTempDir()
  local base = LrPathUtils.getStandardFilePath('temp')
  local dir = LrPathUtils.child(base, 'papat-' .. ids.uuid())
  LrFileUtils.createAllDirectories(dir)
  return dir
end

--- Remove only what this plugin wrote: the rendered files, then the (empty) folder.
function M.cleanup(dir, files)
  for _, path in ipairs(files or {}) do
    if LrFileUtils.exists(path) then LrFileUtils.delete(path) end
  end
  if dir and LrFileUtils.exists(dir) then
    local leftovers = false
    for _ in LrFileUtils.files(dir) do leftovers = true; break end
    if not leftovers then LrFileUtils.delete(dir) end
  end
end

local function exportSettings(dir)
  local edge = config.EXPORT_LONG_EDGE
  return {
    LR_export_destinationType = 'specificFolder',
    LR_export_destinationPathPrefix = dir,
    LR_export_useSubfolder = false,
    LR_collisionHandling = 'rename',
    LR_renamingTokensOn = false,
    LR_extensionCase = 'lowercase',
    LR_reimportExportedPhoto = false,

    LR_format = 'JPEG',
    LR_jpeg_quality = config.EXPORT_QUALITY,
    LR_export_colorSpace = 'sRGB',

    -- A edge x edge box is a "long edge = 2048" limit for every aspect ratio.
    LR_size_doConstrain = true,
    LR_size_resizeType = 'wh',
    LR_size_units = 'pixels',
    LR_size_maxWidth = edge,
    LR_size_maxHeight = edge,
    LR_size_doNotEnlarge = true,

    LR_outputSharpeningOn = true,
    LR_outputSharpeningMedia = 'screen',
    LR_outputSharpeningLevel = 2,

    -- Embedded metadata: Lightroom's own output is not relied on. Everything it writes is
    -- stripped by lib/jpeg.lua and the copyright / creator / contact details are written back
    -- from the catalog values (lib/rights.lua). These flags only keep the temporary file small.
    LR_minimizeEmbeddedMetadata = true,
    LR_removeLocationMetadata = true,
    LR_removeFaceMetadata = true,
    LR_includeVideoFiles = false,
    LR_useWatermark = false,
  }
end

local function photoOf(rendition)
  -- documented as a read-only property; the type stubs show a method. Accept both.
  if type(rendition.photo) == 'function' then return rendition:photo() end
  return rendition.photo
end

--- Render the photos one after another and hand each file over as soon as it exists,
--- so uploading can start before the last photo is rendered.
---   onRendered(photo, path)   a JPEG is ready
---   onFailed(photo, message)  Lightroom could not render this photo
---   isCanceled()              polled between photos
--- @return boolean canceled
function M.renderStream(photos, dir, onRendered, onFailed, isCanceled)
  -- Not inside pcall: creating the session yields (it asks Lightroom to prepare the renditions),
  -- and inside pcall Lightroom takes the caller for the main UI task and refuses
  -- ("addRenditionsForPhotos: must not call on main UI task"). Call from an async task.
  local session = LrExportSession({
    photosToExport = photos,
    exportSettings = exportSettings(dir),
  })

  for _, rendition in session:renditions({ stopIfCanceled = true }) do
    if isCanceled and isCanceled() then return true end
    local ok, pathOrMessage = rendition:waitForRender()
    if ok then
      onRendered(photoOf(rendition), pathOrMessage)
    else
      log.warn('render failed: %s', tostring(pathOrMessage))
      onFailed(photoOf(rendition), tostring(pathOrMessage))
    end
  end

  return isCanceled and isCanceled() or false
end

return M
