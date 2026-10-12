--[[
  lib/rights.lua — "whose photograph is this": copyright, creator, contact details

  What goes into the JPEG sent to papat is built here, from the values the photographer
  registered in Lightroom, never copied from Lightroom's own output:

    kept     copyright, copyright status, rights usage terms, copyright info URL,
             creator, creator job title, creator contact info (address, city, region,
             postal code, country, phone, e-mail, web)
    not kept location, camera / lens serial numbers, develop settings, edit history, RAW file
             name, embedded thumbnail, shooting data — see lib/jpeg.lua, which strips them

  Two small containers are written: an Exif APP1 with Artist / Copyright (read by Preview,
  Explorer, most viewers) and an XMP APP1 (dc:rights, dc:creator, xmpRights, IPTC Core
  contact info: what Photoshop, Bridge and InDesign show). Pure Lua, no Lightroom modules;
  lib/photoinfo.lua reads the values from the catalog and hands them to collect().
]]

local M = {}

local char, floor = string.char, math.floor

-- key in Lightroom -> field name here. `raw` fields come from getRawMetadata.
M.KEYS = {
  { key = 'copyright', field = 'copyright' },
  { key = 'copyrightState', field = 'state', raw = true },
  { key = 'rightsUsageTerms', field = 'terms' },
  { key = 'copyrightInfoUrl', field = 'copyrightUrl' },
  { key = 'creator', field = 'creator' },
  { key = 'creatorJobTitle', field = 'jobTitle' },
  { key = 'creatorAddress', field = 'address' },
  { key = 'creatorCity', field = 'city' },
  { key = 'creatorStateProvince', field = 'region' },
  { key = 'creatorPostalCode', field = 'postalCode' },
  { key = 'creatorCountry', field = 'country' },
  { key = 'creatorPhone', field = 'phone' },
  { key = 'creatorEmail', field = 'email' },
  { key = 'creatorUrl', field = 'url' },
}

local MAX_VALUE = 1000

