--[[
  lib/api.lua — papat integration API v1 over LrHttp

  Talks to the papat integration API v1 (/api/v1). Calls here yield
  (LrHttp, LrTasks.sleep): call from an async task and never wrap them in pcall.
  The API key travels only in the Authorization header over HTTPS.
]]

local LrHttp = import 'LrHttp'
local LrTasks = import 'LrTasks'

local config = dofile(_PLUGIN.path .. '/lib/config.lua')
local json = dofile(_PLUGIN.path .. '/lib/json.lua')
local text = dofile(_PLUGIN.path .. '/lib/text.lua')
local log = dofile(_PLUGIN.path .. '/lib/log.lua')

local M = {}

local TIMEOUT_SHORT = 30
local TIMEOUT_UPLOAD = 180

-- ---------------------------------------------------------------------------
-- Japanese error text. Every message says what to do next.
--
-- The server's stable error `code` decides the text; the HTTP status is only the
-- fallback for codes this plug-in does not know yet. Codes seen on the wire:
--   400 invalid_request invalid_manifest   401 invalid_api_key unauthorized
--   402 card_required monthly_limit paid_country_blocked
--                                          403 tenant_suspended gallery_forbidden invite_only
--   409 billing_country_required (card registration without a country)
--   404 gallery_not_found not_found        409 active_gallery_limit gallery_closed
--                                              idempotency_conflict extension_already_used
--   413 gallery_limit_reached file_too_large
--   415 invalid_image unsupported_media_type
--   422 passcode_required invalid_passcode card_required
--   429 rate_limited
--   500/502/503 internal_error upstream_error schema_not_applied
-- ---------------------------------------------------------------------------

-- the server writes some messages for people (Japanese); those can be shown as they are
local function hasJapanese(s)
  return type(s) == 'string' and s:find('[\227-\233]') ~= nil
end

local SERVER_TEXT_MAX = 300 -- characters; the server's wording is shown in a dialog

