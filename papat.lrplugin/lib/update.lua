--[[
  lib/update.lua — "is there a newer plug-in?" (notice only; nothing is ever replaced
  by the plug-in itself — new versions arrive through the signed installer)

  Source: GET /api/v1/integration/status → client.{minimum_version, latest_version,
  update_available, update_required}. The decision logic is text.updateDecision.

  * optional update  → one quiet notice per day, the command goes on
  * required update  → the command is stopped with instructions (every time)
  * server unreachable / unknown answer → never blocks; a cached answer (≤ 1 hour old)
    is reused so a command does not wait for the network on every run

  Yields (HTTP, dialogs): call from an async task, not inside pcall.
]]

local LrDialogs = import 'LrDialogs'
local LrHttp = import 'LrHttp'

local config = dofile(_PLUGIN.path .. '/lib/config.lua')
local text = dofile(_PLUGIN.path .. '/lib/text.lua')
local api = dofile(_PLUGIN.path .. '/lib/api.lua')
local json = dofile(_PLUGIN.path .. '/lib/json.lua')
local log = dofile(_PLUGIN.path .. '/lib/log.lua')

local M = {}

local CHECK_TIMEOUT = 8 -- seconds; a command must not hang on a slow network

local function loadCache()
  local raw = config.prefs().updateInfoJson
  if type(raw) ~= 'string' or raw == '' then return nil end
  local ok, data = pcall(json.decode, raw)
  if ok and type(data) == 'table' and data.forVersion == config.VERSION then return data end
  return nil
end

local function saveCache(info)
  info.forVersion = config.VERSION
  info.fetchedAt = os.time()
  config.prefs().updateInfoJson = json.encode(info)
end

--- @return table|nil info  { minimum, latest, available, required }
local function currentInfo(apiKey)
  local cached = loadCache()
  if cached and cached.fetchedAt and (os.time() - cached.fetchedAt) < text.UPDATE_CACHE_SECONDS
    and cached.fetchedAt <= os.time() then
    return cached
  end

  local res = api.status(apiKey, CHECK_TIMEOUT)
  if not res.ok then
    log.info('update check: status unavailable (%s)', tostring(res.status))
    return cached -- stale answer (or nil): never block on a failed check
  end

  local client = type(res.data.client) == 'table' and res.data.client or {}
  local info = {
    minimum = client.minimum_version,
    latest = client.latest_version,
    available = client.update_available == true,
    required = client.update_required == true,
    -- the remaining free galleries ride along (shown in the create dialog; never hard-coded)
    freeRemaining = text.parseFreeRemaining(res.data.free_galleries_remaining),
    -- the most photos a gallery may hold: the create command checks against it
    maxPhotos = text.parseMaxPhotos(res.data.max_photos),
  }
  saveCache(info)
  return info
end

--- Remaining free galleries as last told by the server (status or a create response), or nil.
--- Reads the cache only: no request.
function M.freeRemaining()
  local cached = loadCache()
  return cached and text.parseFreeRemaining(cached.freeRemaining) or nil
end

--- The most photos one gallery may hold, as the server last said (status call, cached), or the
--- plug-in's own assumption (text.MAX_PHOTOS) when it did not say. Reads the cache: no request.
function M.maxPhotos()
  local cached = loadCache()
  return (cached and text.parseMaxPhotos(cached.maxPhotos)) or text.MAX_PHOTOS
end

--- Remember the number from a create response (nil is ignored).
function M.rememberFree(count)
  count = text.parseFreeRemaining(count)
  if count == nil then return end
  local cached = loadCache() or { fetchedAt = 0 }
  cached.freeRemaining = count
  cached.forVersion = config.VERSION
  config.prefs().updateInfoJson = json.encode(cached)
end

--- Check and tell. Returns false when the command must stop (required update).
--- @param opts table|nil  { blocking = true }  (false: only ever tell, never stop)
function M.checkAndTell(apiKey, opts)
  local blocking = not (opts and opts.blocking == false)
  local info = currentInfo(apiKey)
  local decision = text.updateDecision(config.VERSION, info)
  if decision == 'none' then return true end

  local latest = (info and info.latest) or ''
  local versions = 'いまのバージョン: v' .. config.VERSION
    .. (latest ~= '' and ('　最新: v' .. latest) or '')
  local how = '更新の手順:\n'
    .. '1. ダウンロードページから papat-lightroom-〈バージョン〉.pkg をダウンロード\n'
    .. '2. .pkg をダブルクリックして、画面の案内どおりに進める（古い版は自動でバックアップに退避されます。'
    .. 'API キーと最近のギャラリーはそのまま残ります）\n'
    .. '3. Lightroom Classic を再起動する'

  if decision == 'required' then
    log.info('update required: current=%s minimum=%s', config.VERSION, tostring(info and info.minimum))
    local choice = LrDialogs.confirm(
      'papat の更新が必要です',
      'この版のプラグインは、現在の papat では使えません。\n' .. versions .. '\n\n' .. how,
      'ダウンロードページを開く',
      '閉じる'
    )
    if choice == 'ok' then LrHttp.openUrlInBrowser(config.HELP_URL) end
    return not blocking
  end

  -- optional: once a day, and the command carries on
  local prefs = config.prefs()
  local now = os.time()
  if text.updateNoticeDue(prefs.updateNotifiedAt, now, text.UPDATE_NOTICE_INTERVAL) then
    prefs.updateNotifiedAt = now
    local choice = LrDialogs.confirm(
      'papat の新しいバージョンがあります',
      versions .. '\n\n' .. how .. '\n\nこのまま続けて使えます。',
      'ダウンロードページを開く',
      'あとで'
    )
    if choice == 'ok' then LrHttp.openUrlInBrowser(config.HELP_URL) end
  end
  return true
end

return M
