--[[
  RecentGalleries.lua — Library menu: "papat 最近のギャラリー…"

  The last galleries made from this Mac: URL, passcode, expiry and the invitation text
  (copy again any time), how many photos were sent, and "続きから送る" for a gallery
  whose upload was cancelled or failed part-way (the photos are found again in the
  catalog by their Lightroom uuid).
]]

local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local function load(name) return dofile(_PLUGIN.path .. '/lib/' .. name .. '.lua') end
local text = load('text')
local guidance = load('guidance')
local jobs = load('jobs')
local sender = load('sender')
local photoinfo = load('photoinfo')
local rights = load('rights')
local config = load('config')
local ui = load('ui')
local update = load('update')
local credentials = load('credentials')
local log = load('log')

local f = LrView.osFactory()

local function pendingCount(entry)
  local job = jobs.getJob(entry.sid)
  if job and type(job.pending) == 'table' then return #job.pending end
  return 0
end

local function label(entry, offset)
  local title = (type(entry.title) == 'string' and entry.title ~= '') and entry.title or '（無題）'
  local y, m, d = text.isoToLocalDate(entry.createdAt, offset)
  local when = y and string.format('%d/%d', m, d) or ''
  return when ~= '' and (title .. '  （' .. when .. ' 作成）') or title
end

local function statusLine(entry)
  local total = tonumber(entry.total) or 0
  local sent = tonumber(entry.uploaded) or 0
  local pending = pendingCount(entry)
  local line
  if pending > 0 then
    line = string.format('送信済み %d / %d 枚。残り %d 枚は未送信です（下の「続きから送る」で再開できます）。', sent, total, pending)
  else
    line = string.format('送信済み %d 枚（全 %d 枚）。', sent, total)
  end
  if type(entry.timing) == 'string' and entry.timing ~= '' then
    line = line .. '\n' .. entry.timing
  end
  local expires = text.isoToEpoch(entry.expiresAt)
  if expires and expires < os.time() then
    line = line .. '\n公開期限が過ぎています。'
  end
  return line
end

local function resume(entry)
  local apiKey = ui.requireApiKey()
  if not apiKey then return end

  local job = jobs.getJob(entry.sid)
  if not job or type(job.pending) ~= 'table' or #job.pending == 0 then
    LrDialogs.message('送り残しはありません', 'このギャラリーの写真はすべて送信済みです。', 'info')
    return
  end

  local catalog = LrApplication.activeCatalog()
  local items, missing = {}, 0
  for _, p in ipairs(job.pending) do
    local photo = p.uuid and catalog:findPhotoByUuid(p.uuid) or nil
    if photo then
      items[#items + 1] = { photo = photo, sourceId = p.sourceId }
    else
      missing = missing + 1
    end
  end

  if #items == 0 then
    LrDialogs.message(
      '続きを送れません',
      'このギャラリーの写真が、いま開いているカタログに見つかりません。'
        .. 'ギャラリーを作ったときの Lightroom カタログを開いて、もう一度お試しください。',
      'critical'
    )
    return
  end

  if missing > 0 then
    local choice = LrDialogs.confirm(
      string.format('%d 枚が見つかりません', missing),
      string.format('残り %d 枚のうち %d 枚はこのカタログに見つかりません。見つかった %d 枚だけを送りますか？',
        #job.pending, missing, #items),
      '送る', 'キャンセル'
    )
    if choice ~= 'ok' then return end
  end

  -- same choices as when the gallery was created (rights mode is kept in the job)
  local options = config.settings()
  local rightsMode = job.rights
  if rightsMode ~= 'embed' and rightsMode ~= 'none' then rightsMode = options.embedRights and 'embed' or 'none' end
  local photos = {}
  for _, item in ipairs(items) do photos[#photos + 1] = item.photo end
  local infos = photoinfo.gather(catalog, photos)
  for _, item in ipairs(items) do
    local info = infos[item.photo]
    item.datetime = info.datetime
    item.rating = options.showRating and info.rating or 0
    item.meta = (rightsMode == 'embed') and rights.segments(info.fields) or ''
  end

  log.info('resume: sid=%s items=%d missing=%d rights=%s', entry.sid, #items, missing, rightsMode)
  sender.start {
    apiKey = apiKey, sid = entry.sid, title = entry.title, keyColor = entry.keyColor or '',
    items = items, usedNames = job.used or {}, status = sender.newStatus('続きを送ります。'),
    total = tonumber(entry.total) or #items, alreadyUploaded = tonumber(entry.uploaded) or 0,
    rightsMode = rightsMode,
  }
  LrDialogs.showBezel(string.format('papat: 残り %d 枚の送信を始めました', #items), 3)
end

local function run(context)
  LrDialogs.attachErrorDialogToFunctionContext(context)

  -- Re-copying a URL must keep working: only tell, never stop.
  local key = credentials.get()
  if key ~= '' then update.checkAndTell(key, { blocking = false }) end

  local entries = jobs.loadRecent()
  if #entries == 0 then
    LrDialogs.message(
      'ギャラリーがまだありません',
      '「papat でギャラリーを作る…」で作成したギャラリーが、ここに最近のものから表示されます。',
      'info'
    )
    return
  end

  local offset = ui.localOffset()
  local items, anyPending = {}, false
  for i, entry in ipairs(entries) do
    items[#items + 1] = { title = label(entry, offset), value = i }
    if pendingCount(entry) > 0 then anyPending = true end
  end

  local props = LrBinding.makePropertyTable(context)
  props.index = 1

  local function refresh()
    local entry = entries[props.index] or entries[1]
    local expireText = text.expireText(entry.expiresAt, offset)
    props.url = entry.url or ''
    props.passcode = entry.passcode or ''
    props.expireText = expireText
    props.guidance = text.announcement {
      title = entry.title, url = entry.url or '', passcode = entry.passcode or '', expireText = expireText,
      template = config.prefs().announcementTemplate,
    }
    props.title = entry.title or ''
    props.copyStatus = ''
    props.statusText = statusLine(entry)
    props.note = ''
  end
  props:addObserver('index', refresh)
  refresh()

  local contents = guidance.column(f, props, {
    f:popup_menu {
      items = items,
      value = LrView.bind { key = 'index', bind_to_object = props },
      width = 560,
    },
  })

  local result = LrDialogs.presentModalDialog {
    title = 'papat 最近のギャラリー',
    contents = contents,
    actionVerb = '閉じる',
    actionBinding = { enabled = { bind_to_object = props, key = 'canClose' } },
    cancelVerb = '< exclude >',
    otherVerb = anyPending and '続きから送る' or nil,
  }

  if result == 'other' then
    resume(entries[props.index] or entries[1])
  end
end

LrTasks.startAsyncTask(function()
  LrFunctionContext.callWithContext('papatRecentGalleries', run)
end)