local function describe(status, code, serverMessage, retryAfter, data)
  code = code or ''
  -- whatever the server wrote is shown as one line of at most 300 characters
  serverMessage = text.oneLine(serverMessage, SERVER_TEXT_MAX)
  if serverMessage == '' then serverMessage = nil end

  if status == 0 then
    return 'papat に接続できませんでした。インターネットの接続を確認して、もう一度お試しください。'
  end

  -- 409: the code matters; the status alone says nothing useful
  if code == 'active_gallery_limit' then
    -- the number is the server's: say it only when the server sent it
    local max = data and tonumber(data.max_active_galleries) or nil
    return string.format(
      '公開中のギャラリーが上限%sに達しています。papat のダッシュボード（%s）で不要なギャラリーを終了するか、'
        .. '期限が切れるのを待ってから、もう一度お試しください。',
      max and string.format('の%d件', max) or '', config.DASHBOARD_URL
    )
  end
  if code == 'idempotency_conflict' then
    return '同じ操作がまだ処理中です。少し待ってから、もう一度お試しください。'
  end
  if code == 'extension_already_used' then
    return 'このギャラリーの延長はすでに使われています。'
  end
  if code == 'gallery_closed' then
    return 'このギャラリーはすでに終了しています。新しくギャラリーを作成してください。'
  end

  if status == 401 or code == 'invalid_api_key' or code == 'unauthorized' then
    return 'API キーが正しくないか、無効になっています。papat のダッシュボード（' .. config.DASHBOARD_URL
      .. '）でキーを発行し直し、ファイル → プラグインマネージャー → papat に入力してください。'
  end
  if code == 'monthly_limit' then
    -- the limit (and its number) belongs to the server and changes: show its wording; without it,
    -- a sentence that names no number
    if hasJapanese(serverMessage) then
      return serverMessage .. '（ダッシュボード: ' .. config.DASHBOARD_URL .. '）'
    end
    return '今月の利用の上限に達しています。請求が成功した後に、もう一度お試しください。'
      .. '（ダッシュボード: ' .. config.DASHBOARD_URL .. '）'
  end
  if code == 'card_required' or code == 'payment_required' then
    -- also raised for paid units (more than 300 photos, 14 days) after the free galleries
    return 'この操作にはカード登録が必要です（無料の範囲の基本利用はカード不要です）。ダッシュボード（'
      .. config.DASHBOARD_URL .. '）でカードを登録すると、続けて利用できます。'
  end
  if code == 'paid_country_blocked' then
    return hasJapanese(serverMessage)
      and serverMessage
      or 'ご登録の請求先の国では、有料のご利用に対応していません。詳しくはダッシュボード（' .. config.DASHBOARD_URL .. '）をご覧ください。'
  end
  if code == 'billing_country_required' then
    return '請求先の国を確認できません。ダッシュボード（' .. config.DASHBOARD_URL
      .. '）で住所を入力して、カード登録をやり直してください。'
  end
  if code == 'invite_only' then
    return 'この環境は、招待された方だけが使えます。'
  end
  if status == 402 then
    -- a message written for people by the server beats a guess
    if hasJapanese(serverMessage) then return serverMessage end
    return '同時に公開できるギャラリーの上限に達しています。ダッシュボードで不要なギャラリーを終了してから、もう一度お試しください。'
  end
  if status == 410 then
    return 'このギャラリーは終了または削除されています。新しくギャラリーを作成してください。'
  end
  if code == 'temporarily_unavailable' then
    return 'サーバーが混み合っています。少し待ってから、もう一度お試しください。'
  end
  if code == 'tenant_suspended' or code == 'gallery_forbidden' or status == 403 then
    return 'このアカウントでは現在ご利用いただけません。' .. config.SUPPORT_MAIL .. ' までご連絡ください。'
  end
  if code == 'invalid_passcode' then
    return 'パスコードを papat に登録できませんでした。パスコードを4〜64文字で入力し直して、もう一度お試しください。'
  end
  if code == 'passcode_required' then
    return 'パスコードが必要です。パスコードを入力してもう一度お試しください。'
  end
  if status == 404 or code == 'gallery_not_found' or code == 'not_found' then
    return 'ギャラリーが見つかりません。期限が切れたか、終了している可能性があります。ギャラリーを作り直してください。'
  end
  if code == 'gallery_limit_reached' or (status == 413 and code ~= 'file_too_large') then
    local numbers = M.limitNumbers(data)
    if numbers then
      return 'ギャラリーの上限に達しました（' .. numbers .. '）。枚数を減らして、新しいギャラリーに分けてください。'
    end
    return '写真の枚数または容量が上限を超えました。枚数を減らして、もう一度お試しください。'
  end
  if code == 'file_too_large' or status == 413 then
    return '1枚のサイズが大きすぎます。この写真は送れませんでした。'
  end
  if code == 'invalid_image' or code == 'unsupported_media_type' or status == 415 then
    return '送信できない形式の画像がありました。JPEG で書き出せる写真を選んでください。'
  end
  if status == 429 or code == 'rate_limited' then
    local wait = retryAfter and (tostring(retryAfter) .. ' 秒') or 'しばらく'
    return 'リクエストが集中しています。' .. wait .. '待ってから、もう一度お試しください。'
  end
  if status >= 500 then
    return 'papat のサーバーで一時的な問題が起きています。しばらくしてから、もう一度お試しください。'
  end
  if (status == 400 or code == 'invalid_request' or code == 'invalid_manifest')
    and type(serverMessage) == 'string' and serverMessage:find('key_color', 1, true) then
    return 'クライアントの色が正しくありません。#RRGGBB の形（例 #0066CC）で入力するか、空欄にしてください。'
  end
  if status == 400 or code == 'invalid_request' or code == 'invalid_manifest' then
    return '送信内容が正しくありませんでした（' .. tostring(serverMessage or code or status)
      .. '）。プラグインを最新版に更新して、それでも直らない場合は ' .. config.SUPPORT_MAIL .. ' までご連絡ください。'
  end
  if status == 409 then
    return '操作を完了できませんでした（' .. tostring(serverMessage or code or 'conflict')
      .. '）。時間をおいて、もう一度お試しください。直らない場合は ' .. config.SUPPORT_MAIL .. ' までご連絡ください。'
  end
  return '予期しないエラーが発生しました（HTTP ' .. tostring(status) .. '）。時間をおいて、もう一度お試しください。'
