--[[
  lib/pipeline.lua — render and upload the photos of one gallery, in the background

      producer (1 task)         workers (N tasks)             manifest
      render / preview  ──▶  queue  ──▶  PUT photo  ──▶  dirty list ──▶ PUT manifest.json
                                                        (every few photos / seconds)

  * Rendering and uploading overlap: a JPEG is uploaded as soon as it exists.
  * N uploads run at once (cooperative tasks; LrHttp yields while it waits).
  * The manifest is sent in small batches (the server merges by source_id / stem), so the
    client's gallery fills up while the photographer keeps working. The last one carries
    complete = true.
  * Cancel / failure leaves the not-yet-sent photos in the job record (lib/jobs.lua)
    so they can be sent later.

  Everything here yields: run it inside an async task and never inside pcall.
]]

local LrDate = import 'LrDate'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

local function load(name) return dofile(_PLUGIN.path .. '/lib/' .. name .. '.lua') end
local text = load('text')
local api = load('api')
local export = load('export')
local preview = load('preview')
local jpeg = load('jpeg')
local thumbLib = load('thumb')
local icc = load('icc')
local rights = load('rights')
local catalogLib = load('catalog')
local jobs = load('jobs')
local log = load('log')

local M = {}

M.DEFAULT_CONCURRENCY = 3

local FIRST_BATCH = 3      -- first manifest after 3 photos: the client sees something early
local BATCH = 10           -- then every 10 photos …
local MAX_AGE = 10         -- … or every 10 seconds
local POLL = 0.1
local MAX_PREVIEW_EDGE = 2560 -- a bigger preview is not sent; the photo is exported instead
local MIN_PREVIEW_EDGE = 1900 -- a smaller one is not sent either (the page promises ~2048 px)
local PROBE_COUNT = 3         -- photos tried before deciding whether previews are usable at all
local PROBE_SLOW = 0.8        -- seconds per probe: slower means previews are rendered on demand,
                              -- which is about as slow as exporting (observed: 0.25-0.32 s vs 1.29 s)
local PREVIEW_TIMEOUT = 10    -- seconds to wait for one preview
local PREVIEW_GIVE_UP = 3     -- this many failures in a row: export the rest
local TROUBLE_LOWER = 2       -- this many troubled uploads in a row: one upload at a time
local CLEAN_RECOVER = 5       -- this many clean uploads in a row: back to the full parallelism
local BUSY_STOP = 6           -- this many photos failed in a row (after retries): pause the send
local MAX_QUEUE = 12       -- rendered but not yet sent: bounds memory / temp space
-- The server allows 300 PUTs a minute per account (photos and manifests count). Requests are
-- started at most this often (about 270 a minute). The small versions are not counted by the
-- server any more: they follow their photo at once. A server that still counts them (an older
-- deployment) answers 429; from the first 429 on, the small versions keep the same interval.
local PACE = 0.22
local THUMB_GIVE_UP = 3       -- this many small versions in a row refused / failed: stop making them
local THUMB_BATCH = 20        -- files per sips call (about 20 ms a file in a batch, 75 ms one by one)
local THUMB_BATCH_MIN = 10    -- wait for this many (or for THUMB_BATCH_WAIT seconds) before a sips call
local THUMB_BATCH_WAIT = 1.5
local THUMB_QUEUE_MAX = 60    -- photos waiting for sips: more than this and the photo workers wait
local THUMB_PUTTERS = 2       -- small versions are sent by their own tasks, not by the photo workers
local THUMB_TAIL_LIMIT = 120  -- seconds the end of a send waits for the small versions
local GROUPS_TAIL_LIMIT = 30  -- seconds the end of a send waits for the similarity groups
                               -- (in practice they are ready long before this: a 300-photo send
                               -- spends minutes uploading, the helper binary a few seconds)

-- Failures that make sending the remaining photos pointless.
local FATAL_CODES = {
  gallery_limit_reached = true, gallery_closed = true, gallery_not_found = true,
  card_required = true, payment_required = true, monthly_limit = true, tenant_suspended = true,
  paid_country_blocked = true, billing_country_required = true, invite_only = true,
  gallery_forbidden = true, active_gallery_limit = true, invalid_api_key = true,
  unauthorized = true,
}

-- Only answers that retrying cannot change stop the whole send (api.lua has already waited out
-- transient failures and re-asked a 413 limit once). A single photo that failed stays a
-- single failed photo: HTTP 500 / 502 / 503 / 504 / 429 and connection errors never come here.
function M.isFatal(res)
  if res.network then return false end
  if FATAL_CODES[res.code or ''] then return true end
  local s = res.status
  return s == 401 or s == 402 or s == 403 or s == 404 or s == 410
end

local function now()
  return LrDate.currentTime()
end

local function readBytes(path)
  local fh = io.open(path, 'rb')
  if not fh then return nil end
  local data = fh:read('*a')
  fh:close()
  return data
end

local function uuidOf(photo)
  local uuid = photo:getRawMetadata('uuid')
  if type(uuid) == 'string' and uuid ~= '' then return uuid end
  return nil
end

--- Identity used to pair a rendition with the photo it came from. The uuid when
--- Lightroom gives one, else path + virtual copy name.
local function keyOf(photo)
  local uuid = uuidOf(photo)
  if uuid then return 'u:' .. uuid end
  return 'p:' .. tostring(photo:getRawMetadata('path') or '') .. '|' .. tostring(photo:getRawMetadata('copyName') or '')
end

local iccSegment

