--[[
  CreateGallery.lua — Library menu: "papat でギャラリーを作る…"

  Flow
    1. selected photos -> dialog (title, 7/14 days, passcode, optional client color)
    2. POST /api/v1/galleries   (passcode_hash + the passcode, key_color if set)
    3. show URL / passcode / invitation text at once (copy buttons)
    4. in the background (lib/sender.lua → lib/pipeline.lua): render and upload overlap,
       several uploads at a time, manifest in small batches; Lightroom stays usable and
       shows its own progress indicator. Results are kept in "最近のギャラリー".

  Yielding calls (dialogs, HTTP, export, catalog) are never inside pcall. Errors that
  escape are shown by LrDialogs.attachErrorDialogToFunctionContext.
]]

local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrColor = import 'LrColor'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local function load(name) return dofile(_PLUGIN.path .. '/lib/' .. name .. '.lua') end
local config = load('config')
local text = load('text')
local sha256 = load('sha256')
local ids = load('ids')
local api = load('api')
local catalogLib = load('catalog')
local clipboard = load('clipboard')
local guidance = load('guidance')
local grouping = load('grouping')
local jobs = load('jobs')
local pipeline = load('pipeline')
local sender = load('sender')
local photoinfo = load('photoinfo')
local rights = load('rights')
local similarity = load('similarity')
local split = load('split')
local ui = load('ui')
local update = load('update')
local log = load('log')

local f = LrView.osFactory()
local RED = LrColor(0.75, 0.2, 0.1)
local GREY = LrColor(0.45, 0.45, 0.45)

-- ---------------------------------------------------------------------------
-- Dialog 1: gallery settings
-- ---------------------------------------------------------------------------

local function defaultTitle(catalog)
  local ok, name = LrTasks.pcall(function()
    local sources = catalog:getActiveSources()
    local first = sources and sources[1]
    if type(first) == 'table' and first.getName then return first:getName() end
    return nil
  end)
  if ok and type(name) == 'string' and name ~= '' then return text.cleanTitle(name, 100) end
  return os.date('%Y-%m-%d')
end


-- Messages shown under the form (bound text cannot grow once the dialog is open: the box is as
-- tall as the longest one)
local function problemPasscodeLength()
  return string.format('パスコードは %d〜%d 文字で入力してください。', text.MIN_PASSCODE_LENGTH, text.MAX_PASSCODE_LENGTH)
end

local exportNote = 'プレビューは Lightroom が持っている画像です。現像を変えた直後で気になるときは、チェックを入れてください。'

local passcodeNote = 'パスコードはクライアントに伝える合言葉です。papat に暗号化して保存され、ダッシュボードでいつでも確認できます。'

