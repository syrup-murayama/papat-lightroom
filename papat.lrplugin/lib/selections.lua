--[[
  lib/selections.lua — normalise a selections response (pure Lua, no LrC modules)

  The body's own `schema` decides how it is read (a server that predates ?schema= ignores the
  request and answers v1, so the shape that was asked for is never trusted):
    papat.selections/v2  { photos = [ {source_id, filename, stem, pick,
                                       reviewer = {rating, keywords, keywords_edited, note},
                                       photographer = {rating, keywords}} ] }
                         adoption is decided by `pick == true` alone (being listed means nothing);
                         `scope` ("picked" / "all") makes no difference; `photographer`,
                         `keywords_edited` and `kind` are not used. The reviewer's rating is only
                         carried along: it is never written to Lightroom's stars.
    papat.selections/v1  { adopted = [ {source_id, filename, stem, adopted, rating, tags, memo} ] }
    no schema            a variant that lists every photo in `photos` with an `adopted` flag, or
                         the legacy DO export { version = 1, adopted = [ {stem, rating, tags, memo} ] }
    papat.selections/vN  (N > 2) or any other schema: refused with a message, never guessed at.
  Unknown keys are ignored. JSON null decodes to nil.
]]

local _PLUGIN_PATH = (_PLUGIN and _PLUGIN.path) or '.'
local text = dofile(_PLUGIN_PATH .. '/lib/text.lua')

local M = {}

local function str(v)
  if type(v) == 'string' then return v end
  return ''
end

local function normalizeTags(v)
  local tags = {}
  if type(v) == 'table' then
    for _, t in ipairs(v) do
      local s = text.trim(tostring(t))
      if s ~= '' then tags[#tags + 1] = s end
    end
  elseif type(v) == 'string' then
    for part in v:gmatch('[^,、]+') do
      local s = text.trim(part)
      if s ~= '' then tags[#tags + 1] = s end
    end
  end
  return tags
end

local function normalizeRating(v)
  local n = math.floor(tonumber(v) or 0)
  if n < 0 then return 0 end
  if n > 5 then return 5 end
  return n
end

local function item(sourceId, filename, stem, rating, tags, memo)
  return { sourceId = sourceId, filename = filename, stem = stem, rating = normalizeRating(rating),
    tags = tags, memo = memo }
end

--- papat.selections/v2: the chooser's values are under `reviewer` of each photo row. A row that
--- lacks a boolean `pick` or a `stem` is dropped on its own (the rest still import); pick == false
--- is not adopted. A missing `reviewer` reads as empty (no keywords, no note).
local function normalizeV2(data)
  local list = data.photos
  if type(list) ~= 'table' then return nil, '結果の形式が正しくありません。' end
  local gallery = type(data.gallery) == 'table' and data.gallery or {}
  local result = {
    sid = str(gallery.sid),
    title = str(gallery.title),
    finalizedAt = str(gallery.finalized_at),
    items = {},
  }
  for _, raw in ipairs(list) do
    if type(raw) == 'table' and raw.pick == true and str(raw.stem) ~= '' then
      local reviewer = type(raw.reviewer) == 'table' and raw.reviewer or {}
      local tags = type(reviewer.keywords) == 'table' and normalizeTags(reviewer.keywords) or {}
      result.items[#result.items + 1] = item(str(raw.source_id), str(raw.filename), str(raw.stem),
        reviewer.rating, tags, str(reviewer.note))
    end
  end
  return result
end

local function shown(s)
  s = tostring(s):gsub('[%c]', ' ')
  if #s > 60 then s = s:sub(1, 60) .. '…' end
  return s
end

--- @param data table decoded JSON
--- @return table|nil result  { sid, title, finalizedAt, items = {...} }
--- @return string|nil err
--- @return string|nil errKind  'schema' when the body is a format this version cannot read
---   (the message already tells the user to update the plug-in)
function M.normalize(data)
  if type(data) ~= 'table' then return nil, '結果の形式が正しくありません。' end

  local schema = data.schema
  if schema ~= nil and schema ~= 'papat.selections/v1' then
    if schema == 'papat.selections/v2' then return normalizeV2(data) end
    local name, ver = tostring(schema):match('^(papat%.[%a][%w%-]*)/v([1-9]%d*)$')
    if type(schema) == 'string' and name == 'papat.selections' and tonumber(ver) > 2 then
      return nil, 'この結果は新しい版の形式（' .. shown(schema) .. '）です。papat のプラグインを新しい版にしてください。', 'schema'
    end
    return nil, 'この結果は「' .. shown(schema) .. '」という形式で、このプラグインでは読めません。papat のプラグインを新しい版にしてください。', 'schema'
  end

  local list = data.adopted
  if type(list) ~= 'table' then list = data.photos end
  if type(list) ~= 'table' then
    return nil, '結果の形式が正しくありません。'
  end

  local gallery = type(data.gallery) == 'table' and data.gallery or {}
  local result = {
    sid = str(data.sid) ~= '' and str(data.sid) or str(gallery.id),
    title = str(data.title) ~= '' and str(data.title) or str(gallery.title),
    finalizedAt = str(data.finalized_at) ~= '' and str(data.finalized_at) or str(gallery.finalized_at),
    items = {},
  }

  for _, raw in ipairs(list) do
    if type(raw) == 'table' and raw.adopted ~= false then
      local filename = str(raw.filename)
      local stem = str(raw.stem)
      if stem == '' and filename ~= '' then stem = text.stemOf(filename) end
      if stem ~= '' or filename ~= '' or str(raw.source_id) ~= '' then
        result.items[#result.items + 1] = item(str(raw.source_id), filename, stem, raw.rating,
          normalizeTags(raw.tags), str(raw.memo))
      end
    end
  end

  return result
end

--- Human label for an item in unmatched / ambiguous lists.
function M.label(item)
  if item.filename ~= '' then return item.filename end
  if item.stem ~= '' then return item.stem end
  return '（名前なし）'
end

return M