--- Put back what the photographer wants to say (copyright, creator, contact: item.meta, built by
--- lib/rights.lua) and the sRGB profile when the file has none. Called on a sanitized JPEG.
--- A failure here never loses the photo: it goes out with whatever could be added.
local function addBack(clean, report, srcItem)
  local meta = srcItem.meta or ''
  local extra = meta
  if not report.icc then
    iccSegment = iccSegment or jpeg.iccSegment(icc.srgb()) or ''
    extra = extra .. iccSegment
  end
  if extra == '' then return clean, report end

  local out = jpeg.withSegments(clean, extra)
  if not out and meta ~= '' then
    log.warn('could not add the copyright / contact segments; sending without them')
    out = jpeg.withSegments(clean, report.icc and '' or iccSegment)
    meta = ''
  end
  if out then
    clean = out
    report.tagged = not report.icc
    report.icc = true
    report.meta = meta ~= ''
  end
  return clean, report
end

--- The gallery's own order: capture time, then file name, then the selection order
--- (text.photoOrderLess) — sets .order / .datetime / .sortName on each item (in place) and
--- returns a new array sorted by them. M.run calls this itself; lib/similarity.lua and the
--- auto-split in CreateGallery.lua call it first, so all three agree on the same order without
--- repeating the rule. Pure bookkeeping (no yielding), but still only meant for an async task
--- (same as everything else here, for consistency).
function M.order(items)
  local ordered = {}
  for i, item in ipairs(items) do
    item.order = i
    item.datetime = item.datetime or ''
    item.sortName = text.nameKey(LrPathUtils.leafName(tostring(item.photo:getRawMetadata('path') or '')))
    ordered[i] = item
  end
  table.sort(ordered, text.photoOrderLess)
  return ordered
end

