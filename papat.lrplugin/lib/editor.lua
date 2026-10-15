--[[
  lib/editor.lua — edit a longer text in the macOS text editor

  Lightroom's edit_field has no way to type a line break inside a dialog: Return always presses the
  dialog's default button (SDK guide, "edit_field"). For the announcement text the plug-in therefore
  also offers the user's text editor: the text is written to a temporary .txt file, opened with
  `open -t` (the default text editor), and read back when the user presses "反映" after saving.
]]

local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

local M = {}

local function pathFor(name)
  return LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), 'papat-' .. tostring(name) .. '.txt')
end

local function quote(path)
  return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

--- Write `content` to the temporary file `name` and open it. Yields: call from a task.
--- @return string|nil path, string|nil why
function M.open(content, name)
  if WIN_ENV then return nil, 'unsupported' end
  local path = pathFor(name)
  local fh = io.open(path, 'wb')
  if not fh then return nil, 'write' end
  fh:write(tostring(content or ''))
  fh:close()
  local rc = LrTasks.execute('open -t ' .. quote(path))
  if rc ~= 0 then return nil, 'open' end
  return path
end

--- What the user saved (UTF-8, line ends as \n, no BOM), or nil when there is no file.
function M.read(name)
  local fh = io.open(pathFor(name), 'rb')
  if not fh then return nil end
  local data = fh:read('*a')
  fh:close()
  data = data:gsub('^\239\187\191', ''):gsub('\r\n', '\n'):gsub('\r', '\n')
  return data
end

return M
