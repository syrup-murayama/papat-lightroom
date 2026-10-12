--[[
  lib/matching.lua — match selection results to catalog photos (pure Lua)

  Candidates are plain records so the logic is testable without Lightroom:
    { handle = <LrPhoto>, sourceId = '', sid = '', papatFilename = '', fileName = 'IMG_0001.CR3' }

  Order of trust (the first stage that finds a candidate wins):
    1. source_id recorded by this plugin at upload time
    2. photos recorded with this gallery's sid, by uploaded filename / stem
    3. whole catalog, exact filename (case-insensitive)
    4. whole catalog, exact stem (case-insensitive)
  Never substring or fuzzy matching. When a key hits more than one photo the
  result is reported as ambiguous and is NOT applied automatically.
]]

local _PLUGIN_PATH = (_PLUGIN and _PLUGIN.path) or '.'
local text = dofile(_PLUGIN_PATH .. '/lib/text.lua')

local M = {}

local function push(map, key, value)
  if key == '' then return end
  local list = map[key]
  if not list then
    list = {}
    map[key] = list
  end
  list[#list + 1] = value
end

local function sameValue(a, b)
  if a.rating ~= b.rating or a.memo ~= b.memo or #a.tags ~= #b.tags then return false end
  for i = 1, #a.tags do
    if a.tags[i] ~= b.tags[i] then return false end
  end
  return true
end

local function indexLinked(linked)
  local idx = { bySource = {}, bySidName = {}, bySidStem = {} }
  for _, c in ipairs(linked) do
    push(idx.bySource, c.sourceId or '', c)
    if (c.sid or '') ~= '' and (c.papatFilename or '') ~= '' then
      push(idx.bySidName, c.sid .. '\0' .. text.nameKey(c.papatFilename), c)
      push(idx.bySidStem, c.sid .. '\0' .. text.nameKey(text.stemOf(c.papatFilename)), c)
    end
  end
  return idx
end

local function indexAll(all)
  local idx = { byName = {}, byStem = {} }
  for _, c in ipairs(all) do
    push(idx.byName, text.nameKey(c.fileName or ''), c)
    push(idx.byStem, text.nameKey(text.stemOf(c.fileName or '')), c)
  end
  return idx
end

local function narrowBySid(list, sid)
  local out = {}
  for _, c in ipairs(list) do
    if c.sid == sid then out[#out + 1] = c end
  end
  return out
end

--- Resolve one item against the linked (plugin-recorded) photos.
--- returns candidate | nil (not found) | false, count (ambiguous)
local function resolveLinked(item, sid, idx)
  if item.sourceId ~= '' then
    local list = idx.bySource[item.sourceId]
    if list then
      if #list == 1 then return list[1], 'source' end
      local narrowed = narrowBySid(list, sid)
      if #narrowed == 1 then return narrowed[1], 'source' end
      return false, #list
    end
  end
  if sid ~= '' then
    if item.filename ~= '' then
      local list = idx.bySidName[sid .. '\0' .. text.nameKey(item.filename)]
      if list then
        if #list == 1 then return list[1], 'sid' end
        return false, #list
      end
    end
    if item.stem ~= '' then
      local list = idx.bySidStem[sid .. '\0' .. text.nameKey(item.stem)]
      if list then
        if #list == 1 then return list[1], 'sid' end
        return false, #list
      end
    end
  end
  return nil
end

local function resolveAll(item, idx)
  if item.filename ~= '' then
    local list = idx.byName[text.nameKey(item.filename)]
    if list then
      if #list == 1 then return list[1], 'filename' end
      return false, #list
    end
  end
  local stem = item.stem
  if stem == '' then stem = text.stemOf(item.filename) end
  if stem ~= '' then
    local list = idx.byStem[text.nameKey(stem)]
    if list then
      if #list == 1 then return list[1], 'stem' end
      return false, #list
    end
  end
  return nil
end

--- @param items table[]   normalised selection items (see selections.lua)
--- @param sid string      gallery id the results belong to
--- @param linked table[]  candidates carrying plugin metadata
--- @param loadAll function|nil  () -> candidates for the whole catalog; called lazily
--- @return table { matched = {{item,handle,how}}, unmatched = {item}, ambiguous = {{item,count,reason}} }
function M.match(items, sid, linked, loadAll)
  local linkedIdx = indexLinked(linked or {})
  local allIdx = nil

  local result = { matched = {}, unmatched = {}, ambiguous = {} }
  local seen = {} -- handle -> index in result.matched

  for _, item in ipairs(items) do
    local cand, how = resolveLinked(item, sid or '', linkedIdx)

    if cand == nil then
      if loadAll then
        if not allIdx then allIdx = indexAll(loadAll() or {}) end
        cand, how = resolveAll(item, allIdx)
      end
    end

    if cand == nil then
      result.unmatched[#result.unmatched + 1] = item
    elseif cand == false then
      result.ambiguous[#result.ambiguous + 1] = { item = item, count = how, reason = 'multiple' }
    else
      local at = seen[cand.handle]
      if at then
        local prev = result.matched[at]
        if prev and not sameValue(prev.item, item) then
          -- two different results for one photo: hold it back instead of guessing
          table.remove(result.matched, at)
          for h, i in pairs(seen) do
            if i > at then seen[h] = i - 1 end
          end
          seen[cand.handle] = false
          result.ambiguous[#result.ambiguous + 1] = { item = prev.item, count = 1, reason = 'conflict' }
          result.ambiguous[#result.ambiguous + 1] = { item = item, count = 1, reason = 'conflict' }
        end
      elseif at == nil then
        result.matched[#result.matched + 1] = { item = item, handle = cand.handle, how = how }
        seen[cand.handle] = #result.matched
      else
        result.ambiguous[#result.ambiguous + 1] = { item = item, count = 1, reason = 'conflict' }
      end
    end
  end

  return result
end

--- Which collections an import creates, as plain data (testable).
---   default      -> one flat collection "papat 採用 <title> <date>"
---   starSets     -> collection set "papat <title> <date>" with "採用" + "★N" children
--- @param matched table[] { item = {rating}, handle }
--- @return table[] plan  { { set = string|nil, name = string, handles = {...} } }
function M.collectionPlan(matched, title, dateText, starSets)
  local label = title ~= '' and (title .. ' ' .. dateText) or dateText
  local all = {}
  for _, m in ipairs(matched) do all[#all + 1] = m.handle end

  if not starSets then
    return { { name = 'papat 採用 ' .. label, handles = all } }
  end

  local setName = 'papat ' .. label
  local plan = { { set = setName, name = '採用', handles = all } }
  for stars = 5, 1, -1 do
    local handles = {}
    for _, m in ipairs(matched) do
      if m.item.rating == stars then handles[#handles + 1] = m.handle end
    end
    if #handles > 0 then
      plan[#plan + 1] = { set = setName, name = '★' .. stars, handles = handles }
    end
  end
  return plan
end

return M