end

--- "いま 265枚・72 MB／上限 900枚・1024 MB" from whatever numbers the server sent (field names
--- are tolerated in several spellings); nil when it sent none.
function M.limitNumbers(data)
  if type(data) ~= 'table' then return nil end
  local function pick(...)
    for _, key in ipairs({ ... }) do
      local v = tonumber(data[key])
      if v then return v end
    end
    return nil
  end
  local count = pick('photos', 'photo_count', 'count', 'current_photos', 'uploaded_total')
  local maxCount = pick('max_photos', 'photo_limit', 'limit_photos', 'max_count')
  local bytes = pick('bytes', 'total_bytes', 'current_bytes', 'used_bytes')
  local maxBytes = pick('max_bytes', 'byte_limit', 'limit_bytes')
  local function mb(n) return string.format('%.0f MB', n / 1048576) end

  local nowPart, limitPart = {}, {}
  if count then nowPart[#nowPart + 1] = string.format('%d枚', count) end
  if bytes then nowPart[#nowPart + 1] = mb(bytes) end
  if maxCount then limitPart[#limitPart + 1] = string.format('%d枚', maxCount) end
  if maxBytes then limitPart[#limitPart + 1] = mb(maxBytes) end
  if #nowPart == 0 and #limitPart == 0 then return nil end
  local out = {}
  if #nowPart > 0 then out[#out + 1] = 'いま ' .. table.concat(nowPart, '・') end
  if #limitPart > 0 then out[#out + 1] = '上限 ' .. table.concat(limitPart, '・') end
  return table.concat(out, '／')
end

M.describe = describe

-- ---------------------------------------------------------------------------
-- Transport
-- ---------------------------------------------------------------------------

local function headerValue(headers, name)
  name = name:lower()
  for _, h in ipairs(headers or {}) do
    if type(h) == 'table' and type(h.field) == 'string' and h.field:lower() == name then
      return h.value
    end
  end
  return nil
end

local function request(method, path, apiKey, opts)
  opts = opts or {}
  local url = config.API_BASE .. path

  local headers = {
    { field = 'Authorization', value = 'Bearer ' .. apiKey },
    { field = 'Accept', value = 'application/json' },
    { field = 'X-Papat-Client', value = config.CLIENT_ID .. '/' .. config.VERSION },
  }
  if opts.contentType then
    headers[#headers + 1] = { field = 'Content-Type', value = opts.contentType }
  end
  if opts.idempotencyKey then
    headers[#headers + 1] = { field = 'Idempotency-Key', value = opts.idempotencyKey }
  end

  local body, respHeaders
  if method == 'GET' then
    body, respHeaders = LrHttp.get(url, headers, opts.timeout or TIMEOUT_SHORT)
  else
    body, respHeaders = LrHttp.post(url, opts.body or '', headers, method, opts.timeout or TIMEOUT_SHORT)
  end

  local status = type(respHeaders) == 'table' and tonumber(respHeaders.status) or nil
  if not status or (type(respHeaders) == 'table' and respHeaders.error and status == 0) then
    local detail = ''
    if type(respHeaders) == 'table' and type(respHeaders.error) == 'table' then
      detail = tostring(respHeaders.error.name or respHeaders.error.errorCode or '')
    end
    log.warn('%s %s -> network error %s', method, path, detail)
    return {
      ok = false, status = 0, network = true,
      message = describe(0),
    }
  end

  local data
  if type(body) == 'string' and body ~= '' then
    local okDecode, decoded = pcall(json.decode, body)
    if okDecode and type(decoded) == 'table' then data = decoded end
  end

  local retryAfter = tonumber(headerValue(respHeaders, 'Retry-After'))
  local success = status >= 200 and status < 300 and not (data and data.ok == false)
  if success and not data and opts.expectJson ~= false then
    success = false
    status = 502
  end

  if success then
    return { ok = true, status = status, data = data or {} }
  end

  local code = data and data.code or nil
  local serverMessage = data and (data.error or data.hint) or nil
  log.warn('%s %s -> HTTP %d code=%s', method, path, status, tostring(code))
  return {
    ok = false, status = status, code = code, data = data,
    retryAfter = retryAfter,
    needsCard = (code == 'card_required' or code == 'payment_required'),
    message = describe(status, code, serverMessage, retryAfter, data),
  }
end

--- Transient failures are waited out and repeated; "no point retrying" answers return at once.
---
---   transient   no answer (timeout, connection lost), HTTP 429 / 500 / 502 / 503 / 504,
---               code temporarily_unavailable
---   waits       1 s, 3 s, 9 s (three retries, four tries in all), each with ±25 % jitter so
---               parallel uploads do not all come back at the same moment; a Retry-After header
---               (capped at 30 s) is never undercut
---   413 limit   gallery_limit_reached is asked once more after a pause: the server has answered
---               it wrongly for a database hiccup before. Same answer again = a real limit.
---
--- `call` returns a response; the final response carries `tries` and `waited` (seconds).
local TRANSIENT_STATUS = { [429] = true, [500] = true, [502] = true, [503] = true, [504] = true }
local RETRY_DELAYS = { 1, 3, 9 }
local MAX_RETRY_AFTER = 30
local LIMIT_RECHECK_DELAY = 3

local function isTransient(res)
  return res.network == true or TRANSIENT_STATUS[res.status] == true or res.code == 'temporarily_unavailable'
end
M.isTransient = isTransient

local function jitter(seconds)
  return seconds * (0.75 + math.random() * 0.5)
end

local function delayFor(res, retryNumber)
  local wait = jitter(RETRY_DELAYS[retryNumber] or RETRY_DELAYS[#RETRY_DELAYS])
  if res.retryAfter and res.retryAfter > 0 then
    wait = math.max(wait, math.min(res.retryAfter, MAX_RETRY_AFTER) + math.random() * 0.5)
  end
  return wait
end

local function withRetry(call, label)
  local res = call()
  res.tries = 1
  local waited = 0
  local rechecked = false
  local rateLimited = (res.status == 429) -- the final answer says whether a 429 was seen (res.rateLimited)

  while not res.ok do
    local retries = res.tries - 1
    local wait
    if isTransient(res) and retries < #RETRY_DELAYS then
      wait = delayFor(res, retries + 1)
    elseif res.code == 'gallery_limit_reached' and not rechecked then
      rechecked = true
      wait = jitter(LIMIT_RECHECK_DELAY)
    else
      break
    end

    log.info('retry %d for %s after HTTP %s code=%s in %.1fs',
      res.tries, tostring(label or '?'), tostring(res.status), tostring(res.code), wait)
    LrTasks.sleep(wait)
    waited = waited + wait
    local tries = res.tries
    res = call()
    res.tries = tries + 1
    if res.status == 429 then rateLimited = true end
  end

  res.waited = waited
  res.rateLimited = rateLimited
  return res
end

-- ---------------------------------------------------------------------------
-- Endpoints
-- ---------------------------------------------------------------------------

function M.status(apiKey, timeoutSeconds)
  local path = '/integration/status?client_id=' .. config.CLIENT_ID .. '&client_version=' .. config.VERSION
  return request('GET', path, apiKey, { timeout = timeoutSeconds })
end

function M.listGalleries(apiKey)
  local res = withRetry(function() return request('GET', '/galleries', apiKey) end, 'list galleries')
  if not res.ok then return res end
  local list = res.data.galleries
  if type(list) ~= 'table' then list = res.data.sessions end
  res.galleries = type(list) == 'table' and list or {}
  return res
end

--- expected_photos (pricing-plans-v0.1.md §10.4, optional): how many photos this one gallery
--- will be sent, so the server can check the monthly limit and whether a card is needed
--- before anything is sent, instead of only finding out partway through. 0..1,000 only — an
--- out-of-range or missing value is simply left off (the server already treats it as optional:
--- an older plug-in or the CLI never sends it).
local function expectedPhotosField(n)
  n = tonumber(n)
  if not n or n ~= n or n < 0 or n > 1000 then return nil end
  return math.floor(n)
end

function M.createGallery(apiKey, args)
  -- passcode_hash is required; `passcode` (plain, over TLS) lets the server keep an
  -- encrypted copy so the photographer can read it again in the dashboard. The
  -- server rejects the request with 422 invalid_passcode if the two do not match.
  local body = json.encode({
    title = args.title,
    days = args.days,
    passcode_hash = args.passcodeHash,
    passcode = args.passcode,
    key_color = args.keyColor, -- nil = papat's default color
    expected_photos = expectedPhotosField(args.expectedPhotos),
  })
  -- the same Idempotency-Key makes a repeated POST safe
  return withRetry(function()
    return request('POST', '/galleries', apiKey, {
      body = body,
      contentType = 'application/json',
      idempotencyKey = args.idempotencyKey,
    })
  end, 'create gallery')
end

local function filePath(sid, logicalPath)
  local segments = {}
  for segment in logicalPath:gmatch('[^/]+') do
    segments[#segments + 1] = text.urlEncodeSegment(segment)
  end
  return '/galleries/' .. text.urlEncodeSegment(sid) .. '/files/' .. table.concat(segments, '/')
end

--- PUT one JPEG (retried once on transient failure).
function M.putPhoto(apiKey, sid, filename, bytes)
  local path = filePath(sid, 'photos/' .. filename)
  return withRetry(function()
    return request('PUT', path, apiKey, {
      body = bytes,
      contentType = 'image/jpeg',
      timeout = TIMEOUT_UPLOAD,
    })
  end, filename)
end

--- PUT the small version of a photo (thumbs/<same name>). The photo must be on the server first.
function M.putThumb(apiKey, sid, filename, bytes)
  local path = filePath(sid, 'thumbs/' .. filename)
  return withRetry(function()
    return request('PUT', path, apiKey, {
      body = bytes,
      contentType = 'image/jpeg',
      timeout = TIMEOUT_UPLOAD,
    })
  end, 'thumb ' .. filename)
end

function M.putManifest(apiKey, sid, manifest)
  local path = filePath(sid, 'manifest.json')
  local body = json.encode(manifest)
  return withRetry(function()
    return request('PUT', path, apiKey, {
      body = body,
      contentType = 'application/json',
    })
  end, 'manifest')
end

--- Close (and purge) a gallery. Used to clean up a gallery that never received a photo.
function M.deleteGallery(apiKey, sid)
  return request('DELETE', '/galleries/' .. text.urlEncodeSegment(sid), apiKey)
end

--- "送信の記録" (1.2.1, opt-in — see lib/report.lua): one small, anonymous performance/error
--- report. Never retried on failure (lib/report.lua is the only caller, and it already swallows
--- any error): a lost report is not worth slowing anything down or being told about.
function M.sendReport(apiKey, body)
  return request('POST', '/integration/report', apiKey, {
    body = json.encode(body),
    contentType = 'application/json',
  })
end

function M.getSelections(apiKey, sid)
  return withRetry(function()
    return request('GET', '/galleries/' .. text.urlEncodeSegment(sid) .. '/selections', apiKey)
  end, 'selections')
end

return M
