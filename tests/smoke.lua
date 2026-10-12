-- Smoke test: runs the real plug-in scripts against a fake Lightroom SDK and a fake
-- papat server. It cannot prove Lightroom behaviour (that is docs/manual-test.md) but
-- it catches typos, nil globals and broken control flow in every code path.
--
--   lua tests/smoke.lua        (from the repository root)

local root = arg and arg[0] and arg[0]:match('^(.*)/tests/[^/]+$') or '.'
_PLUGIN = { path = root .. '/papat.lrplugin' }
MAC_ENV = true

local failed, total = 0, 0
local function check(cond, label)
  total = total + 1
  if not cond then
    failed = failed + 1
    print('FAIL ' .. label)
  end
end

local json = dofile(_PLUGIN.path .. '/lib/json.lua')

-- Structurally valid JPEGs (not decodable pictures): optional Exif / XMP / IPTC / COM segments,
-- ICC profile, a frame header of width x height, and `label` inside the scan data.
local function jseg(marker, payload)
  local len = #payload + 2
  return '\255' .. string.char(marker) .. string.char(math.floor(len / 256), len % 256) .. payload
end
local function jpegBytes(label, withMeta, width, height, noIcc)
  width, height = width or 2048, height or 1365
  local parts = { '\255\216', jseg(0xE0, 'JFIF\0\1\1\0\0\1\0\1\0\0') }
  if withMeta then
    parts[#parts + 1] = jseg(0xE1, 'Exif\0\0MM\0*GPSLatitude SerialNumber=SN123 Artist=Someone')
    parts[#parts + 1] = jseg(0xE1, 'http://ns.adobe.com/xap/1.0/\0<x:xmpmeta crs:Exposure2012="+1" xmpMM:History=""/>')
    parts[#parts + 1] = jseg(0xED, 'Photoshop 3.0\0' .. '8BIM CreatorWorkEmail=person-at-example CreatorAddress')
    parts[#parts + 1] = jseg(0xFE, 'comment')
  end
  if not noIcc then parts[#parts + 1] = jseg(0xE2, 'ICC_PROFILE\0\1\1' .. string.rep('P', 20)) end
  parts[#parts + 1] = jseg(0xDB, '\0' .. string.rep('\16', 64))
  parts[#parts + 1] = jseg(0xC0, '\8' .. string.char(math.floor(height / 256), height % 256, math.floor(width / 256), width % 256) .. '\1\1\17\0')
  parts[#parts + 1] = jseg(0xC4, '\0' .. string.rep('\1', 16) .. '\0')
  parts[#parts + 1] = jseg(0xDA, '\1\1\0\0\63\0')
  parts[#parts + 1] = 'DATA:' .. label .. '\255\0\1\255\217'
  return table.concat(parts)
end

-- ---------------------------------------------------------------------------
-- Fake environment
-- ---------------------------------------------------------------------------

local tmpRoot = os.getenv('TMPDIR') or '/tmp'
tmpRoot = tmpRoot:gsub('/+$', '') .. '/papat-smoke-' .. tostring(os.time())
os.execute('mkdir -p "' .. tmpRoot .. '"')

local env = {
  dialogs = {},       -- { kind, title, info }
  requests = {},      -- { method, url, headers, body }
  commands = {},      -- LrTasks.execute
  passwords = {},
  sleeps = {},
  logLines = {},
  prefs = { locationPromptShown = true },
  server = {},        -- scripted responses: function(req) -> status, bodyTable, headers
}

local function fakeFactory()
  return setmetatable({
    control_spacing = function() return 5 end,
  }, {
    __index = function(_, name)
      return function(_, args) return { kind = name, args = args } end
    end,
  })
end

local modules = {}

modules.LrView = {
  osFactory = fakeFactory,
  bind = function(args) return { bound = args } end,
}
modules.LrColor = function(...) return { ... } end
modules.LrBinding = {
  makePropertyTable = function()
    local observers = {}
    return setmetatable({}, {
      __index = function(_, k)
        if k == 'addObserver' then
          return function(_, key, fn) observers[key] = fn end
        end
        return nil
      end,
    })
  end,
}
-- Dialog layout: every static_text with a literal title, a width and a fixed height_in_lines
-- must be tall enough for its text (a too-short box cuts the end of the sentence).
local layoutText = dofile(_PLUGIN.path .. '/lib/text.lua')
local layoutChecked, layoutProblems = 0, {}
local function walkLayout(node, where)
  if type(node) ~= 'table' then return end
  local args = node.args or node
  if node.kind == 'static_text' and type(args.title) == 'string' and args.width and args.height_in_lines then
    layoutChecked = layoutChecked + 1
    local need = layoutText.wrappedLines(args.title, args.width)
    if need > args.height_in_lines then
      layoutProblems[#layoutProblems + 1] = string.format('%s: needs %d lines, has %d: %s',
        where, need, args.height_in_lines, args.title:sub(1, 40))
    end
  end
  for _, child in ipairs(args) do walkLayout(child, where) end
end

modules.LrDialogs = {
  attachErrorDialogToFunctionContext = function() end,
  showBezel = function(message) env.dialogs[#env.dialogs + 1] = { kind = 'bezel', title = message } end,
  message = function(title, info) env.dialogs[#env.dialogs + 1] = { kind = 'message', title = title, info = info } end,
  confirm = function(title, info, ok)
    env.dialogs[#env.dialogs + 1] = { kind = 'confirm', title = title, info = info }
    return env.confirmAnswer or 'ok'
  end,
  presentModalDialog = function(args)
    walkLayout(args.contents, args.title)
    env.dialogs[#env.dialogs + 1] = { kind = 'modal', title = args.title, args = args }
    return 'ok'
  end,
}
modules.LrFunctionContext = {
  callWithContext = function(_, fn) fn({}) end,
}
-- Cooperative scheduler: a task runs until it sleeps/yields; drain() resumes the rest.
-- This mirrors LrTasks closely enough to exercise the background pipeline.
local ready = {}
local function resumeTask(co)
  local ok, err = coroutine.resume(co)
  if not ok then error(err, 0) end
  return coroutine.status(co) ~= 'dead'
end
modules.LrTasks = {
  pcall = function(fn, ...) return pcall(fn, ...) end,
  startAsyncTask = function(fn)
    local co = coroutine.create(fn)
    if resumeTask(co) then ready[#ready + 1] = co end
  end,
  sleep = function(seconds)
    env.sleeps[#env.sleeps + 1] = seconds or 0
    if coroutine.isyieldable() then coroutine.yield() end
  end,
  yield = function()
    if coroutine.isyieldable() then coroutine.yield() end
  end,
  execute = function(cmd) env.commands[#env.commands + 1] = cmd; return 0 end,
}
local function drain()
  local rounds = 0
  while #ready > 0 do
    rounds = rounds + 1
    if rounds > 20000 then error('scheduler: tasks never finished') end
    local current = ready
    ready = {}
    for _, co in ipairs(current) do
      if coroutine.status(co) == 'suspended' and resumeTask(co) then ready[#ready + 1] = co end
    end
  end
end
modules.LrProgressScope = function()
  local scope = {}
  local calls = 0
  return setmetatable(scope, { __index = function(_, name)
    if name == 'isCanceled' then
      return function()
        calls = calls + 1
        return env.cancelAfter ~= nil and calls > env.cancelAfter
      end
    end
    return function() return false end
  end })
end
-- By default the update check is answered from a fresh cache ("nothing new"), so the
-- scripted servers of the other tests are not asked; the update tests switch it off.
local pluginVersion
do
  local v = dofile(_PLUGIN.path .. '/Info.lua').VERSION
  pluginVersion = string.format('%d.%d.%d', v.major, v.minor, v.revision)
end
modules.LrPrefs = { prefsForPlugin = function()
  local p = env.prefs
  if not env.updateCheckLive and p.updateInfoJson == nil then
    p.updateInfoJson = json.encode({ forVersion = pluginVersion, fetchedAt = os.time(), latest = pluginVersion, minimum = '1.0.0' })
  end
  return p
end }
modules.LrPasswords = {
  store = function(k, v) env.passwords[k] = v end,
  retrieve = function(k) return env.passwords[k] end,
}
modules.LrDate = { currentTime = function() return os.time() + 0.123 + (env.clock or 0) end }
modules.LrLogger = function()
  local function capture(_, message) env.logLines[#env.logLines + 1] = tostring(message) end
  return { enable = function() end, debug = capture, info = capture, warn = capture, error = capture }
end
modules.LrHttp = {
  openUrlInBrowser = function(url) env.opened = url end,
  get = function(url, headers)
    local status, body, h = env.server({ method = 'GET', url = url, headers = headers })
    env.requests[#env.requests + 1] = { method = 'GET', url = url, headers = headers }
    local out = h or {}
    out.status = status
    return type(body) == 'table' and json.encode(body) or body, out
  end,
  post = function(url, body, headers, method)
    local req = { method = method or 'POST', url = url, headers = headers, body = body }
    env.requests[#env.requests + 1] = req
    local status, rbody, h = env.server(req)
    local out = h or {}
    out.status = status
    return type(rbody) == 'table' and json.encode(rbody) or rbody, out
  end,
}
modules.LrPathUtils = {
  getStandardFilePath = function(which)
    if which == 'temp' then return tmpRoot end
    if which == 'appData' then return tmpRoot .. '/home/Library/Application Support/Adobe/Lightroom' end
    return tmpRoot .. '/' .. which
  end,
  standardizePath = function(p) return p end,
  child = function(a, b) return a .. '/' .. b end,
  leafName = function(p) return p:match('([^/]*)$') end,
  extension = function(p) return p:match('%.([^./]*)$') or '' end,
  removeExtension = function(p) return (p:gsub('%.[^./]*$', '')) end,
}
local function sh(cmd)
  local h = io.popen(cmd)
  local out = h:read('*a')
  h:close()
  return out
end
local function lines(cmd)
  local list = {}
  for line in sh(cmd):gmatch('[^\n]+') do list[#list + 1] = line end
  return list
end
local function iter(list)
  local i = 0
  return function() i = i + 1; return list[i] end
end
modules.LrFileUtils = {
  createAllDirectories = function(p) os.execute('mkdir -p "' .. p .. '"'); return true end,
  exists = function(p)
    if os.execute('test -f "' .. p .. '"') == true or os.execute('test -f "' .. p .. '"') == 0 then return 'file' end
    if os.execute('test -d "' .. p .. '"') == true or os.execute('test -d "' .. p .. '"') == 0 then return 'directory' end
    return false
  end,
  delete = function(p) os.remove(p); return true end,
  copy = function(a, b)
    local f = io.open(a, 'rb'); if not f then return false end
    local data = f:read('*a'); f:close()
    local o = io.open(b, 'wb'); if not o then return false, 'cannot write' end
    o:write(data); o:close()
    return true
  end,
  fileAttributes = function(p)
    local f = io.open(p, 'rb'); if not f then return {} end
    local size = f:seek('end'); f:close()
    return { fileSize = size }
  end,
  files = function(dir) return iter(lines('find "' .. dir .. '" -maxdepth 1 -type f 2>/dev/null')) end,
  recursiveFiles = function(dir) return iter(lines('find "' .. dir .. '" -type f 2>/dev/null')) end,
  recursiveDirectoryEntries = function(dir) return iter(lines('find "' .. dir .. '" -mindepth 1 2>/dev/null')) end,
  isEmptyDirectory = function(p) return sh('ls -A "' .. p .. '" 2>/dev/null') == '' end,
}

-- Photos / catalog ---------------------------------------------------------
local function newPhoto(path, props)
  local photo = { path = path, props = props or {}, raw = { uuid = 'uuid-' .. path }, keywords = {}, writes = {} }
  function photo:requestJpegThumbnail(w, h, cb)
    env.thumbRequests = (env.thumbRequests or 0) + 1
    env.clock = (env.clock or 0) + (env.thumbSeconds or 0)
    if self.noThumb then
      cb(nil, 'no preview')
    elseif self.thumbWide then
      cb(jpegBytes('preview-' .. path, false, 4000, 2667, true), nil)
    elseif self.thumbDims then
      cb(jpegBytes('preview-' .. path, false, self.thumbDims[1], self.thumbDims[2], true), nil)
    elseif self.thumbSmall then
      cb(jpegBytes('preview-' .. path, false, 1440, 960, true), nil)
    elseif self.thumbExif then
      cb(jpegBytes('camera-jpeg-' .. path, true, 2056, 1371, true), nil)
    else
      cb(jpegBytes('preview-' .. path, false, 2056, 1371, true), nil)
    end
    return {}
  end
  function photo:getRawMetadata(k) if k == 'path' then return self.path end return self.raw[k] end
  function photo:setRawMetadata(k, v) self.raw[k] = v; self.writes[#self.writes + 1] = k end
  function photo:setPropertyForPlugin(_, k, v) self.props[k] = v end
  function photo:addKeyword(kw) self.keywords[#self.keywords + 1] = kw end
  return photo
end

local function newCatalog(photos)
  local catalog = { photos = photos, collections = {}, sets = {}, keywords = {} }
  function catalog:getTargetPhotos() return self.target or self.photos end
  function catalog:getActiveSources() return { { getName = function() return 'Spring Shoot' end } } end
  function catalog:getAllPhotos() return self.photos end
  function catalog:findPhotoByUuid(uuid)
    for _, p in ipairs(self.photos) do
      if p.raw.uuid == uuid then return p end
    end
    return nil
  end
  function catalog:findPhotosWithProperty()
    local out = {}
    for _, p in ipairs(self.photos) do if p.props.papatSourceId then out[#out + 1] = p end end
    return out
  end
  function catalog:batchGetRawMetadata(photos2, keys)
    local out = {}
    for _, p in ipairs(photos2) do
      out[p] = {}
      for _, k in ipairs(keys) do out[p][k] = p:getRawMetadata(k) end
    end
    return out
  end
  function catalog:batchGetFormattedMetadata(photos2, keys)
    local out = {}
    for _, p in ipairs(photos2) do
      out[p] = {}
      for _, k in ipairs(keys) do out[p][k] = (p.fmt or {})[k] end
    end
    return out
  end
  function catalog:batchGetPropertyForPlugin(photos2, _, ids)
    local out = {}
    for _, p in ipairs(photos2) do
      out[p] = {}
      for _, k in ipairs(ids) do out[p][k] = p.props[k] end
    end
    return out
  end
  function catalog:withWriteAccessDo(_, fn) fn({}); return 'executed' end
  function catalog:withPrivateWriteAccessDo(fn) fn({}); return 'executed' end
  function catalog:createCollectionSet(name)
    self.sets[name] = self.sets[name] or { name = name }
    return self.sets[name]
  end
  function catalog:createCollection(name, parent)
    local key = (parent and parent.name or '') .. '/' .. name
    self.collections[key] = self.collections[key] or { name = name, photos = {} }
    local c = self.collections[key]
    function c:addPhotos(list) for _, p in ipairs(list) do self.photos[#self.photos + 1] = p end end
    return c
  end
  function catalog:createKeyword(name, _, include, parent)
    local kw = { name = name, include = include, parent = parent }
    self.keywords[#self.keywords + 1] = kw
    return kw
  end
  return catalog
end

local activeCatalog
modules.LrApplication = { activeCatalog = function() return activeCatalog end }

modules.LrExportSession = function(args)
  local session = {}
  function session:countRenditions() return #args.photosToExport end
  function session:renditions()
    local i = 0
    return function()
      i = i + 1
      local photo = args.photosToExport[i]
      if not photo then return nil end
      local leaf = (photo.path:match('([^/]*)$'):gsub('%.[^.]*$', '')) .. '.jpg'
      local dest = args.exportSettings.LR_export_destinationPathPrefix .. '/' .. leaf
      env.exportedCount = (env.exportedCount or 0) + 1
      return i, { photo = photo, waitForRender = function()
        modules.LrTasks.yield()
        if photo.failRender then return false, 'render failed' end
        local n = 1
        local base = dest:gsub('%.jpg$', '')
        while io.open(dest, 'rb') do dest = base .. '-' .. n .. '.jpg'; n = n + 1 end
        local fh = io.open(dest, 'wb')
        if photo.badJpeg then
          fh:write('\255\216\255 this is not a usable JPEG')
        else
          fh:write(jpegBytes('fake-jpeg-' .. tostring(i), true))
        end
        fh:close()
        return true, dest
      end }
    end
  end
  env.lastExportSettings = args.exportSettings
  return session
end

function import(name)
  local m = modules[name]
  if m == nil then error('module not available: ' .. name) end
  return m
end

-- Fake server ---------------------------------------------------------------
local function iso(offsetDays)
  return os.date('!%Y-%m-%dT%H:%M:%S.000Z', os.time() + offsetDays * 86400)
end

local function run(script)
  env.dialogs, env.requests, env.commands = {}, {}, {}
  dofile(_PLUGIN.path .. '/' .. script)
  drain()
end

local function lastDialog(kind)
  for i = #env.dialogs, 1, -1 do
    if env.dialogs[i].kind == kind then return env.dialogs[i] end
  end
end

local function findRequest(method, pattern)
  for _, r in ipairs(env.requests) do
    if r.method == method and r.url:find(pattern) then return r end
  end
end

local function headerOf(req, name)
  for _, h in ipairs(req.headers or {}) do
    if h.field == name then return h.value end
  end
end

local KEY = 'sk_live_example_EXAMPLEKEY0000'

-- ---------------------------------------------------------------------------
-- 1. No API key: guidance, no network
-- ---------------------------------------------------------------------------
activeCatalog = newCatalog({ newPhoto('/p/IMG_0001.NEF'), newPhoto('/p/IMG_0002.NEF') })
env.server = function() error('network must not be used without a key') end
run('CreateGallery.lua')
check(lastDialog('confirm') and lastDialog('confirm').title:find('API キー') ~= nil, 'no key: guidance dialog')
check(#env.requests == 0, 'no key: no requests')

-- ---------------------------------------------------------------------------
-- 2. Create gallery: happy path
-- ---------------------------------------------------------------------------
env.passwords.apiKey = KEY
local photos = { newPhoto('/p/IMG_0001.NEF'), newPhoto('/p/IMG_0002.NEF'), newPhoto('/p/日本語 3.NEF') }
activeCatalog = newCatalog(photos)
env.server = function(req)
  if req.method == 'POST' and req.url:find('/api/v1/galleries$') then
    return 201, { ok = true, sid = 'SID123456789', tenant_id = 'abc123', path = '/t/abc123/s/SID123456789', expires_at = iso(7) }
  end
  if req.method == 'PUT' then
    return 200, { ok = true }
  end
  return 404, { ok = false, code = 'not_found', error = 'not found' }
end
run('CreateGallery.lua')

local createReq = findRequest('POST', '/galleries$')
check(createReq ~= nil, 'create: POST /galleries sent')
local createBody = createReq and json.decode(createReq.body) or {}
check(type(createBody.passcode_hash) == 'string' and #createBody.passcode_hash == 64, 'create: passcode_hash is 64 hex')
check(createBody.days == 7, 'create: days = 7')
check(createBody.key_color == nil, 'create: no key_color when the field is empty')
check(createBody.title == 'Spring Shoot', 'create: default title from source name')
local sha256 = dofile(_PLUGIN.path .. '/lib/sha256.lua')
check(type(createBody.passcode) == 'string' and #createBody.passcode == 6, 'create: plaintext passcode is sent (server stores it encrypted)')
check(createBody.passcode and sha256.hex(createBody.passcode) == createBody.passcode_hash, 'create: passcode matches passcode_hash')
check(createReq and headerOf(createReq, 'Authorization') == 'Bearer ' .. KEY, 'create: bearer header')
check(createReq and headerOf(createReq, 'Idempotency-Key') ~= nil, 'create: idempotency key')

local puts = 0
for _, r in ipairs(env.requests) do
  if r.method == 'PUT' and r.url:find('/files/photos/') then
    puts = puts + 1
    check(headerOf(r, 'Content-Type') == 'image/jpeg', 'upload: content type')
    check(r.body:sub(1, 3) == '\255\216\255', 'upload: JPEG signature')
    check(not r.body:find('Exif', 1, true) and not r.body:find('GPSLatitude', 1, true)
      and not r.body:find('SerialNumber', 1, true) and not r.body:find('crs:Exposure', 1, true)
      and not r.body:find('CreatorWorkEmail', 1, true) and not r.body:find('Photoshop', 1, true),
      'upload: no Exif / XMP / IPTC / serial number / develop settings in the sent file')
    check(r.body:find('ICC_PROFILE', 1, true) ~= nil, 'upload: ICC profile is kept')
  end
end
check(puts == 3, 'upload: 3 photos PUT (got ' .. puts .. ')')
check(findRequest('PUT', '/files/photos/%%E6%%97%%A5%%E6%%9C%%AC%%E8%%AA%%9E%%203%.jpg$') ~= nil, 'upload: filename percent-encoded per segment')

local manifestReq = findRequest('PUT', '/files/manifest%.json$')
check(manifestReq ~= nil, 'manifest: PUT sent')
local manifest = manifestReq and json.decode(manifestReq.body) or {}
check(manifest.count == 3 and #manifest.photos == 3, 'manifest: count/photos')
check(manifest.photos and manifest.photos[1].source_id ~= nil and manifest.photos[1].rating == 0, 'manifest: source_id, rating 0')
check(manifest.photos and manifest.photos[3].stem == '日本語 3' and manifest.photos[3].url == 'photos/%E6%97%A5%E6%9C%AC%E8%AA%9E%203.jpg', 'manifest: stem / url')
check(manifest.version == 1 and manifest.theme == 'default', 'manifest: web-compatible header')
check(manifest.key_color == nil, 'manifest: no key_color when empty')
check(manifestReq and headerOf(manifestReq, 'Content-Type') == 'application/json', 'manifest: content type')

check(photos[1].props.papatSid == 'SID123456789' and photos[1].props.papatSourceId ~= nil, 'record: sid / source id stored on photo')
check(#photos[1].writes == 0, 'record: no raw metadata written on export')
check(env.lastExportSettings.LR_size_maxWidth == 2048 and env.lastExportSettings.LR_export_colorSpace == 'sRGB', 'export: 2048 / sRGB')
check(env.lastExportSettings.LR_jpeg_quality == 0.8, 'export: quality 0.8')
check(env.lastExportSettings.LR_embeddedMetadataOption == nil, 'export: no LR_embeddedMetadataOption is passed (metadata is rebuilt by the plug-in)')
check(env.lastExportSettings.LR_minimizeEmbeddedMetadata == true and env.lastExportSettings.LR_removeLocationMetadata == true, 'export: legacy minimise / no-location flags kept')

local result = lastDialog('modal')
check(result and result.title:find('作成しました') ~= nil, 'result: dialog shown')
check(#env.commands == 1 and env.commands[1]:find('pbcopy') ~= nil, 'result: guidance auto-copied via pbcopy')
check(result and result.args.contents ~= nil, 'result: contents built')
for _, cmd in ipairs(env.commands) do
  check(not cmd:find('SID123456789') and not cmd:find('abc123'), 'clipboard command carries no user text')
end

-- ---------------------------------------------------------------------------
-- 3. Create gallery: card required (no files uploaded, nothing recorded)
-- ---------------------------------------------------------------------------
photos = { newPhoto('/p/IMG_0001.NEF') }
activeCatalog = newCatalog(photos)
env.server = function(req)
  if req.method == 'POST' then
    return 422, { ok = false, code = 'card_required', error = 'card required' }
  end
  error('no upload after a failed create')
end
run('CreateGallery.lua')
local d = lastDialog('confirm')
check(d and d.title:find('作成できませんでした') ~= nil and d.info:find('カード') ~= nil, 'card_required: Japanese guidance')
check(photos[1].props.papatSid == nil, 'card_required: nothing recorded')

-- ---------------------------------------------------------------------------
-- 4. Create gallery: network failure
-- ---------------------------------------------------------------------------
env.server = function() return nil, nil, { error = { name = 'NSURLErrorDomain' } } end
run('CreateGallery.lua')
d = lastDialog('message')
check(d and d.info:find('接続できませんでした') ~= nil, 'network: Japanese guidance')

-- 4b. Error codes -> Japanese text (M5: 409 must not always mean "closed")
-- ---------------------------------------------------------------------------
local api = dofile(_PLUGIN.path .. '/lib/api.lua')
local function msg(status, code, data) return api.describe(status, code, nil, nil, data) end
check(msg(409, 'active_gallery_limit', { max_active_galleries = 10 }):find('上限の10件') ~= nil, 'describe: active_gallery_limit names the limit')
check(msg(409, 'active_gallery_limit'):find('終了する') ~= nil, 'describe: active_gallery_limit says what to do')
check(msg(409, 'active_gallery_limit'):find('すでに終了') == nil, 'describe: active_gallery_limit is not "already closed"')
check(msg(409, 'gallery_closed'):find('すでに終了') ~= nil, 'describe: gallery_closed')
check(msg(409, 'idempotency_conflict'):find('処理中') ~= nil, 'describe: idempotency_conflict')
check(msg(409, 'extension_already_used'):find('延長') ~= nil, 'describe: extension_already_used')
check(msg(409, nil):find('すでに終了') == nil, 'describe: unknown 409 is neutral')
check(msg(422, 'card_required'):find('カード') ~= nil, 'describe: 422 card_required')
check(msg(402, 'card_required'):find('カード') ~= nil, 'describe: 402 card_required')
check(msg(402, 'monthly_limit'):find('月20単位') ~= nil, 'describe: 402 monthly_limit (initial invoice)')
check(msg(402, 'card_required'):find('カード登録が必要') ~= nil and msg(402, 'card_required'):find('使い切りました') == nil, 'describe: card_required is not only "free galleries used up"')
check(api.describe(402, 'paid_country_blocked', 'この国では有料利用に対応していません。'):find('この国では有料利用') ~= nil, 'describe: paid_country_blocked shows the server text')
check(msg(402, 'paid_country_blocked'):find('請求先の国') ~= nil, 'describe: paid_country_blocked fallback')
check(msg(409, 'billing_country_required'):find('住所') ~= nil, 'describe: billing_country_required')
check(msg(403, 'invite_only'):find('招待') ~= nil, 'describe: invite_only')
check(api.describe(402, nil, 'カード登録が必要です'):find('カード登録が必要です') ~= nil, 'describe: an unknown 402 shows the server text')
check(msg(413, 'gallery_limit_reached'):find('上限') ~= nil, 'describe: gallery_limit_reached')
check(msg(403, 'tenant_suspended'):find('hello@papat.app') ~= nil, 'describe: tenant_suspended')
check(msg(404, 'gallery_not_found'):find('見つかりません') ~= nil, 'describe: gallery_not_found')
check(msg(503, 'schema_not_applied'):find('一時的') ~= nil, 'describe: 503')
check(msg(422, 'invalid_passcode'):find('パスコード') ~= nil and msg(422, 'invalid_passcode'):find('カード') == nil, 'describe: invalid_passcode is not card_required')

-- the gallery limit shown to the photographer, end to end
photos = { newPhoto('/p/IMG_0001.NEF') }
activeCatalog = newCatalog(photos)
env.server = function(req)
  if req.method == 'POST' then
    return 409, { ok = false, code = 'active_gallery_limit', error = 'x', max_active_galleries = 10 }
  end
  error('no upload after a failed create')
end
run('CreateGallery.lua')
d = lastDialog('confirm')
check(d and d.title:find('作成できませんでした') ~= nil and d.info:find('上限の10件') ~= nil, 'limit: dialog says 10 galleries')
check(d and d.info:find('すでに終了') == nil, 'limit: not the "closed" wording')
check(photos[1].props.papatSid == nil, 'limit: nothing recorded')

-- a 409 on one upload that is NOT fatal (idempotency_conflict) is retried by the user
local puts409 = 0
env.server = function(req)
  if req.method == 'POST' and req.url:find('/galleries$') then
    return 201, { ok = true, sid = 'SID9', tenant_id = 'abc123', path = '/t/abc123/s/SID9', expires_at = iso(7) }
  end
  if req.method == 'PUT' and req.url:find('/photos/') then
    puts409 = puts409 + 1
    if puts409 == 1 then return 409, { ok = false, code = 'idempotency_conflict', error = 'busy' } end
    return 200, { ok = true }
  end
  return 200, { ok = true }
end
photos = { newPhoto('/p/IMG_0001.NEF'), newPhoto('/p/IMG_0002.NEF') }
activeCatalog = newCatalog(photos)
run('CreateGallery.lua')
check(photos[2].props.papatSid == 'SID9' and photos[1].props.papatSid == 'SID9', 'idempotency_conflict: user retry uploads both photos')

-- 4c. Key color (1.0.2): create + manifest carry #rrggbb, remembered in prefs
-- ---------------------------------------------------------------------------
local colorCreate, colorManifest
env.server = function(req)
  if req.method == 'POST' and req.url:find('/galleries$') then
    colorCreate = json.decode(req.body)
    return 201, { ok = true, sid = 'SIDC', tenant_id = 'abc123', path = '/t/abc123/s/SIDC', expires_at = iso(7) }
  end
  if req.method == 'PUT' and req.url:find('manifest%.json$') then colorManifest = json.decode(req.body) end
  return 200, { ok = true }
end
-- the dialog stub accepts defaults; give the stubbed property table a color via the modal hook
local realPresent = modules.LrDialogs.presentModalDialog
env.injectKeyColor = '0066CC'
modules.LrDialogs.presentModalDialog = function(args)
  if args.actionVerb == '作成して送信' and args.actionBinding then
    local props = args.actionBinding.enabled.bind_to_object
    props.keyColor = env.injectKeyColor
  end
  return realPresent(args)
end
photos = { newPhoto('/p/IMG_0001.NEF') }
activeCatalog = newCatalog(photos)
env.prefs = { locationPromptShown = true, recentKeyColors = '#111111' }
run('CreateGallery.lua')
check(colorCreate and colorCreate.key_color == '#0066cc', 'color: create request carries #0066cc')
check(colorManifest and colorManifest.key_color == '#0066cc', 'color: manifest carries #0066cc')
check(env.prefs.recentKeyColors == '#0066cc,#111111', 'color: remembered in prefs')

-- invalid input is never sent: the dialog blocks (canSubmit) and the value falls back to none
colorCreate, colorManifest = nil, nil
env.injectKeyColor = 'blue'
photos = { newPhoto('/p/IMG_0001.NEF') }
activeCatalog = newCatalog(photos)
env.prefs = { locationPromptShown = true }
run('CreateGallery.lua')
check(colorCreate and colorCreate.key_color == nil, 'color: invalid value is not sent')
check(env.prefs.recentKeyColors == nil, 'color: invalid value is not remembered')

env.injectKeyColor = ''
modules.LrDialogs.presentModalDialog = realPresent
check(api.describe(400, 'invalid_request', 'key_color must be a #RRGGBB color'):find('#RRGGBB') ~= nil, 'describe: key_color error')

-- 4d. Background pipeline (1.0.2): overlap, batches, recents, cancel/resume, fast mode
-- ---------------------------------------------------------------------------
local function manifestRequests()
  local out = {}
  for _, r in ipairs(env.requests) do
    if r.method == 'PUT' and r.url:find('manifest%.json$') then out[#out + 1] = json.decode(r.body) end
  end
  return out
end
local function photoPuts()
  local out = {}
  for i, r in ipairs(env.requests) do
    if r.method == 'PUT' and r.url:find('/files/photos/') then out[#out + 1] = i end
  end
  return out
end
local function indexOfManifest(n)
  local seen = 0
  for i, r in ipairs(env.requests) do
    if r.method == 'PUT' and r.url:find('manifest%.json$') then
      seen = seen + 1
      if seen == n then return i end
    end
  end
end
local serverState
local function bigServer()
  serverState = { photos = {}, manifestCalls = 0, deleted = false, failName = nil }
  return function(req)
    if req.method == 'POST' and req.url:find('/galleries$') then
      return 201, { ok = true, sid = 'SIDP', tenant_id = 'abc123', path = '/t/abc123/s/SIDP', expires_at = iso(7) }
    end
    if req.method == 'DELETE' then serverState.deleted = true; return 200, { ok = true } end
    if req.method == 'PUT' and req.url:find('/files/photos/') then
      if serverState.failName and req.url:find(serverState.failName, 1, true) then
        return 409, { ok = false, code = 'gallery_closed', error = 'closed' }
      end
      serverState.photos[#serverState.photos + 1] = req.url
      return 200, { ok = true }
    end
    return 200, { ok = true }
  end
end
local function manyPhotos(n)
  local list = {}
  for i = 1, n do list[#list + 1] = newPhoto(string.format('/p/IMG_%04d.NEF', i)) end
  return list
end

-- 25 photos: everything arrives, in several manifest batches, the last one complete
photos = manyPhotos(25)
activeCatalog = newCatalog(photos)
env.server = bigServer()
env.prefs = { locationPromptShown = true }
env.passwords.recentGalleries = nil
env.exportedCount = 0
run('CreateGallery.lua')
check(#serverState.photos == 25, 'pipeline: all 25 photos uploaded (got ' .. #serverState.photos .. ')')
local ms = manifestRequests()
check(#ms >= 3, 'pipeline: manifest sent in several batches (' .. #ms .. ')')
check(ms[1] and #ms[1].photos >= 1 and #ms[1].photos <= 3 and ms[1].complete == false, 'pipeline: first batch is small and not complete')
check(ms[#ms] and ms[#ms].complete == true, 'pipeline: last manifest has complete = true')
local union = {}
for _, m in ipairs(ms) do for _, p in ipairs(m.photos) do union[p.filename] = true end end
local unionCount = 0
for _ in pairs(union) do unionCount = unionCount + 1 end
check(unionCount == 25, 'pipeline: batches together list all 25 photos')
local puts = photoPuts()
check(indexOfManifest(1) ~= nil and indexOfManifest(1) < puts[#puts], 'pipeline: first manifest is sent before the last photo (the gallery fills while uploading)')
check(photos[25].props.papatSid == 'SIDP', 'pipeline: sid recorded on every photo')
local recent = json.decode(env.passwords.recentGalleries)
check(recent and recent[1] and recent[1].sid == 'SIDP' and recent[1].uploaded == 25 and recent[1].complete == true, 'recents: gallery stored with the final count')
check(recent and recent[1] and #recent[1].passcode == 6, 'recents: passcode kept in the keychain entry')
check(env.prefs.jobsJson == nil or not env.prefs.jobsJson:find('SIDP', 1, true) or (json.decode(env.prefs.jobsJson).bySid.SIDP == nil), 'jobs: finished job removed')
local bezel = false
for _, dlg in ipairs(env.dialogs) do
  if dlg.kind == 'bezel' and dlg.title:find('25 枚') then bezel = true end
end
check(bezel, 'pipeline: quiet bezel when finished')
check(env.prefs.jobsJson == nil or not env.prefs.jobsJson:find('"pending":%[{'), 'jobs: nothing pending')

-- cancel half-way, then "続きから送る" sends the rest and nothing twice
photos = manyPhotos(12)
activeCatalog = newCatalog(photos)
env.server = bigServer()
env.prefs = { locationPromptShown = true }
env.passwords.recentGalleries = nil
env.cancelAfter = 14
run('CreateGallery.lua')
env.cancelAfter = nil
local sentFirst = #serverState.photos
check(sentFirst > 0 and sentFirst < 12, 'cancel: partial upload (' .. sentFirst .. '/12)')
local jobData = json.decode(env.prefs.jobsJson)
local pendingN = #jobData.bySid.SIDP.pending
check(pendingN == 12 - sentFirst, 'cancel: job keeps exactly the unsent photos (' .. pendingN .. ')')
local rec = json.decode(env.passwords.recentGalleries)
check(rec[1].uploaded == sentFirst and rec[1].complete == false, 'cancel: recents show a partial gallery')
local lastManifest = manifestRequests()
check(lastManifest[#lastManifest].complete == true, 'cancel: partial gallery is closed with what was sent')

local firstUrls = {}
for _, u in ipairs(serverState.photos) do firstUrls[u] = true end
env.requests = {}
env.dialogs = {}
env.server = (function()
  local inner = bigServer()
  return function(req)
    local s, b, h = inner(req)
    return s, b, h
  end
end)()
-- resume through the menu (the dialog stub answers "other" = 続きから送る)
local realPresent2 = modules.LrDialogs.presentModalDialog
modules.LrDialogs.presentModalDialog = function(args)
  env.dialogs[#env.dialogs + 1] = { kind = 'modal', title = args.title, args = args }
  if args.title == 'papat 最近のギャラリー' then return 'other' end
  return 'ok'
end
run('RecentGalleries.lua')
modules.LrDialogs.presentModalDialog = realPresent2
check(#serverState.photos == 12 - sentFirst, 'resume: only the unsent photos are uploaded (' .. #serverState.photos .. ')')
for _, u in ipairs(serverState.photos) do
  check(not firstUrls[u], 'resume: ' .. u:match('[^/]*$') .. ' was not sent twice')
end
rec = json.decode(env.passwords.recentGalleries)
check(rec[1].uploaded == 12 and rec[1].complete == true, 'resume: gallery complete')
check(env.prefs.jobsJson == nil or json.decode(env.prefs.jobsJson).bySid.SIDP == nil, 'resume: job removed')

-- nothing could be rendered: the empty gallery is withdrawn
photos = { newPhoto('/p/IMG_0001.NEF') }
photos[1].failRender = true
activeCatalog = newCatalog(photos)
env.server = bigServer()
env.prefs = { locationPromptShown = true }
env.passwords.recentGalleries = nil
run('CreateGallery.lua')
check(serverState.deleted == true, 'render failure: empty gallery is deleted')
check(env.passwords.recentGalleries == nil or #json.decode(env.passwords.recentGalleries) == 0, 'render failure: not kept in recents')

-- a fatal answer (gallery closed) stops the whole send and keeps the rest for later
photos = manyPhotos(6)
activeCatalog = newCatalog(photos)
env.server = bigServer()
serverState.failName = 'IMG_0003'
env.prefs = { locationPromptShown = true }
env.passwords.recentGalleries = nil
run('CreateGallery.lua')
local closedDialog = nil
for _, dlg in ipairs(env.dialogs) do
  if dlg.kind == 'message' and dlg.title:find('送信を中止') then closedDialog = dlg end
end
check(closedDialog ~= nil and closedDialog.info:find('すでに終了') ~= nil, 'fatal: stops with the "already closed" text')
check(#serverState.photos < 6, 'fatal: remaining photos are not sent')

-- speed-first mode: no export, JPEGs come from the preview; missing previews fall back
photos = manyPhotos(4)
photos[2].noThumb = true
activeCatalog = newCatalog(photos)
env.server = bigServer()
env.prefs = { locationPromptShown = true, fastMode = true }
env.passwords.recentGalleries = nil
env.thumbRequests, env.exportedCount = 0, 0
local bodies = {}
local innerServer = env.server
env.server = function(req)
  if req.method == 'PUT' and req.url:find('/files/photos/') then bodies[#bodies + 1] = req.body end
  return innerServer(req)
end
run('CreateGallery.lua')
check(env.thumbRequests == 4, 'fast: preview requested for every photo (' .. env.thumbRequests .. ')')
check(env.exportedCount == 1, 'fast: the photo without a preview falls back to export (' .. env.exportedCount .. ')')
check(#bodies == 4, 'fast: 4 photos uploaded')
local previews = 0
for _, b in ipairs(bodies) do
  check(b:sub(1, 3) == '\255\216\255', 'fast: JPEG signature')
  if b:find('preview-', 1, true) then previews = previews + 1 end
end
check(previews == 3, 'fast: three JPEGs came from the preview')
env.prefs = { locationPromptShown = true }

-- exported file that cannot be cleaned is NOT sent (fail closed), the others are
photos = { newPhoto('/p/IMG_0001.NEF'), newPhoto('/p/IMG_0002.NEF'), newPhoto('/p/IMG_0003.NEF') }
photos[2].badJpeg = true
activeCatalog = newCatalog(photos)
env.server = bigServer()
env.prefs = { locationPromptShown = true }
env.passwords.recentGalleries = nil
run('CreateGallery.lua')
check(#serverState.photos == 2, 'sanitize failure: only the two clean photos are sent (' .. #serverState.photos .. ')')
local sentBad = false
for _, u in ipairs(serverState.photos) do if u:find('IMG_0002', 1, true) then sentBad = true end end
check(not sentBad, 'sanitize failure: the unusable file is not uploaded')
local failDialog = nil
for _, dlg in ipairs(env.dialogs) do
  if dlg.kind == 'message' and dlg.info and dlg.info:find('メタデータ') then failDialog = dlg end
end
check(failDialog ~= nil, 'sanitize failure: the photographer is told (' .. tostring(failDialog and failDialog.title) .. ')')

-- speed-first, probe says "no": previews missing / too big -> everything is exported from the start
local function timingOf(sid)
  for _, e in ipairs(json.decode(env.passwords.recentGalleries)) do
    if e.sid == sid then return e.timing end
  end
end
photos = manyPhotos(6)
photos[1].thumbWide = true
for i = 3, 6 do photos[i].noThumb = true end
activeCatalog = newCatalog(photos)
env.server = bigServer()
env.prefs = { locationPromptShown = true, fastMode = true }
env.passwords.recentGalleries = nil
env.thumbRequests, env.exportedCount = 0, 0
run('CreateGallery.lua')
check(#serverState.photos == 6, 'probe: all six photos arrive (' .. #serverState.photos .. ')')
check(env.thumbRequests == 3, 'probe: only the three probes asked for a preview (' .. env.thumbRequests .. ')')
check(env.exportedCount == 6, 'probe: everything exported when previews are not usable (' .. env.exportedCount .. ')')
local line = timingOf('SIDP') or ''
check(line:find('このカタログではプレビューを使えなかった', 1, true) ~= nil, 'probe: the result says previews were not usable')
check(line:find('標準サイズのプレビューを作っておくと速くなります', 1, true) ~= nil, 'probe: the result hints at building standard previews')

-- probe is fine, later photos fail: three in a row and the rest is exported
photos = manyPhotos(10)
for _, i in ipairs({ 2, 3, 4, 6, 7, 8, 9 }) do photos[i].noThumb = true end
activeCatalog = newCatalog(photos)
env.server = bigServer()
env.passwords.recentGalleries = nil
env.thumbRequests, env.exportedCount = 0, 0
run('CreateGallery.lua')
check(#serverState.photos == 10, 'give-up: all ten photos arrive (' .. #serverState.photos .. ')')
check(env.thumbRequests == 9, 'give-up: 3 probes + 3 + 3 requests, then no more (' .. env.thumbRequests .. ')')
check(env.exportedCount == 7, 'give-up: the seven without a preview are exported (' .. env.exportedCount .. ')')
line = timingOf('SIDP') or ''
check(line:find('プレビューから 3 枚・書き出しで 7 枚', 1, true) ~= nil, 'result: counts of preview / export photos')
check(line:find('標準サイズのプレビューを作っておくと速くなります', 1, true) ~= nil, 'result: hint when exports outnumber previews')

-- a preview that still carries Exif is the camera's embedded JPEG (not Lightroom's rendering): export
photos = manyPhotos(3)
for _, p in ipairs(photos) do p.thumbExif = true end
activeCatalog = newCatalog(photos)
env.server = bigServer()
env.passwords.recentGalleries = nil
env.thumbRequests, env.exportedCount = 0, 0
run('CreateGallery.lua')
check(env.exportedCount == 3 and #serverState.photos == 3, 'embedded: camera JPEG previews are not used (exported ' .. env.exportedCount .. ')')

-- previews smaller than ~2048 px are not used either
photos = manyPhotos(3)
for _, p in ipairs(photos) do p.thumbSmall = true end
activeCatalog = newCatalog(photos)
env.server = bigServer()
env.passwords.recentGalleries = nil
env.exportedCount = 0
run('CreateGallery.lua')
check(env.exportedCount == 3, 'small preview: exported instead (' .. env.exportedCount .. ')')

-- previews that are rendered on demand (slow probes) are no faster than exporting: export from the start
photos = manyPhotos(5)
activeCatalog = newCatalog(photos)
env.server = bigServer()
env.prefs = { locationPromptShown = true, fastMode = true }
env.passwords.recentGalleries = nil
env.thumbRequests, env.exportedCount = 0, 0
env.thumbSeconds = 1.1
run('CreateGallery.lua')
env.thumbSeconds = nil
check(env.thumbRequests == 3 and env.exportedCount == 5, 'slow probe: everything is exported (' .. env.thumbRequests .. ' previews asked, ' .. env.exportedCount .. ' exported)')
check((timingOf('SIDP') or ''):find('このカタログではプレビューを使えなかった', 1, true) ~= nil, 'slow probe: result explains it')

-- small originals / tight crops: a preview as small as the export would be is fine; the sRGB tag is added
photos = manyPhotos(3)
for _, p in ipairs(photos) do
  p.raw.croppedWidth, p.raw.croppedHeight = 1500, 1000
  p.thumbDims = { 1500, 1000 }
end
activeCatalog = newCatalog(photos)
env.server = bigServer()
env.prefs = { locationPromptShown = true, fastMode = true }
env.passwords.recentGalleries = nil
env.thumbRequests, env.exportedCount = 0, 0
local tagBodies = {}
do
  local inner = env.server
  env.server = function(req)
    if req.method == 'PUT' and req.url:find('/files/photos/') then tagBodies[#tagBodies + 1] = req.body end
    return inner(req)
  end
end
run('CreateGallery.lua')
check(env.exportedCount == 0 and env.thumbRequests == 3, 'small original: previews of the true size are used (exported ' .. env.exportedCount .. ')')
check(#tagBodies == 3 and tagBodies[1]:find('ICC_PROFILE', 1, true) ~= nil, 'preview: an sRGB profile is added to previews that have none')
check(tagBodies[1] and tagBodies[1]:find('sRGB IEC61966-2.1 (papat)', 1, true) ~= nil, 'preview: it is the generated sRGB profile')

-- the same small preview for a photo that should be big (no crop info saying so): still "small"
photos = manyPhotos(3)
for _, p in ipairs(photos) do p.raw.croppedWidth, p.raw.croppedHeight = 6000, 4000; p.thumbDims = { 1500, 1000 } end
activeCatalog = newCatalog(photos)
env.server = bigServer()
env.passwords.recentGalleries = nil
env.exportedCount = 0
run('CreateGallery.lua')
check(env.exportedCount == 3, 'small preview of a big photo: exported (' .. env.exportedCount .. ')')

-- good previews, no hint
photos = manyPhotos(5)
activeCatalog = newCatalog(photos)
env.server = bigServer()
env.passwords.recentGalleries = nil
env.thumbRequests, env.exportedCount = 0, 0
run('CreateGallery.lua')
check(env.exportedCount == 0 and env.thumbRequests == 5, 'previews ok: nothing exported (' .. env.exportedCount .. ')')
line = timingOf('SIDP') or ''
check(line:find('プレビューから 5 枚・書き出しで 0 枚', 1, true) ~= nil and line:find('標準サイズのプレビュー', 1, true) == nil, 'previews ok: counts, no hint')
env.prefs = { locationPromptShown = true }

-- videos are not sent (their preview would be a still frame)
photos = manyPhotos(3)
photos[2].raw.isVideo = true
activeCatalog = newCatalog(photos)
env.server = bigServer()
env.passwords.recentGalleries = nil
run('CreateGallery.lua')
local videoSent = false
for _, u in ipairs(serverState.photos) do if u:find('IMG_0002', 1, true) then videoSent = true end end
check(#serverState.photos == 2 and not videoSent, 'video: only the two photos are sent (' .. #serverState.photos .. ')')

-- ---------------------------------------------------------------------------
-- Failures while sending (1.0.3): transient errors are waited out, only a hopeless answer stops
-- ---------------------------------------------------------------------------
local function scripted(handler)
  -- handler(filename, nth request for that file, req) -> nil (ok) | status, body, headers
  local seen = {}
  serverState = { photos = {}, attempts = {}, deleted = false }
  return function(req)
    if req.method == 'POST' and req.url:find('/galleries$') then
      return 201, { ok = true, sid = 'SIDF', tenant_id = 'abc123', path = '/t/abc123/s/SIDF', expires_at = iso(7) }
    end
    if req.method == 'PUT' and req.url:find('/files/photos/') then
      local name = req.url:match('[^/]*$')
      seen[name] = (seen[name] or 0) + 1
      serverState.attempts[#serverState.attempts + 1] = name
      local status, body, headers = handler(name, seen[name], req)
      if status == 'network' then return nil, nil, { error = { name = 'timeout' } } end
      if status then return status, body, headers end
      serverState.photos[#serverState.photos + 1] = req.url
      return 200, { ok = true }
    end
    if req.method == 'DELETE' then serverState.deleted = true end
    return 200, { ok = true }
  end
end
local function attemptsOf(name)
  local n = 0
  for _, a in ipairs(serverState.attempts) do if a == name then n = n + 1 end end
  return n
end
local function longSleeps()
  local out = {}
  for _, d in ipairs(env.sleeps) do if d >= 0.5 then out[#out + 1] = d end end
  return out
end
local function logHas(fragment)
  for _, l in ipairs(env.logLines) do if l:find(fragment, 1, true) then return true end end
  return false
end
local function failureDialog()
  for i = #env.dialogs, 1, -1 do
    local d = env.dialogs[i]
    if d.kind == 'message' and d.title and (d.title:find('送信を中止') or d.title:find('混み合って')) then return d end
  end
end
local function freshRun(n, handler)
  photos = manyPhotos(n)
  activeCatalog = newCatalog(photos)
  env.server = scripted(handler)
  env.prefs = { locationPromptShown = true }
  env.passwords.recentGalleries = nil
  env.sleeps, env.logLines = {}, {}
  run('CreateGallery.lua')
end

-- HTTP 500 once: waited and sent again, nothing is reported
freshRun(6, function(name, n) if name == 'IMG_0002.jpg' and n == 1 then return 500, { ok = false, error = 'x' } end end)
check(#serverState.photos == 6, 'retry 500: all six photos arrive (' .. #serverState.photos .. ')')
check(attemptsOf('IMG_0002.jpg') == 2, 'retry 500: the photo was sent twice')
local waits = longSleeps()
check(#waits == 1 and waits[1] >= 0.75 and waits[1] <= 1.26, 'retry 500: waited about one second with jitter (' .. tostring(waits[1]) .. ')')
check(failureDialog() == nil, 'retry 500: no failure dialog')
check(logHas('retries=1'), 'retry 500: retry count in the log')

-- HTTP 503 with Retry-After: never retried sooner than the server asked
freshRun(4, function(name, n)
  if name == 'IMG_0001.jpg' and n == 1 then return 503, { ok = false, code = 'temporarily_unavailable' }, { { field = 'Retry-After', value = '4' } } end
end)
waits = longSleeps()
check(#serverState.photos == 4 and #waits == 1 and waits[1] >= 4, 'retry 503: waited at least Retry-After (' .. tostring(waits[1]) .. ')')

-- backoff grows: 1 s, 3 s, 9 s for a photo that keeps failing (and the others still go through)
env.confirmAnswer = 'cancel'
freshRun(5, function(name) if name == 'IMG_0003.jpg' then return 500, { ok = false } end end)
env.confirmAnswer = nil
check(attemptsOf('IMG_0003.jpg') == 4, 'retry: four tries for a failing photo (' .. attemptsOf('IMG_0003.jpg') .. ')')
check(#serverState.photos == 4, 'retry: the other four photos are still sent (' .. #serverState.photos .. ')')
waits = longSleeps()
check(#waits == 3 and waits[1] < 1.26 and waits[2] > 2.2 and waits[2] < 3.8 and waits[3] > 6.7 and waits[3] < 11.3,
  'retry: waits of about 1 s, 3 s, 9 s (' .. table.concat(waits, ', ') .. ')')
check(logHas('failedUploads=[500x1]'), 'retry: the final HTTP status of the failed photo is logged')
check(failureDialog() == nil or failureDialog().title:find('一部') ~= nil, 'retry: a single failed photo does not stop the send')
rec = json.decode(env.passwords.recentGalleries)
check(rec[1].uploaded == 4 and rec[1].total == 5, 'retry: recents show 4 of 5 sent')

-- connection errors are transient too
freshRun(3, function(name, n) if name == 'IMG_0002.jpg' and n == 1 then return 'network' end end)
check(#serverState.photos == 3 and attemptsOf('IMG_0002.jpg') == 2, 'retry network: a lost connection is retried')

-- 413 gallery_limit_reached once (a server hiccup): asked again, then it works
freshRun(4, function(name, n)
  if name == 'IMG_0002.jpg' and n == 1 then return 413, { ok = false, code = 'gallery_limit_reached', error = 'limit' } end
end)
check(#serverState.photos == 4, 'limit once: all photos arrive after the second ask (' .. #serverState.photos .. ')')
check(failureDialog() == nil, 'limit once: no stop dialog')
waits = longSleeps()
check(#waits == 1 and waits[1] > 2.2 and waits[1] < 3.8, 'limit once: one pause of about 3 s before asking again')

-- 413 gallery_limit_reached that stays: the send stops, with the numbers the server gave
freshRun(8, function(name, n)
  if name == 'IMG_0004.jpg' then
    return 413, { ok = false, code = 'gallery_limit_reached', error = 'limit',
      photos = 265, max_photos = 900, bytes = 75497472, max_bytes = 1073741824 }
  end
end)
check(attemptsOf('IMG_0004.jpg') == 2, 'limit stays: asked twice, then stops (' .. attemptsOf('IMG_0004.jpg') .. ')')
local limitDialog = failureDialog()
check(limitDialog ~= nil and limitDialog.info:find('いま 265枚', 1, true) ~= nil and limitDialog.info:find('上限 900枚', 1, true) ~= nil
  and limitDialog.info:find('72 MB', 1, true) ~= nil and limitDialog.info:find('1024 MB', 1, true) ~= nil,
  'limit stays: the message shows current and maximum numbers')
check(#serverState.photos < 8, 'limit stays: the remaining photos are not sent')
check(json.decode(env.prefs.jobsJson).bySid.SIDF ~= nil, 'limit stays: the unsent photos stay pending for "続きから送る"')

-- 413 without numbers: the plain wording
freshRun(3, function(name) if name == 'IMG_0002.jpg' then return 413, { ok = false, code = 'gallery_limit_reached' } end end)
limitDialog = failureDialog()
check(limitDialog ~= nil and limitDialog.info:find('上限を超えました', 1, true) ~= nil, 'limit without numbers: plain text')

-- 401 stops at once, without waiting
freshRun(6, function() return 401, { ok = false, code = 'invalid_api_key' } end)
check(#longSleeps() == 0, '401: no retries, no waiting')
check(#serverState.attempts <= 3, '401: stops after the requests already in flight (' .. #serverState.attempts .. ')')
check(failureDialog() ~= nil or lastDialog('confirm') ~= nil, '401: the photographer is told')

-- gallery ended (404 / 410): stops at once
freshRun(5, function(name) if name == 'IMG_0002.jpg' then return 410, { ok = false } end end)
check(#longSleeps() == 0, '410: no retries')
check(failureDialog() ~= nil and failureDialog().info:find('終了または削除', 1, true) ~= nil, '410: ended / deleted wording')

-- the server keeps failing: after six photos in a row the send pauses, the rest stays pending
freshRun(12, function(name) if tonumber(name:match('(%d+)')) > 2 then return 503, { ok = false, code = 'temporarily_unavailable' } end end)
check(#serverState.photos == 2, 'busy: the first two photos were sent (' .. #serverState.photos .. ')')
check(logHas('send paused'), 'busy: the pause is logged')
local busy = failureDialog()
check(busy ~= nil and busy.title:find('混み合っています', 1, true) ~= nil and busy.info:find('続きから送る', 1, true) ~= nil,
  'busy: tells to wait and use "続きから送る"')
local jobs12 = json.decode(env.prefs.jobsJson).bySid.SIDF
check(jobs12 and #jobs12.pending == 10, 'busy: ten photos stay pending (' .. tostring(jobs12 and #jobs12.pending) .. ')')
check(attemptsOf('IMG_0012.jpg') == 0, 'busy: later photos are not even tried')

-- trouble lowers the parallelism, calm restores it
freshRun(10, function(name, n)
  if (name == 'IMG_0001.jpg' or name == 'IMG_0002.jpg') and n == 1 then return 500, { ok = false } end
end)
check(#serverState.photos == 10, 'parallelism: all ten photos arrive')
check(logHas('parallel uploads lowered to 1'), 'parallelism: lowered after troubled uploads')
check(logHas('parallel uploads back to 3'), 'parallelism: restored after clean uploads')

-- ---------------------------------------------------------------------------
-- Capture time and gallery order (1.0.3)
-- ---------------------------------------------------------------------------
local function manifestOrder()
  local names, entries = {}, {}
  for _, r in ipairs(env.requests) do
    if r.method == 'PUT' and r.url:find('manifest%.json$') then
      for _, p in ipairs(json.decode(r.body).photos) do
        names[#names + 1] = p.filename
        entries[p.filename] = p
      end
    end
  end
  return names, entries
end
local function dated(path, iso, extra)
  local p = newPhoto(path)
  p.raw.dateTimeISO8601 = iso
  if extra then for k, v in pairs(extra) do p.raw[k] = v end end
  return p
end

-- two cameras mixed, selected in a "wrong" order, one undated scan, a tie: capture order, whatever finishes first
photos = {
  dated('/p/CAM2_0002.CR3', '2026-10-12T10:00:12+09:00'),
  dated('/p/IMG_0001.NEF', '2026-10-12T10:00:00'),
  newPhoto('/p/SCAN_0001.TIF'),                      -- no capture time
  dated('/p/CAM2_0001.CR3', '2026-10-12T10:00:07'),
  dated('/p/IMG_0003.NEF', '2026-10-12T10:00:12'),   -- same second as CAM2_0002: file name decides
  dated('/p/IMG_0002.NEF', '2026-10-12T10:00:05'),
  dated('/p/AAA_0001.TIF', '', {}),
}
activeCatalog = newCatalog(photos)
local first500 = true
env.server = scripted(function(name, n)
  -- the first photo in gallery order is slow to finish: it must still come first
  if name == 'IMG_0001.jpg' and n == 1 then return 500, { ok = false } end
end)
env.prefs = { locationPromptShown = true }
env.passwords.recentGalleries = nil
run('CreateGallery.lua')
local order, entries = manifestOrder()
check(#order == 7, 'order: all seven photos listed (' .. #order .. ')')
check(table.concat(order, ',') == 'IMG_0001.jpg,IMG_0002.jpg,CAM2_0001.jpg,CAM2_0002.jpg,IMG_0003.jpg,AAA_0001.jpg,SCAN_0001.jpg',
  'order: capture time, then file name; undated last by file name (' .. table.concat(order, ',') .. ')')
check(entries['IMG_0001.jpg'] and entries['IMG_0001.jpg'].datetime == '2026-10-12T10:00:00', 'datetime: plain wall time')
check(entries['CAM2_0002.jpg'] and entries['CAM2_0002.jpg'].datetime == '2026-10-12T10:00:12', 'datetime: zone designator removed')
check(entries['SCAN_0001.jpg'] and entries['SCAN_0001.jpg'].datetime == '', 'datetime: undated stays empty')
local anyZ = false
for _, e in pairs(entries) do if e.datetime:find('Z', 1, true) then anyZ = true end end
check(not anyZ, 'datetime: never carries a Z')
check(entries['IMG_0001.jpg'].camera == '' and entries['IMG_0001.jpg'].rating == 0 and entries['IMG_0001.jpg'].label == ''
  and #entries['IMG_0001.jpg'].keywords == 0, 'manifest: camera / rating / label / keywords stay empty by design')

-- the adjusted capture time (Edit Capture Time) wins over the original; numeric fallback works
photos = {
  dated('/p/B_0001.NEF', '2026-10-12T09:00:00', { dateTimeOriginalISO8601 = '2026-10-12T12:00:00' }),
  newPhoto('/p/A_0001.NEF'),
}
photos[2].raw.dateTimeOriginal = 788918400 + 3600 * 5 -- 2026-01-01T05:00:00 as wall time
activeCatalog = newCatalog(photos)
env.server = scripted(function() end)
env.passwords.recentGalleries = nil
run('CreateGallery.lua')
order, entries = manifestOrder()
check(entries['B_0001.jpg'] and entries['B_0001.jpg'].datetime == '2026-10-12T09:00:00', 'datetime: adjusted time preferred')
check(entries['A_0001.jpg'] and entries['A_0001.jpg'].datetime:match('^%d%d%d%d%-%d%d%-%d%dT05:00:00$') ~= nil,
  'datetime: numeric fallback (' .. tostring(entries['A_0001.jpg'] and entries['A_0001.jpg'].datetime) .. ')')
check(order[1] == 'A_0001.jpg', 'datetime: numeric 2026-01 photo sorts before 2026-10 photo')

-- cancel half-way and resume: the first batches are a prefix of the gallery order, the rest follows in order
photos = {}
for i = 1, 12 do
  photos[#photos + 1] = dated(string.format('/p/IMG_%04d.NEF', i), string.format('2026-10-12T10:%02d:00', 60 - i))
end
activeCatalog = newCatalog(photos)
env.server = scripted(function() end)
env.prefs = { locationPromptShown = true }
env.passwords.recentGalleries = nil
env.cancelAfter = 12
run('CreateGallery.lua')
env.cancelAfter = nil
local firstOrder = manifestOrder()
check(#firstOrder > 0 and #firstOrder < 12, 'resume order: partial first run (' .. #firstOrder .. ')')
local expected = {}
for i = 12, 1, -1 do expected[#expected + 1] = string.format('IMG_%04d.jpg', i) end -- newest number = earliest time
for k, name in ipairs(firstOrder) do
  check(name == expected[k], 'resume order: first run lists ' .. expected[k] .. ' at position ' .. k .. ' (got ' .. name .. ')')
end
env.requests = {}
local realPresent3 = modules.LrDialogs.presentModalDialog
modules.LrDialogs.presentModalDialog = function(args)
  env.dialogs[#env.dialogs + 1] = { kind = 'modal', title = args.title, args = args }
  if args.title == 'papat 最近のギャラリー' then return 'other' end
  return 'ok'
end
run('RecentGalleries.lua')
modules.LrDialogs.presentModalDialog = realPresent3
local secondOrder = manifestOrder()
local all = {}
for _, n in ipairs(firstOrder) do all[#all + 1] = n end
for _, n in ipairs(secondOrder) do all[#all + 1] = n end
check(#all == 12 and table.concat(all, ',') == table.concat(expected, ','),
  'resume order: first + resumed manifests together are in gallery order (' .. table.concat(all, ',') .. ')')

-- ---------------------------------------------------------------------------
-- Rights in the image, photographer's stars (1.0.3)
-- ---------------------------------------------------------------------------
local function rightsPhotos(n)
  local list = {}
  for k = 1, n do
    local p = newPhoto(string.format('/p/IMG_%04d.NEF', k))
    p.raw.rating = 3
    p.raw.copyrightState = 'copyrighted'
    p.fmt = {
      copyright = '© 2026 Taro Example', creator = 'Taro Example',
      creatorEmail = 'taro-at-example', creatorPhone = '03-0000-0000',
      creatorAddress = '1-2-3 Example-cho', rightsUsageTerms = 'Contact before use',
    }
    list[#list + 1] = p
  end
  return list
end
local function rightsDialogs()
  local n = 0
  for _, dlg in ipairs(env.dialogs) do
    if dlg.kind == 'confirm' and dlg.title:find('画像に入れる情報の確認', 1, true) then n = n + 1 end
  end
  return n
end
local function sentBodies()
  local out = {}
  for _, r in ipairs(env.requests) do
    if r.method == 'PUT' and r.url:find('/files/photos/') then out[#out + 1] = r.body end
  end
  return out
end
local function createRequests()
  local n = 0
  for _, r in ipairs(env.requests) do
    if r.method == 'POST' and r.url:find('/galleries$') then n = n + 1 end
  end
  return n
end

-- default: confirmed once, copyright / creator / contact go into every image, nothing else
photos = rightsPhotos(3)
activeCatalog = newCatalog(photos)
env.server = scripted(function() end)
env.prefs = { locationPromptShown = true }
env.passwords.recentGalleries = nil
run('CreateGallery.lua')
check(rightsDialogs() == 1, 'rights: confirmation shown once')
local info = nil
for _, dlg in ipairs(env.dialogs) do
  if dlg.kind == 'confirm' and dlg.title:find('画像に入れる情報の確認', 1, true) then info = dlg.info end
end
check(info and info:find('Taro Example', 1, true) and info:find('03-0000-0000', 1, true) and info:find('1-2-3 Example-cho', 1, true),
  'rights: the dialog lists what will be embedded (copyright, creator, phone, address)')
check(info and info:find('位置情報、カメラのシリアル番号、現像設定は入りません', 1, true) ~= nil, 'rights: the dialog says what is not embedded')
local bodies = sentBodies()
check(#bodies == 3, 'rights: three photos sent')
for _, b in ipairs(bodies) do
  check(b:find('© 2026 Taro Example', 1, true) ~= nil and b:find('CiEmailWork>taro-at-example<', 1, true) ~= nil
    and b:find('Exif\0\0II', 1, true) ~= nil, 'rights: copyright, contact (XMP) and Exif Artist/Copyright are in the image')
  check(not b:find('GPSLatitude', 1, true) and not b:find('SerialNumber', 1, true) and not b:find('crs:Exposure', 1, true)
    and not b:find('CreatorWorkEmail', 1, true) and not b:find('Photoshop', 1, true), 'rights: nothing else from Lightroom survives')
end
local m3, e3 = manifestOrder()
check(e3['IMG_0001.jpg'] and e3['IMG_0001.jpg'].rating == 3, 'rating: the photographer\'s stars are in the manifest')
check(e3['IMG_0001.jpg'] and e3['IMG_0001.jpg'].label == '', 'rating: the colour label is not sent')
check(json.decode(env.prefs.jobsJson) == nil or json.decode(env.prefs.jobsJson).bySid.SIDF == nil, 'rights: job finished')

-- same content again: not asked again
env.prefs.updateInfoJson = env.prefs.updateInfoJson
photos = rightsPhotos(2)
activeCatalog = newCatalog(photos)
env.server = scripted(function() end)
env.passwords.recentGalleries = nil
run('CreateGallery.lua')
check(rightsDialogs() == 0, 'rights: the same content is not asked about twice')
check(#sentBodies() == 2 and sentBodies()[1]:find('Taro Example', 1, true) ~= nil, 'rights: acknowledged content is still embedded')

-- changed content: asked again
photos = rightsPhotos(2)
for _, p in ipairs(photos) do p.fmt.creatorAddress = '9-9-9 Another-cho' end
activeCatalog = newCatalog(photos)
env.server = scripted(function() end)
env.passwords.recentGalleries = nil
run('CreateGallery.lua')
check(rightsDialogs() == 1, 'rights: a changed address is asked about again')

-- "入れずに送る": sent without any of it, once
env.prefs = { locationPromptShown = true }
photos = rightsPhotos(2)
activeCatalog = newCatalog(photos)
env.server = scripted(function() end)
env.passwords.recentGalleries = nil
env.confirmAnswer = 'other'
run('CreateGallery.lua')
env.confirmAnswer = nil
bodies = sentBodies()
check(#bodies == 2 and not bodies[1]:find('Taro Example', 1, true) and not bodies[1]:find('Exif\0\0', 1, true),
  'rights: "入れずに送る" sends images without copyright / contact')
check(json.decode(env.passwords.recentGalleries)[1].total == 2, 'rights: the gallery was still created')

-- cancel at the confirmation: nothing is created
env.prefs = { locationPromptShown = true }
photos = rightsPhotos(2)
activeCatalog = newCatalog(photos)
env.server = scripted(function() end)
env.passwords.recentGalleries = nil
env.confirmAnswer = 'cancel'
run('CreateGallery.lua')
env.confirmAnswer = nil
check(createRequests() == 0, 'rights: cancelling creates no gallery')

-- switched off in the settings: no question, nothing embedded; stars can be hidden separately
env.prefs = { locationPromptShown = true, embedRights = false, showRating = false }
photos = rightsPhotos(2)
activeCatalog = newCatalog(photos)
env.server = scripted(function() end)
env.passwords.recentGalleries = nil
run('CreateGallery.lua')
check(rightsDialogs() == 0, 'rights: no question when switched off')
bodies = sentBodies()
check(#bodies == 2 and not bodies[1]:find('Taro Example', 1, true), 'rights: nothing embedded when switched off')
m3, e3 = manifestOrder()
check(e3['IMG_0001.jpg'] and e3['IMG_0001.jpg'].rating == 0, 'rating: hidden when switched off')

-- speed-first images get the same segments (previews carry nothing)
env.prefs = { locationPromptShown = true, fastMode = true, rightsAck = '' }
photos = rightsPhotos(3)
activeCatalog = newCatalog(photos)
env.server = scripted(function() end)
env.passwords.recentGalleries = nil
env.exportedCount = 0
run('CreateGallery.lua')
bodies = sentBodies()
check(env.exportedCount == 0 and #bodies == 3, 'rights fast: previews used (' .. env.exportedCount .. ' exported)')
check(bodies[1] and bodies[1]:find('© 2026 Taro Example', 1, true) ~= nil and bodies[1]:find('sRGB IEC61966-2.1 (papat)', 1, true) ~= nil,
  'rights fast: copyright and the sRGB profile are both added to previews')
env.prefs = { locationPromptShown = true }

-- billing: card needed in the middle of a send -> stops, the rest is kept, the dashboard is offered
freshRun(8, function(name)
  if tonumber(name:match('(%d+)')) >= 4 then
    return 402, { ok = false, code = 'card_required', error = 'カード登録が必要です' }
  end
end)
check(#serverState.photos == 3, 'billing: photos before the card requirement were sent (' .. #serverState.photos .. ')')
check(#longSleeps() == 0, 'billing: card_required is not retried')
local cardDialog = lastDialog('confirm')
check(cardDialog and cardDialog.info:find('カード登録が必要です', 1, true) ~= nil
  and cardDialog.info:find('続きから送る', 1, true) ~= nil, 'billing: tells to register a card and that the rest is kept')
check(json.decode(env.prefs.jobsJson).bySid.SIDF ~= nil, 'billing: the unsent photos stay pending')

-- billing: country blocked while sending -> stops with the server's words
freshRun(5, function(name)
  if name == 'IMG_0002.jpg' then return 402, { ok = false, code = 'paid_country_blocked', error = 'この国では有料利用に対応していません。' } end
end)
cardDialog = lastDialog('confirm')
check(cardDialog and cardDialog.info:find('この国では有料利用に対応していません', 1, true) ~= nil, 'billing: paid_country_blocked shows the server text')
check(#longSleeps() == 0, 'billing: paid_country_blocked is not retried')

-- duplicate file names from different folders get unique names on the server
photos = { newPhoto('/a/IMG_0001.NEF'), newPhoto('/b/IMG_0001.CR3') }
activeCatalog = newCatalog(photos)
env.server = bigServer()
run('CreateGallery.lua')
local dup = {}
for _, u in ipairs(serverState.photos) do dup[u:match('[^/]*$')] = true end
check(dup['IMG_0001.jpg'] and (dup['IMG_0001-2.jpg']), 'names: duplicates are made unique (IMG_0001.jpg / IMG_0001-2.jpg)')

-- 4e. Update notice (1.0.2): once a day, required updates stop the command
-- ---------------------------------------------------------------------------
env.updateCheckLive = true
local statusCalls, statusAnswer
local function updateServer()
  statusCalls = 0
  return function(req)
    if req.url:find('/integration/status') then
      statusCalls = statusCalls + 1
      if statusAnswer == 'network' then return nil, nil, { error = { name = 'x' } } end
      return 200, { ok = true, tenant_id = 'abc123', client = statusAnswer }
    end
    if req.method == 'POST' and req.url:find('/galleries$') then
      return 201, { ok = true, sid = 'SIDU', tenant_id = 'abc123', path = '/t/abc123/s/SIDU', expires_at = iso(7) }
    end
    return 200, { ok = true, galleries = {} }
  end
end
local function noticeDialogs()
  local n = 0
  for _, dlg in ipairs(env.dialogs) do
    if dlg.kind == 'confirm' and dlg.title:find('新しいバージョン') then n = n + 1 end
  end
  return n
end
local function requiredDialogs()
  local n = 0
  for _, dlg in ipairs(env.dialogs) do
    if dlg.kind == 'confirm' and dlg.title:find('更新が必要') then n = n + 1 end
  end
  return n
end
local function creates()
  local n = 0
  for _, r in ipairs(env.requests) do
    if r.method == 'POST' and r.url:find('/galleries$') then n = n + 1 end
  end
  return n
end

-- optional update: noticed once, the command still runs; a second run the same day is quiet
photos = { newPhoto('/p/IMG_0001.NEF') }
activeCatalog = newCatalog(photos)
env.server = updateServer()
statusAnswer = { minimum_version = '1.0.0', latest_version = '9.9.9', update_available = true }
env.prefs = { locationPromptShown = true }
env.opened = nil
run('CreateGallery.lua')
check(noticeDialogs() == 1, 'update notice: shown once')
check(creates() == 1, 'update notice: the command is not stopped')
check(env.opened == 'https://papat.app/lightroom/', 'update notice: "ダウンロードページを開く" opens the download page')
check(env.prefs.updateNotifiedAt ~= nil, 'update notice: time of the notice is remembered')
env.opened = nil
run('CreateGallery.lua')
check(noticeDialogs() == 0, 'update notice: not repeated the same day')
check(creates() == 1, 'update notice: second run still works')
check(statusCalls == 1, 'update check: answer cached for the hour (' .. statusCalls .. ' status calls)')

-- a day later it is shown again
env.prefs.updateNotifiedAt = os.time() - 86400 - 5
env.prefs.updateInfoJson = nil
run('CreateGallery.lua')
check(noticeDialogs() == 1, 'update notice: shown again after a day')

-- the same notice appears for the other menu commands
env.prefs.updateNotifiedAt = nil
run('ImportSelections.lua')
check(noticeDialogs() == 1, 'update notice: also on "セレクトを読み込む"')

-- required update: the command stops, every time
photos = { newPhoto('/p/IMG_0001.NEF') }
activeCatalog = newCatalog(photos)
statusAnswer = { minimum_version = '9.0.0', latest_version = '9.9.9', update_available = true }
env.prefs = { locationPromptShown = true, updateNotifiedAt = os.time() }
env.server = updateServer()
run('CreateGallery.lua')
check(requiredDialogs() == 1, 'required: "更新が必要です" is shown')
check(creates() == 0, 'required: no gallery is created')
check(env.opened == 'https://papat.app/lightroom/', 'required: download page opened on request')
run('CreateGallery.lua')
check(requiredDialogs() == 1 and creates() == 0, 'required: shown every time, ignoring the daily limit')
run('ImportSelections.lua')
check(requiredDialogs() == 1, 'required: also stops "セレクトを読み込む"')
for _, r in ipairs(env.requests) do
  check(not r.url:find('/selections'), 'required: no selections requested')
end

-- minimum == latest is an announcement, not a lock-out
statusAnswer = { minimum_version = '9.9.9', latest_version = '9.9.9', update_available = true }
env.prefs = { locationPromptShown = true }
env.server = updateServer()
run('CreateGallery.lua')
check(requiredDialogs() == 0 and creates() == 1, 'minimum == latest never blocks')

-- explicit update_required wins
statusAnswer = { minimum_version = '1.0.0', latest_version = '9.9.9', update_available = true, update_required = true }
env.prefs = { locationPromptShown = true }
env.server = updateServer()
run('CreateGallery.lua')
check(requiredDialogs() == 1 and creates() == 0, 'update_required: true stops the command')

-- network down: never blocks (and no 30 s wait: the check uses a short timeout)
statusAnswer = 'network'
env.prefs = { locationPromptShown = true }
env.server = updateServer()
run('CreateGallery.lua')
check(requiredDialogs() == 0 and noticeDialogs() == 0 and creates() == 1, 'offline check: fail-open, silent')

-- stale cache is still honoured when the server cannot be reached
env.prefs = { locationPromptShown = true, updateInfoJson = json.encode({
  forVersion = pluginVersion, fetchedAt = os.time() - 7200, minimum = '9.0.0', latest = '9.9.9', available = true }) }
env.server = updateServer()
statusAnswer = 'network'
run('CreateGallery.lua')
check(requiredDialogs() == 1 and creates() == 0, 'offline: a cached "required" answer still applies')

-- "最近のギャラリー" only tells, never stops
statusAnswer = { minimum_version = '9.0.0', latest_version = '9.9.9', update_available = true }
env.prefs = { locationPromptShown = true }
env.passwords.recentGalleries = nil
env.server = updateServer()
run('RecentGalleries.lua')
local recentBlocked = false
for _, dlg in ipairs(env.dialogs) do
  if dlg.kind == 'confirm' and dlg.title:find('更新が必要') then recentBlocked = true end
end
check(recentBlocked == true, 'recent: the notice is shown')
check(lastDialog('message') and lastDialog('message').title:find('まだありません') ~= nil, 'recent: the list still opens')

env.updateCheckLive = false
env.passwords.apiKey = KEY

-- ---------------------------------------------------------------------------
-- 5. Plug-in manager: sections build and connection check
-- ---------------------------------------------------------------------------
local provider = dofile(_PLUGIN.path .. '/PluginInfoProvider.lua')
local propsTable = {}
local props = setmetatable({}, { __index = function(_, k)
  if k == 'addObserver' then return function(_, key, fn) propsTable[key] = fn end end
end })
local sections = provider.sectionsForTopOfDialog(fakeFactory(), props)
walkLayout(sections, 'manager')
do
  local titles = {}
  for _, sec in ipairs(sections) do titles[#titles + 1] = sec.title end
  check(titles[1] == 'papat — インストール場所' and titles[2] == 'papat — 接続' and titles[3] == 'papat — アタリ送付'
    and titles[4] == 'papat — セレクト受け取り 反映設定', 'manager (not standard): location, connect, send, receive (' .. table.concat(titles, ' | ') .. ')')
end
check(type(sections) == 'table' and #sections == 5, 'manager: five sections (location first when not standard)')
check(props.keyStatus and props.keyStatus:find('設定済み') ~= nil and not props.keyStatus:find('EXAMPLEKEY'), 'manager: key masked')
check(props.applyPick == true and props.applyMemo == true and props.applyTags == true and props.starCollections == false, 'manager: defaults (pick/memo/tags on, star sub-collections off)')

-- ---------------------------------------------------------------------------
-- 6. Import (concept §11.2 defaults): collection + pick + memo appended + keywords
-- ---------------------------------------------------------------------------
local linkedA = newPhoto('/p/IMG_0001.NEF', { papatSourceId = 'u-A', papatSid = 'SIDX', papatFilename = 'IMG_0001.jpg' })
linkedA.raw.caption = 'keep me'
linkedA.raw.rating = 4
linkedA.raw.label = 'Red'
local plain = newPhoto('/p/LEGACY_07.CR3')
local other = newPhoto('/p/IMG_0009.NEF')
activeCatalog = newCatalog({ linkedA, plain, other })
env.prefs = { locationPromptShown = true }
env.server = function(req)
  if req.url:find('/api/v1/galleries$') then
    return 200, { ok = true, galleries = {
      { sid = 'SIDX', title = '春の撮影', status = 'active', created_at = iso(-1), expires_at = iso(6), photos = 10 },
    } }
  end
  if req.url:find('/selections$') then
    return 200, { ok = true, schema = 'papat.selections/v1', sid = 'SIDX', title = '春の撮影', adopted = {
      { source_id = 'u-A', filename = 'IMG_0001.jpg', stem = 'IMG_0001', adopted = true, rating = 3, tags = { '表紙' }, memo = '余白' },
      { stem = 'LEGACY_07', adopted = true, rating = 1, tags = {}, memo = '' },
      { stem = 'GONE_01', adopted = true, rating = 0, tags = {}, memo = '' },
    } }
  end
  return 404, { ok = false, error = 'not found' }
end
run('ImportSelections.lua')

local collectionCount = 0
for key, c in pairs(activeCatalog.collections) do
  collectionCount = collectionCount + 1
  check(c.name:find('^papat 採用 春の撮影 ') ~= nil, 'import: collection name (' .. key .. ')')
  check(#c.photos == 2, 'import: two photos added')
end
check(collectionCount == 1, 'import: exactly one collection by default (no star sub-collections)')
check(linkedA.raw.pickStatus == 1 and plain.raw.pickStatus == 1 and other.raw.pickStatus == nil, 'import: pick flag on matched photos only')
check(linkedA.raw.caption == 'keep me\n— papat: 余白', 'import: memo appended after existing caption')
check(plain.raw.caption == nil, 'import: empty memo leaves caption alone')
check(#activeCatalog.keywords == 2 and activeCatalog.keywords[1].name == 'papat' and activeCatalog.keywords[1].include == false
  and activeCatalog.keywords[2].name == '表紙' and activeCatalog.keywords[2].parent == activeCatalog.keywords[1],
  'import: tag under non-exported "papat" parent keyword')
check(linkedA.raw.rating == 4 and linkedA.raw.label == 'Red', 'import: rating / color label untouched')
local forbidden = false
for _, p in ipairs({ linkedA, plain, other }) do
  for _, k in ipairs(p.writes) do
    if k == 'rating' or k == 'label' then forbidden = true end
  end
end
check(not forbidden, 'import: rating/label never written')
local confirmDialog = nil
for _, dlg in ipairs(env.dialogs) do
  if dlg.kind == 'modal' and dlg.args.actionVerb == 'コレクションに追加' then confirmDialog = dlg end
end
check(confirmDialog ~= nil, 'import: confirmation dialog shown')
check(lastDialog('message') and lastDialog('message').info:find('2 枚をコレクションに追加') ~= nil, 'import: done message')

-- re-import of the same gallery: caption not duplicated, no new collection
run('ImportSelections.lua')
check(linkedA.raw.caption == 'keep me\n— papat: 余白', 'rerun: caption not duplicated')
local c2 = 0
for _ in pairs(activeCatalog.collections) do c2 = c2 + 1 end
check(c2 == 1, 'rerun: no duplicate collection')

-- ---------------------------------------------------------------------------
-- 7. Import: switches off, star sub-collections on
-- ---------------------------------------------------------------------------
local fresh = newPhoto('/p/IMG_0001.NEF', { papatSourceId = 'u-A', papatSid = 'SIDX', papatFilename = 'IMG_0001.jpg' })
fresh.raw.caption = 'keep me'
local plain2 = newPhoto('/p/LEGACY_07.CR3')
activeCatalog = newCatalog({ fresh, plain2 })
env.prefs = { locationPromptShown = true, applyPick = false, applyMemo = false, applyTags = false, starCollections = true }
run('ImportSelections.lua')
check(fresh.raw.pickStatus == nil and fresh.raw.caption == 'keep me' and #activeCatalog.keywords == 0, 'off: nothing written to photos')
local names = {}
for _, c in pairs(activeCatalog.collections) do names[c.name] = #c.photos end
check(names['採用'] == 2 and names['★3'] == 1 and names['★1'] == 1, 'star sub-collections: 採用 + ★3 + ★1')
local setCount = 0
for _ in pairs(activeCatalog.sets) do setCount = setCount + 1 end
check(setCount == 1, 'star sub-collections: one collection set')

-- ---------------------------------------------------------------------------
-- 8. Import: server errors
-- ---------------------------------------------------------------------------
env.prefs = { locationPromptShown = true }
env.server = function(req)
  if req.url:find('/api/v1/galleries$') then return 401, { ok = false, code = 'invalid_api_key', error = 'invalid api key' } end
end
run('ImportSelections.lua')
d = lastDialog('confirm')
check(d and d.info:find('API キー') ~= nil and d.info:find('papat.app/app') ~= nil, 'import 401: key guidance with dashboard link')

-- ---------------------------------------------------------------------------
-- 9. Install location (1.0.1)
-- ---------------------------------------------------------------------------
local function freshLocation()
  return dofile(_PLUGIN.path .. '/lib/location.lua')
end
local location = freshLocation()
local st = location.status()
check(st.standard == false and st.downloads == false, 'location: repo checkout is not the standard folder')
check(st.target:find('/home/Library/Application Support/Adobe/Lightroom/Modules/papat.lrplugin$') ~= nil, 'location: target path under <home>/Library/Application Support/Adobe/Lightroom/Modules')
check(st.target:find('Adobe/Lightroom/Adobe', 1, true) == nil, 'location: Adobe/Lightroom is not doubled (appData already ends in it)')

local res = location.install()
check(res.ok == true and res.count > 10 and res.backup == nil, 'install: first copy ok, no backup')
check(io.open(st.target .. '/Info.lua') ~= nil and io.open(st.target .. '/lib/api.lua') ~= nil, 'install: Info.lua and lib/ copied')
check(io.open(st.target .. '/.DS_Store') == nil, 'install: hidden files skipped')

-- stale file from an "older version" must disappear and be backed up
local stale = io.open(st.target .. '/lib/stale-old-module.lua', 'w'); stale:write('-- old'); stale:close()
res = location.install()
check(res.ok == true and res.backup ~= nil, 'install: second copy creates a backup')
check(io.open(st.target .. '/lib/stale-old-module.lua') == nil, 'install: stale file removed from Modules copy')
check(res.backup and io.open(res.backup .. '/lib/stale-old-module.lua') ~= nil, 'install: backup holds the previous version')
check(res.backup and not res.backup:find('/Modules/', 1, true), 'install: backup lives outside Modules')

-- once the plug-in runs from Modules, it is "standard" and install is a no-op
local savedPath = _PLUGIN.path
_PLUGIN.path = st.target
location = freshLocation()
st = location.status()
check(st.standard == true, 'location: Modules copy is detected as standard')
local again = location.install()
check(again.ok == false and again.already == true, 'install: nothing to do when already standard')

-- Plug-in Manager when loaded from Modules: one line, no warning, no copy section/button
do
  local propsStd = setmetatable({}, { __index = function(_, k)
    if k == 'addObserver' then return function() end end
  end })
  local secs = provider.sectionsForTopOfDialog(fakeFactory(), propsStd)
  walkLayout(secs, 'manager (standard location)')
  check(#secs == 4, 'manager (standard): no location section')
do
  local titles = {}
  for _, sec in ipairs(secs) do titles[#titles + 1] = sec.title end
  check(table.concat(titles, ' | ') == 'papat — 接続 | papat — アタリ送付 | papat — セレクト受け取り 反映設定 | papat — バージョン',
    'manager: sections in the order connect, send, receive, version (' .. table.concat(titles, ' | ') .. ')')
end
  check(propsStd.locationWarn == false and propsStd.locationStandard == true, 'manager (standard): no warning')
  check(propsStd.locationText == '標準の場所にインストールされています。', 'manager (standard): one line text')
  check(propsStd.locationOneLine == '標準の場所にインストールされています。', 'manager (standard): line shown in the version section')
end

-- the same folder reached through "~", a trailing slash and /System/Volumes/Data is still standard
local variants = {
  st.target .. '/',
  '/System/Volumes/Data' .. st.target,
  (st.target:gsub(tmpRoot .. '/home', '~', 1)),
}
local loaded = freshLocation()
for i, v in ipairs(variants) do
  _PLUGIN.path = v
  check(loaded.status().standard == true, 'location: variant ' .. i .. ' (' .. v:sub(1, 12) .. '…) is standard')
end
_PLUGIN.path = savedPath

-- first-run prompt appears once, then never again
local prompted = false
env.prefs = {}
activeCatalog = newCatalog({ newPhoto('/p/IMG_0001.NEF') })
env.passwords.apiKey = ''
run('CreateGallery.lua')
for _, dlg in ipairs(env.dialogs) do
  if dlg.kind == 'confirm' and dlg.title:find('標準の場所にコピー') then prompted = true end
end
check(prompted, 'first run: offer to copy to the standard location')
check(env.prefs.locationPromptShown == true, 'first run: flag stored')
local prompts = 0
run('CreateGallery.lua')
for _, dlg in ipairs(env.dialogs) do
  if dlg.kind == 'confirm' and dlg.title:find('標準の場所にコピー') then prompts = prompts + 1 end
end
check(prompts == 0, 'first run: not offered a second time')

-- plug-in manager shows where it is loaded from
local props2 = setmetatable({}, { __index = function(_, k)
  if k == 'addObserver' then return function() end end
end })
env.passwords.apiKey = KEY
walkLayout(provider.sectionsForTopOfDialog(fakeFactory(), props2), 'manager (other location)')
check(props2.locationText and props2.locationText:find('読み込み元: ') ~= nil and props2.locationWarn == true, 'manager: location text + warning when not standard')


-- 4f. Free galleries come from the server (1.0.3) -----------------------------
do
  env.updateCheckLive = true
  local priceSeen
  local presentBefore = modules.LrDialogs.presentModalDialog
  modules.LrDialogs.presentModalDialog = function(args)
    if args.actionVerb == '作成して送信' and args.actionBinding then
      priceSeen = args.actionBinding.enabled.bind_to_object.priceText
    end
    return presentBefore(args)
  end
  local function freeServer(statusFree, createFree, statusFails)
    return function(req)
      if req.url:find('/integration/status') then
        if statusFails then return nil, nil, { error = { name = 'x' } } end
        return 200, { ok = true, tenant_id = 'abc123', free_galleries_remaining = statusFree, client = {} }
      end
      if req.method == 'POST' and req.url:find('/galleries$') then
        return 201, { ok = true, sid = 'SIDF', tenant_id = 'abc123', path = '/t/abc123/s/SIDF', expires_at = iso(7),
          free_galleries_remaining = createFree }
      end
      return 200, { ok = true, galleries = {} }
    end
  end
  local function createWith(server, prefs)
    photos = { newPhoto('/p/IMG_0001.NEF') }
    activeCatalog = newCatalog(photos)
    env.server = server
    env.prefs = prefs or { locationPromptShown = true }
    priceSeen = nil
    run('CreateGallery.lua')
    return priceSeen
  end

  local price = createWith(freeServer(5, 4))
  check(price and price:find('無料の残り 5 ギャラリー', 1, true) ~= nil, 'free: the dialog shows the server number (' .. tostring(price) .. ')')
  check(price and price:find('3ギャラリー') == nil and price:find('8ギャラリー') == nil, 'free: no number is written in the plug-in')
  -- the create response updates what the next dialog shows (status is cached for an hour)
  price = createWith(freeServer(5, 4), env.prefs)
  check(price and price:find('無料の残り 4 ギャラリー', 1, true) ~= nil, 'free: the create response updates the count')
  price = createWith(freeServer(0, 0))
  check(price and price:find('無料の残りはありません', 1, true) ~= nil, 'free: zero says none are left')
  price = createWith(freeServer(nil, nil))
  check(price and price:find('無料') == nil and price:find('目安 88 円') ~= nil, 'free: unknown count = free allowance not mentioned')
  price = createWith(freeServer(5, 5, true))
  check(price and price:find('無料') == nil, 'free: status unreachable = not mentioned')
  modules.LrDialogs.presentModalDialog = presentBefore
  env.updateCheckLive = false
end

-- Dialog layout (1.0.3): no fixed-height text box is shorter than its text, and the bound ones
-- (status / note of the result window) hold the longest messages the plug-in produces.
check(layoutChecked >= 12, 'layout: static texts checked (' .. layoutChecked .. ')')
for _, problem in ipairs(layoutProblems) do print('  layout: ' .. problem) end
check(#layoutProblems == 0, 'layout: every fixed-height text box fits its text')
do
  local guidanceLib = dofile(_PLUGIN.path .. '/lib/guidance.lua')
  local pipelineLib = dofile(_PLUGIN.path .. '/lib/pipeline.lua')
  local timing = pipelineLib.timingText({
    fast = true, render = 754, renderPerPhoto = 1.5, upload = 754, uploadPerPhoto = 1.5, concurrency = 3,
    total = 1500, previewOk = 120, previewFallback = 180, longMin = 1620, longMax = 2048,
  })
  local busy = '送信をいったん止めました（100 / 299 枚を送信済み）。サーバーが混み合っています。'
    .. '少し待って、「最近のギャラリー」→「続きから送る」を押してください。'
  check(layoutText.wrappedLines(busy .. '\n' .. timing, 560) <= guidanceLib.STATUS_LINES,
    'layout: status box holds the longest outcome + timing text (' .. layoutText.wrappedLines(busy .. '\n' .. timing, 560) .. ')')
  local note = table.concat({
    '書き出せなかった写真が 12 枚あります。',
    '例: ' .. string.rep('あ', 20) .. '…',
    '送信できなかった写真が 3 枚あります。',
    '「最近のギャラリー」から続きを送れます。',
  }, '\n')
  check(layoutText.wrappedLines(note, 560) <= guidanceLib.NOTE_LINES,
    'layout: note box holds the longest note (' .. layoutText.wrappedLines(note, 560) .. ')')
end

print(string.format('%d smoke checks, %d failed', total, failed))
os.execute('rm -rf "' .. tmpRoot .. '"')
os.exit(failed == 0 and 0 or 1)
