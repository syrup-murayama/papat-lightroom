--[[
  lib/ui.lua — dialogs shared by the menu commands
]]

local LrDialogs = import 'LrDialogs'
local LrHttp = import 'LrHttp'

local config = dofile(_PLUGIN.path .. '/lib/config.lua')
local credentials = dofile(_PLUGIN.path .. '/lib/credentials.lua')
local location = dofile(_PLUGIN.path .. '/lib/location.lua')

local M = {}

--- Local UTC offset in seconds (0 when it cannot be determined).
function M.localOffset()
  local ok, value = pcall(function()
    return os.time() - os.time(os.date('!*t'))
  end)
  if ok and type(value) == 'number' then return value end
  return 0
end

--- Returns the API key, or shows how to set one and returns nil.
function M.requireApiKey()
  local key = credentials.get()
  if key ~= '' then return key end
  local choice = LrDialogs.confirm(
    'API キーが設定されていません',
    '先に API キーを設定してください。\n\n'
      .. '1. papat のダッシュボード（' .. config.DASHBOARD_URL .. '）でキーを発行する\n'
      .. '2. Lightroom Classic の メニュー「ファイル」→「プラグインマネージャー」→「papat」を開き、キーを貼り付けて「保存」\n\n'
      .. 'キーは他の人に見せないでください。チャットやメールに貼り付けないでください。',
    'ダッシュボードを開く',
    '閉じる'
  )
  if choice == 'ok' then LrHttp.openUrlInBrowser(config.DASHBOARD_URL) end
  return nil
end

-- ---------------------------------------------------------------------------
-- Install location
-- ---------------------------------------------------------------------------

