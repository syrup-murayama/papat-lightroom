--[[
  AddToGallery.lua — Library menu: "papat の既存のギャラリーに追加…" (1.2.6)

  Flow
    1. selected photos -> GET /api/v1/galleries -> the galleries that are still open (active and
       not past their expiry), newest first -> the photographer picks one
    2. the gallery's manifest is read (file names and source ids it already holds)
    3. photos whose source id is already in it are left out; more than the gallery may hold
       (1,000) stops here, before anything is sent
    4. the rest goes the same way as a new gallery (lib/sender.lua → lib/pipeline.lua): render,
       PUT photo / small version / manifest — but no POST /galleries, and file names that the
       gallery already uses get "-2", "-3" … (the server overwrites a PUT to the same name)
    5. the result window shows the URL; the passcode is not shown (it does not change)

  The server is used as it is: nothing here needs a new API. Yielding calls (dialogs, HTTP,
  export, catalog) are never inside pcall; errors that escape are shown by
  LrDialogs.attachErrorDialogToFunctionContext.
]]

local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrColor = import 'LrColor'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrHttp = import 'LrHttp'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local function load(name) return dofile(_PLUGIN.path .. '/lib/' .. name .. '.lua') end
local config = load('config')
local text = load('text')
local sha256 = load('sha256')
local ids = load('ids')
local api = load('api')
local addto = load('addto')
local catalogLib = load('catalog')
local clipboard = load('clipboard')
local jobs = load('jobs')
local sender = load('sender')
local photoinfo = load('photoinfo')
local rights = load('rights')
local ui = load('ui')
local update = load('update')
local log = load('log')

local f = LrView.osFactory()
local GREY = LrColor(0.45, 0.45, 0.45)
local RED = LrColor(0.75, 0.2, 0.1)

local WIDTH = 560

-- ---------------------------------------------------------------------------
-- Dialog 1: which gallery
-- ---------------------------------------------------------------------------

local exportNote = 'プレビューは Lightroom が持っている画像です。現像を変えた直後で気になるときは、チェックを入れてください。'

local function introText(count)
  return string.format(
    '選んだ %d 枚を、papat の公開中のギャラリーに追加します。ギャラリーのタイトル・公開期限・パスコードは変わりません。'
      .. 'すでに入っている写真は送りません。', count)
end

