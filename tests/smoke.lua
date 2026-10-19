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
tmpRoot = tmpRoot:gsub('/+$', '') .. '/papat-smoke-' .. tostring(os.time()) .. '-' .. (os.tmpname():match('[^/]+$') or '0') -- two runs in one second must not share a folder
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

-- macOS `sips -Z <long> -s format jpeg -s formatOptions 80 <in>... --out <dir>`: for every input writes
-- <dir>/<same file name>, a (structurally valid) JPEG whose long edge is <long>. env.sipsMode:
-- 'fail' (exit 1, nothing written), 'big' (over 256 KB), 'wide' (ignores -Z), 'garbage' (not a JPEG).
function env.fakeSips(cmd, inPaths, outDir)
  env.sipsCalls = (env.sipsCalls or 0) + 1
  env.sipsFilesSeen = (env.sipsFilesSeen or 0) + #inPaths
  local mode = env.sipsMode
  if mode == 'fail' then return 1 end
  local jpegLib = dofile(_PLUGIN.path .. '/lib/jpeg.lua')
  local long = tonumber(cmd:match('%-Z (%d+)'))
  for _, inPath in ipairs(inPaths) do
    local fh = io.open(inPath, 'rb')
    local info
    if fh then
      local data = fh:read('*a')
      fh:close()
      info = jpegLib.parse(data)
    end
    if info then
      local w, h = info.width, info.height
      if mode ~= 'wide' then
        local scale = long / math.max(w, h)
        w, h = math.max(1, math.floor(w * scale + 0.5)), math.max(1, math.floor(h * scale + 0.5))
      end
      local out = io.open(outDir .. '/' .. inPath:match('[^/]+$'), 'wb')
      if out then
        if mode == 'garbage' then
          out:write('not a jpeg at all')
        else
          local body = jpegBytes('thumb', true, w, h, true) -- sips adds a little Exif: the plug-in removes it
          if mode == 'big' then body = body:sub(1, -4) .. string.rep('X', 300 * 1024) .. body:sub(-3) end
          out:write(body)
        end
        out:close()
        env.sipsSizes = env.sipsSizes or {}
        env.sipsSizes[#env.sipsSizes + 1] = { w, h }
      end
    end
  end
  return 0
end

-- The bundled similarity helper (papat.lrplugin/bin/papat-fprint; tools/papat-fprint/main.swift):
-- reads { photos, timeGroups } from inPath, writes { groups } to outPath. env.fprintMode:
--   'passthrough' (default)  groups = timeGroups, unchanged (nothing to refine, nothing lost)
--   'refine'                 env.fprintGroups overrides the whole groups array
--   'fail'                   exit 1, nothing written
--   'garbage'                exit 0, but outPath is not valid JSON
--   'wronglen'                exit 0, but groups has the wrong length
function env.fakeFprint(inPath, outPath)
  env.fprintCalls = (env.fprintCalls or 0) + 1
  local mode = env.fprintMode or 'passthrough'
  if mode == 'fail' then return 1 end
  local inFh = io.open(inPath, 'rb')
  local raw = inFh and inFh:read('*a') or ''
  if inFh then inFh:close() end
  local okDecode, input = pcall(json.decode, raw)
  local n = (okDecode and type(input) == 'table' and type(input.photos) == 'table') and #input.photos or 0
  local groups
  if mode == 'garbage' then
    local fh = io.open(outPath, 'wb'); fh:write('not json'); fh:close()
    return 0
  elseif mode == 'wronglen' then
    groups = { 1 }
  elseif mode == 'refine' then
    groups = env.fprintGroups
  else
    groups = input.timeGroups
  end
  local fh = io.open(outPath, 'wb')
  if not fh then return 1 end
  fh:write(json.encode({ groups = groups }))
  fh:close()
  return 0
end

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
  -- like Lightroom's observable table: observers run when a value changes
  makePropertyTable = function()
    local observers, values = {}, {}
    return setmetatable({}, {
      __index = function(_, k)
        if k == 'addObserver' then
          return function(_, key, fn) observers[key] = fn end
        end
        return values[k]
      end,
      __newindex = function(t, k, v)
        local changed = values[k] ~= v
        values[k] = v
        if changed and observers[k] then observers[k](t, k, v) end
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
    env.clock = (env.clock or 0) + (seconds or 0) -- time passes while a task sleeps
    if coroutine.isyieldable() then coroutine.yield() end
  end,
  yield = function()
    if coroutine.isyieldable() then coroutine.yield() end
  end,
  execute = function(cmd)
    env.commands[#env.commands + 1] = cmd
    if cmd:find('^sips ') then
      local paths = {}
      for quoted in cmd:gmatch("'([^']+)'") do paths[#paths + 1] = quoted end
      local outDir = table.remove(paths) -- the last quoted path is --out <dir>
      return env.fakeSips(cmd, paths, outDir)
    end
    if cmd:find("papat%-fprint'") then
      local quoted = {}
      for q in cmd:gmatch("'([^']+)'") do quoted[#quoted + 1] = q end
      return env.fakeFprint(quoted[2], quoted[3]) -- quoted[1] is the binary itself
    end
    return 0
  end,
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
  -- Since 1.1.0 sending from the preview is the default. The older tests are about the export
  -- path: they run as if the 1.1.0 migration had happened and fastMode had been switched off.
  -- The tests of the new default set env.rawPrefs.
  if not env.rawPrefs and p.fastModeDefaultV110 == nil then
    p.fastModeDefaultV110 = true
    if p.fastMode == nil then p.fastMode = false end
    if p.thumbs == nil then p.thumbs = false end -- the small versions have their own tests
  end
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
    -- a manifest PUT that waits for the network (the other tasks run meanwhile)
    if env.yieldOnManifest and url:find('manifest%.json$') then
      for _ = 1, env.yieldOnManifest do modules.LrTasks.yield() end
    end
    if env.thumbPutYields and url:find('/files/thumbs/') then
      for _ = 1, env.thumbPutYields do modules.LrTasks.yield() end
    end
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
    if w and w <= 600 then
      -- the small preview (the plug-in asks for 400): the smallest level that is 400 px or more
      env.smallRequests = (env.smallRequests or 0) + 1
      env.clock = (env.clock or 0) + (env.smallSeconds or 0)
      if env.smallMode == 'none' or self.noSmall then
        cb(nil, 'no small preview')
      elseif env.smallMode == 'big' or self.smallBig then
        cb(jpegBytes('small-' .. path, false, 1028 * 2, 1371 * 2 // 2, true), nil) -- longer than the server takes
      elseif env.smallMode == 'exif' or self.smallExif then
        cb(jpegBytes('camera-thumb-' .. path, true, 514, 343, true), nil)
      else
        cb(jpegBytes('small-' .. path, false, 514, 343, true), nil)
      end
      return {}
    end
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
    elseif self.thumbSmallThenBig then
      -- 2026-10-19 field theory: a quick, too-small placeholder immediately followed by the
      -- real, properly rendered preview (lib/preview.lua's opts.minEdge is meant to catch this)
      cb(jpegBytes('preview-small-' .. path, false, 1440, 960, true), nil)
      cb(jpegBytes('preview-' .. path, false, 2056, 1371, true), nil)
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
modules.LrApplication = {
  activeCatalog = function() return activeCatalog end,
  versionTable = function() return env.lrVersion or { major = 14, minor = 5, revision = 1 } end,
}
modules.LrSystemInfo = {
  osVersion = function() return env.osVersion or 'macOS 15.1' end,
  architecture = function() return env.arch or 'x64' end,
}

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
          local d = photo.exportDims or {}
          fh:write(jpegBytes('fake-jpeg-' .. tostring(i), true, d[1], d[2]))
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
check(msg(402, 'monthly_limit'):find('上限') ~= nil and msg(402, 'monthly_limit'):find('%d') == nil,
  'describe: 402 monthly_limit without the server text names no number')
check(api.describe(402, 'monthly_limit', '初回請求の成功までは、月60単位が上限です。'):find('月60単位が上限です', 1, true) ~= nil,
  'describe: 402 monthly_limit shows the server wording (the number is the server\'s)')
check(api.describe(402, 'monthly_limit', 'monthly limit reached'):find('monthly limit') == nil,
  'describe: monthly_limit does not show an English server text')
check(msg(409, 'active_gallery_limit'):find('%d') == nil, 'describe: active_gallery_limit without a number from the server names none')
check(msg(409, 'extension_already_used'):find('%d') == nil, 'describe: extension_already_used names no number')
do
  local long = '初回請求の成功までは、月60単位が上限です。' .. string.rep('あ', 400) .. '\r\n次の行'
  local shown = api.describe(402, 'monthly_limit', long)
  check(not shown:find('[\r\n]') and shown:find('…', 1, true) ~= nil and shown:find('次の行', 1, true) == nil,
    'describe: the server text is one line and cut (no line breaks, "…")')
  local _, chars = shown:gsub('[%z\1-\127\194-\244][\128-\191]*', '')
  check(chars <= 300 + #'（ダッシュボード: https://papat.app/app）' + 1, 'describe: about 300 characters at most (' .. chars .. ')')
  check(api.describe(402, nil, 'エ\nラ\nー'):find('[\r\n]') == nil, 'describe: a 402 text with line breaks is one line')
end
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

-- 4c. Key color: not offered in the create dialog any more (1.1.0; it is set in the dashboard)
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
local realPresent = modules.LrDialogs.presentModalDialog
local colorDialog
modules.LrDialogs.presentModalDialog = function(args)
  if args.actionVerb == '作成して送信' and args.actionBinding then
    colorDialog = args
    -- whatever a leftover property would say: the plug-in does not read a colour any more
    args.actionBinding.enabled.bind_to_object.keyColor = '0066CC'
  end
  return realPresent(args)
end
photos = { newPhoto('/p/IMG_0001.NEF') }
activeCatalog = newCatalog(photos)
env.prefs = { locationPromptShown = true, recentKeyColors = '#111111' }
run('CreateGallery.lua')
check(colorCreate and colorCreate.key_color == nil, 'color: the create request carries no colour')
check(colorManifest and colorManifest.key_color == nil, 'color: the manifest carries no colour')
check(env.prefs.recentKeyColors == '#111111', 'color: the stored recent colours are left alone')
do
  -- nothing about a colour on the screen
  local strings = {}
  local function collect(node)
    if type(node) ~= 'table' then return end
    local args = node.args or node
    if type(args.title) == 'string' then strings[#strings + 1] = args.title end
    local value = args.value
    if type(value) == 'table' and value.bound and value.bound.key == 'keyColor' then strings[#strings + 1] = 'BOUND:keyColor' end
    for _, child in ipairs(args) do collect(child) end
  end
  collect(colorDialog and colorDialog.contents)
  local joined = table.concat(strings, '\n')
  check(joined ~= '' and not joined:find('色', 1, true) and not joined:find('#RRGGBB', 1, true)
    and not joined:find('BOUND:keyColor', 1, true), 'color: the create dialog has no colour field, popup or text')
end
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
  serverState = { photos = {}, thumbs = {}, order = {}, times = {}, manifestCalls = 0, deleted = false, failName = nil }
  return function(req)
    if req.method == 'POST' and req.url:find('/integration/report') then
      serverState.reports = serverState.reports or {}
      serverState.reports[#serverState.reports + 1] = json.decode(req.body)
      if env.reportStatus then
        return env.reportStatus, { ok = false, code = env.reportCode or 'error', error = 'x' }
      end
      return 200, { ok = true }
    end
    if req.method == 'POST' and req.url:find('/galleries$') then
      return 201, { ok = true, sid = 'SIDP', tenant_id = 'abc123', path = '/t/abc123/s/SIDP', expires_at = iso(7) }
    end
    if req.method == 'DELETE' then serverState.deleted = true; return 200, { ok = true } end
    if req.method == 'PUT' and req.url:find('/files/photos/') then
      if serverState.failName and req.url:find(serverState.failName, 1, true) then
        return 409, { ok = false, code = 'gallery_closed', error = 'closed' }
      end
      serverState.photos[#serverState.photos + 1] = req.url
      serverState.order[#serverState.order + 1] = 'photo:' .. req.url:match('[^/]*$')
      serverState.times[#serverState.order] = env.clock or 0
      return 200, { ok = true }
    end
    if req.method == 'PUT' and req.url:find('/files/thumbs/') then
      local name = req.url:match('[^/]*$')
      serverState.order[#serverState.order + 1] = 'thumb:' .. name
      serverState.times[#serverState.order] = env.clock or 0
      serverState.thumbPuts = (serverState.thumbPuts or 0) + 1
      if serverState.thumb429First and serverState.thumbPuts == 1 then
        -- a server that still counts the small versions: 429 with Retry-After
        return 429, { ok = false, code = 'rate_limited', error = 'rate limit exceeded' }, { { field = 'Retry-After', value = '2' } }
      end
      if serverState.thumbStatus then
        return serverState.thumbStatus, { ok = false, code = serverState.thumbCode, error = 'refused' }
      end
      serverState.thumbs[#serverState.thumbs + 1] = { url = req.url, body = req.body, type = req.headers }
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

-- 1.1.0: sending from the preview is the default; "export this time" overrides it
do
  env.rawPrefs = true
  local configLib = dofile(_PLUGIN.path .. '/lib/config.lua')

  -- a fastMode=false stored by 1.0.x is dropped once; a choice made afterwards is kept
  env.prefs = { locationPromptShown = true, fastMode = false }
  check(configLib.settings().fastMode == true, 'default: preview first, even over a stored false from 1.0.x')
  check(env.prefs.fastMode == nil and env.prefs.fastModeDefaultV110 == true, 'default: the old value is dropped once')
  env.prefs.fastMode = false -- switched off in the plug-in manager afterwards
  check(configLib.settings().fastMode == false, 'default: a later choice is kept')
  env.prefs = { locationPromptShown = true }
  check(configLib.settings().fastMode == true, 'default: nothing stored = preview')

  -- the create dialog: a check box "export this time"; nothing changes when it is left alone
  local function checkboxes(node, out)
    out = out or {}
    if type(node) ~= 'table' then return out end
    local args = node.args or node
    if node.kind == 'checkbox' then out[#out + 1] = args end
    for _, child in ipairs(args) do checkboxes(child, out) end
    return out
  end
  local exportNowAnswer = false
  local presentBefore = modules.LrDialogs.presentModalDialog
  local lastCreateDialog
  modules.LrDialogs.presentModalDialog = function(args)
    if args.actionVerb == '作成して送信' and args.actionBinding then
      lastCreateDialog = args
      args.actionBinding.enabled.bind_to_object.exportNow = exportNowAnswer
    end
    return presentBefore(args)
  end
  local function createWith(prefs, answer)
    photos = manyPhotos(3)
    activeCatalog = newCatalog(photos)
    env.server = bigServer()
    env.prefs = prefs
    env.passwords.recentGalleries = nil
    env.thumbRequests, env.exportedCount = 0, 0
    exportNowAnswer = answer
    lastCreateDialog = nil
    run('CreateGallery.lua')
  end

  createWith({ locationPromptShown = true }, false)
  check(env.thumbRequests == 3 and env.exportedCount == 0,
    'default: the three photos come from the preview (' .. env.thumbRequests .. '/' .. env.exportedCount .. ')')
  local boxes = lastCreateDialog and checkboxes(lastCreateDialog.contents) or {}
  check(#boxes == 1 and tostring(boxes[1].title):find('この回だけ', 1, true) ~= nil,
    'default: the create dialog has the "export this time" check box')

  createWith({ locationPromptShown = true }, true)
  check(env.thumbRequests == 0 and env.exportedCount == 3,
    'export this time: all three are exported (' .. env.thumbRequests .. '/' .. env.exportedCount .. ')')

  -- preview switched off in the manager: always exported, no check box
  createWith({ locationPromptShown = true, fastMode = false, fastModeDefaultV110 = true }, false)
  check(env.thumbRequests == 0 and env.exportedCount == 3, 'switched off: exported')
  check(lastCreateDialog and #checkboxes(lastCreateDialog.contents) == 0, 'switched off: no check box')

  modules.LrDialogs.presentModalDialog = presentBefore
  env.rawPrefs = nil
  env.prefs = { locationPromptShown = true }
end

-- Small versions for the gallery's overview (1.1.0): thumbs/<same name>, after the photo
do
  env.rawPrefs = true
  local function thumbRun(prefs, setup)
    photos = manyPhotos(4)
    if setup then setup(photos) end
    activeCatalog = newCatalog(photos)
    env.server = bigServer()
    env.prefs = prefs or { locationPromptShown = true, fastMode = false, fastModeDefaultV110 = true }
    env.passwords.recentGalleries = nil
    env.commands, env.sipsCalls, env.sipsFilesSeen, env.sipsSizes, env.sipsMode = {}, 0, 0, {}, nil
    env.sleeps, env.logLines = {}, {}
    run('CreateGallery.lua')
  end
  local function manifestEntries()
    local out = {}
    for _, m in ipairs(manifestRequests()) do for _, p in ipairs(m.photos) do out[p.filename] = p end end
    return out
  end
  local function hasString(body, needle) return body:find(needle, 1, true) ~= nil end

  local thumbModule = dofile(_PLUGIN.path .. '/lib/thumb.lua')
  check(thumbModule.targetLong(2048, 1365) == 600 and thumbModule.targetLong(1365, 2048) == 600
    and thumbModule.targetLong(3000, 1000) == 800 and thumbModule.targetLong(4000, 4000) == 400
    and thumbModule.targetLong(600, 400) == nil and thumbModule.targetLong(380, 570) == nil
    and thumbModule.targetLong(0, 0) == nil, 'thumbs: target sizes (short edge 400, long edge at most 800, never enlarged)')

  -- every photo gets one: made from the JPEG that was sent, short edge 400 / long edge <= 800
  thumbRun()
  check(#serverState.photos == 4 and #serverState.thumbs == 4, 'thumbs: four photos, four small versions ('
    .. #serverState.photos .. '/' .. #serverState.thumbs .. ')')
  local first = serverState.thumbs[1]
  check(first and first.url:find('/galleries/SIDP/files/thumbs/IMG_000%d%.jpg$') ~= nil, 'thumbs: PUT .../files/thumbs/<same name>')
  check(first and first.body:sub(1, 3) == '\255\216\255', 'thumbs: a JPEG')
  check(first and #first.body <= 256 * 1024, 'thumbs: at most 256 KB')
  check(first and not hasString(first.body, 'SerialNumber') and not hasString(first.body, 'GPSLatitude'),
    'thumbs: the Exif that sips adds is removed again')
  check(first and hasString(first.body, 'ICC_PROFILE'), 'thumbs: carries the sRGB profile like the big one')
  local ok600 = true
  for _, size in ipairs(env.sipsSizes) do
    if math.max(size[1], size[2]) ~= 600 or math.min(size[1], size[2]) ~= 400 then ok600 = false end
  end
  check(ok600 and #env.sipsSizes == 4, 'thumbs: 2048x1365 becomes 600x400 (short edge 400)')
  local sipsCommand
  for _, command in ipairs(env.commands) do if command:find('^sips ') then sipsCommand = command; break end end
  check(sipsCommand and sipsCommand:find('-Z 600', 1, true) and sipsCommand:find('formatOptions 80', 1, true),
    'thumbs: sips -Z 600 ... formatOptions 80')

  -- photo first, then its small version (the server refuses a small version without its photo)
  local seen, orderOk = {}, true
  for _, event in ipairs(serverState.order) do
    local kind, name = event:match('^(%a+):(.+)$')
    if kind == 'thumb' and not seen[name] then orderOk = false end
    if kind == 'photo' then seen[name] = true end
  end
  check(orderOk and #serverState.order == 8, 'thumbs: every small version goes after its photo')

  -- the manifest says where they are
  local entries = manifestEntries()
  local linked = 0
  for name, entry in pairs(entries) do
    if entry.thumb == 'thumbs/' .. name then linked = linked + 1 end
  end
  check(linked == 4, 'thumbs: manifest entries carry thumb = thumbs/<name> (' .. linked .. ')')

  -- the small versions are made in batches by sips (one call for many files) and sent by their own
  -- tasks; photos are started at least 0.22 s apart
  do
    local photoTimes, gapsOk = {}, true
    for i, event in ipairs(serverState.order) do
      if event:find('^photo:') then photoTimes[#photoTimes + 1] = serverState.times[i] end
    end
    for i = 2, #photoTimes do
      if photoTimes[i] - photoTimes[i - 1] < 0.21 then gapsOk = false end
    end
    check(gapsOk and #photoTimes == 4, 'thumbs: photos keep the 0.22 s interval')
    check(env.sipsCalls >= 1 and env.sipsCalls <= 2 and env.sipsFilesSeen == 4,
      'thumbs: four files in one or two sips calls, not one call each (' .. tostring(env.sipsCalls) .. ' calls, '
        .. tostring(env.sipsFilesSeen) .. ' files)')
  end

  -- an older server that counts them: 429 -> Retry-After is waited out, and from then on the
  -- small versions keep the interval too. The photos are not stopped.
  do
    photos = manyPhotos(5)
    activeCatalog = newCatalog(photos)
    env.server = bigServer()
    serverState.thumb429First = true
    env.prefs = { locationPromptShown = true, fastMode = false, fastModeDefaultV110 = true }
    env.passwords.recentGalleries = nil
    env.sleeps, env.logLines = {}, {}
    run('CreateGallery.lua')
    check(#serverState.photos == 5 and #serverState.thumbs == 5,
      'thumbs 429: all photos and all small versions arrive (' .. #serverState.photos .. '/' .. #serverState.thumbs .. ')')
    local waitedRetryAfter = false
    for _, d in ipairs(env.sleeps) do if d >= 2 then waitedRetryAfter = true end end
    check(waitedRetryAfter, 'thumbs 429: Retry-After is waited out')
    -- (the interval itself is not asserted here: the fake clock only advances when a task sleeps, so
    -- the times of concurrent workers are not comparable; the log line says the small versions
    -- switched to the interval)
    local pacedLogged = false
    for _, line in ipairs(env.logLines) do if line:find('paced=true', 1, true) then pacedLogged = true end end
    check(pacedLogged, 'thumbs 429: the log says the small versions were paced')
    serverState.thumb429First = nil
  end

  -- a photo that is already small gets none
  thumbRun(nil, function(list) list[1].exportDims = { 600, 400 }; list[2].exportDims = { 380, 570 } end)
  check(#serverState.photos == 4 and #serverState.thumbs == 2, 'thumbs: small photos get none (' .. #serverState.thumbs .. ')')
  entries = manifestEntries()
  check(entries['IMG_0001.jpg'] and entries['IMG_0001.jpg'].thumb == nil, 'thumbs: no thumb key for a small photo')

  -- portrait and wide: the short edge is 400 up to a long edge of 800
  thumbRun(nil, function(list) list[1].exportDims = { 1365, 2048 }; list[2].exportDims = { 3000, 1000 } end)
  local sized = {}
  for _, size in ipairs(env.sipsSizes) do sized[#sized + 1] = size[1] .. 'x' .. size[2] end
  table.sort(sized)
  check(table.concat(sized, ',') == '400x600,600x400,600x400,800x267', 'thumbs: portrait 400x600, 3:1 long edge 800 ('
    .. table.concat(sized, ',') .. ')')

  -- a small version that cannot be made never fails the photo
  local function modeRun(mode)
    photos = manyPhotos(5)
    activeCatalog = newCatalog(photos)
    env.server = bigServer()
    env.prefs = { locationPromptShown = true, fastMode = false, fastModeDefaultV110 = true }
    env.passwords.recentGalleries = nil
    env.commands, env.sipsCalls, env.sipsSizes = {}, 0, {}
    env.sipsMode = mode
    env.logLines = {}
    run('CreateGallery.lua')
    env.sipsMode = nil
  end
  for _, mode in ipairs({ 'fail', 'garbage', 'wide', 'big' }) do
    modeRun(mode)
    check(#serverState.photos == 5 and #serverState.thumbs == 0, 'thumbs: ' .. mode .. ': all photos sent, no small version ('
      .. #serverState.photos .. '/' .. #serverState.thumbs .. ')')
    local ms = manifestRequests()
    check(ms[#ms] and ms[#ms].complete == true, 'thumbs: ' .. mode .. ': the gallery is completed')
    -- the batch fails as a whole (five failures in a row): no more attempts in this send
    check(env.sipsCalls >= 1 and env.sipsCalls <= 2,
      'thumbs: ' .. mode .. ': gives up after the failed batch (' .. env.sipsCalls .. ' calls)')
  end

  -- the server refuses them (an older server: 415 unsupported_media_type): photos go on, no more tries
  photos = manyPhotos(6)
  activeCatalog = newCatalog(photos)
  env.server = bigServer()
  serverState.thumbStatus, serverState.thumbCode = 415, 'unsupported_media_type'
  env.prefs = { locationPromptShown = true, fastMode = false, fastModeDefaultV110 = true }
  env.passwords.recentGalleries = nil
  env.commands = {}
  run('CreateGallery.lua')
  local thumbPuts = 0
  for _, event in ipairs(serverState.order) do if event:find('^thumb:') then thumbPuts = thumbPuts + 1 end end
  check(#serverState.photos == 6 and thumbPuts >= 3 and thumbPuts <= 5, 'thumbs: refused: three or four tries, then none (' .. thumbPuts .. ')')
  local entries2 = manifestEntries()
  local anyThumb = false
  for _, entry in pairs(entries2) do if entry.thumb then anyThumb = true end end
  check(not anyThumb, 'thumbs: refused: the manifest names none')

  -- off in the preferences: nothing is made
  thumbRun({ locationPromptShown = true, fastMode = false, fastModeDefaultV110 = true, thumbs = false })
  check(#serverState.thumbs == 0 and env.sipsCalls == 0, 'thumbs: switched off = none')

  -- from the preview (the default): the small version is Lightroom's small preview (no sips)
  local function previewRun(setup, prefs, mode)
    photos = manyPhotos(6)
    if setup then setup(photos) end
    activeCatalog = newCatalog(photos)
    env.server = bigServer()
    env.prefs = prefs or { locationPromptShown = true }
    env.passwords.recentGalleries = nil
    env.commands, env.sipsCalls, env.sipsFilesSeen, env.sipsSizes, env.sipsMode = {}, 0, 0, {}, nil
    env.smallRequests, env.thumbRequests, env.exportedCount, env.smallMode = 0, 0, 0, mode
    env.sleeps, env.logLines = {}, {}
    run('CreateGallery.lua')
    env.smallMode = nil
  end
  local function logHas(part)
    for _, line in ipairs(env.logLines) do if line:find(part, 1, true) then return line end end
  end
  local function dims(bytes)
    local info = dofile(_PLUGIN.path .. '/lib/jpeg.lua').parse(bytes)
    return info and info.width, info and info.height
  end

  previewRun()
  check(#serverState.photos == 6 and #serverState.thumbs == 6, 'small versions (preview send): six photos, six small versions ('
    .. #serverState.photos .. '/' .. #serverState.thumbs .. ')')
  -- Lightroom's small previews are never asked for (they can stay old after an edit while the big
  -- one is new): the small version always comes from the bytes that were sent, through sips
  check(env.smallRequests == 0, 'small versions: no small preview is requested (' .. env.smallRequests .. ' requests)')
  check(env.sipsCalls >= 1 and env.sipsCalls <= 2 and env.sipsFilesSeen == 6,
    'small versions: six files in one or two sips calls (' .. env.sipsCalls .. ' calls, ' .. env.sipsFilesSeen .. ' files)')
  local w, h = dims(serverState.thumbs[1].body)
  check(w == 600 and h == 400, 'small versions: the 2056x1371 preview becomes 600x400 (' .. tostring(w) .. 'x' .. tostring(h) .. ')')
  check(not hasString(serverState.thumbs[1].body, 'SerialNumber') and hasString(serverState.thumbs[1].body, 'ICC_PROFILE'),
    'small versions: cleaned, with the sRGB profile')
  check(logHas('probe small preview') == nil and logHas('small versions: from the preview') == nil,
    'small versions: no small-preview probe in the log')
  check(logHas('pipeline small versions: sent=6 none=0') ~= nil, 'small versions: the log counts them')
  check(logHas('pipeline times: photoPUT=') ~= nil and logHas('thumbPUT=') ~= nil and logHas('sips=') ~= nil
    and logHas('smallPreview=') == nil, 'small versions: the log has the time breakdown')
  local entriesP = manifestEntries()
  local linkedP, extraKeys = 0, false
  for name, entry in pairs(entriesP) do
    if entry.thumb == 'thumbs/' .. name then linkedP = linkedP + 1 end
    for key in pairs(entry) do if key == 'thumbPublished' then extraKeys = true end end
  end
  check(linkedP == 6, 'small preview: the manifest names all six (' .. linkedP .. ')')
  check(not extraKeys, 'small preview: nothing internal leaks into the manifest entries')

  -- a small version that arrives while a manifest PUT is waiting is not in that body: it must be
  -- added by the late pass (audit 11)
  env.yieldOnManifest, env.thumbPutYields = 40, 3 -- the manifest PUT waits much longer than a small version's PUT
  previewRun()
  env.yieldOnManifest, env.thumbPutYields = nil, nil
  do
    local entriesY = manifestEntries()
    local linkedY = 0
    for name, entry in pairs(entriesY) do
      if entry.thumb == 'thumbs/' .. name then linkedY = linkedY + 1 end
    end
    check(#serverState.thumbs == 6 and linkedY == 6,
      'small versions: a small version that came in during a manifest PUT is added later (' .. linkedY .. ' of 6)')
  end

  -- the late pass leaves key_color to the server (the colour may have been changed in the browser
  -- meanwhile). A gallery made by an earlier version has a colour of its own: resume it with one.
  do
    photos = manyPhotos(6)
    activeCatalog = newCatalog(photos)
    env.server = bigServer()
    env.prefs = { locationPromptShown = true }
    env.passwords.recentGalleries = nil
    local senderLib = dofile(_PLUGIN.path .. '/lib/sender.lua')
    local items = {}
    for i, photo in ipairs(photos) do items[i] = { photo = photo, sourceId = 'src-' .. i } end
    senderLib.start {
      apiKey = KEY, sid = 'SIDP', title = 'Resumed', keyColor = '#0066cc',
      items = items, usedNames = {}, status = senderLib.newStatus('x'), total = 6, alreadyUploaded = 0,
      rightsMode = 'none', fast = true,
    }
    drain()
    local withColor, passes = 0, 0
    for _, m in ipairs(manifestRequests()) do
      if m.key_color == '#0066cc' then withColor = withColor + 1 end
      local onlyThumbs = #m.photos > 0
      for _, p in ipairs(m.photos) do if not p.thumb then onlyThumbs = false end end
      if onlyThumbs and not m.key_color then passes = passes + 1 end
    end
    check(withColor >= 1 and passes >= 1,
      'small versions: manifests carry the gallery colour, the late pass (only entries with thumb) does not ('
        .. withColor .. ' with, ' .. passes .. ' late passes without)')
    check(manifestRequests()[#manifestRequests()].title == 'Resumed', 'small versions: the late pass keeps the title')
  end

  -- "export this time": photos are exported, the small versions come from the exported files via sips
  do
    photos = manyPhotos(4)
    activeCatalog = newCatalog(photos)
    env.server = bigServer()
    env.prefs = { locationPromptShown = true }
    env.passwords.recentGalleries = nil
    env.commands, env.sipsCalls, env.sipsFilesSeen, env.smallRequests, env.exportedCount = {}, 0, 0, 0, 0
    env.logLines = {}
    local presentBefore2 = modules.LrDialogs.presentModalDialog
    modules.LrDialogs.presentModalDialog = function(args)
      if args.actionVerb == '作成して送信' and args.actionBinding then
        args.actionBinding.enabled.bind_to_object.exportNow = true
      end
      return presentBefore2(args)
    end
    run('CreateGallery.lua')
    modules.LrDialogs.presentModalDialog = presentBefore2
    check(env.exportedCount == 4 and env.smallRequests == 0 and env.sipsCalls >= 1 and #serverState.thumbs == 4,
      'small versions: exporting this time = small versions through sips (' .. env.smallRequests .. ' small requests, '
        .. env.sipsCalls .. ' sips calls, ' .. #serverState.thumbs .. ' small versions)')
  end

  env.rawPrefs = nil
  env.prefs = { locationPromptShown = true }
end

-- Announcement template (1.1.0): used by the create dialog, kept from the result window, edited in the manager
do
  local function findButton(node, titlePart, out)
    if type(node) ~= 'table' then return out end
    local args = node.args or node
    if node.kind == 'push_button' and tostring(args.title):find(titlePart, 1, true) then return args end
    for _, child in ipairs(args) do
      local found = findButton(child, titlePart)
      if found then return found end
    end
    return out
  end
  local function createWith(prefs)
    photos = manyPhotos(2)
    activeCatalog = newCatalog(photos)
    env.server = bigServer()
    env.prefs = prefs
    env.passwords.recentGalleries = nil
    run('CreateGallery.lua')
    return lastDialog('modal')
  end

  -- default: the usual text
  local result = createWith({ locationPromptShown = true })
  local resultProps = result.args.contents.args.bind_to_object
  check(resultProps.guidance:find('写真をお送りします。', 1, true) == 1
    and resultProps.guidance:find('公開期限: ', 1, true) ~= nil
    and resultProps.guidance:find('ブラウザで開いて', 1, true) ~= nil, 'template: the default text in the result window')

  -- an own template in the preferences
  result = createWith({ locationPromptShown = true,
    announcementTemplate = '{題} の選定をお願いします。\nここです→ {URL}\n合言葉: {パスコード}' })
  resultProps = result.args.contents.args.bind_to_object
  check(resultProps.guidance:find('の選定をお願いします。', 1, true) ~= nil
    and resultProps.guidance:find('合言葉: ', 1, true) ~= nil
    and resultProps.guidance:find('写真をお送りします', 1, true) == nil, 'template: the own template is used')

  -- a broken template (no marks at all) still gives a usable text
  result = createWith({ locationPromptShown = true, announcementTemplate = 'よろしくお願いします。' })
  resultProps = result.args.contents.args.bind_to_object
  check(resultProps.guidance:find('よろしくお願いします。', 1, true) == 1
    and resultProps.guidance:find('URL: https://', 1, true) ~= nil
    and resultProps.guidance:find('パスコード: ', 1, true) ~= nil, 'template: a template without marks gets the URL and passcode')

  -- result window: edit the text, press "この文面を、次回から使う"
  result = createWith({ locationPromptShown = true })
  resultProps = result.args.contents.args.bind_to_object
  resultProps.guidance = '春のご案内です。\n' .. resultProps.url .. '\nパスコードは ' .. resultProps.passcode .. ' です。'
  local save = findButton(result.args.contents, 'この文面を、次回から使う')
  check(save ~= nil, 'template: the result window has the "use this wording next time" button')
  save.action()
  check(env.prefs.announcementTemplate == '春のご案内です。\n{URL}\nパスコードは {パスコード} です。',
    'template: the edited wording is stored as a template (' .. tostring(env.prefs.announcementTemplate) .. ')')
  result = createWith(env.prefs)
  resultProps = result.args.contents.args.bind_to_object
  check(resultProps.guidance:find('春のご案内です。', 1, true) == 1 and resultProps.guidance:find('パスコードは ', 1, true) ~= nil,
    'template: the next gallery uses the stored wording')

  -- plug-in manager: a field with the stored (or default) text, a reset button, and the preference follows
  env.prefs = { locationPromptShown = true, announcementTemplate = '保存済みの文 {URL}' }
  local observers = {}
  local mgrProps = setmetatable({}, { __index = function(_, k)
    if k == 'addObserver' then return function(_, key, fn) observers[key] = fn end end
  end })
  env.passwords.apiKey = KEY
  local sectionsList = dofile(_PLUGIN.path .. '/PluginInfoProvider.lua').sectionsForTopOfDialog(fakeFactory(), mgrProps)
  walkLayout(sectionsList, 'manager (announcement)')
  check(mgrProps.announcementTemplate == '保存済みの文 {URL}', 'template: the manager shows the stored text')
  local reset = findButton(sectionsList, 'もとの文に戻す')
  check(reset ~= nil, 'template: the manager has a reset button')
  reset.action()
  mgrProps.announcementTemplate = mgrProps.announcementTemplate -- (the observer is called by Lightroom)
  observers.announcementTemplate()
  check(env.prefs.announcementTemplate == nil, 'template: reset = the default again (nothing stored)')
  mgrProps.announcementTemplate = '{題}\n{URL}\n{パスコード}'
  observers.announcementTemplate()
  check(env.prefs.announcementTemplate == '{題}\n{URL}\n{パスコード}', 'template: an edit in the manager is stored')
  mgrProps.announcementTemplate = '   '
  observers.announcementTemplate()
  check(env.prefs.announcementTemplate == nil, 'template: an emptied field means the default')


  -- Editing the text (1.1.0). The SDK has no way to type a line break in an edit field (Return presses the
  -- default button): the field sits in a scrolling window, "編集中" stops the closing button, and the text
  -- editor is offered.
  do
    local function findKind(node, kind, acc)
      acc = acc or {}
      if type(node) ~= 'table' then return acc end
      local args = node.args or node
      if node.kind == kind then acc[#acc + 1] = args end
      for _, child in ipairs(args) do findKind(child, kind, acc) end
      return acc
    end
    local function openCommand()
      for i = #env.commands, 1, -1 do
        local path = env.commands[i]:match("^open %-t '([^']+)'")
        if path then return path end
      end
    end
    local editResult = createWith({ locationPromptShown = true })
    local contents = editResult.args.contents
    local editProps = contents.args.bind_to_object

    -- a scrolling window onto a field that is taller than the window
    local windowed = false
    for _, view in ipairs(findKind(contents, 'scrolled_view')) do
      for _, field in ipairs(findKind(view, 'edit_field')) do
        if type(field.value) == 'table' and field.value.bound.key == 'guidance' and (field.height_in_lines or 0) > 9 then
          windowed = true
        end
      end
    end
    check(windowed, 'edit: the announcement field is a tall field in a scrolling window')

    -- the closing button follows "編集中"
    local binding = editResult.args.actionBinding
    check(binding and binding.enabled and binding.enabled.key == 'canClose', 'edit: the closing button is bound to canClose')
    check(editProps.canClose == true, 'edit: closing is possible by default')
    editProps.editing = true
    check(editProps.canClose == false, 'edit: "編集中" disables the closing button (Return cannot close the window)')
    editProps.editing = false
    check(editProps.canClose == true, 'edit: and enables it again')

    -- the text editor: write, open, read back
    local before = editProps.guidance
    local openButton = findButton(contents, 'テキストエディタで開く')
    check(openButton ~= nil, 'edit: a "open in the text editor" button')
    openButton.action()
    drain()
    local path = openCommand()
    check(path ~= nil and path:find('papat%-announcement%.txt$') ~= nil, 'edit: `open -t` is run on a .txt file')
    local fh = path and io.open(path, 'rb')
    check(fh and fh:read('*a') == before, 'edit: the file holds the current text')
    if fh then fh:close() end
    local out = io.open(path, 'wb')
    out:write('\239\187\191新しい文\r\n二行目')
    out:close()
    local readButton = findButton(contents, '編集した内容を反映')
    readButton.action()
    check(editProps.guidance == '新しい文\n二行目', 'edit: what was saved comes back (BOM and CRLF removed)')
    out = io.open(path, 'wb'); out:write('   '); out:close()
    editProps.guidance = 'そのまま'
    readButton.action()
    check(editProps.guidance == 'そのまま', 'edit: an empty file does not wipe the text')

    -- "最近のギャラリー" has the same field
    env.passwords.recentGalleries = nil
    createWith({ locationPromptShown = true })
    env.dialogs = {}
    run('RecentGalleries.lua')
    local recent = lastDialog('modal')
    check(recent and recent.args.actionBinding and recent.args.actionBinding.enabled.key == 'canClose',
      'edit: the recent galleries window has the same closing-button rule')
  end

  -- plug-in manager: tall field in a window, the editor buttons write and read the template
  do
    local function findKindM(node, kind, acc)
      acc = acc or {}
      if type(node) ~= 'table' then return acc end
      local args = node.args or node
      if node.kind == kind then acc[#acc + 1] = args end
      for _, child in ipairs(args) do findKindM(child, kind, acc) end
      return acc
    end
    env.prefs = { locationPromptShown = true }
    local observersM = {}
    local mgr = setmetatable({}, { __index = function(_, k)
      if k == 'addObserver' then return function(_, key, fn) observersM[key] = fn end end
    end })
    env.passwords.apiKey = KEY
    local sectionsM = dofile(_PLUGIN.path .. '/PluginInfoProvider.lua').sectionsForTopOfDialog(fakeFactory(), mgr)
    local windowedM = false
    for _, view in ipairs(findKindM(sectionsM, 'scrolled_view')) do
      for _, field in ipairs(findKindM(view, 'edit_field')) do
        if type(field.value) == 'table' and field.value.bound.key == 'announcementTemplate' and (field.height_in_lines or 0) > 8 then
          windowedM = true
        end
      end
    end
    check(windowedM, 'edit: the manager field is a tall field in a scrolling window')
    local openM = findButton(sectionsM, 'テキストエディタで開く')
    local readM = findButton(sectionsM, '編集した内容を反映')
    check(openM ~= nil and readM ~= nil, 'edit: the manager has the text editor buttons')
    env.commands = {}
    openM.action()
    drain()
    local pathM
    for _, command in ipairs(env.commands) do pathM = pathM or command:match("^open %-t '([^']+)'") end
    check(pathM and pathM:find('papat%-announcement%-template%.txt$') ~= nil, 'edit: the manager writes its own file')
    local outM = io.open(pathM, 'wb'); outM:write('{題}\n\n{URL}\nパスコード {パスコード}'); outM:close()
    readM.action()
    check(mgr.announcementTemplate == '{題}\n\n{URL}\nパスコード {パスコード}', 'edit: the template comes back from the editor')
  end
  env.prefs = { locationPromptShown = true }
end

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

-- speed-first, a bad probe sample no longer dooms the whole gallery (2026-10-19 fix): each
-- photo still gets its own attempt even when the probe itself looked unusable
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
check(env.thumbRequests == 6, 'probe: every photo gets its own preview attempt (' .. env.thumbRequests .. ')')
check(env.exportedCount == 5, 'probe: only the five bad ones are exported, not all six (' .. env.exportedCount .. ')')
local line = timingOf('SIDP') or ''
check(line:find('プレビューから 1 枚・書き出しで 5 枚', 1, true) ~= nil, 'probe: the one good photo still used its preview')
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

-- 2026-10-19: the probe log shows the real size for a rejected probe (it used to always say
-- "-", which is what hid the field incident this fix responds to)
photos = manyPhotos(3)
photos[1].thumbSmall = true
activeCatalog = newCatalog(photos)
env.server = bigServer()
env.prefs = { locationPromptShown = true, fastMode = true }
env.passwords.recentGalleries = nil
env.exportedCount = 0
env.logLines = {}
run('CreateGallery.lua')
local sawRealSize = false
for _, l in ipairs(env.logLines) do
  if l:find('probe photo 1: 1440x960', 1, true) then sawRealSize = true end
end
check(sawRealSize, 'probe log: shows the real size for a rejected probe instead of "-"')

-- a suspiciously fast, too-small first callback followed by a bigger one is used, not
-- exported (2026-10-19 field theory: Lightroom answers once with whatever cheap placeholder
-- it has on hand, then again with the real preview, when the standard preview was not
-- actually cached — see lib/preview.lua's opts.minEdge)
photos = manyPhotos(3)
photos[1].thumbSmallThenBig = true
activeCatalog = newCatalog(photos)
env.server = bigServer()
env.prefs = { locationPromptShown = true, fastMode = true }
env.passwords.recentGalleries = nil
env.exportedCount = 0
env.logLines = {}
run('CreateGallery.lua')
check(env.exportedCount == 0, 'second callback: the bigger, later callback is used instead of exporting (' .. env.exportedCount .. ')')
local sawTwoCallbacks = false
for _, l in ipairs(env.logLines) do
  if l:find('probe photo 1:', 1, true) and l:find('calls=2', 1, true) then sawTwoCallbacks = true end
end
check(sawTwoCallbacks, 'second callback: the probe log shows two callbacks for photo 1')

-- audit 17 §4.1: once this send has seen 3 small_timeout outcomes and 0 small_then_big, the
-- 5s settle-wait stops for the rest of THIS send — a catalog where the "2nd callback" theory
-- never pays off does not keep paying 5s per small photo for hundreds of photos. Good photos
-- are interspersed so the PRE-EXISTING PREVIEW_GIVE_UP streak (3 *consecutive* failures) never
-- fires on its own and muddies what is being measured here — every other photo is good, so
-- failuresInRow never exceeds 1 regardless of this fix.
photos = manyPhotos(11)
for _, i in ipairs({ 2, 4, 6, 8, 10 }) do photos[i].thumbSmall = true end -- 5 small, never improve
activeCatalog = newCatalog(photos)
env.server = bigServer()
env.prefs = { locationPromptShown = true, fastMode = true }
env.passwords.recentGalleries = nil
env.exportedCount = 0
env.sleeps, env.logLines = {}, {}
run('CreateGallery.lua')
check(env.exportedCount == 5, 'settle give-up: the five small photos are still exported ('
  .. env.exportedCount .. ')')
local settleTicks = 0
for _, s in ipairs(env.sleeps) do if s >= 0.04 and s <= 0.06 then settleTicks = settleTicks + 1 end end
-- 5 small photos * 5s / 0.05s-per-tick = up to 500 ticks if every one waited the full settle
-- window; with the give-up, only the first 3 (wherever probing/order puts them) pay it in
-- full = ~300 (±a couple for floating-point drift in the 0.05s accumulation), not ~500.
check(settleTicks >= 290 and settleTicks <= 320, 'settle give-up: roughly 3 photos\' worth of '
  .. 'waiting, not 5 (' .. settleTicks .. ' ticks of ~0.05s, expected ~300)')
local sawGiveUpLog = false
for _, l in ipairs(env.logLines) do
  if l:find('small_timeout, 0 small_then_big', 1, true) then sawGiveUpLog = true end
end
check(sawGiveUpLog, 'settle give-up: logged once')

-- ... but a single small_then_big this send means the hypothesis IS paying off here, so the
-- wait never gets switched off, however many small_timeout outcomes pile up alongside it. The
-- small_then_big is placed first (photo 1, always probed) so it is counted before any of the
-- plain-small photos could otherwise reach the give-up threshold.
photos = manyPhotos(11)
photos[1].thumbSmallThenBig = true
for _, i in ipairs({ 3, 5, 7, 9 }) do photos[i].thumbSmall = true end -- 4 small, never improve
activeCatalog = newCatalog(photos)
env.server = bigServer()
env.prefs = { locationPromptShown = true, fastMode = true }
env.passwords.recentGalleries = nil
env.exportedCount = 0
env.sleeps, env.logLines = {}, {}
run('CreateGallery.lua')
check(env.exportedCount == 4, 'settle kept on: the four genuinely-small photos are exported, '
  .. 'photo 1 used its (eventually big) preview (' .. env.exportedCount .. ')')
local keptTicks = 0
for _, s in ipairs(env.sleeps) do if s >= 0.04 and s <= 0.06 then keptTicks = keptTicks + 1 end end
check(keptTicks >= 380, 'settle kept on: all four small photos still pay the full 5s wait, '
  .. 'because this send also has a small_then_big (' .. keptTicks .. ' ticks, expected ~400)')
local sawGiveUpLog2 = false
for _, l in ipairs(env.logLines) do
  if l:find('small_timeout, 0 small_then_big', 1, true) then sawGiveUpLog2 = true end
end
check(not sawGiveUpLog2, 'settle kept on: never logged (the hypothesis held for this send)')

-- previews that are rendered on demand (slow probes) are still used per photo (2026-10-19:
-- this used to make the whole gallery export from the start on the probe's say alone)
photos = manyPhotos(5)
activeCatalog = newCatalog(photos)
env.server = bigServer()
env.prefs = { locationPromptShown = true, fastMode = true }
env.passwords.recentGalleries = nil
env.thumbRequests, env.exportedCount = 0, 0
env.thumbSeconds = 1.1
run('CreateGallery.lua')
env.thumbSeconds = nil
check(env.thumbRequests == 5 and env.exportedCount == 0, 'slow probe: every photo still uses its (slow) preview (' .. env.thumbRequests .. ' previews asked, ' .. env.exportedCount .. ' exported)')
check((timingOf('SIDP') or ''):find('プレビューから 5 枚・書き出しで 0 枚', 1, true) ~= nil, 'slow probe: the result counts them as previews, not exports')

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
    and titles[4] == 'papat — 送信の記録' and titles[5] == 'papat — 案内文（クライアントに送る文面）'
    and titles[6] == 'papat — セレクト受け取り 反映設定',
    'manager (not standard): location, connect, send, report, wording, receive (' .. table.concat(titles, ' | ') .. ')')
end
check(type(sections) == 'table' and #sections == 7, 'manager: seven sections (location first when not standard)')
check(props.keyStatus and props.keyStatus:find('設定済み') ~= nil and not props.keyStatus:find('EXAMPLEKEY'), 'manager: key masked')
check(props.applyPick == true and props.applyMemo == true and props.applyTags == true and props.starCollections == false, 'manager: defaults (pick/memo/tags on, star sub-collections off)')
check(props.reportConsent == false, 'manager: 送信の記録 defaults to off until asked or switched on')

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
  check(#secs == 6, 'manager (standard): no location section')
do
  local titles = {}
  for _, sec in ipairs(secs) do titles[#titles + 1] = sec.title end
  check(table.concat(titles, ' | ') == 'papat — 接続 | papat — アタリ送付 | papat — 送信の記録 | papat — 案内文（クライアントに送る文面） | papat — セレクト受け取り 反映設定 | papat — バージョン',
    'manager: sections in the order connect, send, report, wording, receive, version (' .. table.concat(titles, ' | ') .. ')')
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

-- The photo limit before creating: the server's max_photos (status), 900 until it says (1.1.0)
do
  env.updateCheckLive = true
  local function limitRun(maxPhotos, count)
    photos = manyPhotos(count)
    activeCatalog = newCatalog(photos)
    env.prefs = { locationPromptShown = true }
    env.passwords.recentGalleries = nil
    local creates = 0
    env.server = function(req)
      if req.url:find('/integration/status') then
        return 200, { ok = true, tenant_id = 'abc123', client = {}, max_photos = maxPhotos }
      end
      if req.method == 'POST' and req.url:find('/galleries$') then
        creates = creates + 1
        return 201, { ok = true, sid = 'SIDL', tenant_id = 'abc123', path = '/t/abc123/s/SIDL', expires_at = iso(7) }
      end
      return 200, { ok = true, galleries = {} }
    end
    env.dialogs = {}
    run('CreateGallery.lua')
    return creates, lastDialog('message')
  end

  -- below the auto-split trigger (888): the old hard limit still applies as a plain refusal
  local creates, msg = limitRun(50, 60)
  check(creates == 0 and msg and msg.title == '写真が多すぎます' and msg.info:find('50 枚まで', 1, true)
    and msg.info:find('現在 60 枚', 1, true), 'limit: the server\'s max_photos (50) is the limit and is in the sentence')
  creates = limitRun(50, 40)
  check(creates == 1, 'limit: 40 photos are fine under a limit of 50')

  -- above 888: 1.2.0's auto-split (lib/split.lua) tries first; these photos are all undated
  -- (manyPhotos never sets a capture time), so it falls back to a fixed cut at 888 — a
  -- remainder under 100 merges back into one gallery, 100 or more stays split
  creates, msg = limitRun(nil, 901)
  check(creates == 1 and msg == nil,
    'limit: 901 undated photos (888+13) merges back to one gallery (1000 until the server says)')
  creates, msg = limitRun('junk', 901)
  check(creates == 1 and msg == nil, 'limit: a max_photos that makes no sense is ignored the same way')
  creates = limitRun(1200, 1000)
  check(creates == 2, 'limit: 1000 undated photos (888+112) split into two galleries even though 1200 would fit one')

  -- a custom max_photos too small even for the auto-split's own target (888) still refuses
  -- cleanly instead of sending an oversized gallery (lib/split.lua's own clamp keeps every
  -- segment at or under max_photos; this is CreateGallery.lua's defensive check on top of it)
  creates, msg = limitRun(500, 1000)
  check(creates == 2, 'limit: a small max_photos (500) still splits, just into smaller pieces')

  env.updateCheckLive = false
  env.prefs = { locationPromptShown = true }
end

-- ---------------------------------------------------------------------------
-- Auto-split (1.2.0): the settings dialog's one-line notice, two galleries with suffixed
-- titles, one combined multi-URL invitation, two "最近のギャラリー" entries, and the manifest
-- group numbers restarting at 1 for the second gallery. 900 photos with a deliberate one-hour
-- gap at position 800 (well inside lib/split.lua's [750,888] range), so the cut is a real time
-- group boundary rather than the "no information at all" fallback already covered above.
-- ---------------------------------------------------------------------------
do
  local function photoAt(path, wallTime)
    local p = newPhoto(path)
    p.raw.dateTimeISO8601 = wallTime
    return p
  end
  local splitPhotos, t = {}, 1790000000
  for i = 1, 900 do
    if i == 801 then t = t + 3600 end -- the one boundary: 1 hour, against ~10s elsewhere
    splitPhotos[i] = photoAt(string.format('/p/s%04d.NEF', i), os.date('!%Y-%m-%dT%H:%M:%S', t))
    t = t + 10
  end
  activeCatalog = newCatalog(splitPhotos)
  env.passwords.recentGalleries = nil
  env.prefs = { locationPromptShown = true }

  local sidCount, createdTitles = 0, {}
  env.server = function(req)
    if req.method == 'POST' and req.url:find('/galleries$') then
      sidCount = sidCount + 1
      local body = json.decode(req.body)
      createdTitles[#createdTitles + 1] = body.title
      return 201, { ok = true, sid = 'SIDSPLIT' .. sidCount, tenant_id = 'abc123',
        path = '/t/abc123/s/SIDSPLIT' .. sidCount, expires_at = iso(7) }
    end
    if req.method == 'PUT' then return 200, { ok = true } end
    return 404, { ok = false, code = 'not_found', error = 'not found' }
  end

  -- capture the settings dialog's split notice and the result dialog's combined invitation
  local realPresentSplit = modules.LrDialogs.presentModalDialog
  local splitNoticeSeen, resultProps
  modules.LrDialogs.presentModalDialog = function(args)
    if args.actionVerb == '作成して送信' and args.actionBinding then
      splitNoticeSeen = args.actionBinding.enabled.bind_to_object.splitLine
    elseif args.actionVerb and args.actionVerb:find('閉じる', 1, true) then
      resultProps = args.actionBinding.enabled.bind_to_object
    end
    return realPresentSplit(args)
  end
  run('CreateGallery.lua')
  modules.LrDialogs.presentModalDialog = realPresentSplit

  check(sidCount == 2, 'split: two galleries created at the time-group boundary (800/100)')
  check(splitNoticeSeen == '900 枚を 2 つのギャラリーに分けて送ります（800枚・100枚）',
    'split: the one-line notice before creating (' .. tostring(splitNoticeSeen) .. ')')
  check(createdTitles[1] and createdTitles[1]:find('（1/2）', 1, true) ~= nil
    and createdTitles[2] and createdTitles[2]:find('（2/2）', 1, true) ~= nil,
    'split: titles carry the (1/2) / (2/2) suffix')

  check(resultProps ~= nil, 'split: the result dialog was shown')
  if resultProps then
    check(resultProps.guidance:find('1/2：', 1, true) ~= nil and resultProps.guidance:find('2/2：', 1, true) ~= nil,
      'split: the invitation lists both URLs, numbered')
    check(resultProps.guidance:find('/s/SIDSPLIT1/', 1, true) ~= nil
      and resultProps.guidance:find('/s/SIDSPLIT2/', 1, true) ~= nil,
      'split: the invitation carries both galleries\' own URLs')
  end

  local recent = env.passwords.recentGalleries and json.decode(env.passwords.recentGalleries) or {}
  check(#recent == 2, 'split: two entries in "最近のギャラリー" (' .. #recent .. ')')

  -- the manifest: group numbers restart at 1 for the second gallery (not continuing from the
  -- first's own count), 0 only where the source grouping itself had none (never here: every
  -- photo above is dated)
  local bySid = {}
  for _, r in ipairs(env.requests) do
    if r.method == 'PUT' and r.url:find('manifest%.json$') then
      local sid = r.url:match('/galleries/([^/]+)/')
      bySid[sid] = bySid[sid] or {}
      local body = json.decode(r.body)
      for _, p in ipairs(body.photos or {}) do bySid[sid][p.stem] = p.group end
    end
  end
  local g1 = bySid.SIDSPLIT1 or {}
  local g2 = bySid.SIDSPLIT2 or {}
  check(g1.s0001 == 1, 'split: first gallery, first photo is group 1 (' .. tostring(g1.s0001) .. ')')
  check(g2.s0801 == 1, 'split: second gallery, its own first photo restarts at group 1 (' .. tostring(g2.s0801) .. ')')
  check((g1.s0001 or 0) > 0 and (g2.s0801 or 0) > 0, 'split: neither gallery sent group 0 (every photo is dated)')
end

-- ---------------------------------------------------------------------------
-- Auto-split, partial failure (audit 15 §3.1): the 2nd gallery's own creation fails after the
-- 1st already succeeded. The 1st must not be left behind — empty, in a resume job, in "最近の
-- ギャラリー", or (課金 ON) holding its reserved base unit. 1000 undated photos -> {888, 112}
-- (the same fixed-888 fallback already covered above; the point here is the failure, not the
-- cut point).
-- ---------------------------------------------------------------------------
do
  env.passwords.recentGalleries = nil
  env.prefs = { locationPromptShown = true }
  activeCatalog = newCatalog(manyPhotos(1000))

  local posts, deletes = 0, {}
  env.server = function(req)
    if req.method == 'POST' and req.url:find('/galleries$') then
      posts = posts + 1
      if posts == 1 then
        return 201, { ok = true, sid = 'SIDOK1', tenant_id = 'abc123', path = '/t/abc123/s/SIDOK1', expires_at = iso(7) }
      end
      return 402, { ok = false, code = 'card_required', error = 'card required' }
    end
    if req.method == 'DELETE' and req.url:find('/galleries/') then
      deletes[#deletes + 1] = req.url
      return 200, { ok = true }
    end
    if req.method == 'PUT' then return 200, { ok = true } end
    return 200, { ok = true, galleries = {} }
  end
  run('CreateGallery.lua')

  check(posts == 2, 'split failure: both creations were attempted (1st ok, 2nd failed)')
  check(#deletes == 1 and deletes[1]:find('SIDOK1', 1, true) ~= nil,
    'split failure: the 1st (already-created) gallery was deleted, not the 2nd (never created)')
  local manifestSent = false
  for _, r in ipairs(env.requests) do
    if r.method == 'PUT' and r.url:find('manifest%.json$') then manifestSent = true end
  end
  check(not manifestSent, 'split failure: no photo was ever sent for either gallery')
  local recent = env.passwords.recentGalleries and json.decode(env.passwords.recentGalleries) or {}
  check(#recent == 0, 'split failure: the 1st gallery was removed from "最近のギャラリー" again (' .. #recent .. ' left)')
  -- card_required routes through ui.showApiError's "confirm" (dashboard shortcut), not .message
  check(lastDialog('confirm') ~= nil, 'split failure: a dialog about the failed creation was shown')
  check(lastDialog('message') == nil or lastDialog('message').title ~= '作成済みのギャラリーが残っています',
    'split failure: cleanup succeeded silently (no "残っています" dialog)')
end

-- Auto-split, partial failure where the cleanup DELETE also fails: the photographer is told,
-- by title, instead of silently leaving an orphaned gallery with no explanation at all.
do
  env.passwords.recentGalleries = nil
  env.prefs = { locationPromptShown = true }
  activeCatalog = newCatalog(manyPhotos(1000))

  local posts = 0
  env.server = function(req)
    if req.method == 'POST' and req.url:find('/galleries$') then
      posts = posts + 1
      if posts == 1 then
        return 201, { ok = true, sid = 'SIDSTUCK', tenant_id = 'abc123', path = '/t/abc123/s/SIDSTUCK', expires_at = iso(7) }
      end
      return 402, { ok = false, code = 'card_required', error = 'card required' }
    end
    if req.method == 'DELETE' then return 500, { ok = false, error = 'server error' } end
    if req.method == 'PUT' then return 200, { ok = true } end
    return 200, { ok = true, galleries = {} }
  end
  env.dialogs = {}
  run('CreateGallery.lua')

  local stuck
  for _, d in ipairs(env.dialogs) do
    if d.title == '作成済みのギャラリーが残っています' then stuck = d end
  end
  check(stuck ~= nil, 'split failure: cleanup itself failing is reported')
  check(stuck and stuck.info:find('ダッシュボード', 1, true) ~= nil, 'split failure: … and says to use the dashboard')
  check(stuck and stuck.info:find('（1/2）', 1, true) ~= nil, 'split failure: … naming the stuck gallery by its own (1/2) title')
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

-- ---------------------------------------------------------------------------
-- Similarity (1.2.0): lib/similarity.lua drives the bundled helper
-- (papat.lrplugin/bin/papat-fprint; env.fakeFprint stands in for it, same approach as
-- env.fakeSips for the small-version shrinker). No real binary is built for this test; the
-- repository never ships one. similarityLib.binaryPath is swapped for a file this test creates.
-- ---------------------------------------------------------------------------
do
  local similarityLib = dofile(_PLUGIN.path .. '/lib/similarity.lua')
  local groupingLib = dofile(_PLUGIN.path .. '/lib/grouping.lua')
  local fakeBin = tmpRoot .. '/fake-papat-fprint'
  os.execute('touch "' .. fakeBin .. '" && chmod +x "' .. fakeBin .. '"')
  similarityLib.binaryPath = function() return fakeBin end
  env.fprintMode = 'passthrough'
  env.fprintCalls = 0

  local function photoAt(path, wallTime)
    local p = newPhoto(path)
    p.raw.dateTimeISO8601 = wallTime
    return p
  end

  -- two clusters, 3 photos each, a long gap between them: grouping.autoGroups should find 2
  local items = {
    { photo = photoAt('/p/a1.NEF', '2026-10-01T09:00:00'), sourceId = 'a1', datetime = '2026-10-01T09:00:00' },
    { photo = photoAt('/p/a2.NEF', '2026-10-01T09:00:05'), sourceId = 'a2', datetime = '2026-10-01T09:00:05' },
    { photo = photoAt('/p/a3.NEF', '2026-10-01T09:00:10'), sourceId = 'a3', datetime = '2026-10-01T09:00:10' },
    { photo = photoAt('/p/b1.NEF', '2026-10-01T09:20:00'), sourceId = 'b1', datetime = '2026-10-01T09:20:00' },
    { photo = photoAt('/p/b2.NEF', '2026-10-01T09:20:05'), sourceId = 'b2', datetime = '2026-10-01T09:20:05' },
    { photo = photoAt('/p/b3.NEF', '2026-10-01T09:20:10'), sourceId = 'b3', datetime = '2026-10-01T09:20:10' },
  }
  local expected = groupingLib.autoGroups({
    '2026-10-01T09:00:00', '2026-10-01T09:00:05', '2026-10-01T09:00:10',
    '2026-10-01T09:20:00', '2026-10-01T09:20:05', '2026-10-01T09:20:10',
  })
  check(expected.count == 2, 'similarity test fixture: 2 time groups (sanity)')

  -- not macOS: never even looks for the binary
  do
    WIN_ENV = true
    local groupsNow = {}
    local ran = similarityLib.compute(items, groupsNow)
    check(ran == false and groupsNow._done == true and next(groupsNow, '_done') == nil,
      'similarity: WIN_ENV skips entirely')
    WIN_ENV = false
  end

  -- the binary is not where it is expected
  do
    local saved = similarityLib.binaryPath
    similarityLib.binaryPath = function() return tmpRoot .. '/does-not-exist' end
    local groupsNow = {}
    local ran = similarityLib.compute(items, groupsNow)
    check(ran == false and groupsNow._done == true, 'similarity: missing binary skips, does not fail the caller')
    similarityLib.binaryPath = saved
  end

  -- too few photos: never calls the helper
  do
    env.fprintCalls = 0
    local groupsNow = {}
    local ran = similarityLib.compute({ items[1] }, groupsNow)
    check(ran == false and groupsNow._done == true and env.fprintCalls == 0,
      'similarity: fewer than 2 photos, nothing to refine, helper not called')
  end

  -- success (passthrough): groupsNow gets exactly lib/grouping.lua's own answer
  do
    env.fprintMode = 'passthrough'
    local groupsNow = {}
    local ran = similarityLib.compute(items, groupsNow)
    check(ran == true and groupsNow._done == true, 'similarity: passthrough succeeds')
    local ok = true
    for i, item in ipairs(items) do
      if groupsNow[item.sourceId] ~= expected.groups[i] then ok = false end
    end
    check(ok, 'similarity: passthrough matches lib/grouping.lua exactly')
  end

  -- the helper actually refines: a custom answer comes back untouched
  do
    env.fprintMode = 'refine'
    env.fprintGroups = { 1, 1, 2, 3, 3, 3 } -- splits cluster A, keeps B as one group
    local groupsNow = {}
    local ran = similarityLib.compute(items, groupsNow)
    check(ran == true, 'similarity: refine succeeds')
    local wantBySource = { a1 = 1, a2 = 1, a3 = 2, b1 = 3, b2 = 3, b3 = 3 }
    local ok = true
    for sourceId, want in pairs(wantBySource) do
      if groupsNow[sourceId] ~= want then ok = false end
    end
    check(ok, 'similarity: refine is passed through to groupsNow untouched')
  end

  -- the helper fails outright: no groups, caller is never told
  do
    env.fprintMode = 'fail'
    local groupsNow = {}
    local ran = similarityLib.compute(items, groupsNow)
    check(ran == false and groupsNow._done == true and next(groupsNow, '_done') == nil,
      'similarity: helper exit 1 -> no groups')
  end

  -- the helper's answer cannot be read: same as failing outright
  do
    env.fprintMode = 'garbage'
    local groupsNow = {}
    check(similarityLib.compute(items, groupsNow) == false, 'similarity: unreadable JSON -> no groups')
    env.fprintMode = 'wronglen'
    groupsNow = {}
    check(similarityLib.compute(items, groupsNow) == false, 'similarity: wrong-length answer -> no groups')
  end

  -- a photo whose preview could not be made: excluded from the window average (no feature
  -- print to average), but keeps its time-based group rather than being forced to 0 — one bad
  -- preview must not make the gallery discard every other photo's group too (必須, audit 15 §5.3)
  do
    env.fprintMode = 'passthrough'
    local withOneBad = {}
    for i, item in ipairs(items) do withOneBad[i] = item end
    withOneBad[2].photo.noThumb = true -- a2's preview fails
    local groupsNow = {}
    local ran = similarityLib.compute(withOneBad, groupsNow)
    check(ran == true, 'similarity: one bad preview out of six still runs')
    check(groupsNow.a2 ~= nil and groupsNow.a2 == groupsNow.a1,
      'similarity: the photo with no preview still gets its time-based group, not 0 (' .. tostring(groupsNow.a2) .. ')')
    check(groupsNow.a1 ~= nil and groupsNow.b1 ~= nil, 'similarity: the rest are unaffected')
    withOneBad[2].photo.noThumb = false
  end

  -- too many bad previews: skipped outright rather than refining from a thin sample
  do
    env.fprintMode = 'passthrough'
    local mostlyBad = {}
    for i, item in ipairs(items) do mostlyBad[i] = item end
    for i = 1, 5 do mostlyBad[i].photo.noThumb = true end -- only 1 of 6 previews usable
    local groupsNow = {}
    env.fprintCalls = 0
    local ran = similarityLib.compute(mostlyBad, groupsNow)
    check(ran == false and env.fprintCalls == 0, 'similarity: too few usable previews, helper not even called')
    for i = 1, 5 do mostlyBad[i].photo.noThumb = false end
  end

  -- a time budget and a cancel button (audit 15 §5.2): the auto-split's one synchronous,
  -- unavoidable wait must not run unbounded or be stuck with no way out
  do
    env.fprintMode = 'passthrough'

    -- already past the deadline before starting: gives up immediately, never calls the helper
    env.fprintCalls = 0
    local groupsNow = {}
    local ran = similarityLib.compute(items, groupsNow, { deadlineEpoch = os.time() - 1 })
    check(ran == false and groupsNow._done == true and env.fprintCalls == 0,
      'similarity: a deadline already in the past skips entirely')

    -- already canceled before starting: same
    env.fprintCalls = 0
    groupsNow = {}
    ran = similarityLib.compute(items, groupsNow, { isCanceled = function() return true end })
    check(ran == false and env.fprintCalls == 0, 'similarity: canceled before starting skips entirely')

    -- canceled partway through rendering previews: the rest are left without one, and (since
    -- the cancel flag stays set) the helper is never called even if enough were still usable
    env.fprintCalls = 0
    local calls = 0
    groupsNow = {}
    ran = similarityLib.compute(items, groupsNow, {
      isCanceled = function() calls = calls + 1; return calls > 2 end,
    })
    check(ran == false and env.fprintCalls == 0,
      'similarity: canceled partway through rendering previews, helper still not called')

    -- a deadline far in the future does not interfere with an otherwise normal run
    env.fprintCalls = 0
    groupsNow = {}
    ran = similarityLib.compute(items, groupsNow, { deadlineEpoch = os.time() + 3600, isCanceled = function() return false end })
    check(ran == true and env.fprintCalls == 1, 'similarity: a deadline that has not passed does not block a normal run')
  end

  env.fprintMode = 'passthrough'
end

-- ---------------------------------------------------------------------------
-- Similarity groups end to end (1.2.0): CreateGallery.lua -> lib/similarity.lua ->
-- lib/pipeline.lua -> the manifest. CreateGallery.lua loads its own copy of lib/similarity.lua
-- (every module here is a fresh dofile, not a singleton — see lib/*.lua's `local function load`),
-- so it cannot be handed the monkey-patched instance above: the fake helper is placed at the
-- real path instead (papat.lrplugin/bin/, which the repository otherwise never populates —
-- scripts/build-pkg.sh only ever builds one into a temp payload copy; .gitignore excludes it).
-- The fake helper resolves synchronously here (there is no real subprocess to wait for), so
-- this exercises the normal path, not the late-pass timing; lib/pipeline.lua's groupsNow
-- handling itself reuses the already-tested thumb late-pass code (same function, same tests).
-- ---------------------------------------------------------------------------
do
  local binDir = _PLUGIN.path .. '/bin'
  os.execute('mkdir -p "' .. binDir .. '" && touch "' .. binDir .. '/papat-fprint" && chmod +x "'
    .. binDir .. '/papat-fprint"')

  local function photoAt(path, wallTime)
    local p = newPhoto(path)
    p.raw.dateTimeISO8601 = wallTime
    return p
  end
  -- already in chronological order, so manifest order == selection order (no surprises)
  local photosList = {
    photoAt('/p/g1.NEF', '2026-10-01T09:00:00'),
    photoAt('/p/g2.NEF', '2026-10-01T09:00:05'),
    photoAt('/p/g3.NEF', '2026-10-01T09:20:00'),
    photoAt('/p/g4.NEF', '2026-10-01T09:20:05'),
  }
  activeCatalog = newCatalog(photosList)
  env.fprintMode = 'refine'
  env.fprintGroups = { 1, 1, 2, 2 }
  env.server = function(req)
    if req.method == 'POST' and req.url:find('/galleries$') then
      return 201, { ok = true, sid = 'SIDSIM', tenant_id = 'abc123', path = '/t/abc123/s/SIDSIM', expires_at = iso(7) }
    end
    if req.method == 'PUT' then return 200, { ok = true } end
    return 404, { ok = false, code = 'not_found', error = 'not found' }
  end
  run('CreateGallery.lua')

  -- each manifest PUT carries only the photos that became ready since the last one (the server
  -- merges by stem/source_id, lib/pipeline.lua's own top comment); so every request is folded
  -- together here, later ones winning, the same way the server's own merge behaves.
  local manifestCount, byStem = 0, {}
  for _, r in ipairs(env.requests) do
    if r.method == 'PUT' and r.url:find('manifest%.json$') then
      manifestCount = manifestCount + 1
      local body = json.decode(r.body)
      for _, p in ipairs(body.photos or {}) do byStem[p.stem] = p.group end
    end
  end
  check(manifestCount > 0, 'similarity e2e: a manifest was sent')
  check(byStem.g1 == 1 and byStem.g2 == 1 and byStem.g3 == 2 and byStem.g4 == 2,
    'similarity e2e: the helper\'s groups reach the manifest (' .. json.encode(byStem) .. ')')

  os.execute('rm -rf "' .. binDir .. '"')
end

-- ---------------------------------------------------------------------------
-- "送信の記録"（1.2.1・オプトイン）: lib/report.lua
-- ---------------------------------------------------------------------------
do
  local reportLib = dofile(_PLUGIN.path .. '/lib/report.lua')

  local function lastConfirm()
    for i = #env.dialogs, 1, -1 do
      if env.dialogs[i].kind == 'confirm' and env.dialogs[i].title == 'papat' then return env.dialogs[i] end
    end
  end

  -- first gallery after "updating to 1.2.1": asked once, exact wording, "送る" -> sent
  photos = manyPhotos(3)
  activeCatalog = newCatalog(photos)
  env.server = bigServer()
  env.prefs = { locationPromptShown = true, fastMode = true }
  env.passwords.recentGalleries = nil
  env.confirmAnswer = 'ok' -- "送る"
  run('CreateGallery.lua')
  local asked = lastConfirm()
  check(asked ~= nil and asked.info == reportLib.CONSENT_TEXT, 'report: asked once, with the exact consent text')
  check(env.prefs.reportAsked == true and env.prefs.reportConsent == true, 'report: consent recorded')
  check(#(serverState.reports or {}) == 1, 'report: one report sent (' .. #(serverState.reports or {}) .. ')')

  local rep = serverState.reports[1]
  check(rep.client and rep.client.name == 'papat-lrc' and rep.client.version == pluginVersion,
    'report: client name/version')
  check(rep.lightroom == '14.5.1', 'report: lightroom token from LrApplication.versionTable (' .. tostring(rep.lightroom) .. ')')
  check(rep.os == 'macOS-15.1', 'report: os token strips everything but digits/dots, never the raw string ('
    .. tostring(rep.os) .. ')')
  check(rep.arch == 'x64', 'report: arch token (' .. tostring(rep.arch) .. ')')
  check(type(rep.sid) == 'table' and #rep.sid == 1 and rep.sid[1] == 'SIDP', 'report: sid of the one gallery created')
  check(rep.split and rep.split.segments == 1, 'report: split.segments = 1 (no auto-split)')
  check(rep.counts and rep.counts.total == 3 and rep.counts.preview == 3 and rep.counts.export == 0,
    'report: counts (preview mode, nothing exported)')
  check(rep.similarity and rep.similarity.used == false, 'report: similarity not used (helper unavailable, selection too small)')
  check(type(rep.timings) == 'table' and type(rep.timings.wall) == 'number', 'report: timings.wall present')
  check(rep.errors == nil or #rep.errors == 0, 'report: no errors')
  do
    local encoded = json.encode(rep)
    check(not encoded:find('IMG_', 1, true) and not encoded:find('/p/', 1, true),
      'report: no filename/path leaks into the body')
  end

  -- a second gallery, same session: not asked again, but still sent (consent already given)
  env.dialogs = {}
  env.server = bigServer() -- fresh serverState.reports
  photos = manyPhotos(2)
  activeCatalog = newCatalog(photos)
  run('CreateGallery.lua')
  check(lastConfirm() == nil, 'report: not asked a second time')
  check(#(serverState.reports or {}) == 1, 'report: still sent once consent is already on file')

  -- a photographer who answers "送らない": asked once, never sent, never asked again
  env.prefs = { locationPromptShown = true, fastMode = true }
  env.server = bigServer()
  photos = manyPhotos(3)
  activeCatalog = newCatalog(photos)
  env.confirmAnswer = 'cancel' -- "送らない"
  run('CreateGallery.lua')
  env.confirmAnswer = nil
  check(lastConfirm() ~= nil, 'report: still asked once for a photographer who has not been asked yet')
  check(env.prefs.reportAsked == true and env.prefs.reportConsent == false, 'report: decline recorded')
  check(serverState.reports == nil or #serverState.reports == 0, 'report: nothing sent after declining (' .. #(serverState.reports or {}) .. ')')
  env.dialogs = {}
  photos = manyPhotos(2)
  activeCatalog = newCatalog(photos)
  run('CreateGallery.lua')
  check(lastConfirm() == nil, 'report: a photographer who declined is not asked again')
  check(serverState.reports == nil or #serverState.reports == 0, 'report: still nothing sent after declining')

  -- a failed send: the result still reaches the report (counted as an error, not a message)
  env.prefs = { locationPromptShown = true, fastMode = true, reportAsked = true, reportConsent = true }
  env.server = function(req)
    if req.method == 'POST' and req.url:find('/integration/report') then
      serverState = serverState or {}
      serverState.reports = serverState.reports or {}
      serverState.reports[#serverState.reports + 1] = json.decode(req.body)
      return 200, { ok = true }
    end
    if req.method == 'POST' and req.url:find('/galleries$') then
      return 201, { ok = true, sid = 'SIDERR', tenant_id = 'abc123', path = '/t/abc123/s/SIDERR', expires_at = iso(7) }
    end
    if req.method == 'PUT' and req.url:find('/files/photos/') then
      return 503, { ok = false, code = 'upstream_error', error = '一時的なエラー' }
    end
    return 200, { ok = true }
  end
  photos = manyPhotos(2)
  activeCatalog = newCatalog(photos)
  env.dialogs = {}
  run('CreateGallery.lua')
  local errRep = serverState.reports[#serverState.reports]
  check(errRep ~= nil and type(errRep.errors) == 'table' and #errRep.errors > 0, 'report: a failed send adds an error entry')
  if errRep and errRep.errors and errRep.errors[1] then
    check(errRep.errors[1].code ~= nil and errRep.errors[1].where ~= nil and errRep.errors[1].message == nil,
      'report: error entries are code/where/count only, never a message')
  end

  -- a 2-segment send (lib/sender.lua directly: the auto-split needs 889+ photos to trigger
  -- through the menu, too slow for a unit test) folds into exactly one combined report
  do
    local sender = dofile(_PLUGIN.path .. '/lib/sender.lua')
    env.prefs = { locationPromptShown = true, fastMode = true, reportAsked = true, reportConsent = true }
    env.server = bigServer()
    local segPhotos = manyPhotos(4)
    activeCatalog = newCatalog(segPhotos)
    local items = {}
    for i, p in ipairs(segPhotos) do
      items[i] = { photo = p, sourceId = 'src-' .. i, datetime = '', rating = 0 }
    end
    local status = sender.newStatus('x')
    sender.startMany({
      {
        apiKey = 'k', sid = 'SIDA', title = 'A（1/2）', items = { items[1], items[2] }, usedNames = {},
        status = status, total = 2, alreadyUploaded = 0, fast = true,
      },
      {
        apiKey = 'k', sid = 'SIDB', title = 'A（2/2）', items = { items[3], items[4] }, usedNames = {},
        status = status, total = 2, alreadyUploaded = 0, fast = true,
      },
    })
    drain()
    check(#(serverState.reports or {}) == 1, 'report: one combined report for a 2-segment send ('
      .. #(serverState.reports or {}) .. ')')
    local split2 = serverState.reports[1]
    if split2 then
      check(split2.split and split2.split.segments == 2, 'report: split.segments = 2')
      table.sort(split2.sid)
      check(split2.sid[1] == 'SIDA' and split2.sid[2] == 'SIDB', 'report: both sids present ('
        .. table.concat(split2.sid, ',') .. ')')
      check(split2.counts and split2.counts.total == 4, 'report: counts summed across both segments')
    end
  end

  -- a dangerous "os"/"arch" from the SDK never passes through raw
  env.osVersion = "Daisuke's MacBook Pro"
  env.arch = 'Daisukes-Mac'
  env.prefs = { locationPromptShown = true, fastMode = true, reportAsked = true, reportConsent = true }
  env.server = bigServer()
  photos = manyPhotos(2)
  activeCatalog = newCatalog(photos)
  run('CreateGallery.lua')
  env.osVersion, env.arch = nil, nil
  local safetyRep = serverState.reports and serverState.reports[1]
  check(safetyRep ~= nil, 'report: still sent even when the system strings look dangerous')
  if safetyRep then
    check(safetyRep.os == nil, 'report: a computer-name-shaped osVersion() yields no digits, so os is omitted, never passed through ('
      .. tostring(safetyRep.os) .. ')')
    check(safetyRep.arch == nil, 'report: an unrecognized architecture() string is omitted, never passed through ('
      .. tostring(safetyRep.arch) .. ')')
  end

  -- The question behind the telemetry: how often does waiting past a small, fast
  -- first callback turn up a bigger one? export_reasons carries it (the server allows any key,
  -- up to 16), and probe carries the first 3 {w,h,seconds,reason} samples.
  photos = manyPhotos(3)
  photos[1].thumbSmallThenBig = true -- small, then (after waiting) big: preview_small_then_big
  photos[2].thumbSmall = true -- small, stays small: preview_small_timeout
  -- photos[3]: default, big from the first callback: preview_first_big
  activeCatalog = newCatalog(photos)
  env.server = bigServer()
  env.prefs = { locationPromptShown = true, fastMode = true, reportAsked = true, reportConsent = true }
  env.passwords.recentGalleries = nil
  run('CreateGallery.lua')
  local waitRep = serverState.reports and serverState.reports[#serverState.reports]
  check(waitRep ~= nil, 'report: sent for the preview-wait scenario')
  if waitRep then
    local reasons = waitRep.export_reasons or {}
    check(reasons.preview_small_then_big == 1, 'report: small-then-big counted once ('
      .. tostring(reasons.preview_small_then_big) .. ')')
    check(reasons.preview_small_timeout == 1, 'report: small-timeout counted once ('
      .. tostring(reasons.preview_small_timeout) .. ')')
    check(reasons.preview_first_big == 1, 'report: first-big counted once ('
      .. tostring(reasons.preview_first_big) .. ')')
    check(reasons.small == 1, 'report: the existing export reason (why photo 2 was exported) is still there too')
    check(type(waitRep.probe) == 'table' and #waitRep.probe == 3, 'report: probe has the first three samples ('
      .. tostring(waitRep.probe and #waitRep.probe) .. ')')
    if waitRep.probe then
      check(waitRep.probe[1].w == 2056 and waitRep.probe[1].h == 1371 and waitRep.probe[1].reason == 'ok',
        'report: probe photo 1 (small-then-big, judged on the final size)')
      check(waitRep.probe[2].w == 1440 and waitRep.probe[2].h == 960 and waitRep.probe[2].reason == 'small',
        'report: probe photo 2 (stayed small, real size shown, not omitted)')
      check(waitRep.probe[3].w == 2056 and waitRep.probe[3].h == 1371 and waitRep.probe[3].reason == 'ok',
        'report: probe photo 3 (big from the start)')
      for i, p in ipairs(waitRep.probe) do
        check(type(p.seconds) == 'number' and p.seconds >= 0, 'report: probe ' .. i .. ' has a seconds value')
      end
    end
  end
end

print(string.format('%d smoke checks, %d failed', total, failed))
os.execute('rm -rf "' .. tmpRoot .. '"')
os.exit(failed == 0 and 0 or 1)
