--[[
  PluginInfoProvider.lua — Plug-in Manager screen

  Sections: connection (API key, connection check, dashboard link), import options,
  version.

  This callback runs in a restricted context: it only builds the UI. Network calls
  happen in async tasks started by the buttons; xpcall is not available here, and
  only non-yielding code is wrapped in pcall.
]]

local LrColor = import 'LrColor'
local LrHttp = import 'LrHttp'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local config = dofile(_PLUGIN.path .. '/lib/config.lua')
local credentials = dofile(_PLUGIN.path .. '/lib/credentials.lua')
local text = dofile(_PLUGIN.path .. '/lib/text.lua')
local api = dofile(_PLUGIN.path .. '/lib/api.lua')
local location = dofile(_PLUGIN.path .. '/lib/location.lua')
local ui = dofile(_PLUGIN.path .. '/lib/ui.lua')
local log = dofile(_PLUGIN.path .. '/lib/log.lua')

local PluginInfoProvider = {}

local GREY = LrColor(0.45, 0.45, 0.45)
local RED = LrColor(0.75, 0.2, 0.1)

-- default: value shown when the preference was never set
local OPTIONS = {
  { key = 'applyPick', default = true, title = '採用した写真に 採用フラグ を付ける' },
  { key = 'applyMemo', default = true, title = 'メモ を 説明(Caption) の末尾に追記する' },
  { key = 'applyTags', default = true, title = 'タグ を キーワード に反映する' },
  { key = 'starCollections', default = false, title = '★ごとのサブコレクション（採用 / ★3 / ★2 / ★1）も作る' },
}

-- Sending options (not import options)
local SEND_OPTIONS = {
  { key = 'showRating', default = true,
    title = '撮影者の★（Lightroom のレーティング）をギャラリーに表示する' },
  { key = 'embedRights', default = true,
    title = '画像に、著作権情報・作成者・連絡先（Lightroom に登録したもの）を入れる' },
  { key = 'fastMode', default = false,
    title = '速さ優先（書き出しの代わりに Lightroom のプレビューから送る・実験的）' },
}

local function refreshKeyStatus(props)
  local key = credentials.get()
  if key ~= '' then
    props.keyStatus = 'API キー: 設定済み（' .. text.maskKey(key) .. '）'
  else
    props.keyStatus = 'API キー: 未設定'
  end
end

