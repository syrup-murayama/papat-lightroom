--[[
  lib/log.lua — diagnostics

  Log file: <Documents>/LrClassicLogs/papat-lightroom.log
  API keys are masked on the way out; never pass passcodes or announcement text.
]]

local LrFileUtils = import 'LrFileUtils'
local LrLogger = import 'LrLogger'
local LrPathUtils = import 'LrPathUtils'

local LOG_DIR = LrPathUtils.child(LrPathUtils.getStandardFilePath('documents'), 'LrClassicLogs')
local LOG_FILE = LrPathUtils.child(LOG_DIR, 'papat-lightroom.log')

LrFileUtils.createAllDirectories(LOG_DIR)

local function redact(s)
  s = tostring(s)
  s = s:gsub('sk_live_[%w_%-]+', 'sk_live_***')
  s = s:gsub('Bearer%s+%S+', 'Bearer ***')
  return s
end

local function render(fmt, ...)
  if select('#', ...) == 0 then return redact(fmt) end
  local ok, msg = pcall(string.format, tostring(fmt), ...)
  if ok then return redact(msg) end
  return redact(fmt)
end

local function makeWriter(level)
  return function(msg)
    local f = io.open(LOG_FILE, 'a')
    if f then
      f:write(string.format('[%s] [%-5s] %s\n', os.date('%Y-%m-%d %H:%M:%S'), level, tostring(msg)))
      f:close()
    end
  end
end

local lrLogger = LrLogger('papat-lightroom')
lrLogger:enable({
  trace = makeWriter('TRACE'),
  debug = makeWriter('DEBUG'),
  info = makeWriter('INFO'),
  warn = makeWriter('WARN'),
  error = makeWriter('ERROR'),
  fatal = makeWriter('FATAL'),
})

local M = { logFile = LOG_FILE }

function M.debug(fmt, ...) lrLogger:debug(render(fmt, ...)) end
function M.info(fmt, ...) lrLogger:info(render(fmt, ...)) end
function M.warn(fmt, ...) lrLogger:warn(render(fmt, ...)) end
function M.error(fmt, ...) lrLogger:error(render(fmt, ...)) end

return M
