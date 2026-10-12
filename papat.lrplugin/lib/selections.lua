--[[
  lib/selections.lua — normalise a selections response (pure Lua, no LrC modules)

  Accepts, in order of preference:
    1. papat.selections/v1  { adopted = [ {source_id, filename, stem, adopted, rating, tags, memo} ] }
    2. a variant that lists every photo in `photos` with an `adopted` flag
    3. the legacy DO export   { version = 1, adopted = [ {stem, rating, tags, memo} ] }
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

--- @param data table decoded JSON
--- @return table|nil result  { sid, title, finalizedAt, items = {...} }
--- @return string|nil err
function M.normalize(data)
  if type(data) ~= 'table' then return nil, '結果の形式が正しくありません。' end

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
        result.items[#result.items + 1] = {
          sourceId = str(raw.source_id),
          filename = filename,
          stem = stem,
          rating = normalizeRating(raw.rating),
          tags = normalizeTags(raw.tags),
          memo = str(raw.memo),
        }
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