--- @param o table
---   apiKey, sid, title, keyColor ('' = none), catalog
---   items        array of { photo, sourceId }
---   usedNames    array of file names already on the server (resume)
---   concurrency  upload tasks (default 3)
---   fast         take the JPEG from the preview (falls back to export per photo)
---   isCanceled() -> boolean
---   onStatus(s)  s = { rendered, uploaded, total, failed, phase }
---   askRetry(count, example) -> boolean      (optional)
---   groupsNow    table|nil  [sourceId] = similarity group (1-based), filled in by the caller's
---                own background task (lib/similarity.lua) as it goes, while this is sending.
---                A photo not yet uploaded when its group becomes known just picks it up here
---                (uploadItem reads this table fresh each time); photos already sent are patched
---                by one extra manifest pass near the end (bounded wait: GROUPS_TAIL_LIMIT) —
---                the same approach as the thumb late pass below, and for the same reason (the
---                photos' own manifest entries must never be rebuilt from outside this file).
---                `groupsNow._done` true marks it finished (whether or not it found anything).
--- @return table result
---   { uploaded, usedNames, failedUpload, failedRender, canceled, fatal, manifestError,
---     timings = { total, render, upload, renderPerPhoto, uploadPerPhoto, concurrency, fast } }
function M.run(o)
  local concurrency = math.max(1, math.min(o.concurrency or M.DEFAULT_CONCURRENCY, 4))

  -- The order of the gallery is decided here, once (M.order; see its own comment). Rendering
  -- and uploading follow it, and manifests are published as a prefix of it, so the order never
  -- depends on which upload finishes first.
  local ordered = M.order(o.items)
  for rank, item in ipairs(ordered) do item.rank = rank end
  o.items = ordered
  local total = #o.items

  local st = {
    queue = {}, head = 1,
    producerDone = false,
    rendered = 0, uploaded = 0,
    failedRender = {}, failedUpload = {},
    ready = {}, skipped = {}, late = {}, nextIndex = 1, flushes = 0, lastFlush = now(), flushing = false,
    canceled = false, fatal = nil, manifestError = nil,
    uploadSeconds = 0, uploadCalls = 0, renderSeconds = 0,
    t0 = now(),
    previewOk = 0, previewFallback = 0, previewTagged = 0, metaAdded = 0, reasons = {}, fastDisabled = false,
    allowed = concurrency, trouble = 0, clean = 0, failStreak = 0, lowered = 0,
    retries = 0, busyStop = false, failedStatus = {},
    longMin = nil, longMax = nil, sentBytes = 0, sentCount = 0,
    removed = {}, strippedBytes = 0,
    thumbs = o.thumbs ~= false, thumbSent = 0, thumbFailed = 0, thumbSkipped = 0, thumbBytes = 0,
    thumbStreak = 0, thumbWhy = {}, nextSlot = 0, thumbPaced = false,
    -- small versions: their size and where the time goes
    thumbLongMin = nil, thumbLongMax = nil,
    thumbQ = {}, thumbPutQ = {}, thumbsClosed = false, thumbMakerDone = false, thumbRunning = 0,
    sipsSeconds = 0, sipsCalls = 0, sipsFiles = 0, thumbPutSeconds = 0, thumbPutCalls = 0,
    sentEntries = {}, thumbPublished = {}, passSeconds = 0, passEntries = 0,
  }
  local used = {}
  for _, name in ipairs(o.usedNames or {}) do used[name:lower()] = true end
  -- names that are in a published manifest; only these are remembered for a later resume.
  -- (A name merely planned or uploaded but not published belongs to a photo that is still
  -- pending: on resume it gets the same name again and simply replaces the file.)
  local usedList = {}
  for _, name in ipairs(o.usedNames or {}) do usedList[#usedList + 1] = name end

  local byKey = {}
  for _, item in ipairs(o.items) do byKey[keyOf(item.photo)] = item end

  local checkCanceled  -- defined below

  local function status(phase)
    if o.onStatus then
      o.onStatus({
        phase = phase,
        rendered = st.rendered, uploaded = st.uploaded, total = total,
        failed = #st.failedUpload + #st.failedRender,
      })
    end
  end

  local function stopped()
    return st.canceled or st.fatal ~= nil or st.busyStop
  end

  --- Wait for the next free slot before a request (see PACE).
  local function pace()
    local t = now()
    local slot = math.max(st.nextSlot, t)
    st.nextSlot = slot + PACE
    if slot > t then LrTasks.sleep(slot - t) end
  end

  function checkCanceled()
    if not st.canceled and o.isCanceled and o.isCanceled() then st.canceled = true end
    return stopped()
  end

  local function uniqueName(leaf)
    local base, ext = leaf:match('^(.*)(%.[^.]*)$')
    if not base then base, ext = leaf, '' end
    local name, n = leaf, 1
    while used[name:lower()] do
      n = n + 1
      name = base .. '-' .. n .. ext
    end
    used[name:lower()] = true
    return name
  end

  local function noteImage(report, bytes)
    if report.meta then st.metaAdded = st.metaAdded + 1 end
    local long = math.max(report.width or 0, report.height or 0)
    if long > 0 then
      st.longMin = st.longMin and math.min(st.longMin, long) or long
      st.longMax = st.longMax and math.max(st.longMax, long) or long
    end
    st.sentBytes = st.sentBytes + bytes
    st.sentCount = st.sentCount + 1
    st.strippedBytes = st.strippedBytes + math.max(report.before - report.after, 0)
    for label, n in pairs(report.removed) do st.removed[label] = (st.removed[label] or 0) + n end
  end

  local function noteThumbSize(report)
    local long = math.max(report.width or 0, report.height or 0)
    if long > 0 then
      st.thumbLongMin = st.thumbLongMin and math.min(st.thumbLongMin, long) or long
      st.thumbLongMax = st.thumbLongMax and math.max(st.thumbLongMax, long) or long
    end
  end

  local function push(item)
    -- back-pressure: do not run far ahead of the uploads
    while (#st.queue - st.head + 1) >= MAX_QUEUE and not checkCanceled() do
      LrTasks.sleep(POLL)
    end
    st.queue[#st.queue + 1] = item
    st.rendered = st.rendered + 1
    status('render')
  end

  -- -------------------------------------------------------------------------
  -- Manifest
  -- -------------------------------------------------------------------------

  --- opts.omitKeyColor: the server then uses the gallery's current color (what the photographer
  --- may have changed in the browser while the photos were being sent) instead of the one this
  --- send started with. Used by the late pass that only adds the small versions.
  local function manifestBody(photos, complete, opts)
    local m = {
      version = 1,
      title = o.title,
      theme = 'default',
      count = #photos,
      photos = photos,
      credit = '',
      groupThreshold = 3,
      complete = complete,
    }
    if o.keyColor and o.keyColor ~= '' and not (opts and opts.omitKeyColor) then m.key_color = o.keyColor end
    return m
  end

  local function persistJob()
    local pending = {}
    for _, item in ipairs(o.items) do
      if not item.done then
        pending[#pending + 1] = { uuid = uuidOf(item.photo), sourceId = item.sourceId }
      end
    end
    if #pending == 0 then
      jobs.removeJob(o.sid)
    else
      jobs.saveJob(o.sid, { pending = pending, used = usedList, rights = o.rightsMode })
    end
  end

  --- Send the photos that are next in the gallery order. A photo is only published when every
  --- photo before it has been uploaded (or has permanently failed), so partial and final
  --- manifests list photos in the same order. force = also when few/recent; complete = last one.
  local function flush(force, complete)
    if st.flushing then return true end

    local batch, nextIndex = {}, st.nextIndex
    if complete then
      -- end of the send: everything that is ready, in order; unsent photos leave gaps
      for k = st.nextIndex, total do
        if st.ready[k] then batch[#batch + 1] = st.ready[k] end
      end
      nextIndex = total + 1
    else
      while true do
        local d = st.ready[nextIndex]
        if d then
          batch[#batch + 1] = d
          nextIndex = nextIndex + 1
        elseif st.skipped[nextIndex] then
          nextIndex = nextIndex + 1
        else
          break
        end
      end
    end
    -- photos that succeeded only after their turn had passed (a retry round) go last
    for _, d in ipairs(st.late) do batch[#batch + 1] = d end

    local n = #batch
    if n == 0 and not complete then return true end
    local need = (st.flushes == 0) and FIRST_BATCH or BATCH
    if not force and n < need and (now() - st.lastFlush) < MAX_AGE then return true end

    st.flushing = true
    pace()
    local entries = {}
    -- which of these already carry their small version in what is being sent: noted now, before
    -- the request (it waits; a small version that arrives meanwhile is not in this body)
    local carried = {}
    for _, d in ipairs(batch) do
      entries[#entries + 1] = d.entry
      carried[d.entry] = (d.entry.thumb ~= nil)
    end
    local res = api.putManifest(o.apiKey, o.sid, manifestBody(entries, complete == true))
    st.flushing = false

    if not res.ok then
      st.manifestError = res
      if M.isFatal(res) then st.fatal = res end
      return false -- nothing was consumed: the same photos go out next time
    end

    -- consumed
    for _, d in ipairs(batch) do
      if not d.late then st.ready[d.index] = nil end
    end
    st.late = {}
    st.nextIndex = nextIndex
    st.manifestError = nil
    st.flushes = st.flushes + 1
    st.lastFlush = now()

    local records = {}
    for _, d in ipairs(batch) do
      st.thumbPublished[d.entry] = carried[d.entry] -- (kept outside the entry: it is sent as it is)
      d.item.src.done = true
      usedList[#usedList + 1] = d.filename
      records[#records + 1] = {
        photo = d.item.photo, sourceId = d.item.sourceId, sid = o.sid, filename = d.filename,
      }
    end
    if #records > 0 and o.catalog then
      local recorded = catalogLib.recordUploads(o.catalog, records)
      if recorded ~= 'executed' then log.warn('recordUploads status=%s', tostring(recorded)) end
    end
    persistJob()
    return true
  end

  -- -------------------------------------------------------------------------
  -- Producer: render (or take the preview) and queue the JPEGs
  -- -------------------------------------------------------------------------

  local function produce()
    local dir = export.newTempDir()
    st.dir = dir
    st.files = {}
    local tStart = now()

    local function onRendered(photo, path)
      local item = byKey[keyOf(photo)]
      if not item then return end
      st.files[#st.files + 1] = path
      push({
        src = item, photo = item.photo, sourceId = item.sourceId, path = path,
        filename = uniqueName(LrPathUtils.leafName(path)),
      })
    end
    local function onFailed(photo, message)
      st.failedRender[#st.failedRender + 1] = { photo = photo, message = message }
      status('render')
    end

    local toExport = {}
    if o.fast then
      -- What makes a preview usable (reason keys are used in the log and the result):
      --   invalid   not a readable JPEG
      --   embedded  still carries Exif / XMP / IPTC: the camera's embedded JPEG, not a preview
      --             rendered by Lightroom (rendered previews carry none) — it would not show the edit
      --   large     longer than MAX_PREVIEW_EDGE
      --   small     shorter than MIN_PREVIEW_EDGE
      local function judge(bytes, item)
        local clean, report = jpeg.sanitize(bytes)
        if not clean then return nil, nil, 'invalid' end
        local r = report.removed
        if r.exif or r.xmp or r.iptc or r['app1-other'] then return nil, nil, 'embedded' end
        local long = math.max(report.width, report.height)
        if long > MAX_PREVIEW_EDGE then return nil, nil, 'large' end

        -- A small picture (or a tight crop) is legitimately smaller than 2048 px; an export would
        -- not enlarge it either (LR_size_doNotEnlarge). Only a preview that is smaller than
        -- what the export would deliver counts as "small".
        local minimum = MIN_PREVIEW_EDGE
        local okSize, w, h = LrTasks.pcall(function()
          return item.photo:getRawMetadata('croppedWidth'), item.photo:getRawMetadata('croppedHeight')
        end)
        if okSize and tonumber(w) and tonumber(h) and math.max(w, h) > 0 then
          minimum = math.min(MIN_PREVIEW_EDGE, math.floor(math.max(w, h) * 0.95))
        end
        if long < minimum then return nil, nil, 'small' end

        -- sRGB profile (a normal export has one) and the copyright / creator / contact segments
        clean, report = addBack(clean, report, item)
        return clean, report
      end

      local function fetch(item)
        local bytes, why = preview.jpeg(item.photo, 2048, PREVIEW_TIMEOUT)
        if not bytes then return nil, nil, (why == 'timeout') and 'timeout' or 'none' end
        return judge(bytes, item)
      end

      local function count(reason)
        st.reasons[reason] = (st.reasons[reason] or 0) + 1
      end

      -- 1. Probe a few photos (first / middle / last) and decide for the whole run: a catalog
      --    whose previews are missing or are camera JPEGs is exported from the start instead
      --    of getting slower half-way through.
      local probe = {}
      local n = #o.items
      local picks = {}
      for _, i in ipairs({ 1, math.ceil(n / 2), n }) do
        if i >= 1 and i <= n and not picks[i] and #probe < PROBE_COUNT then
          picks[i] = true
          probe[#probe + 1] = i
        end
      end
      local cache, probeOk, probeSeconds = {}, 0, 0
      for _, i in ipairs(probe) do
        if checkCanceled() then break end
        local t0 = now()
        local clean, report, reason = fetch(o.items[i])
        local took = now() - t0
        probeSeconds = probeSeconds + took
        cache[i] = { clean = clean, report = report, reason = reason }
        if clean then probeOk = probeOk + 1 else count(reason) end
        log.info('probe photo %d: %s %.2fs %s', i,
          report and string.format('%dx%d', report.width, report.height) or '-', took, tostring(reason or 'ok'))
      end
      local usable = #probe == 0 or (probeOk * 2 > #probe)
      local avg = #probe > 0 and (probeSeconds / #probe) or 0
      if usable and avg >= PROBE_SLOW then
        -- previews have to be rendered first (standard preview size below ~2048, or none built):
        -- no faster than exporting, and it fills the preview cache
        usable = false
        count('slow')
        log.info('speed-first: previews are rendered on demand here (%.2fs per photo): exporting everything', avg)
      end
      if not usable then
        st.fastDisabled = true
        log.info('speed-first: previews not usable here (%d of %d probes ok, %.2fs per probe): exporting everything',
          probeOk, #probe, avg)
      end

      -- 2. Per photo: use the preview when it is good, export when it is not.
      local failuresInRow = 0
      for i, item in ipairs(o.items) do
        if checkCanceled() then break end
        local clean, report, reason
        if usable then
          local c = cache[i]
          if c then
            clean, report, reason = c.clean, c.report, c.reason
          elseif failuresInRow < PREVIEW_GIVE_UP then
            clean, report, reason = fetch(item)
            if not clean then count(reason) end
          else
            reason = 'gave-up'
          end
          if clean then failuresInRow = 0 else failuresInRow = failuresInRow + 1 end
        end

        if clean then
          st.previewOk = st.previewOk + 1
          if report.tagged then st.previewTagged = st.previewTagged + 1 end
          local leaf = LrPathUtils.leafName(item.photo:getRawMetadata('path') or 'photo')
          noteImage(report, #clean)
          push({
            src = item, photo = item.photo, sourceId = item.sourceId, bytes = clean, sanitized = true,
            filename = uniqueName(text.stemOf(leaf) .. '.jpg'),
          })
        else
          st.previewFallback = st.previewFallback + 1
          if reason then log.info('exporting instead of the preview: %s', tostring(reason)) end
          toExport[#toExport + 1] = item.photo
        end
      end
    else
      for _, item in ipairs(o.items) do toExport[#toExport + 1] = item.photo end
    end

    if #toExport > 0 and not checkCanceled() then
      local canceled = export.renderStream(toExport, dir, onRendered, onFailed, function()
        return checkCanceled()
      end)
      if canceled then st.canceled = true end
    end

    st.renderSeconds = now() - tStart
    st.producerDone = true
    status('render')
  end

  -- -------------------------------------------------------------------------
  -- Workers: PUT photos
  -- -------------------------------------------------------------------------

  -- -------------------------------------------------------------------------
  -- Small versions: a side channel, never on the photos' way
  --   The JPEG that was sent (preview or export, cleaned) is shrunk by macOS sips in batches by
  --   a separate task and PUT by their own tasks, after their photo; the manifest names them
  --   (`thumb`) in a later pass, once they have arrived. A failure here never touches a photo.
  --   (Lightroom's small previews are NOT used: after an edit they can stay old while the big
  --   preview is already new - seen on a real machine, 2026-10-15.)
  -- -------------------------------------------------------------------------

  local function thumbFail(why)
    st.thumbFailed = st.thumbFailed + 1
    st.thumbWhy[why] = (st.thumbWhy[why] or 0) + 1
    st.thumbStreak = st.thumbStreak + 1
    if st.thumbStreak >= THUMB_GIVE_UP and st.thumbs then
      st.thumbs = false
      log.warn('small versions: %d failures in a row (%s); not making any more in this send',
        st.thumbStreak, tostring(why))
    end
  end

  --- What happens to a photo's small version once the photo is on the server.
  local function handOffThumb(item, bytes, entry)
    if not st.thumbs or stopped() then return end
    local info = jpeg.parse(bytes)
    if not info then return end
    local long = thumbLib.targetLong(info.width, info.height)
    if not long then
      st.thumbSkipped = st.thumbSkipped + 1 -- already small: the big one is the small one
      return
    end
    -- bounded, so it can never run away
    while #st.thumbQ >= THUMB_QUEUE_MAX and st.thumbs and not stopped() do LrTasks.sleep(POLL) end
    if not st.thumbs then return end
    st.thumbQ[#st.thumbQ + 1] = { item = item, bytes = bytes, long = long, entry = entry, queuedAt = now() }
  end

  --- The next batch for sips: up to THUMB_BATCH photos that need the same long edge; waits for
  --- THUMB_BATCH_MIN of them (or THUMB_BATCH_WAIT seconds, or the end of the send).
  local function takeBatch()
    local n = #st.thumbQ
    if n == 0 then return nil end
    if n < THUMB_BATCH_MIN and (now() - st.thumbQ[1].queuedAt) < THUMB_BATCH_WAIT and not st.thumbsClosed then
      return nil
    end
    local long = st.thumbQ[1].long
    local batch, rest = {}, {}
    for _, entry in ipairs(st.thumbQ) do
      if entry.long == long and #batch < THUMB_BATCH then batch[#batch + 1] = entry else rest[#rest + 1] = entry end
    end
    st.thumbQ = rest
    return batch
  end

  local function makeBatch(batch)
    local jobs = {}
    for _, b in ipairs(batch) do jobs[#jobs + 1] = { tag = tostring(b.item.src.rank), bytes = b.bytes } end
    local results, info = thumbLib.shrinkMany(jobs, st.dir, batch[1].long, now)
    st.sipsSeconds = st.sipsSeconds + info.seconds
    st.sipsCalls = st.sipsCalls + 1
    st.sipsFiles = st.sipsFiles + #batch
    for _, b in ipairs(batch) do
      local small = results[tostring(b.item.src.rank)]
      b.bytes = nil
      if not small then
        thumbFail(info.why or 'sips')
      else
        local clean, report = jpeg.sanitize(small)
        if not clean then
          thumbFail('unreadable')
        elseif math.max(report.width, report.height) > thumbLib.MAX_LONG_EDGE then
          thumbFail('long-edge')
        else
          clean, report = addBack(clean, report, b.item.src) -- copyright / contact + sRGB, as on the big one
          if #clean > thumbLib.MAX_BYTES then
            thumbFail('too-large')
          else
            noteThumbSize(report)
            st.thumbPutQ[#st.thumbPutQ + 1] = { filename = b.item.filename, bytes = clean, entry = b.entry }
          end
        end
      end
    end
  end

  local function thumbMaker()
    while true do
      local batch = takeBatch()
      if batch then
        if st.thumbs and not stopped() then makeBatch(batch) end
      elseif st.thumbsClosed and #st.thumbQ == 0 then
        break
      else
        LrTasks.sleep(POLL)
      end
    end
    st.thumbMakerDone = true
    st.thumbRunning = st.thumbRunning - 1
  end

  local function thumbPutter()
    while true do
      local job = table.remove(st.thumbPutQ, 1)
      if job then
        if st.thumbs and not stopped() then
          -- not counted by the server; paced only once the server has shown that it counts them
          if st.thumbPaced then pace() end
          local t = now()
          local res = api.putThumb(o.apiKey, o.sid, job.filename, job.bytes)
          st.thumbPutSeconds = st.thumbPutSeconds + (now() - t)
          st.thumbPutCalls = st.thumbPutCalls + 1
          if res.rateLimited and not st.thumbPaced then
            st.thumbPaced = true
            log.info('small versions: 429 seen; they keep the %.2fs interval from now on', PACE)
          end
          if res.ok then
            st.thumbStreak = 0
            st.thumbSent = st.thumbSent + 1
            st.thumbBytes = st.thumbBytes + #job.bytes
            job.entry.thumb = 'thumbs/' .. text.urlEncodeSegment(job.filename)
          else
            log.warn('small version refused: %s HTTP %s code=%s', job.filename, tostring(res.status), tostring(res.code))
            thumbFail(res.network and 'network' or ('http-' .. tostring(res.status)))
          end
        end
      elseif st.thumbsClosed and st.thumbMakerDone then
        break
      else
        LrTasks.sleep(POLL)
      end
    end
    st.thumbRunning = st.thumbRunning - 1
  end

  local function uploadItem(item)
    local bytes = item.bytes or readBytes(item.path)
    if not bytes then
      item.message = '書き出したファイルを読み込めませんでした。'
      st.failedUpload[#st.failedUpload + 1] = item
      return
    end

    if not item.sanitized then
      local clean, report, err = jpeg.sanitize(bytes)
      if not clean then
        -- never send a file whose metadata could not be removed
        log.warn('metadata could not be removed (%s): %s', tostring(err), item.filename)
        st.failedRender[#st.failedRender + 1] = {
          photo = item.photo,
          message = 'メタデータを取り除けなかったため、この写真は送信しませんでした（' .. tostring(err) .. '）。',
        }
        item.src.done = false
        st.skipped[item.src.rank] = true
        status('upload')
        flush(false, false)
        return
      end
      clean, report = addBack(clean, report, item.src)
      noteImage(report, #clean)
      bytes = clean
      item.sanitized = true
    end

    pace()
    local t = now()
    local res = api.putPhoto(o.apiKey, o.sid, item.filename, bytes)
    st.uploadSeconds = st.uploadSeconds + (now() - t)
    st.uploadCalls = st.uploadCalls + 1
    local tries = res.tries or 1
    st.retries = st.retries + math.max(tries - 1, 0)

    -- parallelism follows how the server is doing
    local function trouble()
      st.clean = 0
      st.trouble = st.trouble + 1
      if st.trouble >= TROUBLE_LOWER and st.allowed > 1 then
        st.allowed = 1
        st.lowered = st.lowered + 1
        log.info('parallel uploads lowered to 1 (troubled uploads in a row: %d)', st.trouble)
      end
    end
    local function calm()
      st.trouble = 0
      st.clean = st.clean + 1
      if st.clean >= CLEAN_RECOVER and st.allowed < concurrency then
        st.allowed = concurrency
        log.info('parallel uploads back to %d', concurrency)
      end
    end

    if res.ok then
      st.uploaded = st.uploaded + 1
      st.failStreak = 0
      if tries > 1 then trouble() else calm() end
      local d = {
        item = item,
        filename = item.filename,
        index = item.src.rank,
        entry = {
          source_id = item.sourceId,
          stem = LrPathUtils.removeExtension(item.filename),
          filename = item.filename,
          url = 'photos/' .. text.urlEncodeSegment(item.filename),
          rating = math.max(0, math.min(5, math.floor(tonumber(item.src.rating) or 0))),
          label = '',
          keywords = {},
          datetime = item.src.datetime or '',
          camera = '',
          group = (o.groupsNow and o.groupsNow[item.sourceId]) or 0,
        },
      }
      st.sentEntries[#st.sentEntries + 1] = d.entry
      handOffThumb(item, bytes, d.entry)
      if d.index < st.nextIndex then
        d.late = true
        st.late[#st.late + 1] = d
      else
        st.ready[d.index] = d
      end
      if item.path and LrFileUtils.exists(item.path) then LrFileUtils.delete(item.path) end
      item.bytes = nil
      status('upload')
      flush(false, false)
    else
      item.message = res.message
      item.status = res.network and 'network' or res.status
      item.code = res.code
      local key = tostring(item.status) .. (res.code and (':' .. res.code) or '')
      st.failedStatus[key] = (st.failedStatus[key] or 0) + 1
      log.warn('upload failed after %d tries: %s HTTP %s code=%s', tries, item.filename,
        tostring(item.status), tostring(res.code))

      if M.isFatal(res) then
        st.fatal = res
      else
        st.failedUpload[#st.failedUpload + 1] = item
        st.skipped[item.src.rank] = true
        st.failStreak = st.failStreak + 1
        trouble()
        if st.failStreak >= BUSY_STOP then
          st.busyStop = true
          log.warn('send paused: %d photos in a row could not be sent', st.failStreak)
        end
        flush(false, false)
      end
      status('upload')
    end
  end

  local function worker(index)
    while true do
      if checkCanceled() then return end
      local item = st.queue[st.head]
      if index > st.allowed then
        -- held back while the server is struggling (see trouble() / calm())
        if item == nil and st.producerDone then return end
        LrTasks.sleep(POLL)
      elseif item then
        st.head = st.head + 1
        uploadItem(item)
      elseif st.producerDone then
        return
      else
        LrTasks.sleep(POLL)
      end
    end
  end

  --- Run `count` tasks and wait for all of them.
  local function runTasks(fns)
    local running = #fns
    for _, fn in ipairs(fns) do
      LrTasks.startAsyncTask(function()
        fn()
        running = running - 1
      end)
    end
    while running > 0 do LrTasks.sleep(POLL) end
  end

  -- -------------------------------------------------------------------------
  -- Run
  -- -------------------------------------------------------------------------

  status('start')
  -- The small versions have their own tasks: they run next to the photos, never inside a photo's way.
  if st.thumbs then
    st.thumbRunning = 1 + THUMB_PUTTERS
    LrTasks.startAsyncTask(thumbMaker)
    for _ = 1, THUMB_PUTTERS do LrTasks.startAsyncTask(thumbPutter) end
  end
  local tasks = { produce }
  for k = 1, concurrency do tasks[#tasks + 1] = function() worker(k) end end
  local tUploadStart = now()
  runTasks(tasks)

  -- Failed uploads: offer another round (the rendered files are still here).
  while #st.failedUpload > 0 and not stopped() and o.askRetry do
    local first = st.failedUpload[1]
    if not o.askRetry(#st.failedUpload, first) then break end
    local again = st.failedUpload
    st.failedUpload = {}
    st.queue, st.head = again, 1
    st.producerDone = true
    local ws = {}
    for k = 1, concurrency do ws[#ws + 1] = function() worker(k) end end
    runTasks(ws)
  end

  -- No more photos: the small versions that are still under way are the only thing left.
  local tPhotosDone = now()
  st.thumbsClosed = true

  -- Final manifest (complete = true), retried on request.
  local finished = flush(true, true)
  while not finished and not st.fatal and o.askRetry do
    local res = st.manifestError
    if not o.askRetry(-1, { message = res and res.message or '' }) then break end
    finished = flush(true, true)
  end

  -- Wait (bounded, each on its own clock) for the small versions and the similarity groups,
  -- then tell the gallery about whichever entries arrived after their photo's own manifest
  -- went out: the same entries again, now with `thumb` and/or `group`.
  do
    local thumbGiveUpAt = now() + THUMB_TAIL_LIMIT
    local groupsGiveUpAt = now() + GROUPS_TAIL_LIMIT
    local groupsPending = o.groupsNow ~= nil and not o.groupsNow._done
    while st.thumbRunning > 0 or groupsPending do
      local t = now()
      if st.thumbRunning > 0 and t > thumbGiveUpAt and st.thumbs then
        st.thumbs = false
        log.warn('small versions: not finished after %ds; the rest is left to the server', THUMB_TAIL_LIMIT)
      end
      if groupsPending and (t > groupsGiveUpAt or o.groupsNow._done) then
        if t > groupsGiveUpAt and not o.groupsNow._done then
          log.warn('similarity groups: not finished after %ds; already-sent photos keep their time-based group',
            GROUPS_TAIL_LIMIT)
        end
        groupsPending = false
      end
      if st.thumbRunning > 0 or groupsPending then LrTasks.sleep(POLL) end
    end
  end
  st.thumbTail = now() - tPhotosDone
  if finished and not stopped() then
    local pending = {}
    for _, entry in ipairs(st.sentEntries) do
      local needsThumb = entry.thumb and not st.thumbPublished[entry]
      local newGroup = o.groupsNow and entry.group == 0 and o.groupsNow[entry.source_id]
      if newGroup then entry.group = newGroup end
      if needsThumb or newGroup then pending[#pending + 1] = entry end
    end
    local tPass = now()
    local i = 1
    while i <= #pending do
      local chunk = {}
      for k = i, math.min(i + 99, #pending) do chunk[#chunk + 1] = pending[k] end
      pace()
      local res = api.putManifest(o.apiKey, o.sid, manifestBody(chunk, true, { omitKeyColor = true }))
      if not res.ok then
        log.warn('late manifest pass (thumb/group) refused: HTTP %s code=%s', tostring(res.status), tostring(res.code))
        break
      end
      for _, entry in ipairs(chunk) do st.thumbPublished[entry] = true end
      st.passEntries = st.passEntries + #chunk
      i = i + 100
    end
    st.passSeconds = now() - tPass
  end

  -- Clean up what is left of the temporary files.
  if st.dir and LrFileUtils.exists(st.dir .. '/thumbs-out') then LrFileUtils.delete(st.dir .. '/thumbs-out') end
  local leftover = {}
  for _, p in ipairs(st.files or {}) do leftover[#leftover + 1] = p end
  export.cleanup(st.dir, leftover)

  local tEnd = now()
  local renderCount = math.max(st.rendered + #st.failedRender, 1)
  local timings = {
    total = tEnd - st.t0,
    render = st.renderSeconds,
    upload = tEnd - tUploadStart,
    renderPerPhoto = st.renderSeconds / renderCount,
    uploadPerPhoto = st.uploadCalls > 0 and (st.uploadSeconds / st.uploadCalls) or 0,
    concurrency = concurrency,
    fast = o.fast == true,
    previewOk = st.previewOk, previewFallback = st.previewFallback,
    fastDisabled = st.fastDisabled, reasons = st.reasons,
    longMin = st.longMin, longMax = st.longMax,
    avgKB = st.sentCount > 0 and (st.sentBytes / st.sentCount / 1024) or 0,
    thumbSent = st.thumbSent, thumbFailed = st.thumbFailed,
  }
  local removedParts = {}
  for label, n in pairs(st.removed) do removedParts[#removedParts + 1] = label .. '=' .. n end
  table.sort(removedParts)
  log.info('pipeline: total=%d uploaded=%d failedUpload=%d failedRender=%d canceled=%s fast=%s '
    .. 'wall=%.1fs render=%.1fs (%.2fs/photo) upload=%.1fs (%.2fs/request x%d)',
    total, st.uploaded, #st.failedUpload, #st.failedRender, tostring(st.canceled), tostring(o.fast == true),
    timings.total, timings.render, timings.renderPerPhoto, timings.upload, timings.uploadPerPhoto, concurrency)
  local reasonParts = {}
  for reason, n in pairs(st.reasons) do reasonParts[#reasonParts + 1] = reason .. '=' .. n end
  table.sort(reasonParts)
  log.info('pipeline images: preview=%d (sRGB tag added to %d) exportFallback=%d previewDisabled=%s '
    .. 'previewRejected=[%s] longEdge=%s..%s avg=%.0fKB metadataRemoved=[%s] strippedBytes=%d',
    st.previewOk, st.previewTagged, st.previewFallback, tostring(st.fastDisabled), table.concat(reasonParts, ' '),
    tostring(st.longMin), tostring(st.longMax), timings.avgKB,
    table.concat(removedParts, ' '), st.strippedBytes)

  local failedParts = {}
  for key, n in pairs(st.failedStatus) do failedParts[#failedParts + 1] = key .. 'x' .. n end
  table.sort(failedParts)
  local thumbWhy = {}
  for why, n in pairs(st.thumbWhy) do thumbWhy[#thumbWhy + 1] = why .. '=' .. n end
  table.sort(thumbWhy)
  local noThumb = math.max(st.uploaded - st.thumbSent - st.thumbSkipped, 0)
  log.info('pipeline small versions: sent=%d none=%d alreadySmall=%d failed=%d (%s) stopped=%s paced=%s avg=%.0fKB long=%s..%s',
    st.thumbSent, noThumb, st.thumbSkipped, st.thumbFailed, table.concat(thumbWhy, ' '),
    tostring(o.thumbs ~= false and not st.thumbs), tostring(st.thumbPaced),
    st.thumbSent > 0 and (st.thumbBytes / st.thumbSent / 1024) or 0,
    tostring(st.thumbLongMin), tostring(st.thumbLongMax))
  log.info('pipeline times: photoPUT=%.1fs/%d (%.2fs each) sips=%.1fs/%d calls (%d files) '
    .. 'thumbPUT=%.1fs/%d (%.2fs each) thumbTail=%.1fs manifestPass=%.1fs (%d entries)',
    st.uploadSeconds, st.uploadCalls, st.uploadCalls > 0 and (st.uploadSeconds / st.uploadCalls) or 0,
    st.sipsSeconds, st.sipsCalls, st.sipsFiles,
    st.thumbPutSeconds, st.thumbPutCalls, st.thumbPutCalls > 0 and (st.thumbPutSeconds / st.thumbPutCalls) or 0,
    st.thumbTail or 0, st.passSeconds, st.passEntries)
  log.info('pipeline retries=%d parallelLowered=%d busyStop=%s failedUploads=[%s]',
    st.retries, st.lowered, tostring(st.busyStop), table.concat(failedParts, ' '))

  persistJob()
  status('done')

  return {
    uploaded = st.uploaded,
    failedUpload = st.failedUpload,
    failedRender = st.failedRender,
    canceled = st.canceled,
    busyStop = st.busyStop,
    retries = st.retries,
    fatal = st.fatal,
    manifestError = (not finished) and st.manifestError or nil,
    timings = timings,
    usedNames = usedList,
  }
end

--- One line for the result dialog / log:
---   書き出し 4分10秒（0.8秒/枚）／送信 5分30秒（1.1秒/枚・3並列）／全体 6分20秒
function M.timingText(t)
  local renderLabel = t.fast and 'プレビュー取得' or '書き出し'
  local line = string.format(
    '%s %s（%.1f秒/枚）／送信 %s（%.1f秒/枚・%d並列）／全体 %s',
    renderLabel, text.formatDuration(t.render), t.renderPerPhoto,
    text.formatDuration(t.upload), t.uploadPerPhoto, t.concurrency,
    text.formatDuration(t.total)
  )
  if t.fast then
    if t.fastDisabled then
      line = line .. '\nこのカタログではプレビューを使えなかったため、通常の書き出しで送りました。'
    else
      line = line .. string.format('\nプレビューから %d 枚・書き出しで %d 枚', t.previewOk or 0, t.previewFallback or 0)
      if t.longMin and t.longMax then
        line = line .. string.format('（プレビューの長辺 %d〜%d px）', t.longMin, t.longMax)
      end
    end
    -- many exports: previews are missing (or are camera JPEGs), so "speed first" did not help
    if t.fastDisabled or (t.previewFallback or 0) > (t.previewOk or 0) then
      line = line .. '\n標準サイズのプレビューを作っておくと速くなります。'
    end
  end
  return line
end

return M