local function bindPrefs(props)
  local prefs = config.prefs()
  local all = {}
  for _, opt in ipairs(OPTIONS) do all[#all + 1] = opt end
  for _, opt in ipairs(SEND_OPTIONS) do all[#all + 1] = opt end
  for _, opt in ipairs(all) do
    if prefs[opt.key] == nil then
      props[opt.key] = opt.default
    else
      props[opt.key] = prefs[opt.key] == true
    end
  end

  if not props._papatObserversInstalled then
    props._papatObserversInstalled = true
    for _, opt in ipairs(all) do
      local key = opt.key
      props:addObserver(key, function()
        prefs[key] = props[key] == true
        log.info('preference changed: %s=%s', key, tostring(prefs[key]))
      end)
    end
  end
end

local function checkConnection(props)
  LrTasks.startAsyncTask(function()
    local key = credentials.get()
    if key == '' then
      props.connectionText = 'API キーが未設定です。キーを貼り付けて「保存」を押してから、もう一度お試しください。'
      props.connectionOk = false
      return
    end

    props.checking = true
    props.connectionText = '確認しています…'
    local res = api.status(key)
    props.checking = false

    if not res.ok then
      props.connectionText = res.message
      props.connectionOk = false
      return
    end

    local data = res.data
    local who = data.display_name or data.tenant_id or ''
    local lines = { '接続できました。' .. (who ~= '' and ('アカウント: ' .. who) or '') }

    local client = type(data.client) == 'table' and data.client or nil
    if client then
      -- same decision as the menu commands: "required" only when the server's minimum is
      -- above this version and below the latest one (or says so explicitly)
      local decision = text.updateDecision(config.VERSION, {
        minimum = client.minimum_version, latest = client.latest_version,
        available = client.update_available == true, required = client.update_required == true,
      })
      if decision == 'required' then
        lines[#lines + 1] = 'このプラグイン（v' .. config.VERSION .. '）は古いため、更新が必要です。'
          .. ' ' .. config.HELP_URL
      elseif decision == 'optional' then
        lines[#lines + 1] = '新しいバージョン（v' .. tostring(client.latest_version or '') .. '）があります。'
          .. ' ' .. config.HELP_URL
      end
    end
    props.connectionText = table.concat(lines, '\n')
    props.connectionOk = true
  end)
end

local function saveKey(props)
  local key = text.trimKey(props.apiKeyInput)
  if key == '' then
    props.connectionText = 'API キーを貼り付けてから「保存」を押してください。'
    props.connectionOk = false
    return
  end
  if not text.looksLikeApiKey(key) then
    props.connectionText = 'API キーの形式が正しくありません。papat のダッシュボードで発行した「sk_live_」で始まるキーを、前後に空白を入れずに貼り付けてください。'
    props.connectionOk = false
    return
  end
  if credentials.set(key) then
    props.apiKeyInput = ''
    refreshKeyStatus(props)
    props.connectionText = '保存しました。「接続を確認」を押して、つながるか確かめてください。'
    props.connectionOk = true
    log.info('api key saved')
  else
    props.connectionText = 'API キーを保存できませんでした。Lightroom Classic を再起動してから、もう一度お試しください。'
    props.connectionOk = false
  end
end

local function removeKey(props)
  credentials.clear()
  props.apiKeyInput = ''
  refreshKeyStatus(props)
  props.connectionText = 'API キーを削除しました。'
  props.connectionOk = true
  log.info('api key removed')
end

local function refreshLocation(props)
  local st = location.status()
  props.locationText = ui.locationText(st)
  props.locationOneLine = st.standard and ui.locationText(st) or ''
  props.locationStandard = st.standard
  props.locationWarn = not st.standard
end

local function copyToStandardLocation(props)
  LrTasks.startAsyncTask(function()
    ui.offerCopyToStandardLocation()
    refreshLocation(props)
  end)
end

local function buildSections(f, props)
  bindPrefs(props)
  refreshKeyStatus(props)
  props.apiKeyInput = props.apiKeyInput or ''
  props.connectionText = props.connectionText or ''
  props.connectionOk = props.connectionOk ~= false
  props.checking = false
  refreshLocation(props)

  local function bind(key)
    return LrView.bind { key = key, bind_to_object = props }
  end

  local optionRows = {}
  for _, opt in ipairs(OPTIONS) do
    optionRows[#optionRows + 1] = f:checkbox {
      title = opt.title,
      value = bind(opt.key),
      checked_value = true,
      unchecked_value = false,
    }
  end

  local sendRows = {}
  for _, opt in ipairs(SEND_OPTIONS) do
    sendRows[#sendRows + 1] = f:checkbox {
      title = opt.title,
      value = bind(opt.key),
      checked_value = true,
      unchecked_value = false,
    }
  end

  -- height_in_lines follows the text: a fixed number cuts whatever wraps beyond it
  local sendIntro = 'ギャラリーの作成後、写真は裏で書き出しと送信を並行して進め、Lightroom で他の作業を続けられます。'
    .. '\n画像には、Lightroom に登録した著作権情報・作成者・連絡先が入ります。'
    .. '位置情報、カメラのシリアル番号、現像設定は入りません。'
    .. '撮影者の★は、ギャラリーに「撮影者」として表示されます（クライアントが付ける★とは別です）。'
  local fastNote = '「速さ優先」は、書き出しを行わず、Lightroom が持っているプレビュー画像（長辺 2048px 前後）をそのまま送ります。'
    .. 'ずっと速くなりますが、画質・シャープネス・明るさが書き出しと少し違うことがあります。'
    .. '届く画像の大きさと画質は、カタログ設定の「標準プレビューサイズ」と「プレビュー画質」で変わります'
    .. '（長辺 2560px を超えるときは、自動で通常の書き出しにします）。'
    .. '現像を変えたあとは、プレビューが古いままのことがあります。'
    .. 'ライブラリ → プレビュー →「標準サイズのプレビューを作成」をしてから送ると確実です。'
    .. '色や明るさを見て判断するクライアントに送る案件では、通常の書き出しをおすすめします。'
    .. 'プレビューが取得できない写真や、大きすぎるプレビューは、自動で通常の書き出しに切り替えます。'
    .. 'どちらの方法でも、位置情報・撮影情報・シリアル番号・現像設定は取り除き、'
    .. '著作権・作成者・連絡先（オンのとき）は画像に入れます。'

  local sendSection = {
    title = 'papat — アタリ送付',
    f:column {
      spacing = f:control_spacing(),
      f:static_text {
        title = sendIntro,
        width = 520,
        height_in_lines = text.linesFor(sendIntro, 520, 5),
      },
      f:column(sendRows),
      f:static_text {
        title = fastNote,
        text_color = GREY,
        width = 520,
        height_in_lines = text.linesFor(fastNote, 520, 10),
      },
    },
  }

  local locationSection = {
    title = 'papat — インストール場所',
    f:column {
      spacing = f:control_spacing(),
      f:static_text {
        title = bind('locationText'),
        text_color = LrView.bind {
          key = 'locationWarn', bind_to_object = props,
          transform = function(warn) return warn and RED or GREY end,
        },
        width = 520,
        -- the path can be long; bound text cannot grow, so leave room
        height_in_lines = text.linesFor(props.locationText or '', 520, 5),
      },
      f:row {
        f:push_button {
          title = '標準の場所にコピー…',
          enabled = LrView.bind {
            key = 'locationStandard', bind_to_object = props,
            transform = function(standard) return standard ~= true end,
          },
          action = function() copyToStandardLocation(props) end,
        },
        f:static_text {
          title = '標準の場所: ~/Library/Application Support/Adobe/Lightroom/Modules/',
          text_color = GREY,
        },
      },
    },
  }

  local keyNote = 'API キーは papat のダッシュボードで発行します。他の人に見せたり、チャットやメールに貼り付けたりしないでください。'
    .. 'キーは Lightroom のパスワード保管領域に保存され、この画面には末尾4文字だけが表示されます。'
  local importIntro = '「papat のセレクトを読み込む」は、クライアントが採用した写真をコレクション「papat 採用 〈ギャラリー名〉 〈日付〉」に追加します。'
    .. 'あわせて、下の項目を写真に反映するかどうかを選べます。'
  local importNote = '※ クライアントの★は、あなたのレーティングにも、カラーラベルにも書き込みません（カラーラベルには触れません）。'
    .. 'メモは、すでにある説明を残したまま、末尾に「— papat: 」から始まる行として追記します（同じギャラリーを読み込み直しても重複しません）。'
    .. 'タグはキーワード「papat」の下に作られ、書き出しには含まれません。'
    .. 'クライアントの★は、★ごとのサブコレクションで確認できます。'
  local helpNote = '困ったときは ' .. config.SUPPORT_MAIL .. ' へ。\nログ: ドキュメント/LrClassicLogs/papat-lightroom.log'

  local sections = {
    {
      title = 'papat — 接続',
      f:column {
        spacing = f:control_spacing(),

        f:static_text {
          title = bind('keyStatus'),
          width = 520,
        },

        f:row {
          f:static_text { title = 'API キー:', width = 70 },
          f:password_field {
            value = bind('apiKeyInput'),
            width = 340,
          },
          f:push_button {
            title = '保存',
            action = function() saveKey(props) end,
          },
          f:push_button {
            title = '削除',
            action = function() removeKey(props) end,
          },
        },

        f:row {
          f:push_button {
            title = '接続を確認',
            enabled = LrView.bind {
              key = 'checking', bind_to_object = props,
              transform = function(value) return value ~= true end,
            },
            action = function() checkConnection(props) end,
          },
          f:push_button {
            title = 'API キーを発行する（papat.app/app を開く）',
            action = function() LrHttp.openUrlInBrowser(config.DASHBOARD_URL) end,
          },
        },

        f:static_text {
          title = bind('connectionText'),
          text_color = LrView.bind {
            key = 'connectionOk', bind_to_object = props,
            transform = function(ok) return ok == false and RED or GREY end,
          },
          width = 520,
          height_in_lines = 4,
        },

        f:static_text {
          title = keyNote,
          text_color = GREY,
          width = 520,
          height_in_lines = text.linesFor(keyNote, 520, 3),
        },
      },
    },

    {
      title = 'papat — セレクト受け取り 反映設定',
      f:column {
        spacing = f:control_spacing(),

        f:static_text {
          title = importIntro,
          width = 520,
          height_in_lines = text.linesFor(importIntro, 520, 2),
        },

        f:column(optionRows),

        f:static_text {
          title = importNote,
          text_color = GREY,
          width = 520,
          height_in_lines = text.linesFor(importNote, 520, 5),
        },
      },
    },

    {
      title = 'papat — バージョン',
      f:column {
        spacing = f:control_spacing(),
        f:static_text {
          title = 'papat for Lightroom Classic  v' .. config.VERSION .. '（macOS）',
          width = 520,
        },
        f:static_text {
          title = bind('locationOneLine'),
          text_color = GREY,
          width = 520,
        },
        f:push_button {
          title = '使い方を開く',
          action = function() LrHttp.openUrlInBrowser(config.HELP_URL) end,
        },
        f:static_text {
          title = helpNote,
          text_color = GREY,
          width = 520,
          height_in_lines = text.linesFor(helpNote, 520, 2),
        },
      },
    },
  }

  -- order follows the work: connect, send (アタリ送付), receive (セレクト受け取り), about
  table.insert(sections, 2, sendSection)

  -- Loaded from the standard Modules folder: no warning, no button, one line above.
  if props.locationWarn then
    table.insert(sections, 1, locationSection)
  end
  return sections
end

function PluginInfoProvider.sectionsForTopOfDialog(f, props)
  local ok, sections = pcall(buildSections, f, props)
  if ok then return sections end
  log.error('sectionsForTopOfDialog failed: %s', tostring(sections))
  local failedText = '設定画面を表示できませんでした。Lightroom Classic を再起動してください。'
    .. '改善しない場合は ' .. config.SUPPORT_MAIL .. ' までご連絡ください。'
  return {
    {
      title = 'papat',
      f:static_text {
        title = failedText,
        width = 520,
        height_in_lines = text.linesFor(failedText, 520, 2),
      },
    },
  }
end

return PluginInfoProvider
