--[[
  lib/jpeg.lua — read a JPEG's header segments, report its size and drop metadata
  (pure Lua 5.1, no Lightroom modules, no file access)

  sanitize(bytes) rewrites the segment list and leaves the image data untouched. The caller
  then adds back only what it wants to say (lib/rights.lua: copyright, creator, contact info;
  lib/icc.lua: the sRGB profile) with withSegments():

    kept     SOI, DQT, DHT, SOF*, DRI, SOS … EOI (the picture itself),
             APP0 "JFIF", APP2 "ICC_PROFILE" (colour profile), APP14 "Adobe" (colour transform)
    dropped  APP1 (Exif, XMP, embedded thumbnail), APP13 (IPTC / Photoshop resources),
             COM, every other APPn (MPF, Ducky, FlashPix …), JFXX thumbnails

  Only the header is parsed (up to SOS); everything after it is copied byte for byte.
  Anything unexpected makes it return nil + a reason: callers must NOT upload the
  original in that case (it may still carry contact data) — see lib/pipeline.lua.
]]

local M = {}

local byte, sub, char = string.byte, string.sub, string.char

local function u16(s, i)
  return byte(s, i) * 256 + byte(s, i + 1)
end

local SOF_MARKERS = {}
for m = 0xC0, 0xCF do
  if m ~= 0xC4 and m ~= 0xC8 and m ~= 0xCC then SOF_MARKERS[m] = true end
end

--- What to do with an application / comment marker.
--- @return boolean keep, string label
local function classify(marker, payload)
  if marker == 0xE0 then
    if sub(payload, 1, 5) == 'JFIF\0' then return true, 'jfif' end
    return false, 'app0-other'
  elseif marker == 0xE1 then
    if sub(payload, 1, 6) == 'Exif\0\0' then return false, 'exif' end
    if sub(payload, 1, 29) == 'http://ns.adobe.com/xap/1.0/\0' then return false, 'xmp' end
    if sub(payload, 1, 35) == 'http://ns.adobe.com/xmp/extension/\0' then return false, 'xmp' end
    return false, 'app1-other'
  elseif marker == 0xE2 then
    if sub(payload, 1, 12) == 'ICC_PROFILE\0' then return true, 'icc' end
    return false, 'app2-other'
  elseif marker == 0xED then
    return false, 'iptc'
  elseif marker == 0xEE then
    if sub(payload, 1, 5) == 'Adobe' then return true, 'adobe' end
    return false, 'app14-other'
  elseif marker == 0xFE then
    return false, 'comment'
  elseif marker >= 0xE3 and marker <= 0xEF then
    return false, 'app-other'
  end
  return true, 'structure'
end

