--[[
  lib/credentials.lua — API key storage (LrPasswords; never LrPrefs, files or logs)
]]

local LrPasswords = import 'LrPasswords'

local config = dofile(_PLUGIN.path .. '/lib/config.lua')

local M = {}

local KEY_NAME = 'apiKey'
local SALT = config.PLUGIN_ID

--- @return string key ('' when unset)
function M.get()
  local ok, value = pcall(LrPasswords.retrieve, KEY_NAME, SALT, config.PLUGIN_ID)
  if ok and type(value) == 'string' then return value end
  return ''
end

function M.has()
  return M.get() ~= ''
end

--- @return boolean ok
function M.set(key)
  local ok = pcall(LrPasswords.store, KEY_NAME, key, SALT, config.PLUGIN_ID)
  return ok
end

function M.clear()
  return M.set('')
end

return M
