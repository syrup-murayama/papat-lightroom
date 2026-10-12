--[[
  lib/catalog.lua — everything that reads or writes the Lightroom catalog

  Rules this file keeps:
    * adopted photos go into a collection; the pick flag, caption (appended) and
      keywords (added) follow the Plug-in Manager switches;
    * the star rating and the color label are never written, not even as an option;
    * nothing is cleared or replaced: the caption keeps the photographer's text and
      gets "— papat: <memo>" on a new line (not repeated on re-import), keywords go
      under a "papat" parent keyword that is not exported;
    * papat's own plug-in fields (papatSourceId, papatSid, papatFilename) are written
      when a gallery is created, so a result can be matched back to the photo;
    * re-running an import does not duplicate collections, keywords or caption text.

  Call from an async task. Catalog writes happen inside withWriteAccessDo /
  withPrivateWriteAccessDo; nothing that yields is wrapped in pcall.
]]

local config = dofile(_PLUGIN.path .. '/lib/config.lua')
local text = dofile(_PLUGIN.path .. '/lib/text.lua')
local log = dofile(_PLUGIN.path .. '/lib/log.lua')

local M = {}

local FIELD_IDS = { 'papatSourceId', 'papatSid', 'papatFilename' }

-- ---------------------------------------------------------------------------
-- Reading
-- ---------------------------------------------------------------------------

local function candidatesFor(catalog, photos, withProperties)
  if not photos or #photos == 0 then return {} end
  local raw = catalog:batchGetRawMetadata(photos, { 'path' }) or {}
  local props = withProperties and catalog:batchGetPropertyForPlugin(photos, _PLUGIN, FIELD_IDS) or {}

  local out = {}
  for _, photo in ipairs(photos) do
    local r = raw[photo] or {}
    local p = props[photo] or {}
    out[#out + 1] = {
      handle = photo,
      sourceId = type(p.papatSourceId) == 'string' and p.papatSourceId or '',
      sid = type(p.papatSid) == 'string' and p.papatSid or '',
      papatFilename = type(p.papatFilename) == 'string' and p.papatFilename or '',
      fileName = text.leafOf(r.path or ''),
    }
  end
  return out
end

--- Photos this plug-in has uploaded before (carry papat metadata).
function M.linkedCandidates(catalog)
  local photos = catalog:findPhotosWithProperty(config.PLUGIN_ID, 'papatSourceId')
  return candidatesFor(catalog, photos, true)
end

--- Every photo in the catalog, by file name only (fallback matching).
function M.allCandidates(catalog)
  return candidatesFor(catalog, catalog:getAllPhotos(), false)
end

--- Existing source ids for photos, so a photo keeps one id across galleries.
function M.sourceIds(catalog, photos)
  local props = catalog:batchGetPropertyForPlugin(photos, _PLUGIN, { 'papatSourceId' }) or {}
  local out = {}
  for _, photo in ipairs(photos) do
    local p = props[photo]
    if p and type(p.papatSourceId) == 'string' and p.papatSourceId ~= '' then
      out[photo] = p.papatSourceId
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Writing: after upload
-- ---------------------------------------------------------------------------

--- records: array of { photo, sourceId, sid, filename }
--- @return string status  'executed' | 'queued' | 'aborted'
function M.recordUploads(catalog, records)
  return catalog:withPrivateWriteAccessDo(function()
    for _, r in ipairs(records) do
      r.photo:setPropertyForPlugin(_PLUGIN, 'papatSourceId', r.sourceId)
      r.photo:setPropertyForPlugin(_PLUGIN, 'papatSid', r.sid)
      r.photo:setPropertyForPlugin(_PLUGIN, 'papatFilename', r.filename)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Writing: put the adopted photos into collections (nothing else)
-- ---------------------------------------------------------------------------

local function trySet(photo, key, value)
  local ok, err = pcall(photo.setRawMetadata, photo, key, value)
  if not ok then log.warn('setRawMetadata(%s) failed: %s', key, tostring(err)) end
  return ok
end

--- @param plan table[]    from matching.collectionPlan
--- @param matched table[] { item, handle }
--- @param settings table  from config.settings()
--- @return string status ('executed' | 'queued' | 'aborted'), table summary
function M.apply(catalog, plan, matched, settings)
  local summary = { picked = 0, captioned = 0, keyworded = 0, pickFailed = 0 }

  local status = catalog:withWriteAccessDo('papat のセレクトを反映', function()
    local sets = {}
    for _, entry in ipairs(plan) do
      local parent = nil
      if entry.set then
        parent = sets[entry.set]
        if not parent then
          parent = catalog:createCollectionSet(entry.set, nil, true)
          sets[entry.set] = parent
        end
      end
      local collection = catalog:createCollection(entry.name, parent, true)
      collection:addPhotos(entry.handles)
    end

    if not (settings.applyPick or settings.applyMemo or settings.applyTags) then return end

    local parentKeyword
    local keywordCache = {}
    local function keywordFor(name)
      if not parentKeyword then
        parentKeyword = catalog:createKeyword(config.KEYWORD_PARENT, {}, false, nil, true)
      end
      local kw = keywordCache[name]
      if not kw then
        kw = catalog:createKeyword(name, {}, false, parentKeyword, true)
        keywordCache[name] = kw
      end
      return kw
    end

    for _, m in ipairs(matched) do
      local photo, item = m.handle, m.item

      if settings.applyPick then
        if trySet(photo, 'pickStatus', 1) then
          summary.picked = summary.picked + 1
        else
          summary.pickFailed = summary.pickFailed + 1
        end
      end

      if settings.applyMemo and item.memo ~= '' then
        local merged = text.appendMemo(photo:getRawMetadata('caption'), item.memo)
        if merged and trySet(photo, 'caption', merged) then
          summary.captioned = summary.captioned + 1
        end
      end

      if settings.applyTags and #item.tags > 0 then
        for _, tag in ipairs(item.tags) do
          local kw = keywordFor(tag)
          if kw then photo:addKeyword(kw) end
        end
        summary.keyworded = summary.keyworded + 1
      end
    end
  end)

  return status, summary
end

return M
