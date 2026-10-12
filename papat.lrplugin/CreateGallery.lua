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
local jobs = load('jobs')
local sender = load('sender')
local photoinfo = load('photoinfo')
local rights = load('rights')
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


-- Messages shown under the form; the box is as tall as the longest one (PROBLEM_COLOR),
-- because bound text cannot grow once the dialog is open
local PROBLEM_COLOR = '色は #RRGGBB の形で入力してください（例 #0066CC）。空欄なら papat の標準色です。'
local function problemPasscodeLength()
  return string.format('パスコードは %d〜%d 文字で入力してください。', text.MIN_PASSCODE_LENGTH, text.MAX_PASSCODE_LENGTH)
end

local passcodeNote = 'パスコードはクライアントに伝える合言葉です。papat に暗号化して保存され、ダッシュボードでいつでも確認できます。'
  .. '色は任意で、空欄なら papat の標準色です。'

--- @return table|nil settings  { title, days, passcode } or nil when cancelled
local function askSettings(context, catalog, count, free)
  local props = LrBinding.makePropertyTable(context)
  props.title = defaultTitle(catalog)
  props.days = 7
  props.passcode = ids.passcode(6)
  props.priceText = text.priceLine(count, 7, free)
  props.problem = ''
  props.canSubmit = true

  -- Client color: optional, empty = papat's default. Remembers the last few.
  local prefs = config.prefs()
  local recent = text.recentColors(prefs.recentKeyColors)
  props.keyColor = ''
  props.recentPick = ''

  local function validate()
    local pass = text.trim(props.passcode)
    local problem = ''
    if #pass < text.MIN_PASSCODE_LENGTH or #pass > text.MAX_PASSCODE_LENGTH then
      problem = problemPasscodeLength()
    elseif pass:find('%s') then
      problem = 'パスコードに空白は使えません。'
    elseif text.normalizeKeyColor(props.keyColor) == nil then
      problem = PROBLEM_COLOR
    end
    props.problem = problem
    props.canSubmit = (problem == '')
    props.priceText = text.priceLine(count, props.days, free)
  end
  props:addObserver('passcode', validate)
  props:addObserver('days', validate)
  props:addObserver('keyColor', validate)
  props:addObserver('recentPick', function()
    if props.recentPick ~= '' then
      props.keyColor = props.recentPick
      props.recentPick = ''
    end
  end)

  local function bind(key) return LrView.bind { key = key, bind_to_object = props } end

  -- Essentials only (what is sent, what the images carry); details are in the plug-in
  -- manager and in the confirmation shown once. height_in_lines follows the text.
  local settings = config.settings()
  local introText = text.createIntro(count, {
    longEdge = config.EXPORT_LONG_EDGE,
    fast = settings.fastMode,
    embedRights = settings.embedRights,
  })

  -- One line: the color is optional and stays out of the way.
  local colorRow = {
    f:static_text { title = '色（任意）', width = 80 },
    f:edit_field { value = bind('keyColor'), width_in_chars = 10, immediate = true },
  }
  if #recent > 0 then
    local items = { { title = '最近使った色…', value = '' } }
    for _, c in ipairs(recent) do items[#items + 1] = { title = c, value = c } end
    colorRow[#colorRow + 1] = f:popup_menu { items = items, value = bind('recentPick'), width = 130 }
  end
  colorRow[#colorRow + 1] = f:static_text {
    title = '#RRGGBB',
    text_color = GREY,
  }

  local contents = f:column {
    bind_to_object = props,
    spacing = f:control_spacing(),
    width = 520,

    f:static_text {
      title = introText,
      width = 520,
      height_in_lines = text.linesFor(introText, 520, 2),
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

    f:row(colorRow),

    f:static_text {
      title = bind('problem'),
      text_color = RED,
      width = 520,
      height_in_lines = text.linesFor(PROBLEM_COLOR, 520, 1),
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
    keyColor = text.normalizeKeyColor(props.keyColor) or '',
  }
end

-- ---------------------------------------------------------------------------
-- Dialog 2: result (URL, passcode, invitation) while the photos are sent
-- ---------------------------------------------------------------------------

local function showResult(context, info, status)
  local props = LrBinding.makePropertyTable(context)
  props.url = info.url
  props.passcode = info.passcode
  props.expireText = info.expireText
  props.guidance = info.guidance
  props.copyStatus = ''
  props.statusText = status.text
  props.note = info.note or status.note or ''
  status.props = props

  local backgroundNote = '写真は裏で送っています。このウィンドウを閉じても、Lightroom で他の作業を続けられます。'
    .. 'パスコードは papat のダッシュボードでも確認できます。'
  local contents = guidance.column(f, props, {
    f:static_text {
      title = string.format('ギャラリーを作成しました（%d 枚）', info.count),
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
  if #selected > text.MAX_PHOTOS then
    LrDialogs.message(
      '写真が多すぎます',
      string.format('一度に送れるのは %d 枚までです（現在 %d 枚）。2回に分けて作成してください。', text.MAX_PHOTOS, #selected),
      'critical'
    )
    return
  end

  -- how many galleries are still free comes from the server (cached by the update check)
  local settings = askSettings(context, catalog, #selected, update.freeRemaining())
  if not settings then return end
  log.info('create gallery: photos=%d days=%d', #selected, settings.days)

  -- 0. what the images will say about their author (asked once per distinct content), the
  --    photographer's stars and the capture times: all read before anything is created
  local options = config.settings()
  local infos = photoinfo.gather(catalog, selected)
  local rightsMode = 'none'
  if options.embedRights then
    rightsMode = ui.confirmRights(photoinfo.distinctRights(selected, infos), sha256, rights)
    if rightsMode == 'cancel' then return end
  end

  -- 1. create the gallery first: the link is usable (and copyable) from now on
  local created = api.createGallery(apiKey, {
    title = settings.title,
    days = settings.days,
    passcodeHash = sha256.hex(settings.passcode),
    passcode = settings.passcode,
    keyColor = settings.keyColor ~= '' and settings.keyColor or nil,
    idempotencyKey = ids.uuid(),
  })
  if not created.ok then
    ui.showApiError('ギャラリーを作成できませんでした', created)
    return
  end

  local sid = tostring(created.data.sid or created.data.gallery_id or '')
  if sid == '' then
    LrDialogs.message('ギャラリーを作成できませんでした', 'papat から正しい応答が返りませんでした。しばらくしてから、もう一度お試しください。', 'critical')
    return
  end
  local sharePath = tostring(created.data.path or ('/t/' .. tostring(created.data.tenant_id or '') .. '/s/' .. sid))
  local url = config.BASE_URL .. sharePath:gsub('/+$', '') .. '/'
  log.info('gallery created: sid=%s', sid)
  update.rememberFree(created.data.free_galleries_remaining)

  if settings.keyColor ~= '' then
    config.prefs().recentKeyColors = text.rememberColor(config.prefs().recentKeyColors, settings.keyColor)
  end

  -- 2. what is shown now, and remembered for later ("最近のギャラリー")
  local expiresAt = tostring(created.data.expires_at or '')
  local y, m, d = text.isoToLocalDate(expiresAt, ui.localOffset())
  local expireText = y and (text.jaMonthDay(m, d) .. 'まで') or ''

  local notes = {}
  if videos > 0 then
    notes[#notes + 1] = string.format('動画 %d 本は送っていません（写真だけを送ります）。', videos)
  end
  local actualDays = text.daysUntil(expiresAt, os.time())
  if settings.days == 14 and actualDays and actualDays <= 8 then
    notes[#notes + 1] = '保存期間は 14 日ではなく ' .. tostring(actualDays) .. ' 日で作成されました。延長はダッシュボードで行えます。'
  end

  local invitation = text.announcement {
    title = settings.title, url = url, passcode = settings.passcode, expireText = expireText,
  }

  -- 3. the photos: source ids first (kept for the whole job), then send in the background
  local existingIds = catalogLib.sourceIds(catalog, selected)
  local items, pending = {}, {}
  for _, photo in ipairs(selected) do
    local sourceId = existingIds[photo] or ids.uuid()
    local info = infos[photo]
    items[#items + 1] = {
      photo = photo, sourceId = sourceId,
      datetime = info.datetime,
      rating = options.showRating and info.rating or 0,
      meta = (rightsMode == 'embed') and rights.segments(info.fields) or '',
    }
    pending[#pending + 1] = { uuid = photo:getRawMetadata('uuid'), sourceId = sourceId }
  end

  jobs.addRecent {
    sid = sid, title = settings.title, url = url, passcode = settings.passcode,
    expiresAt = expiresAt, createdAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    total = #items, uploaded = 0, keyColor = settings.keyColor, complete = false,
  }
  jobs.saveJob(sid, { pending = pending, used = {}, rights = rightsMode })

  local status = sender.newStatus('書き出しと送信を始めます。')
  sender.start {
    apiKey = apiKey, sid = sid, title = settings.title, keyColor = settings.keyColor,
    items = items, usedNames = {}, status = status, total = #items, alreadyUploaded = 0,
    rightsMode = rightsMode,
  }

  showResult(context, {
    count = #items, url = url, passcode = settings.passcode, expireText = expireText,
    guidance = invitation, note = table.concat(notes, '\n'),
  }, status)
end

LrTasks.startAsyncTask(function()
  LrFunctionContext.callWithContext('papatCreateGallery', run)
end)
