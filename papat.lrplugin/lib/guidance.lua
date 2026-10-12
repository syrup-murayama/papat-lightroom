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

local M = {}

M.STATUS_LINES = 6
M.NOTE_LINES = 4

local GREY = LrColor(0.45, 0.45, 0.45)
local RED = LrColor(0.75, 0.2, 0.1)

--- props must hold: url, passcode, expireText, guidance, copyStatus, statusText, note
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
    f:edit_field { value = bind('guidance'), width_in_chars = 56, height_in_lines = 9 },

    f:row {
      f:push_button { title = '案内文をコピー', action = function() copy('案内文', 'guidance') end },
      f:push_button { title = 'URL をコピー', action = function() copy('URL', 'url') end },
      f:push_button { title = 'パスコードをコピー', action = function() copy('パスコード', 'passcode') end },
      f:push_button { title = 'ブラウザで開く', action = function() LrHttp.openUrlInBrowser(props.url) end },
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