--- @param segments table|nil  1.2.0's auto-split: photo counts per gallery (nil / one entry
---   = a single gallery, same as before; price and the one-line notice follow it instead
---   of `count` when there are several)
--- @return table|nil settings  { title, days, passcode } or nil when cancelled
local function askSettings(context, catalog, count, free, segments)
  local props = LrBinding.makePropertyTable(context)
  props.title = defaultTitle(catalog)
  props.days = 7
  props.passcode = ids.passcode(6)
  props.problem = ''
  props.canSubmit = true

  local function priceFor(days)
    if segments and #segments > 1 then return text.priceLineYen(text.priceYenSplit(segments, days), free) end
    return text.priceLine(count, days, free)
  end
  props.priceText = priceFor(7)
  -- 言葉は少なく: one line, only when the selection is actually being split
  props.splitLine = (segments and #segments > 1) and text.splitLine(segments) or ''

  local function validate()
    local pass = text.trim(props.passcode)
    local problem = ''
    if #pass < text.MIN_PASSCODE_LENGTH or #pass > text.MAX_PASSCODE_LENGTH then
      problem = problemPasscodeLength()
    elseif pass:find('%s') then
      problem = 'パスコードに空白は使えません。'
    end
    props.problem = problem
    props.canSubmit = (problem == '')
    props.priceText = priceFor(props.days)
  end
  props:addObserver('passcode', validate)
  props:addObserver('days', validate)

  local function bind(key) return LrView.bind { key = key, bind_to_object = props } end

  -- Essentials only (what is sent, where it comes from, what the images carry); details are in
  -- the plug-in manager and in the confirmation shown once. The intro follows the "export this
  -- time" check box; its height is that of the longer of the two texts.
  local settings = config.settings()
  local function introFor(fast)
    return text.createIntro(count, {
      longEdge = config.EXPORT_LONG_EDGE, fast = fast, embedRights = settings.embedRights,
    })
  end
  local introLines = math.max(
    text.linesFor(introFor(true), 520, 2), text.linesFor(introFor(false), 520, 2))
  props.exportNow = false
  props.intro = introFor(settings.fastMode)
  props:addObserver('exportNow', function()
    props.intro = introFor(settings.fastMode and not props.exportNow)
  end)

  local contents = f:column {
    bind_to_object = props,
    spacing = f:control_spacing(),
    width = 520,

    f:static_text {
      title = bind('intro'),
      width = 520,
      height_in_lines = introLines,
    },

    f:static_text {
      title = bind('splitLine'),
      font = '<system/bold>',
      width = 520,
      height_in_lines = 1,
    },

    f:row {
      f:static_text { title = 'タイトル', width = 80 },
      f:edit_field { value = bind('title'), width_in_chars = 36 },
    },

    f:row {
      f:static_text { title = '保存期間', width = 80 },
      f:radio_button { title = '7日', value = bind('days'), checked_value = 7 },
      f:radio_button { title = '14日', value = bind('days'), checked_value = 14 },
    },
    -- its own line: the estimate (with the server's free-gallery count) is wider than the rest
    f:static_text { title = bind('priceText'), text_color = GREY, width = 520 },

    f:row {
      f:static_text { title = 'パスコード', width = 80 },
      f:edit_field { value = bind('passcode'), width_in_chars = 16, immediate = true },
      f:push_button {
        title = '自動生成',
        action = function() props.passcode = ids.passcode(6) end,
      },
    },

    -- Only when sending from the preview is the default: this one time, export instead
    settings.fastMode and f:column {
      spacing = f:label_spacing(),
      f:checkbox {
        title = 'この回だけ、書き出して送る（時間がかかります）',
        value = bind('exportNow'),
      },
      f:static_text {
        title = exportNote,
        text_color = GREY,
        width = 520,
        height_in_lines = text.linesFor(exportNote, 520, 1),
      },
    } or f:spacer { height = 1 },

    f:static_text {
      title = bind('problem'),
      text_color = RED,
      width = 520,
      height_in_lines = 1,
    },

    f:static_text {
      title = passcodeNote,
      text_color = GREY,
      width = 520,
      height_in_lines = text.linesFor(passcodeNote, 520, 2),
    },
  }

  local result = LrDialogs.presentModalDialog {
    title = 'papat でギャラリーを作る',
    contents = contents,
    actionVerb = '作成して送信',
    cancelVerb = 'キャンセル',
    actionBinding = { enabled = { bind_to_object = props, key = 'canSubmit' } },
  }
  if result ~= 'ok' then return nil end

  return {
    title = text.cleanTitle(props.title, 200),
    days = props.days == 14 and 14 or 7,
    passcode = text.trim(props.passcode),
    keyColor = '', -- the gallery colour is set in the dashboard, not here
    exportNow = settings.fastMode and props.exportNow == true,
  }
end

-- ---------------------------------------------------------------------------
-- Dialog 2: result (URL, passcode, invitation) while the photos are sent
-- ---------------------------------------------------------------------------

local function showResult(context, info, status)
  local props = LrBinding.makePropertyTable(context)
  props.url = info.url
  props.urls = info.urls -- set only when split (audit 15 §3.4): saveWording needs every URL
  props.passcode = info.passcode
  props.expireText = info.expireText
  props.guidance = info.guidance
  props.title = info.title
  props.copyStatus = ''
  props.statusText = status.text
  props.note = info.note or status.note or ''
  status.props = props

  local backgroundNote = '写真は裏で送っています。このウィンドウを閉じても、Lightroom で他の作業を続けられます。'
    .. 'パスコードは papat のダッシュボードでも確認できます。'
  local headline = (info.galleryCount and info.galleryCount > 1)
    and string.format('%d 枚を %d つのギャラリーに作成しました', info.count, info.galleryCount)
    or string.format('ギャラリーを作成しました（%d 枚）', info.count)
  local contents = guidance.column(f, props, {
    f:static_text {
      title = headline,
      font = '<system/bold>',
    },
    f:static_text {
      title = backgroundNote,
      text_color = LrColor(0.45, 0.45, 0.45),
      width = 560,
      height_in_lines = text.linesFor(backgroundNote, 560, 2),
    },
  })

  -- Copy the invitation as soon as the dialog opens: the next step is pasting it.
  LrTasks.startAsyncTask(function()
    if clipboard.copy(props.guidance) then
      props.copyStatus = '案内文をコピーしました。メールやチャットに貼り付けて送れます。'
    end
  end)

  LrDialogs.presentModalDialog {
    title = 'papat ギャラリーを作成しました',
    contents = contents,
    actionVerb = '閉じる（送信は続きます）',
    actionBinding = { enabled = { bind_to_object = props, key = 'canClose' } },
    cancelVerb = '< exclude >',
  }
  status.props = nil
end

-- ---------------------------------------------------------------------------
-- Creating one gallery (title already carries its "（1/2）" suffix, if any)
-- ---------------------------------------------------------------------------

--- @return table|nil created  { sid, url, expiresAt, expireText } — nil if it could not be
---   created (an error dialog has already been shown; the caller should just stop)
local function createOneGallery(apiKey, settings, title)
  local created = api.createGallery(apiKey, {
    title = title,
    days = settings.days,
    passcodeHash = sha256.hex(settings.passcode),
    passcode = settings.passcode,
    keyColor = settings.keyColor ~= '' and settings.keyColor or nil,
    idempotencyKey = ids.uuid(),
  })
  if not created.ok then
    ui.showApiError('ギャラリーを作成できませんでした', created)
    return nil
  end
  local sid = tostring(created.data.sid or created.data.gallery_id or '')
  if sid == '' then
    LrDialogs.message('ギャラリーを作成できませんでした', 'papat から正しい応答が返りませんでした。しばらくしてから、もう一度お試しください。', 'critical')
    return nil
  end
  local sharePath = tostring(created.data.path or ('/t/' .. tostring(created.data.tenant_id or '') .. '/s/' .. sid))
  local url = config.BASE_URL .. sharePath:gsub('/+$', '') .. '/'
  log.info('gallery created: sid=%s title=%s', sid, title)
  update.rememberFree(created.data.free_galleries_remaining)

  local expiresAt = tostring(created.data.expires_at or '')
  local y, m, d = text.isoToLocalDate(expiresAt, ui.localOffset())
  return {
    sid = sid, url = url, expiresAt = expiresAt,
    expireText = y and (text.jaMonthDay(m, d) .. 'まで') or '',
  }
end

--- A split send's 2nd+ gallery could not be created (createOneGallery already showed its own
--- error dialog): the ones already created this round never get a photo and must not be left
--- behind — an empty gallery, a resume job, a "最近のギャラリー" entry, and (課金 ON) the
--- reserved base unit for creating it. `created` is the array built so far (each entry has at
--- least `sid`, `title`). A deletion that itself fails is reported once, by title, so the
--- photographer can remove it from the dashboard (audit 15 §3.1).
local function cleanUpPartialSplit(apiKey, created)
  if #created == 0 then return end
  local stuck = {}
  for _, g in ipairs(created) do
    local res = api.deleteGallery(apiKey, g.sid)
    if res.ok then
      jobs.removeJob(g.sid)
      jobs.removeRecent(g.sid)
    else
      log.warn('could not clean up a partially created split: sid=%s title=%s', g.sid, tostring(g.title))
      stuck[#stuck + 1] = g.title
    end
  end
  if #stuck > 0 then
    LrDialogs.message(
      '作成済みのギャラリーが残っています',
      '一部のギャラリーを自動で消せませんでした。papat のダッシュボードで、次のギャラリーを消してください。\n\n'
        .. table.concat(stuck, '\n'),
      'critical'
    )
  end
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

local function run(context)
  LrDialogs.attachErrorDialogToFunctionContext(context)

  ui.offerStandardLocationOnce()

  local apiKey = ui.requireApiKey()
  if not apiKey then return end

  if not update.checkAndTell(apiKey) then return end

  local catalog = LrApplication.activeCatalog()
  local targets = catalog:getTargetPhotos() or {}
  if #targets == 0 then
    LrDialogs.message('写真が選択されていません', 'ギャラリーに入れる写真を選んでから、もう一度実行してください。', 'info')
    return
  end

  -- videos are not part of a photo gallery (their "preview" would be a still frame)
  local selected, videos = {}, 0
  for _, photo in ipairs(targets) do
    if photo:getRawMetadata('isVideo') == true then
      videos = videos + 1
    else
      selected[#selected + 1] = photo
    end
  end
  if #selected == 0 then
    LrDialogs.message('動画は送れません', '選択されているのは動画だけです。写真を選んでから、もう一度実行してください。', 'info')
    return
  end

  -- What the images will say about their author, the photographer's stars and the capture
  -- times: read before anything else. 1.2.0's auto-split needs the capture times (and, for a
  -- large selection, the similarity groups) to decide where to cut, before the settings dialog
  -- even opens — unlike lib/similarity.lua's per-gallery refinement below, which never adds to
  -- the send's own wait, this one is unavoidable: the dialog has to say how it will be split.
  local options = config.settings()
  local infos = photoinfo.gather(catalog, selected)
  local existingIds = catalogLib.sourceIds(catalog, selected)
  local items = {}
  for _, photo in ipairs(selected) do
    items[#items + 1] = {
      photo = photo, sourceId = existingIds[photo] or ids.uuid(),
      datetime = infos[photo].datetime,
      rating = options.showRating and infos[photo].rating or 0,
    }
  end
  -- the order every gallery (or, split, every sub-gallery) sends in (lib/pipeline.lua's own
  -- rule) — decided once, used for the auto-split's cut points, the manifest's group numbers,
  -- and the send itself
  local ordered = pipeline.order(items)
  local datetimesOrdered = {}
  for i, item in ipairs(ordered) do datetimesOrdered[i] = item.datetime end

  -- Auto-split (decided 2026-10-15): more than 888 photos, cut at one of the gallery's own
  -- group boundaries (time groups, refined by lib/similarity.lua when it can run) — closest to
  -- 888 within 750-888, else within 888-maxPhotos; see lib/split.lua for the full rule and its
  -- fallbacks (no boundary in range; no grouping at all).
  local maxPhotos = update.maxPhotos()
  local segments, combinedGroups = { #ordered }, nil
  if #ordered > split.TRIGGER then
    local progress = LrProgressScope {
      title = '似ている写真を調べています（分け方を決めるため）', functionContext = context,
    }
    progress:setCancelable(true)
    -- A time budget on top of the cancel button (audit 15 §5.2): this is the one call to
    -- lib/similarity.lua that cannot overlap with the send (the dialog below needs the
    -- segment sizes before it can even open), so unlike the per-gallery case it must have its
    -- own ceiling rather than running unbounded. ~0.2s/photo (the design doc's own 296-photo
    -- trial measured far less), capped at 3 minutes either way.
    local budgetSeconds = math.min(180, 0.2 * #ordered)
    local groupsNow = {}
    similarity.compute(ordered, groupsNow, {
      deadlineEpoch = os.time() + budgetSeconds,
      isCanceled = function() return progress:isCanceled() end,
    })
    progress:done()
    -- Whatever lib/similarity.lua could not finish (over budget, canceled, or any other
    -- failure) simply leaves groupsNow empty: the fallback below is the plain time groups,
    -- exactly the "グループが働かないとき" path lib/split.lua already has.
    local timeGroups = grouping.autoGroups(datetimesOrdered).groups
    combinedGroups = {}
    for i, item in ipairs(ordered) do
      combinedGroups[i] = groupsNow[item.sourceId] or timeGroups[i]
    end
    segments = split.plan(#ordered, combinedGroups, datetimesOrdered, maxPhotos)
  end

  -- A defensive check only: lib/split.lua already keeps every segment within maxPhotos, but a
  -- server reporting something far smaller than 888 should still be refused cleanly rather
  -- than sending an oversized gallery.
  for _, count in ipairs(segments) do
    if count > maxPhotos then
      LrDialogs.message(
        '写真が多すぎます',
        string.format('一度に送れるのは %d 枚までです（現在 %d 枚）。枚数を減らしてください。', maxPhotos, #selected),
        'critical'
      )
      return
    end
  end

  -- how many galleries are still free comes from the server (cached by the update check)
  local settings = askSettings(context, catalog, #selected, update.freeRemaining(), segments)
  if not settings then return end
  log.info('create gallery: photos=%d days=%d segments=%d', #selected, settings.days, #segments)

  -- rights consent (asked once for the whole selection, even when it ends up split)
  local rightsMode = 'none'
  if options.embedRights then
    rightsMode = ui.confirmRights(photoinfo.distinctRights(selected, infos), sha256, rights)
    if rightsMode == 'cancel' then return end
  end
  for _, item in ipairs(ordered) do
    item.meta = (rightsMode == 'embed') and rights.segments(infos[item.photo].fields) or ''
  end

  local notes = {}
  if videos > 0 then
    notes[#notes + 1] = string.format('動画 %d 本は送っていません（写真だけを送ります）。', videos)
  end

  -- One gallery per segment (one, unless the selection was split). Created in order, before
  -- any of them starts sending: the result window needs every URL at once (1.2.0's combined
  -- invitation text), and each gets its own entry in "最近のギャラリー" as soon as it exists.
  -- One status line follows whichever gallery is sending now (lib/sender.lua prefixes it).
  local status = sender.newStatus('書き出しと送信を始めます。')
  local galleries, sendList, offset = {}, {}, 0
  for i, count in ipairs(segments) do
    local title = (#segments > 1) and string.format('%s（%d/%d）', settings.title, i, #segments) or settings.title
    local created = createOneGallery(apiKey, settings, title)
    if not created then
      -- an error dialog for THIS failure has already been shown; any earlier gallery in this
      -- same round must not be left behind empty (audit 15 §3.1)
      cleanUpPartialSplit(apiKey, galleries)
      return
    end

    local segItems, pending = {}, {}
    for k = offset + 1, offset + count do
      local item = ordered[k]
      segItems[#segItems + 1] = item
      pending[#pending + 1] = { uuid = item.photo:getRawMetadata('uuid'), sourceId = item.sourceId }
    end

    -- The display group numbers for this segment: already decided above (combinedGroups) when
    -- the selection was large enough to need the auto-split decision, restarting at 1 per
    -- segment (0 = no capture time stays 0) — no per-segment similarity pass needed. Otherwise
    -- (the common case: no split was even considered) this is the one and only segment, and
    -- lib/similarity.lua runs the normal way, in its own task alongside the send below.
    local groupsNow = {}
    if combinedGroups then
      local renumbered = split.renumberSegment(combinedGroups, offset + 1, offset + count)
      for k, item in ipairs(segItems) do
        if renumbered[k] > 0 then groupsNow[item.sourceId] = renumbered[k] end
      end
      groupsNow._done = true
    else
      LrTasks.startAsyncTask(function() similarity.compute(segItems, groupsNow) end)
    end

    jobs.addRecent {
      sid = created.sid, title = title, url = created.url, passcode = settings.passcode,
      expiresAt = created.expiresAt, createdAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
      total = #segItems, uploaded = 0, keyColor = settings.keyColor, complete = false,
    }
    jobs.saveJob(created.sid, { pending = pending, used = {}, rights = rightsMode })

    galleries[#galleries + 1] = {
      sid = created.sid, title = title, url = created.url, expireText = created.expireText, expiresAt = created.expiresAt,
    }
    sendList[#sendList + 1] = {
      apiKey = apiKey, sid = created.sid, title = title, keyColor = settings.keyColor,
      items = segItems, usedNames = {}, status = status, total = #segItems, alreadyUploaded = 0,
      rightsMode = rightsMode, groupsNow = groupsNow,
      fast = config.settings().fastMode and not settings.exportNow, -- "export this time" wins
      label = (#segments > 1) and string.format('ギャラリー %d/%d', i, #segments) or nil,
    }
    offset = offset + count
  end

  -- the server may have shortened 14 days (e.g. near the account's own limit); the first
  -- gallery's own answer stands for all of them (by design: 期限は同じにします)
  if settings.days == 14 and galleries[1].expiresAt then
    local actualDays = text.daysUntil(galleries[1].expiresAt, os.time())
    if actualDays and actualDays <= 8 then
      notes[#notes + 1] = '保存期間は 14 日ではなく ' .. tostring(actualDays) .. ' 日で作成されました。延長はダッシュボードで行えます。'
    end
  end

  local urls = {}
  for _, g in ipairs(galleries) do urls[#urls + 1] = g.url end
  local invitation = text.announcement {
    title = settings.title, urls = urls, passcode = settings.passcode, expireText = galleries[1].expireText,
    template = config.prefs().announcementTemplate,
  }

  -- the sends run in order, in one background task, after this dialog is shown
  sender.startMany(sendList)

  showResult(context, {
    count = #ordered, galleryCount = #segments, url = galleries[1].url, urls = (#urls > 1) and urls or nil,
    passcode = settings.passcode, expireText = galleries[1].expireText, guidance = invitation, title = settings.title,
    note = table.concat(notes, '\n'),
  }, status)
end

LrTasks.startAsyncTask(function()
  LrFunctionContext.callWithContext('papatCreateGallery', run)
end)
