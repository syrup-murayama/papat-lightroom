--[[
  lib/addto.lua — "papat の既存のギャラリーに追加…" (1.2.6): the decisions, without any SDK call

    activeGalleries   which galleries of GET /galleries can still take photos, newest first
    existing          what the gallery's manifest already holds (names, source ids, count)
    plan              which of the selected photos go, which are skipped, and whether the gallery
                      would be over its limit

  Pure Lua: tests/run.lua exercises it directly; AddToGallery.lua does the dialogs and the send.
]]

local text = dofile(_PLUGIN.path .. '/lib/text.lua')

local M = {}

--- The galleries a photo can still be added to: status "active" and not past `expires_at`
--- (the server answers 404 for anything else). Newest first (`created_at`).
--- @param list table  res.galleries of api.listGalleries
--- @param now number  UNIX seconds
--- @return table  array of { sid, title, createdAt, expiresAt }
function M.activeGalleries(list, now)
  local out = {}
  for _, g in ipairs(type(list) == 'table' and list or {}) do
    if type(g) == 'table' and type(g.sid) == 'string' and g.sid ~= '' and g.status == 'active' then
      local expires = text.isoToEpoch(g.expires_at)
      -- no expiry given: the server treats it as not expiring
      if expires == nil or expires > now then
        out[#out + 1] = {
          sid = g.sid,
          title = type(g.title) == 'string' and g.title or '',
          createdAt = type(g.created_at) == 'string' and g.created_at or '',
          expiresAt = type(g.expires_at) == 'string' and g.expires_at or '',
        }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.createdAt ~= b.createdAt then return a.createdAt > b.createdAt end
    return a.sid < b.sid
  end)
  return out
end

--- "秋の撮影  （11/20 作成・11月27日（金）11:00まで）"
function M.label(g, offset)
  local title = (g.title ~= '') and g.title or '（無題）'
  local y, m, d = text.isoToLocalDate(g.createdAt, offset)
  local parts = {}
  if y then parts[#parts + 1] = string.format('%d/%d 作成', m, d) end
  local expire = text.expireText(g.expiresAt, offset)
  if expire ~= '' then parts[#parts + 1] = expire end
  if #parts == 0 then return title end
  return title .. '  （' .. table.concat(parts, '・') .. '）'
end

--- What the manifest already holds.
--- @param manifest table|nil  the decoded manifest.json (nil / no photos = an empty gallery)
--- @return table { count, sourceIds = { [id] = true }, usedNames = { file name, ... }, title, theme, credit, groupThreshold }
function M.existing(manifest)
  local out = { count = 0, sourceIds = {}, usedNames = {}, seen = {} }
  if type(manifest) ~= 'table' then return out end
  local function use(name)
    if type(name) ~= 'string' or name == '' then return end
    local key = name:lower()
    if out.seen[key] then return end
    out.seen[key] = true
    out.usedNames[#out.usedNames + 1] = name
  end
  local photos = type(manifest.photos) == 'table' and manifest.photos or {}
  for _, p in ipairs(photos) do
    if type(p) == 'table' then
      if type(p.source_id) == 'string' and p.source_id ~= '' then out.sourceIds[p.source_id] = true end
      use(p.filename)
      -- the server joins a photo by its stem too: a new photo called <stem>.jpg would replace one
      -- that has the same stem with another extension, so that name counts as taken as well
      if type(p.stem) == 'string' and p.stem ~= '' then use(p.stem .. '.jpg') end
    end
  end
  out.seen = nil
  out.count = math.max(#photos, tonumber(manifest.count) or 0)
  -- what the gallery already says about itself: the add keeps it as it is
  if type(manifest.title) == 'string' then out.title = manifest.title end
  if type(manifest.theme) == 'string' then out.theme = manifest.theme end
  if type(manifest.credit) == 'string' then out.credit = manifest.credit end
  if tonumber(manifest.groupThreshold) then out.groupThreshold = tonumber(manifest.groupThreshold) end
  return out
end

--- The fields of a manifest that a PUT would otherwise overwrite (lib/pipeline.lua's `base`).
function M.base(existing, fallbackTitle)
  return {
    title = existing.title or fallbackTitle or '',
    theme = existing.theme or 'default',
    credit = existing.credit or '',
    groupThreshold = existing.groupThreshold or 3,
  }
end

--- Decide what to send.
--- @param existing table  from M.existing
--- @param items table     array of { photo, sourceId }
--- @param maxPhotos number  what one gallery may hold (the server's number, or 1,000)
--- @return table { send = items, skipped = n, count = existing.count, over = nil | n }
---   over = how many photos too many (existing + new > maxPhotos): then nothing is sent
function M.plan(existing, items, maxPhotos)
  local send, skipped = {}, 0
  for _, item in ipairs(items) do
    if existing.sourceIds[item.sourceId] then
      skipped = skipped + 1
    else
      send[#send + 1] = item
    end
  end
  local result = { send = send, skipped = skipped, count = existing.count, max = maxPhotos }
  if existing.count + #send > maxPhotos then result.over = existing.count + #send - maxPhotos end
  return result
end

return M
