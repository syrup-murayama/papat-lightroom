--[[
  lib/icc.lua — an sRGB ICC profile, generated (pure Lua, no Lightroom modules)

  The JPEG that speed-first mode gets from Lightroom has sRGB pixels but no profile.
  Browsers assume sRGB for untagged images; Photoshop and others assume their working space
  (often Adobe RGB), which would shift the colours of a downloaded file. A normal export embeds
  sRGB, so the preview gets the same tag. The profile is built from the published sRGB
  colorants (Bradford-adapted to D50) and the sRGB transfer curve: matrix/TRC, ICC v2.1,
  about 2.4 KB.
]]

local M = {}

local floor = math.floor

local function u32(n)
  return string.char(floor(n / 16777216) % 256, floor(n / 65536) % 256, floor(n / 256) % 256, n % 256)
end
local function u16(n)
  return string.char(floor(n / 256) % 256, n % 256)
end
local function s15(v)
  local n = floor(v * 65536 + 0.5)
  if n < 0 then n = n + 4294967296 end
  return u32(n)
end

local function pad4(s)
  local r = #s % 4
  if r == 0 then return s end
  return s .. string.rep('\0', 4 - r)
end

local function xyz(x, y, z)
  return 'XYZ ' .. u32(0) .. s15(x) .. s15(y) .. s15(z)
end

-- D50 white point as ICC stores it (s15Fixed16: 0.9642, 1.0, 0.8249)
local D50 = u32(0x0000F6D6) .. u32(0x00010000) .. u32(0x0000D32D)

local function textDescription(s)
  return 'desc' .. u32(0) .. u32(#s + 1) .. s .. '\0'
    .. u32(0) .. u32(0)                      -- Unicode: language, count
    .. u16(0) .. '\0' .. string.rep('\0', 67) -- ScriptCode: code, count, 67 bytes
end

local function plainText(s)
  return 'text' .. u32(0) .. s .. '\0'
end

local function srgbCurve()
  local parts = { 'curv', u32(0), u32(1024) }
  for i = 0, 1023 do
    local x = i / 1023
    local y
    if x <= 0.04045 then y = x / 12.92 else y = ((x + 0.055) / 1.055) ^ 2.4 end
    parts[#parts + 1] = u16(floor(y * 65535 + 0.5))
  end
  return table.concat(parts)
end

local cached

--- @return string the profile bytes
function M.srgb()
  if cached then return cached end

  local curve = srgbCurve()
  local tags = {
    { 'desc', textDescription('sRGB IEC61966-2.1 (papat)') },
    { 'cprt', plainText('No copyright, use freely') },
    { 'wtpt', 'XYZ ' .. u32(0) .. D50 },
    { 'rXYZ', xyz(0.4360747, 0.2225045, 0.0139322) },
    { 'gXYZ', xyz(0.3850649, 0.7168786, 0.0971045) },
    { 'bXYZ', xyz(0.1430804, 0.0606169, 0.7141733) },
    { 'rTRC', curve },
    { 'gTRC', false }, -- same data as rTRC
    { 'bTRC', false },
  }

  local count = #tags
  local offset = 128 + 4 + count * 12
  local table_, data = { u32(count) }, {}
  local trcOffset, trcSize
  for _, tag in ipairs(tags) do
    local sig, body = tag[1], tag[2]
    local size
    if body then
      size = #body
      table_[#table_ + 1] = sig .. u32(offset) .. u32(size)
      local padded = pad4(body)
      data[#data + 1] = padded
      if sig == 'rTRC' then trcOffset, trcSize = offset, size end
      offset = offset + #padded
    else
      table_[#table_ + 1] = sig .. u32(trcOffset) .. u32(trcSize)
    end
  end

  local total = offset
  local header = table.concat({
    u32(total),            -- profile size
    u32(0),                -- preferred CMM
    u32(0x02100000),       -- version 2.1.0
    'mntr', 'RGB ', 'XYZ ',
    u16(2024), u16(1), u16(1), u16(0), u16(0), u16(0), -- creation date
    'acsp',
    u32(0), u32(0),        -- platform, flags
    u32(0), u32(0),        -- manufacturer, model
    u32(0), u32(0),        -- attributes
    u32(0),                -- rendering intent: perceptual
    D50,                   -- illuminant
    u32(0),                -- creator
    string.rep('\0', 16),  -- profile id
    string.rep('\0', 28),  -- reserved
  })

  cached = header .. table.concat(table_) .. table.concat(data)
  return cached
end

return M
