--[[
  lib/sha256.lua — pure Lua 5.1 SHA-256 (no bit library, no LrC modules)

  The papat API expects passcode_hash = lowercase hex SHA-256 of the passcode.
  Inputs are short, so a straightforward arithmetic implementation is plenty.
]]

local M = {}

local floor = math.floor
local MOD = 4294967296

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function bitop(a, b, op)
  local r, p = 0, 1
  for _ = 1, 32 do
    local x, y = a % 2, b % 2
    if op(x, y) then r = r + p end
    a = (a - x) / 2
    b = (b - y) / 2
    p = p * 2
  end
  return r
end

local function xorBit(x, y) return x ~= y end
local function andBit(x, y) return x == 1 and y == 1 end

local function bxor(a, b) return bitop(a, b, xorBit) end
local function band(a, b) return bitop(a, b, andBit) end
local function bnot(a) return MOD - 1 - a end

local function rshift(a, n) return floor(a / 2 ^ n) end
local function rrotate(a, n) return floor(a / 2 ^ n) + (a % 2 ^ n) * 2 ^ (32 - n) end

local function hex8(n)
  local digits = '0123456789abcdef'
  local out = {}
  for i = 8, 1, -1 do
    local d = n % 16
    out[i] = digits:sub(d + 1, d + 1)
    n = floor(n / 16)
  end
  return table.concat(out)
end

local function pad(msg)
  local len = #msg
  local bits = len * 8
  local zeros = (55 - len) % 64
  local hi = floor(bits / MOD)
  local lo = bits % MOD
  local function be32(n)
    return string.char(
      floor(n / 16777216) % 256,
      floor(n / 65536) % 256,
      floor(n / 256) % 256,
      n % 256
    )
  end
  return msg .. '\128' .. string.rep('\0', zeros) .. be32(hi) .. be32(lo)
end

--- SHA-256 of a byte string, returned as 64 lowercase hex chars.
function M.hex(msg)
  msg = pad(tostring(msg))
  local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
  local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

  for chunk = 1, #msg, 64 do
    local w = {}
    for i = 0, 15 do
      local b1, b2, b3, b4 = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
      w[i] = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
    end
    for i = 16, 63 do
      local a, b = w[i - 15], w[i - 2]
      local s0 = bxor(bxor(rrotate(a, 7), rrotate(a, 18)), rshift(a, 3))
      local s1 = bxor(bxor(rrotate(b, 17), rrotate(b, 19)), rshift(b, 10))
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % MOD
    end

    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for i = 0, 63 do
      local S1 = bxor(bxor(rrotate(e, 6), rrotate(e, 11)), rrotate(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local t1 = (h + S1 + ch + K[i + 1] + w[i]) % MOD
      local S0 = bxor(bxor(rrotate(a, 2), rrotate(a, 13)), rrotate(a, 22))
      local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
      local t2 = (S0 + maj) % MOD
      h = g
      g = f
      f = e
      e = (d + t1) % MOD
      d = c
      c = b
      b = a
      a = (t1 + t2) % MOD
    end

    h0 = (h0 + a) % MOD
    h1 = (h1 + b) % MOD
    h2 = (h2 + c) % MOD
    h3 = (h3 + d) % MOD
    h4 = (h4 + e) % MOD
    h5 = (h5 + f) % MOD
    h6 = (h6 + g) % MOD
    h7 = (h7 + h) % MOD
  end

  return hex8(h0) .. hex8(h1) .. hex8(h2) .. hex8(h3) .. hex8(h4) .. hex8(h5) .. hex8(h6) .. hex8(h7)
end

return M