--- Trim, drop control characters, cap the length (on a UTF-8 boundary). '' for non-strings.
function M.clean(value)
  if type(value) ~= 'string' then return '' end
  value = value:gsub('[%c]+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
  if #value > MAX_VALUE then
    local cut = MAX_VALUE
    while cut > 0 do
      local b = value:byte(cut + 1)
      if not b or b < 0x80 or b >= 0xC0 then break end
      cut = cut - 1
    end
    value = value:sub(1, cut)
  end
  return value
end

--- Lightroom returns "not set" in several ways; only real text counts.
local function meaningful(field, value)
  value = M.clean(value)
  if value == '' then return nil end
  if field == 'state' then
    if value == 'copyrighted' or value == 'public domain' then return value end
    return nil -- 'unknown'
  end
  return value
end

--- @param get function(key, raw) -> value   (adapter over a photo or a batch result)
--- @return table fields  only non-empty ones
function M.collect(get)
  local fields = {}
  for _, k in ipairs(M.KEYS) do
    local v = meaningful(k.field, get(k.key, k.raw == true))
    if v then fields[k.field] = v end
  end
  return fields
end

function M.isEmpty(fields)
  return next(fields or {}) == nil
end

-- Order used for the signature and the confirmation text.
local ORDER = { 'copyright', 'state', 'terms', 'copyrightUrl', 'creator', 'jobTitle', 'address', 'city',
  'region', 'postalCode', 'country', 'phone', 'email', 'url' }

--- Stable text of the values (used to remember what the photographer has confirmed).
function M.signature(fields)
  local parts = {}
  for _, name in ipairs(ORDER) do
    if fields[name] then parts[#parts + 1] = name .. '=' .. fields[name] end
  end
  return table.concat(parts, '\n')
end

local LABELS = {
  copyright = '著作権', state = '著作権の状態', terms = '使用条件', copyrightUrl = '著作権情報の URL',
  creator = '作成者', jobTitle = '肩書き', address = '住所', city = '市区町村', region = '都道府県',
  postalCode = '郵便番号', country = '国', phone = '電話', email = 'メール', url = 'Web',
}

--- Lines for the confirmation dialog, in plain Japanese.
function M.describe(fields)
  local lines = {}
  for _, name in ipairs(ORDER) do
    if fields[name] then
      local value = fields[name]
      if name == 'state' then value = (value == 'copyrighted') and '著作権あり' or 'パブリックドメイン' end
      lines[#lines + 1] = LABELS[name] .. ': ' .. value
    end
  end
  return lines
end

-- ---------------------------------------------------------------------------
-- XMP
-- ---------------------------------------------------------------------------

local function xmlEscape(s)
  return (s:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub('"', '&quot;'))
end

local function alt(value)
  return '<rdf:Alt><rdf:li xml:lang="x-default">' .. xmlEscape(value) .. '</rdf:li></rdf:Alt>'
end

--- XMP packet (UTF-8 text).
function M.xmp(fields)
  local d = {}
  local function add(s) d[#d + 1] = s end

  add('<?xpacket begin="\239\187\191" id="W5M0MpCehiHzreSzNTczkc9d"?>\n')
  add('<x:xmpmeta xmlns:x="adobe:ns:meta/">\n<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n')
  add('<rdf:Description rdf:about=""'
    .. ' xmlns:dc="http://purl.org/dc/elements/1.1/"'
    .. ' xmlns:xmpRights="http://ns.adobe.com/xap/1.0/rights/"'
    .. ' xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"'
    .. ' xmlns:Iptc4xmpCore="http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"')
  if fields.state == 'copyrighted' then
    add(' xmpRights:Marked="True"')
  elseif fields.state == 'public domain' then
    add(' xmpRights:Marked="False"')
  end
  add('>\n')

  if fields.copyright then add('<dc:rights>' .. alt(fields.copyright) .. '</dc:rights>\n') end
  if fields.creator then
    add('<dc:creator><rdf:Seq><rdf:li>' .. xmlEscape(fields.creator) .. '</rdf:li></rdf:Seq></dc:creator>\n')
  end
  if fields.terms then add('<xmpRights:UsageTerms>' .. alt(fields.terms) .. '</xmpRights:UsageTerms>\n') end
  if fields.copyrightUrl then
    add('<xmpRights:WebStatement>' .. xmlEscape(fields.copyrightUrl) .. '</xmpRights:WebStatement>\n')
  end
  if fields.jobTitle then
    add('<photoshop:AuthorsPosition>' .. xmlEscape(fields.jobTitle) .. '</photoshop:AuthorsPosition>\n')
  end

  local contact = {
    { 'address', 'CiAdrExtadr' }, { 'city', 'CiAdrCity' }, { 'region', 'CiAdrRegion' },
    { 'postalCode', 'CiAdrPcode' }, { 'country', 'CiAdrCtry' }, { 'phone', 'CiTelWork' },
    { 'email', 'CiEmailWork' }, { 'url', 'CiUrlWork' },
  }
  local any = false
  for _, c in ipairs(contact) do if fields[c[1]] then any = true end end
  if any then
    add('<Iptc4xmpCore:CreatorContactInfo rdf:parseType="Resource">\n')
    for _, c in ipairs(contact) do
      if fields[c[1]] then
        add('<Iptc4xmpCore:' .. c[2] .. '>' .. xmlEscape(fields[c[1]]) .. '</Iptc4xmpCore:' .. c[2] .. '>\n')
      end
    end
    add('</Iptc4xmpCore:CreatorContactInfo>\n')
  end

  add('</rdf:Description>\n</rdf:RDF>\n</x:xmpmeta>\n<?xpacket end="w"?>')
  return table.concat(d)
end

-- ---------------------------------------------------------------------------
-- Exif (IFD0 with Artist and Copyright only)
-- ---------------------------------------------------------------------------

local function le16(n) return char(n % 256, floor(n / 256) % 256) end
local function le32(n) return char(n % 256, floor(n / 256) % 256, floor(n / 65536) % 256, floor(n / 16777216) % 256) end

--- TIFF structure for the Exif APP1 payload (after "Exif\0\0"), or nil when there is nothing.
function M.exifTiff(fields)
  local entries = {}
  if fields.creator then entries[#entries + 1] = { tag = 0x013B, text = fields.creator } end
  if fields.copyright then entries[#entries + 1] = { tag = 0x8298, text = fields.copyright } end
  if #entries == 0 then return nil end

  local count = #entries
  local dataStart = 8 + 2 + 12 * count + 4
  local ifd, data = { le16(count) }, {}
  local offset = dataStart
  for _, e in ipairs(entries) do
    local value = e.text .. '\0'
    local field
    if #value <= 4 then
      field = value .. string.rep('\0', 4 - #value)
    else
      field = le32(offset)
      local padded = value
      if #padded % 2 == 1 then padded = padded .. '\0' end
      data[#data + 1] = padded
      offset = offset + #padded
    end
    ifd[#ifd + 1] = le16(e.tag) .. le16(2) .. le32(#value) .. field
  end
  ifd[#ifd + 1] = le32(0) -- no next IFD
  return 'II' .. le16(42) .. le32(8) .. table.concat(ifd) .. table.concat(data)
end

-- ---------------------------------------------------------------------------
-- JPEG segments
-- ---------------------------------------------------------------------------

local function segment(marker, payload)
  local len = #payload + 2
  return '\255' .. char(marker) .. char(floor(len / 256), len % 256) .. payload
end

local MAX_PAYLOAD = 65533
local XMP_HEADER = 'http://ns.adobe.com/xap/1.0/\0'

--- Binary APP1 segments (Exif, then XMP) for these fields; '' when there is nothing to say.
--- Very long contact blocks are shortened field by field so the packet fits one segment.
function M.segments(fields)
  if M.isEmpty(fields) then return '' end
  local out = {}

  local tiff = M.exifTiff(fields)
  if tiff and #tiff + 6 <= MAX_PAYLOAD then
    out[#out + 1] = segment(0xE1, 'Exif\0\0' .. tiff)
  end

  local work = {}
  for k, v in pairs(fields) do work[k] = v end
  local shed = { 'url', 'email', 'phone', 'country', 'postalCode', 'region', 'city', 'address',
    'jobTitle', 'copyrightUrl', 'terms' }
  local xmp = M.xmp(work)
  local i = 1
  while #xmp + #XMP_HEADER > MAX_PAYLOAD and shed[i] do
    work[shed[i]] = nil
    i = i + 1
    xmp = M.xmp(work)
  end
  if #xmp + #XMP_HEADER <= MAX_PAYLOAD then
    out[#out + 1] = segment(0xE1, XMP_HEADER .. xmp)
  end
  return table.concat(out)
end

return M
