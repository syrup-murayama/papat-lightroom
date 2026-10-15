--[[
  lib/sender.lua — start the background send of one gallery and report the outcome

  The caller (gallery creation, or "続きから送る") has already created the gallery.
  start() returns immediately; the work runs in its own task with a Lightroom progress
  indicator (top-left, cancellable), so the photographer keeps working. A `status`
  object lets a dialog show live progress.
]]

local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'

local function load(name) return dofile(_PLUGIN.path .. '/lib/' .. name .. '.lua') end
local config = load('config')
local text = load('text')
local api = load('api')
local pipeline = load('pipeline')
local jobs = load('jobs')
local ui = load('ui')
local log = load('log')

local M = {}

--- A tiny observable: set() stores the text and mirrors it into the property table of
--- an open dialog (`props`), if any.
function M.newStatus(initial)
  local status = { text = initial or '', note = '', props = nil }
  function status:set(textLine, note)
    self.text = textLine or self.text
    if note ~= nil then self.note = note end
    if self.props then
      self.props.statusText = self.text
      self.props.note = self.note
    end
  end
  return status
end

local function describeOutcome(result, total, previouslyUploaded)
  local lines = {}
  local sent = previouslyUploaded + result.uploaded
  if result.fatal then
    lines[#lines + 1] = string.format('送信を中止しました（%d / %d 枚を送信済み）。', sent, total)
  elseif result.busyStop then
    lines[#lines + 1] = string.format(
      '送信をいったん止めました（%d / %d 枚を送信済み）。サーバーが混み合っています。'
        .. '少し待って、「最近のギャラリー」→「続きから送る」を押してください。', sent, total)
  elseif result.canceled then
    lines[#lines + 1] = string.format('送信を中止しました（%d / %d 枚を送信済み）。「最近のギャラリー」から続きを送れます。', sent, total)
  elseif #result.failedUpload + #result.failedRender > 0 then
    lines[#lines + 1] = string.format('%d / %d 枚を送信しました。', sent, total)
  else
    lines[#lines + 1] = string.format('送信が完了しました（%d 枚）。', sent)
  end
  lines[#lines + 1] = pipeline.timingText(result.timings)
  return table.concat(lines, '\n')
end

--- One gallery's send, inside a caller-supplied functionContext (M.startMany loops this over
--- several galleries, one after another, in the one background task; M.start is the n=1 case).
--- @param a table
---   apiKey, sid, title, keyColor, items = { {photo, sourceId}, ... }, usedNames,
---   status (from newStatus), alreadyUploaded (resume), total (gallery size)
---   groupsNow (optional) forwarded to pipeline.run as-is (lib/similarity.lua's output table)
---   label (optional) "ギャラリー 1/2" — prefixed to the status line, progress title and the
---     per-gallery outcome dialogs (1.2.0's auto-split; omitted, nothing is prefixed)
local function sendOne(context, a)
  local prefix = a.label and (a.label .. ': ') or ''
  local settings = config.settings()
  -- a.fast (the create dialog's "export this time") wins over the stored preference
  local fast = settings.fastMode
  if a.fast ~= nil then fast = a.fast end
  local catalog = LrApplication.activeCatalog()
  local progress = LrProgressScope {
    title = prefix .. 'papat にギャラリーを送信しています', functionContext = context,
  }
  progress:setCancelable(true)

  local total = a.total or #a.items
  local already = a.alreadyUploaded or 0
  local mine = #a.items
  a.status:set(prefix .. '書き出しと送信を始めます。Lightroom で他の作業を続けられます。', '')

  local result = pipeline.run {
    apiKey = a.apiKey, sid = a.sid, title = a.title, keyColor = a.keyColor,
    catalog = catalog, rightsMode = a.rightsMode,
    items = a.items, usedNames = a.usedNames,
    concurrency = pipeline.DEFAULT_CONCURRENCY,
    fast = fast,
    thumbs = settings.thumbs,
    groupsNow = a.groupsNow,
    isCanceled = function() return progress:isCanceled() end,
    onStatus = function(s)
      progress:setCaption(string.format('papat: 書き出し %d ／ 送信 %d ／ 全 %d 枚', s.rendered, s.uploaded, mine))
      progress:setPortionComplete(s.rendered + s.uploaded, math.max(mine * 2, 1))
      if s.phase ~= 'done' then
        a.status:set(string.format('%s送信中… %d / %d 枚（書き出し済み %d 枚）', prefix, already + s.uploaded, total, s.rendered))
      end
    end,
    askRetry = function(count, sample)
      if count < 0 then
        local choice = LrDialogs.confirm(
          '写真の一覧を登録できませんでした',
          (sample and sample.message or '') .. '\n\n写真は送信済みです。もう一度登録しますか？',
          '再試行', '中止'
        )
        return choice == 'ok'
      end
      local choice = LrDialogs.confirm(
        string.format('%d 枚の送信に失敗しました', count),
        '通信が不安定だった可能性があります。失敗した写真だけをもう一度送りますか？\n\n例: '
          .. tostring(sample.filename) .. '\n' .. tostring(sample.message),
        '再送する', '失敗した写真を除いて続ける'
      )
      return choice == 'ok'
    end,
  }
  progress:done()

  -- Nothing could even be rendered: do not leave an empty gallery behind.
  local rendered = mine - #result.failedRender
  if result.uploaded == 0 and already == 0 and rendered <= 0 and not result.canceled and not result.fatal then
    api.deleteGallery(a.apiKey, a.sid)
    jobs.removeJob(a.sid)
    jobs.removeRecent(a.sid)
    a.status:set(prefix .. '写真を書き出せなかったため、ギャラリーを取り消しました。', '')
    LrDialogs.message(
      prefix .. '写真を送れませんでした',
      'どの写真も書き出せなかった（またはメタデータを取り除けなかった）ため、作成したギャラリーを取り消しました。'
        .. '写真ファイルが見つかるか（「？」マークが付いていないか）を確認して、もう一度お試しください。',
      'critical'
    )
    return
  end

  local sent = already + result.uploaded
  local summary = prefix .. describeOutcome(result, total, already)
  local noteParts = {}
  if #result.failedRender > 0 then
    noteParts[#noteParts + 1] = string.format('書き出せなかった写真が %d 枚あります。', #result.failedRender)
    local first = result.failedRender[1]
    if first and first.message and first.message ~= '' then
      -- one line: the box in the result window has a fixed height (the full text is in the log)
      local message = text.cleanTitle(tostring(first.message), 60)
      if #message < #tostring(first.message) then message = message .. '…' end
      noteParts[#noteParts + 1] = '例: ' .. message
    end
  end
  if #result.failedUpload > 0 and not result.busyStop then
    noteParts[#noteParts + 1] = string.format('送信できなかった写真が %d 枚あります。', #result.failedUpload)
  end
  if #noteParts > 0 then
    noteParts[#noteParts + 1] = '「最近のギャラリー」から続きを送れます。'
  end

  a.status:set(summary, table.concat(noteParts, '\n'))
  jobs.updateRecent(a.sid, { uploaded = sent, complete = (sent >= total), timing = pipeline.timingText(result.timings) })
  log.info('send finished: sid=%s sent=%d/%d', a.sid, sent, total)

  if result.fatal then
    local shown = {}
    for k, v in pairs(result.fatal) do shown[k] = v end
    if sent < total then
      shown.message = tostring(result.fatal.message or '')
        .. '\n\n送れていない写真は残してあります。原因を解消したあと、「最近のギャラリー」→「続きから送る」で続きを送れます。'
    end
    ui.showApiError(prefix .. '送信を中止しました', shown)
  elseif result.busyStop then
    LrDialogs.message(prefix .. 'papat: サーバーが混み合っています', summary
      .. '\n\n送れていない写真は残してあります。数分おいてから続きを送れます。', 'info')
  elseif #noteParts > 0 or result.canceled then
    LrDialogs.message(prefix .. 'papat: ' .. (result.canceled and '送信を中止しました' or '一部の写真を送れませんでした'),
      summary .. (#noteParts > 0 and ('\n\n' .. table.concat(noteParts, '\n')) or ''), 'info')
  else
    LrDialogs.showBezel(string.format('papat: %s%d 枚の送信が完了しました', prefix, sent), 4)
  end
end

--- Several galleries, sent one after another in one background task (1.2.0's auto-split: the
--- photographer confirms once, the galleries line up in "最近のギャラリー" as each finishes).
--- A failure in one (fatal, busyStop, canceled) does not stop the rest — each is its own
--- gallery, exactly as if it had been sent on its own; only the per-gallery dialog says so.
--- @param list table  array of M.start's own `a` shape; list[i].status may be the same object
---   for all of them (a single status line follows "whichever gallery is sending now")
function M.startMany(list)
  LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext('papatSend', function(context)
      LrDialogs.attachErrorDialogToFunctionContext(context)
      for _, a in ipairs(list) do
        sendOne(context, a)
      end
    end)
  end)
end

--- @param a table  see sendOne's own doc comment
function M.start(a)
  M.startMany({ a })
end

return M