--- One-paragraph description of where the plug-in is loaded from.
function M.locationText(st)
  st = st or location.status()
  if st.standard then
    return '標準の場所にインストールされています。'
  end
  local lines = { '読み込み元: ' .. st.path }
  if st.downloads then
    lines[#lines + 1] = '注意: ダウンロードフォルダから読み込まれています。このフォルダを整理・削除すると、papat が使えなくなります。'
  else
    lines[#lines + 1] = 'このフォルダを移動・削除すると、papat が使えなくなります。'
  end
  lines[#lines + 1] = '「標準の場所にコピー」を押すと、移動・削除しても動くようになります。'
  return table.concat(lines, '\n')
end

local function installedMessage(result)
  local lines = {
    string.format('標準の場所にコピーしました（%d ファイル）。', result.count),
    '',
    '1. Lightroom Classic を再起動してください。',
    '2. 再起動後、プラグインマネージャーに papat が2つ並んでいたら、今の場所のほう（「読み込み元」で見分けられます）を「削除」してください。',
    '3. そのあとで、今の場所の papat.lrplugin は削除できます。',
  }
  if result.backup then
    lines[#lines + 1] = ''
    lines[#lines + 1] = '以前の papat は ' .. result.backup .. ' に退避しました。'
  end
  return table.concat(lines, '\n')
end

--- Ask, copy to the standard Modules folder, report. Yields (dialogs); call from a task.
--- @return boolean copied
function M.offerCopyToStandardLocation()
  local st = location.status()
  if st.standard then
    LrDialogs.message('標準の場所にあります', 'papat はすでに Lightroom の標準の場所から読み込まれています。', 'info')
    return false
  end

  local info = {
    '今の場所: ' .. st.path,
    '標準の場所: ' .. st.target,
    '',
    '標準の場所に置いたプラグインは、Lightroom の起動時に自動で読み込まれます。'
      .. 'コピーしたあと、今の場所のファイルを消しても動くようになります。',
  }
  if st.downloads then
    info[#info + 1] = ''
    info[#info + 1] = 'ダウンロードフォルダは、整理や自動削除で消えやすい場所です。'
  end

  local choice = LrDialogs.confirm(
    'papat を Lightroom の標準の場所にコピーしますか？',
    table.concat(info, '\n'),
    'コピーする',
    '今はしない'
  )
  if choice ~= 'ok' then return false end

  local result = location.install()
  if result.ok then
    LrDialogs.message('コピーしました', installedMessage(result), 'info')
    return true
  end
  LrDialogs.message(
    'コピーできませんでした',
    result.message .. '\n\n今の場所のまま使えます。手動で移す場合は、papat.lrplugin を ' .. st.modules .. ' に入れて、Lightroom を再起動してください。',
    'critical'
  )
  return false
end

--- Once per installation: offer the copy the first time a menu command runs from a
--- non-standard folder. The flag is stored before asking, so it never nags.
function M.offerStandardLocationOnce()
  local prefs = config.prefs()
  if prefs.locationPromptShown == true then return end
  local st = location.status()
  if st.standard then return end
  prefs.locationPromptShown = true
  M.offerCopyToStandardLocation()
end

-- ---------------------------------------------------------------------------
-- What goes into the images (copyright / creator / contact)
-- ---------------------------------------------------------------------------

local ACK_MAX = 10

local function loadAck()
  local raw = config.prefs().rightsAck
  if type(raw) ~= 'string' or raw == '' then return {} end
  local out = {}
  for h in raw:gmatch('[^,]+') do out[h] = true end
  return out
end

local function saveAck(hashes)
  local list = {}
  for h in pairs(hashes) do list[#list + 1] = h end
  table.sort(list)
  while #list > ACK_MAX do table.remove(list, 1) end
  config.prefs().rightsAck = table.concat(list, ',')
end

--- Show the copyright / creator / contact details that would be embedded and ask once per
--- distinct content (people sometimes keep a home address in the contact fields).
--- @param distinct table  from photoinfo.distinctRights
--- @return string 'embed' | 'none' | 'cancel'
function M.confirmRights(distinct, sha256, rights)
  if #distinct == 0 then return 'embed' end -- nothing registered: nothing to embed or to ask

  local ack = loadAck()
  local fresh = false
  local hashes = {}
  for _, d in ipairs(distinct) do
    local h = sha256.hex(d.signature):sub(1, 16)
    hashes[#hashes + 1] = h
    if not ack[h] then fresh = true end
  end
  if not fresh then return 'embed' end

  local lines = { '送る画像には、Lightroom に登録されている次の情報が入ります。', '' }
  for _, line in ipairs(rights.describe(distinct[1].fields)) do lines[#lines + 1] = '  ' .. line end
  if #distinct > 1 then
    lines[#lines + 1] = ''
    lines[#lines + 1] = string.format(
      '（写真によって内容が違い、あと %d 通りの組み合わせがあります。いちばん多いものを表示しています）', #distinct - 1)
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = '位置情報、カメラのシリアル番号、現像設定は入りません。住所や電話番号を登録している場合は、'
    .. 'クライアントがダウンロードした画像にも入ります。'
  lines[#lines + 1] = '設定（ファイル → プラグインマネージャー → papat）でオフにもできます。'

  local choice = LrDialogs.confirm(
    '画像に入れる情報の確認',
    table.concat(lines, '\n'),
    'この内容で送る',
    'キャンセル',
    '入れずに送る'
  )
  if choice == 'ok' then
    for _, h in ipairs(hashes) do ack[h] = true end
    saveAck(ack)
    return 'embed'
  elseif choice == 'other' then
    return 'none'
  end
  return 'cancel'
end

--- Show an API failure. Card / key / gallery-limit problems offer a shortcut to the dashboard.
function M.showApiError(headline, res)
  local billing = { monthly_limit = true, paid_country_blocked = true, billing_country_required = true }
  if res.needsCard or res.status == 401 or res.code == 'active_gallery_limit' or billing[res.code or ''] then
    local choice = LrDialogs.confirm(headline, res.message, 'ダッシュボードを開く', '閉じる')
    if choice == 'ok' then LrHttp.openUrlInBrowser(config.DASHBOARD_URL) end
    return
  end
  LrDialogs.message(headline, res.message, 'critical')
end

return M