--- Walk the header segments.
--- @return table|nil info, string|nil err
---   info = { width, height, segments = { {marker, length, keep, label}, ... },
---            sosOffset (1-based position of the SOS marker), icc = bool }
function M.parse(bytes)
  if type(bytes) ~= 'string' or #bytes < 4 then return nil, 'too short' end
  if byte(bytes, 1) ~= 0xFF or byte(bytes, 2) ~= 0xD8 then return nil, 'not a JPEG (no SOI)' end

  local info = { segments = {}, icc = false }
  local pos = 3
  local n = #bytes

  while true do
    if pos > n then return nil, 'no SOS marker' end
    if byte(bytes, pos) ~= 0xFF then return nil, 'marker expected at ' .. pos end
    -- fill bytes: any number of 0xFF may precede the marker code
    while pos < n and byte(bytes, pos + 1) == 0xFF do pos = pos + 1 end
    if pos >= n then return nil, 'truncated marker' end
    local marker = byte(bytes, pos + 1)
    local markerPos = pos
    pos = pos + 2

    if marker == 0xD9 then return nil, 'EOI before SOS' end
    if marker == 0xD8 then return nil, 'second SOI' end
    if marker == 0x00 then return nil, 'invalid marker 0xFF00' end

    if marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7) then
      info.segments[#info.segments + 1] = { marker = marker, length = 0, keep = true, label = 'standalone', pos = markerPos }
    else
      if pos + 1 > n then return nil, 'truncated length' end
      local len = u16(bytes, pos)
      if len < 2 then return nil, 'bad segment length' end
      local last = pos + len - 1
      if last > n then return nil, 'segment runs past the end' end
      local payload = sub(bytes, pos + 2, last)

      if SOF_MARKERS[marker] then
        if #payload < 6 then return nil, 'short SOF' end
        info.height = u16(payload, 2)
        info.width = u16(payload, 4)
      end

      if marker == 0xDA then
        info.sosOffset = markerPos
        info.segments[#info.segments + 1] = { marker = marker, length = len, keep = true, label = 'sos', pos = markerPos }
        break
      end

      local keep, label = classify(marker, payload)
      if label == 'icc' then info.icc = true end
      info.segments[#info.segments + 1] = { marker = marker, length = len, keep = keep, label = label, pos = markerPos }
      pos = last + 1
    end
  end

  if not info.width or not info.height or info.width == 0 or info.height == 0 then
    return nil, 'no frame header (SOF)'
  end

  -- a file without EOI (FF D9) near its end is truncated. (FF D9 cannot occur inside the
  -- entropy-coded data, where every FF is followed by 00, so finding it there means EOI;
  -- a little trailing padding some writers add is tolerated.)
  local tailBytes = sub(bytes, math.max(n - 63, 1))
  info.complete = tailBytes:find('\255\217', 1, true) ~= nil
  return info
end

--- Rewrite without metadata.
--- @return string|nil clean, table|nil report, string|nil err
---   report = { before, after, removed = { exif = n, xmp = n, iptc = n, comment = n, ... },
---              width, height, icc }
function M.sanitize(bytes)
  local info, err = M.parse(bytes)
  if not info then return nil, nil, err end
  if not info.complete then return nil, nil, 'no EOI marker (truncated file?)' end

  local out = { sub(bytes, 1, 2) }
  local removed = {}
  for _, seg in ipairs(info.segments) do
    if seg.marker == 0xDA then break end
    if seg.keep then
      local size = (seg.length == 0) and 2 or (2 + seg.length)
      out[#out + 1] = sub(bytes, seg.pos, seg.pos + size - 1)
    else
      removed[seg.label] = (removed[seg.label] or 0) + 1
    end
  end
  -- SOS header + entropy-coded data + EOI, untouched
  out[#out + 1] = sub(bytes, info.sosOffset)

  local clean = table.concat(out)
  if byte(clean, 1) ~= 0xFF or byte(clean, 2) ~= 0xD8 or #clean < 4 then
    return nil, nil, 'rewrite failed'
  end
  -- the picture data (SOS header, entropy-coded data, EOI) must be identical to the original
  local tail = sub(bytes, info.sosOffset)
  if #clean < #tail or sub(clean, #clean - #tail + 1) ~= tail then
    return nil, nil, 'picture data changed during the rewrite'
  end
  -- the result must parse again and keep the same frame size
  local again = M.parse(clean)
  if not again or again.width ~= info.width or again.height ~= info.height then
    return nil, nil, 'rewritten file did not verify'
  end
  for _, seg in ipairs(again.segments) do
    if not seg.keep then return nil, nil, 'metadata marker survived the rewrite' end
  end

  return clean, {
    before = #bytes, after = #clean, removed = removed,
    width = info.width, height = info.height, icc = info.icc,
  }
end

--- Complete APP2 segment holding an ICC profile (single chunk).
function M.iccSegment(profile)
  if #profile > 65535 - 2 - 14 then return nil end
  local payload = 'ICC_PROFILE\0' .. '\1\1' .. profile
  local len = #payload + 2
  return '\255\226' .. char(math.floor(len / 256), len % 256) .. payload
end

--- Insert ready-made segments (markers and lengths included) right after SOI and the JFIF
--- header. The picture data is not touched; the result must parse again with the same size.
--- @return string|nil out, string|nil err
function M.withSegments(bytes, segments)
  if segments == nil or segments == '' then return bytes end
  local info, err = M.parse(bytes)
  if not info then return nil, err end

  local at = 3
  for _, seg in ipairs(info.segments) do
    if seg.marker == 0xE0 then at = seg.pos + 2 + seg.length else break end
  end
  local out = sub(bytes, 1, at - 1) .. segments .. sub(bytes, at)
  local again = M.parse(out)
  if not again or again.width ~= info.width or again.height ~= info.height or not again.complete then
    return nil, 'file with added segments did not verify'
  end
  local tail = sub(bytes, info.sosOffset)
  if #out < #tail or sub(out, #out - #tail + 1) ~= tail then
    return nil, 'picture data changed while adding segments'
  end
  return out
end

--- Insert an ICC profile (one APP2 segment) right after the JFIF header.
--- @return string|nil tagged, string|nil err   (nil + reason when the file is not in the expected shape)
function M.withIcc(bytes, profile)
  local info, err = M.parse(bytes)
  if not info then return nil, err end
  if info.icc then return bytes end -- already tagged
  local segment = M.iccSegment(profile)
  if not segment then return nil, 'profile too large for one segment' end
  local out, err2 = M.withSegments(bytes, segment)
  if not out then return nil, err2 end
  local again = M.parse(out)
  if not again or not again.icc then return nil, 'tagged file did not verify' end
  return out
end

--- Longer side in pixels, or nil.
function M.longEdge(bytes)
  local info = M.parse(bytes)
  if not info then return nil end
  return math.max(info.width, info.height)
end

return M
