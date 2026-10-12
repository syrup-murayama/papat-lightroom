--[[
  lib/ids.lua — random identifiers (UUID, passcode)

  Lua 5.1 in Lightroom has no secure RNG. Entropy is gathered from the clock, the
  process clock, table addresses and math.random, then run through SHA-256. That is
  good enough to make IDs unique and passcodes non-sequential; passcodes are also
  rate-limited server-side and editable by the photographer.
]]

local LrDate = import 'LrDate'

local sha256 = dofile(_PLUGIN.path .. '/lib/sha256.lua')

local M = {}

math.randomseed(os.time() + math.floor(os.clock() * 1000000))

local counter = 0

local function entropyHex()
  counter = counter + 1
  return sha256.hex(table.concat({
    tostring(LrDate.currentTime()),
    tostring(os.clock()),
    tostring(os.time()),
    tostring({}),
    tostring(math.random()),
    tostring(math.random(1, 2147483647)),
    tostring(counter),
  }, '|'))
end

function M.uuid()
  local h = entropyHex()
  local variant = ('89ab'):sub((tonumber(h:sub(17, 17), 16) % 4) + 1, (tonumber(h:sub(17, 17), 16) % 4) + 1)
  return h:sub(1, 8) .. '-' .. h:sub(9, 12) .. '-4' .. h:sub(14, 16) .. '-' .. variant .. h:sub(18, 20) .. '-' .. h:sub(21, 32)
end

-- No 0/O/1/I/L so it survives being read aloud or retyped. 32 symbols, matches the web UI.
local ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'

function M.passcode(length)
  length = length or 6
  local h = entropyHex()
  local out = {}
  for i = 1, length do
    local byte = tonumber(h:sub(i * 2 - 1, i * 2), 16)
    local idx = (byte % #ALPHABET) + 1
    out[i] = ALPHABET:sub(idx, idx)
  end
  return table.concat(out)
end

return M