--- @param galleries table  from addto.activeGalleries
--- @param recentBySid table  [sid] = the "最近のギャラリー" entry (its URL is known)
--- @return table|nil { gallery, exportNow }  nil when cancelled
local function askTarget(context, galleries, count, offset, recentBySid)
  local props = LrBinding.makePropertyTable(context)
  props.sid = galleries[1].sid
  props.exportNow = false

  local bySid, items = {}, {}
  for _, g in ipairs(galleries) do
    bySid[g.sid] = g
    items[#items + 1] = { title = addto.label(g, offset), value = g.sid }
  end

  local function detailFor(sid)
    local g = bySid[sid] or galleries[1]
    local lines = { g.title ~= '' and g.title or '（無題）' }
    local y, m, d = text.isoToLocalDate(g.createdAt, offset)
    if y then lines[#lines + 1] = '作成: ' .. text.jaDate(y, m, d) end
    local expire = text.expireText(g.expiresAt, offset)
    if expire ~= '' then lines[#lines + 1] = '公開期限: ' .. expire end
    local known = recentBySid[g.sid]
    if known and type(known.url) == 'string' and known.url ~= '' then lines[#lines + 1] = 'URL: ' .. known.url end
    return table.concat(lines, '\n')
  end
  props.detail = detailFor(props.sid)
  props:addObserver('sid', function() props.detail = detailFor(props.sid) end)

  local function bind(key) return LrView.bind { key = key, bind_to_object = props } end
  local settings = config.settings()
  local intro = introText(count)

  local contents = f:column {
    bind_to_object = props,
    spacing = f:control_spacing(),
    width = WIDTH,

    f:static_text { title = intro, width = WIDTH, height_in_lines = text.linesFor(intro, WIDTH, 2) },

    f:row {
      f:static_text { title = 'ギャラリー', width = 80 },
      f:popup_menu { items = items, value = bind('sid'), width = WIDTH - 90 },
    },
    f:static_text { title = bind('detail'), text_color = GREY, width = WIDTH, height_in_lines = 4 },

    settings.fastMode and f:column {
      spacing = f:label_spacing(),
      f:checkbox { title = 'この回だけ、書き出して送る（時間がかかります）', value = bind('exportNow') },
      f:static_text {
        title = exportNote, text_color = GREY, width = WIDTH,
        height_in_lines = text.linesFor(exportNote, WIDTH, 1),
      },
    } or f:spacer { height = 1 },
  }

  local result = LrDialogs.presentModalDialog {
    title = 'papat の既存のギャラリーに追加',
    contents = contents,
    actionVerb = '追加して送信',
    cancelVerb = 'キャンセル',
  }
  if result ~= 'ok' then return nil end
  return {
    gallery = bySid[props.sid] or galleries[1],
    exportNow = settings.fastMode and props.exportNow == true,
  }
end

-- ---------------------------------------------------------------------------
-- Dialog 2: result (URL) while the photos are sent
-- ---------------------------------------------------------------------------

local function showResult(context, info, status)
  local props = LrBinding.makePropertyTable(context)
  props.url = info.url
  props.expireText = info.expireText
  props.copyStatus = ''
  props.statusText = status.text
  props.note = info.note or status.note or ''
  status.props = props

  local headline = string.format('「%s」に %d 枚を追加します', info.title ~= '' and info.title or '（無題）', info.count)
  local backgroundNote = '写真は裏で送っています。このウィンドウを閉じても、Lightroom で他の作業を続けられます。'
    .. 'ギャラリーのパスコードは変わりません（papat のダッシュボードで確認できます）。'

  local function bind(key) return LrView.bind { key = key, bind_to_object = props } end
  local rows = {
    bind_to_object = props,
    spacing = f:control_spacing(),
    width = WIDTH,
    f:static_text { title = headline, font = '<system/bold>', width = WIDTH, height_in_lines = text.linesFor(headline, WIDTH, 1) },
    f:static_text {
      title = backgroundNote, text_color = GREY, width = WIDTH,
      height_in_lines = text.linesFor(backgroundNote, WIDTH, 2),
    },
  }
  if info.skippedLine and info.skippedLine ~= '' then
    rows[#rows + 1] = f:static_text {
      title = info.skippedLine, width = WIDTH, height_in_lines = text.linesFor(info.skippedLine, WIDTH, 1),
    }
  end
  if info.url ~= '' then
    rows[#rows + 1] = f:row {
      f:static_text { title = 'URL', width = 80 },
      f:edit_field { value = bind('url'), width_in_chars = 44 },
    }
    rows[#rows + 1] = f:row {
      f:static_text { title = '公開期限', width = 80 },
      f:static_text { title = bind('expireText') },
    }
    rows[#rows + 1] = f:row {
      f:push_button {
        title = 'URL をコピー',
        action = function()
          LrTasks.startAsyncTask(function()
            props.copyStatus = clipboard.copy(props.url) and 'URL をコピーしました。'
              or 'コピーできませんでした。URL の欄を選択して、Cmd+C でコピーしてください。'
          end)
        end,
      },
      f:push_button { title = 'ブラウザで開く', action = function() LrHttp.openUrlInBrowser(props.url) end },
    }
  else
    rows[#rows + 1] = f:static_text {
      title = 'ギャラリーの URL は papat のダッシュボード（' .. config.DASHBOARD_URL .. '）で確認できます。',
      width = WIDTH, height_in_lines = 2,
    }
  end
  rows[#rows + 1] = f:static_text { title = bind('copyStatus'), text_color = GREY, width = WIDTH, height_in_lines = 1 }
  rows[#rows + 1] = f:separator { width = WIDTH }
  rows[#rows + 1] = f:static_text { title = bind('statusText'), width = WIDTH, height_in_lines = 6 }
  rows[#rows + 1] = f:static_text { title = bind('note'), text_color = RED, width = WIDTH, height_in_lines = 4 }

  LrDialogs.presentModalDialog {
    title = 'papat ギャラリーに追加',
    contents = f:column(rows),
    actionVerb = '閉じる（送信は続きます）',
    cancelVerb = '< exclude >',
  }
  status.props = nil
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
    LrDialogs.message('写真が選択されていません', 'ギャラリーに追加する写真を選んでから、もう一度実行してください。', 'info')
    return
  end

  -- videos are not part of a photo gallery
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

  -- 1. the galleries that can still take photos
  local listed = api.listGalleries(apiKey)
  if not listed.ok then
    ui.showApiError('ギャラリーの一覧を取得できませんでした', listed)
    return
  end
  local galleries = addto.activeGalleries(listed.galleries, os.time())
  if #galleries == 0 then
    LrDialogs.message(
      '追加できるギャラリーがありません',
      '公開中のギャラリーが見つかりません（期限が切れたか、終了したギャラリーには追加できません）。'
        .. '「papat でギャラリーを作る…」で新しく作成してください。',
      'info'
    )
    return
  end

  local recentBySid = {}
  for _, entry in ipairs(jobs.loadRecent()) do
    if type(entry) == 'table' and type(entry.sid) == 'string' then recentBySid[entry.sid] = entry end
  end

  local offset = ui.localOffset()
  local choice = askTarget(context, galleries, #selected, offset, recentBySid)
  if not choice then return end
  local gallery = choice.gallery

  -- 2. what the gallery holds now
  local read = api.getManifest(apiKey, gallery.sid)
  if not read.ok then
    ui.showApiError('ギャラリーの中身を確かめられませんでした', read)
    return
  end
  local existing = addto.existing(read.data)

  -- 3. leave out what is already in it; stop before sending when it would not fit
  local existingIds = catalogLib.sourceIds(catalog, selected)
  local candidates = {}
  for _, photo in ipairs(selected) do
    candidates[#candidates + 1] = { photo = photo, sourceId = existingIds[photo] or ids.uuid() }
  end
  local maxPhotos = update.maxPhotos()
  local plan = addto.plan(existing, candidates, maxPhotos)
  log.info('add to gallery: sid=%s selected=%d skipped=%d existing=%d max=%d', gallery.sid, #selected,
    plan.skipped, existing.count, maxPhotos)

  if plan.over then
    LrDialogs.message(
      '上限を超えるため、追加できません',
      string.format('このギャラリーには今 %d 枚入っています。%d 枚を足すと、1 つのギャラリーの上限（%d 枚）を %d 枚超えます。'
        .. '選ぶ枚数を減らすか、新しいギャラリーを作ってください。',
        plan.count, #plan.send, plan.max, plan.over)
        .. (plan.skipped > 0 and string.format('\n（選んだ写真のうち %d 枚は、すでに入っているので数えていません）', plan.skipped) or ''),
      'critical'
    )
    return
  end
  if #plan.send == 0 then
    LrDialogs.message(
      '追加する写真がありません',
      string.format('選んだ %d 枚は、すべてこのギャラリーに入っています。', plan.skipped),
      'info'
    )
    return
  end

  -- 4. what the images say about their author (asked once, as when a gallery is made)
  local options = config.settings()
  local sendPhotos = {}
  for _, item in ipairs(plan.send) do sendPhotos[#sendPhotos + 1] = item.photo end
  local infos = photoinfo.gather(catalog, sendPhotos)
  local rightsMode = 'none'
  if options.embedRights then
    rightsMode = ui.confirmRights(photoinfo.distinctRights(sendPhotos, infos), sha256, rights)
    if rightsMode == 'cancel' then return end
  end
  local items, pending = {}, {}
  for _, c in ipairs(plan.send) do
    items[#items + 1] = {
      photo = c.photo, sourceId = c.sourceId,
      datetime = infos[c.photo].datetime,
      rating = options.showRating and infos[c.photo].rating or 0,
      meta = (rightsMode == 'embed') and rights.segments(infos[c.photo].fields) or '',
    }
    pending[#pending + 1] = { uuid = c.photo:getRawMetadata('uuid'), sourceId = c.sourceId }
  end

  -- where the client opens it: known from "最近のギャラリー", else built from the account's id
  local url = ''
  local known = recentBySid[gallery.sid]
  if known and type(known.url) == 'string' then
    url = known.url
  else
    local st = api.status(apiKey, 10)
    local tenant = st.ok and st.data.tenant_id
    if type(tenant) == 'string' and tenant ~= '' then
      url = config.BASE_URL .. '/t/' .. text.urlEncodeSegment(tenant) .. '/s/' .. text.urlEncodeSegment(gallery.sid) .. '/'
    end
  end

  -- "最近のギャラリー": when this gallery is in it, its counts grow by what is added
  local total, already = #items, 0
  if known then
    already = tonumber(known.uploaded) or 0
    total = (tonumber(known.total) or already) + #items
    jobs.updateRecent(gallery.sid, { total = total, complete = false })
  end
  jobs.saveJob(gallery.sid, { pending = pending, used = existing.usedNames, rights = rightsMode })

  local notes = {}
  if videos > 0 then
    notes[#notes + 1] = string.format('動画 %d 本は送っていません（写真だけを送ります）。', videos)
  end

  local base = addto.base(existing, gallery.title)
  local status = sender.newStatus('書き出しと送信を始めます。')
  sender.start {
    apiKey = apiKey, sid = gallery.sid, title = base.title, keyColor = '', base = base, append = true,
    items = items, usedNames = existing.usedNames, status = status, total = total, alreadyUploaded = already,
    rightsMode = rightsMode,
    fast = options.fastMode and not choice.exportNow,
  }

  showResult(context, {
    title = base.title, count = #items, url = url, expireText = text.expireText(gallery.expiresAt, offset),
    skippedLine = plan.skipped > 0
      and string.format('%d 枚は、すでに入っているので送りませんでした。', plan.skipped) or '',
    note = table.concat(notes, '\n'),
  }, status)
end

LrTasks.startAsyncTask(function()
  LrFunctionContext.callWithContext('papatAddToGallery', run)
end)
