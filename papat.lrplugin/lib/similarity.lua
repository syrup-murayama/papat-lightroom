--[[
  lib/similarity.lua — refine the time groups with Vision feature prints (macOS only)

  Refines the time groups (lib/grouping.lua) by splitting further wherever the picture changes
  sharply within one of them ("時刻で切って、似ているかで直す"). Computes its own small JPEG
  previews — never the ones being sent, so the main send is never touched or slowed by this —
  writes them to a temp folder together with the already-computed time groups, and hands both
  to the bundled helper (papat.lrplugin/bin/papat-fprint: Vision's
  VNGenerateImageFeaturePrintRequest, no networking; source: tools/papat-fprint/main.swift).
  Only the resulting group numbers ever leave this
  function; the feature prints themselves are never written anywhere but the helper's own
  memory, and the previews are deleted before this returns.

  M.compute(items, groupsNow) must run inside its own async task, started next to the upload
  (lib/sender.lua does this) so the two overlap: computing here never makes the send wait, and
  the send never waits for this beyond pipeline.lua's own small, bounded allowance
  (GROUPS_TAIL_LIMIT) for photos that were already uploaded by the time this finishes.

  On any problem — not macOS, the helper missing, too few usable previews, the helper failing
  or timing out, a malformed answer — this simply leaves `groupsNow` without new entries: the
  gallery falls back to the time groups it already has (the browser's own autoGroups). The
  send is never held up and nobody is ever told; one line goes to the log (lib/log.lua).

  CreateGallery.lua's auto-split (lib/split.lua) is the one caller that cannot overlap this with
  anything (it needs the groups before it can even show the settings dialog) and so awaits this
  directly, with a cancellable LrProgressScope. `opts.deadlineEpoch` / `opts.isCanceled` (both
  optional) bound that one wait: past the deadline, or once canceled, this gives up early and
  returns false the same way any other failure does — split.lua then falls back to time groups.
]]

local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

local function load(name) return dofile(_PLUGIN.path .. '/lib/' .. name .. '.lua') end
local ids = load('ids')
local json = load('json')
local grouping = load('grouping')
local preview = load('preview')
local log = load('log')

local M = {}

M.PREVIEW_EDGE = 1024       -- plenty for Vision; much smaller/faster than the JPEG that is sent
M.PREVIEW_TIMEOUT = 10       -- seconds, per photo
M.MIN_USABLE_FRACTION = 0.5  -- skip (no groups) if fewer previews than this could be made
M.MIN_ITEMS = 2              -- nothing to refine below this many photos

-- Not enforced: the Lightroom SDK has no documented way to cap how long LrTasks.execute may
-- run (unlike preview.jpeg's callback, which this plug-in can simply stop waiting on). If the
-- helper ever hung, this one background task would stay suspended; it yields to every other
-- task meanwhile (clipboard.lua's own comment notes the same of LrTasks.execute), so nothing
-- else is held up, and lib/pipeline.lua's own GROUPS_TAIL_LIMIT still bounds how long a send
-- waits for it. In practice the design doc's own trial measured ~8s for 296 photos.

function M.binaryPath()
  return LrPathUtils.child(LrPathUtils.child(_PLUGIN.path, 'bin'), 'papat-fprint')
end

--- Is the helper available at all on this platform? (a path check only; no process is run)
function M.available()
  if WIN_ENV then return false end
  return LrFileUtils.exists(M.binaryPath()) == 'file'
end

local function quote(path)
  return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

--- One small JPEG per item into `dir`, in the given order (the gallery's own order:
--- lib/pipeline.lua's M.order — items must already be sorted that way, see M.compute).
--- `stop()` is polled between photos (the auto-split's time budget / cancel button, see
--- M.compute); once it says so, the remaining photos are simply left without a preview
--- (counted as unusable below, same as a photo whose preview genuinely failed).
--- @return table paths  same length as items; '' where that photo's preview could not be made
local function renderPreviews(items, dir, stop)
  local paths = {}
  for i, item in ipairs(items) do
    paths[i] = ''
    if not (stop and stop()) then
      local bytes = preview.jpeg(item.photo, M.PREVIEW_EDGE, M.PREVIEW_TIMEOUT)
      if bytes then
        local path = LrPathUtils.child(dir, string.format('%06d.jpg', i))
        local fh = io.open(path, 'wb')
        if fh then
          fh:write(bytes)
          fh:close()
          paths[i] = path
        end
      end
    end
  end
  return paths
end

local function removeDir(dir)
  for path in LrFileUtils.recursiveFiles(dir) do
    if LrFileUtils.exists(path) == 'file' then LrFileUtils.delete(path) end
  end
  if LrFileUtils.exists(dir) and LrFileUtils.isEmptyDirectory(dir) then LrFileUtils.delete(dir) end
end

--- @param items table  array of { photo, sourceId, datetime }, already in the gallery's own
---   order (lib/pipeline.lua's M.order) — adjacency here must mean chronological adjacency, so
---   the caller sorts once and uses the same order for sending, this and (1.2.0's) the gallery
---   auto-split.
--- @param groupsNow table  filled in here (by sourceId); groupsNow._done = true when this
---   returns, whatever the outcome (lib/pipeline.lua waits on that flag, not on this call
---   returning, so it keeps working even if the caller never awaits this function itself).
--- @param opts table|nil
---   deadlineEpoch  os.time() value; past it, this gives up early (the same as any other
---                  failure) instead of starting the helper (or finishing rendering previews)
---   isCanceled()   polled the same way; CreateGallery.lua's auto-split ties this to its
---                  LrProgressScope's own cancel button
--- @return boolean refined  true only when the helper actually produced usable group numbers
function M.compute(items, groupsNow, opts)
  opts = opts or {}
  local function timeUp()
    return (opts.deadlineEpoch and os.time() >= opts.deadlineEpoch) or (opts.isCanceled and opts.isCanceled())
  end

  local function finish(refined)
    groupsNow._done = true
    return refined == true
  end

  if not M.available() then
    log.info('similarity: no helper binary on this platform; the gallery will use time groups only')
    return finish(false)
  end
  if #items < M.MIN_ITEMS then return finish(false) end
  if timeUp() then
    log.info('similarity: already past the deadline / canceled before starting; skipping')
    return finish(false)
  end

  local dir = LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), 'papat-similarity-' .. ids.uuid())
  LrFileUtils.createAllDirectories(dir)

  local ok, refined = LrTasks.pcall(function()
    local datetimes = {}
    for i, item in ipairs(items) do datetimes[i] = item.datetime or '' end
    local timeGroups = grouping.autoGroups(datetimes).groups

    local t0 = os.time()
    local photos = renderPreviews(items, dir, timeUp)
    -- A photo with no preview gets no feature print either, but keeps its time-based group
    -- number (not forced to 0): the helper only excludes it from the window average (no
    -- vector), it still comes out of the helper with a real group. Zeroing it here would make
    -- this one photo's `group: 0` discard the similarity result for every other photo too,
    -- wherever the gallery requires every photo in a session to carry a group of 1 or more.
    local usable = 0
    for i = 1, #items do
      if photos[i] ~= '' then usable = usable + 1 end
    end
    if timeUp() then
      log.info('similarity: past the deadline / canceled after rendering previews; skipping the helper')
      return false
    end
    if usable < math.max(M.MIN_ITEMS, math.ceil(#items * M.MIN_USABLE_FRACTION)) then
      log.info('similarity: only %d/%d previews usable; skipping', usable, #items)
      return false
    end

    local inPath = LrPathUtils.child(dir, 'in.json')
    local outPath = LrPathUtils.child(dir, 'out.json')
    local inFh = io.open(inPath, 'wb')
    if not inFh then return false end
    inFh:write(json.encode({ photos = photos, timeGroups = timeGroups }))
    inFh:close()

    local cmd = string.format('%s %s %s', quote(M.binaryPath()), quote(inPath), quote(outPath))
    local rc = LrTasks.execute(cmd)
    log.info('similarity: helper rc=%s %ds for %d photos (%d previews usable)',
      tostring(rc), os.time() - t0, #items, usable)
    if rc ~= 0 then return false end

    local outFh = io.open(outPath, 'rb')
    if not outFh then return false end
    local raw = outFh:read('*a')
    outFh:close()
    local okDecode, data = pcall(json.decode, raw)
    if not okDecode or type(data) ~= 'table' or type(data.groups) ~= 'table' or #data.groups ~= #items then
      log.warn('similarity: the helper\'s answer could not be read')
      return false
    end

    local any = false
    for i, item in ipairs(items) do
      local g = math.floor(tonumber(data.groups[i]) or 0)
      if g > 0 then
        groupsNow[item.sourceId] = g
        any = true
      end
    end
    return any
  end)

  removeDir(dir)
  if not ok then log.warn('similarity: failed (%s)', tostring(refined)) end
  return finish(ok and refined)
end

return M
