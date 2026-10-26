--[[
  ImportSelections.lua — Library menu: "papat のセレクトを読み込む…"

  Flow
    1. list galleries (API) -> pick one
    2. fetch the client's selection
    3. match to catalog photos: recorded source_id / sid first, then exact filename,
       then exact stem (never partial matches; ambiguous hits are reported, not applied)
    4. confirm (counts, unmatched list, what will be written)
    5. add the adopted photos to a collection

  Result: collection + pick flag + memo appended to the caption +
  tags as keywords, each switchable in the Plug-in Manager; star sub-collections are
  opt-in. The rating and the color label are never written.
]]

local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local function load(name) return dofile(_PLUGIN.path .. '/lib/' .. name .. '.lua') end
local config = load('config')
local text = load('text')
local api = load('api')
local selections = load('selections')
local matching = load('matching')
local catalogLib = load('catalog')
local ui = load('ui')
local update = load('update')
local log = load('log')

local f = LrView.osFactory()

-- ---------------------------------------------------------------------------
-- Gallery picker
-- ---------------------------------------------------------------------------

local function activeGalleries(list)
  local now = os.time()
  local out = {}
  for _, g in ipairs(list) do
    if type(g) == 'table' and type(g.sid) == 'string' and g.sid ~= '' then
      local status = g.status
      local expires = text.isoToEpoch(g.expires_at)
      local live = (status == nil or status == 'active') and not (expires and expires < now)
      if live then out[#out + 1] = g end
    end
  end
  return out
end

local function galleryLabel(g, offset)
  local title = (type(g.title) == 'string' and g.title ~= '') and g.title or ('（無題）' .. g.sid:sub(-4))
  local parts = {}
  local y, m, d = text.isoToLocalDate(g.expires_at, offset)
  if y then parts[#parts + 1] = string.format('%d/%d まで', m, d) end
  if tonumber(g.photos) then parts[#parts + 1] = string.format('%d 枚', tonumber(g.photos)) end
  if #parts == 0 then return title end
  return title .. '  （' .. table.concat(parts, '・') .. '）'
end

local function pickGallery(context, galleries)
  local offset = ui.localOffset()
  local items = {}
  for i, g in ipairs(galleries) do
    items[#items + 1] = { title = galleryLabel(g, offset), value = i }
  end

  local props = LrBinding.makePropertyTable(context)
  props.index = 1
  local pickIntro = '読み込むギャラリーを選んでください。クライアントが「確定」を押していれば、最終の結果が届いています。'

  local result = LrDialogs.presentModalDialog {
    title = 'papat のセレクトを読み込む',
    contents = f:column {
      bind_to_object = props,
      spacing = f:control_spacing(),
      f:static_text {
        title = pickIntro,
        width = 480,
        height_in_lines = text.linesFor(pickIntro, 480, 2),
      },
      f:popup_menu {
        items = items,
        value = LrView.bind { key = 'index', bind_to_object = props },
        width = 480,
      },
    },
    actionVerb = '読み込む',
    cancelVerb = 'キャンセル',
  }
  if result ~= 'ok' then return nil end
  return galleries[props.index]
end

-- ---------------------------------------------------------------------------
-- Confirmation
-- ---------------------------------------------------------------------------

local function optionLines(settings)
  local out = {}
  if settings.starCollections then out[#out + 1] = '★ごとのサブコレクション（採用 / ★N）を作る' end
  if settings.applyPick then out[#out + 1] = '採用フラグを付ける' end
  if settings.applyMemo then out[#out + 1] = 'メモを説明(Caption)の末尾に追記する（すでにある説明は残す）' end
  if settings.applyTags then out[#out + 1] = 'タグをキーワード「papat」の下に追加する' end
  return out
end

local function confirm(summaryText)
  return LrDialogs.presentModalDialog {
    title = 'papat のセレクトを読み込む',
    contents = f:column {
      spacing = f:control_spacing(),
      f:scrolled_view {
        horizontal_scroller = false,
        width = 560,
        height = 320,
        f:static_text {
          title = summaryText,
          width = 540,
          -- long lists scroll; the text box must be as tall as the text or its end is cut off
          height_in_lines = text.linesFor(summaryText, 540, 18),
        },
      },
    },
    actionVerb = 'コレクションに追加',
    cancelVerb = 'キャンセル',
    resizable = true,
  }
end

local function labels(list, pick)
  local out = {}
  for _, entry in ipairs(list) do out[#out + 1] = selections.label(pick(entry)) end
  return out
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
  local settings = config.settings()

  -- 1. galleries
  local progress = LrProgressScope { title = 'papat のセレクトを読み込んでいます', functionContext = context }
  progress:setIndeterminate()
  progress:setCaption('ギャラリーの一覧を取得しています…')
  local listRes = api.listGalleries(apiKey)
  progress:done()
  if not listRes.ok then
    ui.showApiError('ギャラリーの一覧を取得できませんでした', listRes)
    return
  end

  local galleries = activeGalleries(listRes.galleries)
  if #galleries == 0 then
    LrDialogs.message(
      '読み込めるギャラリーがありません',
      '公開中のギャラリーが見つかりませんでした。「papat でギャラリーを作る…」で作成すると、ここに表示されます。',
      'info'
    )
    return
  end

  local gallery = pickGallery(context, galleries)
  if not gallery then return end
  local sid = gallery.sid

  -- 2. selection
  progress = LrProgressScope { title = 'papat のセレクトを読み込んでいます', functionContext = context }
  progress:setIndeterminate()
  progress:setCaption('セレクト結果を取得しています…')
  local selRes = api.getSelections(apiKey, sid)
  if not selRes.ok then
    progress:done()
    ui.showApiError('セレクト結果を取得できませんでした', selRes)
    return
  end
  local selection, parseErr = selections.normalize(selRes.data)
  if not selection then
    progress:done()
    LrDialogs.message('セレクト結果を読み込めませんでした', parseErr .. ' プラグインを最新版に更新してください。', 'critical')
    return
  end
  if #selection.items == 0 then
    progress:done()
    LrDialogs.message(
      'まだ採用された写真がありません',
      'クライアントが写真を選んで「確定」を押すと、結果が届きます。しばらくしてからもう一度お試しください。',
      'info'
    )
    return
  end

  -- 3. match
  progress:setCaption('写真を照合しています…')
  local linked = catalogLib.linkedCandidates(catalog)
  local result = matching.match(selection.items, sid, linked, function()
    progress:setCaption('カタログ全体を検索しています…')
    return catalogLib.allCandidates(catalog)
  end)
  progress:done()

  local unmatchedLabels = labels(result.unmatched, function(item) return item end)
  local ambiguousLabels = labels(result.ambiguous, function(entry) return entry.item end)
  log.info('import: sid=%s adopted=%d matched=%d unmatched=%d ambiguous=%d',
    sid, #selection.items, #result.matched, #result.unmatched, #result.ambiguous)

  -- 4. plan + confirm
  local offset = ui.localOffset()
  local y, m, d = text.isoToLocalDate(gallery.created_at, offset)
  if not y then y, m, d = text.isoToLocalDate(selection.finalizedAt, offset) end
  local dateText
  if y then
    dateText = text.isoDate(y, m, d)
  else
    dateText = os.date('%Y-%m-%d')
  end
  local title = text.cleanTitle(
    (type(gallery.title) == 'string' and gallery.title ~= '') and gallery.title or selection.title, 60
  )
  local plan = matching.collectionPlan(result.matched, title, dateText, settings.starCollections)

  local names = {}
  for _, entry in ipairs(plan) do
    names[#names + 1] = entry.set and (entry.set .. ' / ' .. entry.name) or entry.name
  end

  if #result.matched == 0 then
    LrDialogs.message(
      '一致する写真が見つかりませんでした',
      text.importSummary {
        adopted = #selection.items, matched = 0, collectionNames = {}, options = {},
        unmatched = unmatchedLabels, ambiguous = ambiguousLabels, limit = 12,
      } .. '\n\nギャラリーを作った Lightroom のカタログを開いているか、ファイル名が変わっていないかを確認してください。',
      'info'
    )
    return
  end

  local summaryText = text.importSummary {
    adopted = #selection.items,
    matched = #result.matched,
    collectionNames = names,
    options = optionLines(settings),
    unmatched = unmatchedLabels,
    ambiguous = ambiguousLabels,
    limit = 40,
  }
  if confirm(summaryText) ~= 'ok' then return end

  -- 5. apply
  local status, summary = catalogLib.apply(catalog, plan, result.matched, settings)
  if status ~= 'executed' then
    LrDialogs.message(
      '反映できませんでした',
      'カタログが他の処理で使用中のため、反映できませんでした。少し待ってから、もう一度お試しください。',
      'critical'
    )
    return
  end

  local done = { string.format('%d 枚をコレクションに追加しました。', #result.matched) }
  for _, name in ipairs(names) do done[#done + 1] = '  ・' .. name end
  if settings.applyPick then
    done[#done + 1] = string.format('採用フラグ: %d 枚', summary.picked)
    if summary.pickFailed > 0 then
      done[#done + 1] = string.format('  （%d 枚は採用フラグを付けられませんでした）', summary.pickFailed)
    end
  end
  if settings.applyMemo then
    done[#done + 1] = string.format('メモを説明に追記: %d 枚', summary.captioned)
    if summary.captionFailed > 0 then
      done[#done + 1] = string.format('  （%d 枚は説明にメモを追記できませんでした）', summary.captionFailed)
    end
  end
  if settings.applyTags then
    done[#done + 1] = string.format('タグをキーワードに追加: %d 枚', summary.keyworded)
    if summary.tagFailed > 0 then
      done[#done + 1] = string.format('  （%d 枚はタグを追加できませんでした）', summary.tagFailed)
    end
  end
  -- an option that is switched off in the Plug-in Manager is said so, instead of silently doing nothing
  local off = {}
  if not settings.applyPick then off[#off + 1] = '採用フラグ' end
  if not settings.applyMemo then off[#off + 1] = 'メモ' end
  if not settings.applyTags then off[#off + 1] = 'タグ' end
  if #off > 0 then
    done[#done + 1] = string.format(
      '設定で OFF のため反映していません: %s（プラグインマネージャーの「セレクト受け取り 反映設定」で変えられます）',
      table.concat(off, '・')
    )
  end
  if #result.unmatched + #result.ambiguous > 0 then
    done[#done + 1] = string.format(
      '反映しなかった写真: %d 枚（見つからない %d・複数一致 %d）',
      #result.unmatched + #result.ambiguous, #result.unmatched, #result.ambiguous
    )
  end
  LrDialogs.message('セレクトを読み込みました', table.concat(done, '\n'), 'info')
end

LrTasks.startAsyncTask(function()
  LrFunctionContext.callWithContext('papatImportSelections', run)
end)
