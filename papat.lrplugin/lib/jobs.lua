--[[
  lib/jobs.lua — "recent galleries" and unfinished upload jobs

  recent galleries  LrPasswords (macOS Keychain): URL, passcode, expiry … — the
                    passcode is secret, so it never goes to LrPrefs or the log.
  jobs              LrPrefs: which photos of a gallery are still to be sent
                    (catalog uuid + source id) and the file names already used,
                    so "続きから送る" can continue after a restart.
]]

local LrPasswords = import 'LrPasswords'

local config = dofile(_PLUGIN.path .. '/lib/config.lua')
local json = dofile(_PLUGIN.path .. '/lib/json.lua')

local M = {}

local RECENT_KEY = 'recentGalleries'
local MAX_RECENT = 10
local MAX_JOBS = 5

-- ---------------------------------------------------------------------------
-- Recent galleries
-- ---------------------------------------------------------------------------

function M.loadRecent()
  local ok, raw = pcall(LrPasswords.retrieve, RECENT_KEY, config.PLUGIN_ID, config.PLUGIN_ID)
  if not ok or type(raw) ~= 'string' or raw == '' then return {} end
  local okDecode, list = pcall(json.decode, raw)
  if not okDecode or type(list) ~= 'table' then return {} end
  return list
end

local function saveRecent(list)
  local okEncode, raw = pcall(json.encode, list)
  if not okEncode then return false end
  return (pcall(LrPasswords.store, RECENT_KEY, raw, config.PLUGIN_ID, config.PLUGIN_ID))
end

--- entry: { sid, title, url, passcode, expiresAt, createdAt, total, uploaded, keyColor, complete }
function M.addRecent(entry)
  local list = { entry }
  for _, e in ipairs(M.loadRecent()) do
    if type(e) == 'table' and e.sid ~= entry.sid then list[#list + 1] = e end
    if #list >= MAX_RECENT then break end
  end
  return saveRecent(list)
end

function M.updateRecent(sid, fields)
  local list = M.loadRecent()
  for _, e in ipairs(list) do
    if type(e) == 'table' and e.sid == sid then
      for k, v in pairs(fields) do e[k] = v end
    end
  end
  return saveRecent(list)
end

function M.removeRecent(sid)
  local list = {}
  for _, e in ipairs(M.loadRecent()) do
    if type(e) == 'table' and e.sid ~= sid then list[#list + 1] = e end
  end
  return saveRecent(list)
end

-- ---------------------------------------------------------------------------
-- Jobs (what is still to be sent)
-- ---------------------------------------------------------------------------

local function loadJobs()
  local raw = config.prefs().jobsJson
  if type(raw) ~= 'string' or raw == '' then return { order = {}, bySid = {} } end
  local ok, data = pcall(json.decode, raw)
  if not ok or type(data) ~= 'table' or type(data.order) ~= 'table' or type(data.bySid) ~= 'table' then
    return { order = {}, bySid = {} }
  end
  return data
end

local function saveJobs(data)
  config.prefs().jobsJson = json.encode(data)
end

--- job: { pending = { {uuid, sourceId}, ... }, used = { filename, ... } }
function M.saveJob(sid, job)
  local data = loadJobs()
  local order = { sid }
  for _, s in ipairs(data.order) do
    if s ~= sid then order[#order + 1] = s end
  end
  while #order > MAX_JOBS do
    data.bySid[order[#order]] = nil
    order[#order] = nil
  end
  data.order = order
  data.bySid[sid] = job
  saveJobs(data)
end

function M.getJob(sid)
  return loadJobs().bySid[sid]
end

function M.removeJob(sid)
  local data = loadJobs()
  data.bySid[sid] = nil
  local order = {}
  for _, s in ipairs(data.order) do
    if s ~= sid then order[#order + 1] = s end
  end
  data.order = order
  saveJobs(data)
end

return M
