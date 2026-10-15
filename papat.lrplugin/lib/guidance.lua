--[[
  lib/guidance.lua — the dialog that shows a gallery's URL, passcode, expiry and the
  invitation text with copy buttons. Used right after creation (while the photos are
  still being sent) and from "最近のギャラリー".

  All values are bound properties, so the same dialog can switch between galleries
  and show live progress.
]]

local LrColor = import 'LrColor'
local LrHttp = import 'LrHttp'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local clipboard = dofile(_PLUGIN.path .. '/lib/clipboard.lua')
local config = dofile(_PLUGIN.path .. '/lib/config.lua')
local text = dofile(_PLUGIN.path .. '/lib/text.lua')
local editor = dofile(_PLUGIN.path .. '/lib/editor.lua')

local M = {}

M.STATUS_LINES = 6
M.NOTE_LINES = 4
M.GUIDANCE_VIEW_HEIGHT = 190 -- px of the text field's window; the field inside is taller and scrolls
M.GUIDANCE_FIELD_LINES = 40

local GREY = LrColor(0.45, 0.45, 0.45)
local RED = LrColor(0.75, 0.2, 0.1)

--- props must hold: url, passcode, expireText, guidance, copyStatus, statusText, note (and title, to
--- turn an edited text into the template)
--- @param extraRows table|nil  views inserted above the status line
function M.column(f, props, extraRows)
  local function bind(key) return LrView.bind { key = key, bind_to_object = props } end

  local function copy(label, key)
    LrTasks.startAsyncTask(function()
      if clipboard.copy(props[key]) then
        props.copyStatus = label .. 'をコピーしました。'
      else
        props.copyStatus = 'コピーできませんでした。下の欄を選択して、Cmd+C でコピーしてください。'
      end
    end)
  end

  -- The wording the photographer edited in the text field becomes next time's template: the URL,
  -- passcode and expiry date of this gallery go back to marks ({URL} {パスコード} {期限}).
  -- props.urls (1.2.0's auto-split: set only when there was more than one gallery this time)
  -- takes every one of them back to the single {URL} mark — never just the first, which would
  -- leave this client's 2nd+ gallery link sitting in the template for the next client to see.
  local function saveWording()
    local template = text.templateFromAnnouncement(props.guidance, {
      title = props.title, url = props.url, urls = props.urls, passcode = props.passcode, expireText = props.expireText,
    })
    config.prefs().announcementTemplate = template
    props.copyStatus = 'この文面を保存しました。次回から、この書き方になります。'
  end

  -- Return in an edit field presses the dialog's default button (SDK guide). While "editing" is on
  -- the button that closes the dialog is disabled (props.canClose, bound by the caller as the
  -- action button's `enabled`), so Return cannot close the window under the user's hands.
  props.editing = false
  props.canClose = true
  props:addObserver('editing', function() props.canClose = not props.editing end)

  local function openInEditor()
    LrTasks.startAsyncTask(function()
      local path = editor.open(props.guidance, 'announcement')
      if path then
        props.copyStatus = 'テキストエディタで開きました。保存してから「編集した内容を反映」を押してください。'
      else
        props.copyStatus = 'テキストエディタを開けませんでした。'
      end
    end)
  end
  local function readFromEditor()
    local data = editor.read('announcement')
    if data and text.trim(data) ~= '' then
      props.guidance = data
      props.copyStatus = '編集した内容を反映しました。'
    else
      props.copyStatus = '編集した内容を読み込めませんでした（保存されているか確かめてください）。'
    end
  end

  local children = {
    bind_to_object = props,
    spacing = f:control_spacing(),
    width = 560,
  }
  for _, row in ipairs(extraRows or {}) do children[#children + 1] = row end

  local rest = {
    f:row {
      f:static_text { title = 'URL', width = 80 },
      f:edit_field { value = bind('url'), width_in_chars = 44 },
    },
    f:row {
      f:static_text { title = 'パスコード', width = 80 },
      f:edit_field { value = bind('passcode'), width_in_chars = 16 },
    },
    f:row {
      f:static_text { title = '公開期限', width = 80 },
      f:static_text { title = bind('expireText') },
    },

    f:static_text { title = '案内文（クライアントに送る文面）', font = '<system/bold>' },
    -- a window onto a taller field: long texts scroll
    f:scrolled_view {
      horizontal_scroller = false,
      width = 560,
      height = M.GUIDANCE_VIEW_HEIGHT,
      f:edit_field {
        value = bind('guidance'),
        width_in_chars = 56,
        height_in_lines = M.GUIDANCE_FIELD_LINES,
        immediate = true,
      },
    },
    f:row {
      f:checkbox { title = '編集中（「閉じる」を止めて、Return で改行できるようにする）', value = bind('editing') },
    },
    f:row {
      f:push_button { title = 'テキストエディタで開く', action = openInEditor },
      f:push_button { title = '編集した内容を反映', action = readFromEditor },
    },

    f:row {
      f:push_button { title = '案内文をコピー', action = function() copy('案内文', 'guidance') end },
      f:push_button { title = 'URL をコピー', action = function() copy('URL', 'url') end },
      f:push_button { title = 'パスコードをコピー', action = function() copy('パスコード', 'passcode') end },
      f:push_button { title = 'ブラウザで開く', action = function() LrHttp.openUrlInBrowser(props.url) end },
    },
    f:row {
      f:push_button { title = 'この文面を、次回から使う', action = saveWording },
      f:static_text {
        title = 'URL・パスコード・期限は「印」にして保存されます',
        text_color = GREY,
      },
    },
    f:static_text { title = bind('copyStatus'), text_color = GREY, width = 560, height_in_lines = 1 },

    f:separator { width = 560 },
    -- Bound text cannot grow once the dialog is open, so these boxes are sized for the longest
    -- case (speed-first outcome with timing, hint and a busy stop; see tests/smoke.lua).
    f:static_text { title = bind('statusText'), width = 560, height_in_lines = M.STATUS_LINES },
    f:static_text { title = bind('note'), text_color = RED, width = 560, height_in_lines = M.NOTE_LINES },
  }
  for _, row in ipairs(rest) do children[#children + 1] = row end

  return f:column(children)
end

return M
