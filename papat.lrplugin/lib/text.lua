--[[
  lib/text.lua — pure helpers (no LrC modules): price estimate, announcement text,
  dates, URL encoding, filename normalisation, passcode/UUID formatting.
]]

local M = {}

-- ---------------------------------------------------------------------------
-- Pricing (tax included): 88 yen per unit.
--   unit = up to 300 photos x 7 days
--   +1 unit per further 300 photos, +1 unit for the 7-day extension (14 days)
-- The server is the source of truth; this is only the estimate shown in the dialog.
-- ---------------------------------------------------------------------------

M.UNIT_YEN = 88
M.PHOTOS_PER_UNIT = 300
M.MAX_PHOTOS = 900
M.MIN_PASSCODE_LENGTH = 4
M.MAX_PASSCODE_LENGTH = 64

function M.priceUnits(photoCount, days)
  local blocks = math.max(1, math.ceil((photoCount or 0) / M.PHOTOS_PER_UNIT))
  if days and days > 7 then blocks = blocks + 1 end
  return blocks
end

function M.priceYen(photoCount, days)
  return M.priceUnits(photoCount, days) * M.UNIT_YEN
end

--- The server's number of galleries that are still free (`free_galleries_remaining`), or nil
--- when it is missing or not a sensible number. The plug-in never hard-codes the free allowance.
function M.parseFreeRemaining(value)
  local n = tonumber(value)
  if not n or n ~= n or n < 0 or n > 10000 then return nil end
  return math.floor(n)
end

--- The estimate line of the create dialog. `free` is the server's remaining free galleries
--- (nil = unknown: the free allowance is then not mentioned at all).
function M.priceLine(photoCount, days, free)
  local line = string.format('目安 %d 円（税込）', M.priceYen(photoCount, days))
  if free == nil then return line end
  if free <= 0 then return line .. '　※無料の残りはありません' end
  return line .. string.format('　※無料の残り %d ギャラリー', free)
end

-- ---------------------------------------------------------------------------
-- Dates
-- ---------------------------------------------------------------------------

local function daysFromCivil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

local function civilFromDays(z)
  z = z + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  if m <= 2 then y = y + 1 end
  return y, m, d
end

--- "2026-10-17T01:00:00.000Z" -> UNIX seconds (UTC). nil when unparsable.
function M.isoToEpoch(iso)
  if type(iso) ~= 'string' then return nil end
  local y, mo, d, h, mi, s = iso:match('^(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d):?(%d*)')
  if not y then
    y, mo, d = iso:match('^(%d%d%d%d)-(%d%d)-(%d%d)$')
    h, mi, s = '0', '0', '0'
  end
  if not y then return nil end
  local sec = tonumber(s) or 0
  return daysFromCivil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
    + tonumber(h) * 3600 + tonumber(mi) * 60 + sec
end

--- Local calendar date of an ISO timestamp. offsetSec = local UTC offset (JST = 32400).
function M.isoToLocalDate(iso, offsetSec)
  local epoch = M.isoToEpoch(iso)
  if not epoch then return nil end
  local y, m, d = civilFromDays(math.floor((epoch + (offsetSec or 0)) / 86400))
  return y, m, d
end

function M.jaDate(y, m, d)
  return string.format('%d年%d月%d日', y, m, d)
end

function M.jaMonthDay(m, d)
  return string.format('%d月%d日', m, d)
end

function M.isoDate(y, m, d)
  return string.format('%04d-%02d-%02d', y, m, d)
end

--- 250 -> "4分10秒", 45 -> "45秒", 3700 -> "1時間1分40秒"
function M.formatDuration(seconds)
  seconds = math.max(0, math.floor((tonumber(seconds) or 0) + 0.5))
  local h = math.floor(seconds / 3600)
  local m = math.floor((seconds % 3600) / 60)
  local s = seconds % 60
  if h > 0 then return string.format('%d時間%d分%d秒', h, m, s) end
  if m > 0 then return string.format('%d分%d秒', m, s) end
  return string.format('%d秒', s)
end

--- Whole days from now (epoch seconds) to the expiry, rounded up. nil if unknown.
function M.daysUntil(expiresIso, nowEpoch)
  local epoch = M.isoToEpoch(expiresIso)
  if not epoch or not nowEpoch then return nil end
  return math.max(0, math.ceil((epoch - nowEpoch) / 86400))
end

-- ---------------------------------------------------------------------------
-- Strings
-- ---------------------------------------------------------------------------

function M.trim(s)
  return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

--- One-line, bounded title for the gallery / collection name.
function M.cleanTitle(s, maxChars)
  s = tostring(s or ''):gsub('[%c]+', ' ')
  s = M.trim(s)
  maxChars = maxChars or 200
  if #s > maxChars then
    -- cut on a UTF-8 character boundary
    local cut = maxChars
    while cut > 0 do
      local b = s:byte(cut + 1)
      if not b or b < 0x80 or b >= 0xC0 then break end
      cut = cut - 1
    end
    s = s:sub(1, cut)
  end
  return s
end

--- Percent-encode one URL path segment (UTF-8 bytes; RFC 3986 unreserved kept).
function M.urlEncodeSegment(s)
  return (tostring(s):gsub('[^%w%-%._~]', function(c)
    return string.format('%%%02X', c:byte())
  end))
end

--- Mask an API key for display: only the last 4 characters are shown.
function M.maskKey(key)
  key = tostring(key or '')
  if key == '' then return '' end
  if #key <= 8 then return '••••' end
  return '••••••••' .. key:sub(-4)
end

function M.trimKey(key)
  return (tostring(key or ''):gsub('%s+', ''))
end

function M.looksLikeApiKey(key)
  return type(key) == 'string' and key:match('^sk_live_[%w%-]+_[%w%-_]+$') ~= nil
end

-- Marker that starts the line papat appends to a caption. Used to avoid appending
-- the same memo twice when a gallery is imported again.
M.CAPTION_MARK = '— papat: '

--- Append the client's memo to the photographer's caption (never replaces it).
--- Returns the new caption, or nil when the memo is already there.
function M.appendMemo(existing, memo)
  memo = tostring(memo or '')
  if memo == '' then return nil end
  existing = type(existing) == 'string' and existing or ''
  local block = M.CAPTION_MARK .. memo
  if existing:find(block, 1, true) then return nil end
  if existing == '' then return block end
  return existing .. '\n' .. block
end

-- ---------------------------------------------------------------------------
-- Capture time (manifest `datetime`) and the order of a gallery
-- ---------------------------------------------------------------------------

--- Camera wall-clock time as "YYYY-MM-DDTHH:MM:SS" from an ISO 8601 string. Any zone
--- designator and fraction are dropped on purpose: the gallery shows hour:minute from the
--- string itself and parses it as local time, so the zone must not move the clock.
function M.isoWallTime(value)
  if type(value) ~= 'string' then return nil end
  local y, mo, d, h, mi, s = value:match('^%s*(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d):(%d%d)')
  if not y then
    y, mo, d, h, mi = value:match('^%s*(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d)')
    s = '00'
  end
  if not y then return nil end
  if tonumber(mo) < 1 or tonumber(mo) > 12 or tonumber(d) < 1 or tonumber(d) > 31
    or tonumber(h) > 23 or tonumber(mi) > 59 or tonumber(s) > 60 then
    return nil
  end
  if tonumber(y) < 1990 then return nil end
  return string.format('%s-%s-%sT%s:%s:%s', y, mo, d, h, mi, s)
end

--- Seconds since 2001-01-01 (Lightroom's date numbers, wall-clock encoded as if UTC) -> wall time.
function M.cocoaToWallTime(seconds)
  seconds = tonumber(seconds)
  if not seconds or seconds ~= seconds then return nil end
  local base = daysFromCivil(2001, 1, 1) * 86400
  local epoch = math.floor(base + seconds)
  local days = math.floor(epoch / 86400)
  local rest = epoch - days * 86400
  local y, m, d = civilFromDays(days)
  return M.isoWallTime(string.format('%04d-%02d-%02dT%02d:%02d:%02d',
    y, m, d, math.floor(rest / 3600), math.floor((rest % 3600) / 60), rest % 60))
end

--- Order of photos in a gallery: dated photos by capture time, then by file name; undated
--- photos last, by file name; the selection order breaks the remaining ties. Total order,
--- independent of how fast each upload finishes.
function M.photoOrderLess(a, b)
  local da, db = a.datetime or '', b.datetime or ''
  if (da == '') ~= (db == '') then return db == '' end
  if da ~= db then return da < db end
  local na, nb = a.sortName or '', b.sortName or ''
  if na ~= nb then return na < nb end
  return (a.order or 0) < (b.order or 0)
end

--- Compare "1.2.3" style versions. Returns -1, 0, 1.
function M.compareVersions(a, b)
  local function parts(v)
    local out = {}
    for n in tostring(v or ''):gmatch('%d+') do out[#out + 1] = tonumber(n) end
    return out
  end
  local pa, pb = parts(a), parts(b)
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x < y then return -1 end
    if x > y then return 1 end
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Key color (the client's color of the gallery page). The server accepts only
-- "#RRGGBB" (null / absent = papat's default), so nothing else is ever sent.
-- ---------------------------------------------------------------------------

M.MAX_RECENT_COLORS = 5

--- @return string|nil color  "#rrggbb" (lowercase) or '' for "no color"; nil = invalid
function M.normalizeKeyColor(value)
  value = M.trim(value)
  if value == '' then return '' end
  local hex = value:match('^#?(%x%x%x%x%x%x)$')
  if not hex then return nil end
  return '#' .. hex:lower()
end

--- Put `color` first in a comma-separated recent list; no duplicates, bounded.
function M.rememberColor(list, color)
  local out = {}
  if color and color ~= '' then out[1] = color end
  for entry in tostring(list or ''):gmatch('[^,]+') do
    local c = M.normalizeKeyColor(entry)
    if c and c ~= '' and c ~= color then out[#out + 1] = c end
  end
  while #out > M.MAX_RECENT_COLORS do out[#out] = nil end
  return table.concat(out, ',')
end

function M.recentColors(list)
  local out = {}
  for entry in tostring(list or ''):gmatch('[^,]+') do
    local c = M.normalizeKeyColor(entry)
    if c and c ~= '' then out[#out + 1] = c end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Update notice
-- ---------------------------------------------------------------------------

M.UPDATE_NOTICE_INTERVAL = 24 * 3600   -- tell about an optional update once a day
M.UPDATE_CACHE_SECONDS = 3600          -- re-ask the server at most hourly

local function versionOrNil(v)
  if type(v) == 'string' and v:match('^%d+%.%d+%.%d+') then return v end
  return nil
end

--- What to do about the plug-in's own version.
---   info = { minimum, latest, available, required }  (all optional; from the status API)
--- @return string 'required' | 'optional' | 'none'
---
--- 'required' only when the server says so explicitly (`required`) or its minimum is
--- above this version AND below the latest one. A server that reports minimum == latest
--- (it did, in 1.0.0) is merely announcing a new version: that must never lock anybody out.
function M.updateDecision(current, info)
  if type(info) ~= 'table' then return 'none' end
  if info.required == true then return 'required' end
  local minimum, latest = versionOrNil(info.minimum), versionOrNil(info.latest)
  if minimum and M.compareVersions(current, minimum) < 0
    and (latest == nil or M.compareVersions(minimum, latest) < 0) then
    return 'required'
  end
  if latest and M.compareVersions(current, latest) < 0 then return 'optional' end
  if info.available == true then return 'optional' end
  return 'none'
end

--- Is the once-a-day notice due? lastNotified / now are UNIX seconds.
function M.updateNoticeDue(lastNotified, now, interval)
  lastNotified = tonumber(lastNotified)
  if not lastNotified then return true end
  if lastNotified > now then return true end -- clock went backwards: do not stay silent forever
  return (now - lastNotified) >= (interval or M.UPDATE_NOTICE_INTERVAL)
end

function M.starText(n)
  n = math.max(0, math.min(5, math.floor(tonumber(n) or 0)))
  if n == 0 then return '' end
  return string.rep('★', n)
end

-- ---------------------------------------------------------------------------
-- Filenames: lowercase ASCII + compose kana + dakuten/handakuten (macOS may hand
-- back decomposed names) so "ｶﾞ" style differences don't break exact matching.
-- ---------------------------------------------------------------------------

local function utf8Encode(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
  end
  return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

local VOICED_BASES = {}
local SEMI_BASES = {}
do
  local function add(list, first, last, step)
    for cp = first, last, step do list[cp] = true end
  end
  -- hiragana: か き く け こ さ し す せ そ た ち つ て と は ひ ふ へ ほ
  add(VOICED_BASES, 0x304B, 0x3061, 2) -- か..ち (か,き,く,け,こ,さ,し,す,せ,そ,た,ち)
  add(VOICED_BASES, 0x3064, 0x3068, 2) -- つ て と
  add(VOICED_BASES, 0x306F, 0x307B, 3) -- は ひ ふ へ ほ
  VOICED_BASES[0x3046] = true -- う -> ゔ (U+3094, special)
  add(SEMI_BASES, 0x306F, 0x307B, 3)
  -- katakana mirror (+0x60)
  local extraV, extraS = {}, {}
  for cp in pairs(VOICED_BASES) do extraV[#extraV + 1] = cp + 0x60 end
  for cp in pairs(SEMI_BASES) do extraS[#extraS + 1] = cp + 0x60 end
  for _, cp in ipairs(extraV) do VOICED_BASES[cp] = true end
  for _, cp in ipairs(extraS) do SEMI_BASES[cp] = true end
end

local function composeKana(s)
  -- U+3099 = E3 82 99, U+309A = E3 82 9A
  s = s:gsub('(\227[\129-\131][\128-\191])\227\130([\153\154])', function(base, mark)
    local b1, b2, b3 = base:byte(1, 3)
    local cp = (b1 - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
    local out
    if mark == '\153' then
      if cp == 0x3046 then
        out = 0x3094
      elseif cp == 0x30A6 then
        out = 0x30F4
      elseif VOICED_BASES[cp] then
        out = cp + 1
      end
    else
      if SEMI_BASES[cp] then out = cp + 2 end
    end
    if out then return utf8Encode(out) end
    return nil
  end)
  return s
end

--- Key used to compare filenames: composed kana, ASCII lowercase.
function M.nameKey(s)
  s = tostring(s or '')
  s = composeKana(s)
  s = s:gsub('%u', string.lower)
  return s
end

-- ---------------------------------------------------------------------------
-- Paths (pure string handling; Lightroom paths use "/" on macOS)
-- ---------------------------------------------------------------------------

function M.stripTrailingSlash(p)
  p = tostring(p or '')
  if #p > 1 then p = p:gsub('/+$', '') end
  return p
end

--- Case-insensitive comparison (the default macOS volume format is case-insensitive).
function M.samePath(a, b)
  return M.stripTrailingSlash(a):lower() == M.stripTrailingSlash(b):lower()
end

function M.parentPath(p)
  p = M.stripTrailingSlash(p)
  local parent = p:match('^(.*)/[^/]+$')
  if parent == nil then return '' end
  if parent == '' then return '/' end
  return parent
end

--- Relative path of `path` under `base`, or nil when it is not inside.
function M.relativePath(base, path)
  base = M.stripTrailingSlash(base)
  path = tostring(path or '')
  local prefix = base .. '/'
  if path:sub(1, #prefix):lower() ~= prefix:lower() then return nil end
  local rel = path:sub(#prefix + 1)
  if rel == '' then return nil end
  return rel
end

--- Canonical form for comparing locations: "\" -> "/", "~" expanded with `home`, "//" and
--- "." / ".." resolved, trailing "/" removed, and the macOS aliases "/private/var|tmp|etc"
--- and "/System/Volumes/Data" folded back to their usual spelling. Case is kept
--- (compare with :lower()). No file system access, so symbolic links are not resolved.
function M.normalizePath(p, home)
  p = M.trim(tostring(p or ''):gsub('\\', '/'))
  if home and home ~= '' and (p == '~' or p:sub(1, 2) == '~/') then
    p = M.normalizePath(home) .. p:sub(2)
  end
  local out = {}
  for segment in p:gmatch('[^/]+') do
    if segment == '..' then
      if #out > 0 and out[#out] ~= '..' then out[#out] = nil else out[#out + 1] = segment end
    elseif segment ~= '.' then
      out[#out + 1] = segment
    end
  end
  local absolute = p:sub(1, 1) == '/'
  local joined = (absolute and '/' or '') .. table.concat(out, '/')
  local lower = joined:lower()
  if lower:sub(1, 20) == '/system/volumes/data' and (#joined == 20 or joined:sub(21, 21) == '/') then
    joined = joined:sub(21)
    if joined == '' then joined = '/' end
    lower = joined:lower()
  end
  for _, dir in ipairs({ '/private/var', '/private/tmp', '/private/etc' }) do
    if lower:sub(1, #dir) == dir and (#joined == #dir or joined:sub(#dir + 1, #dir + 1) == '/') then
      joined = joined:sub(#'/private' + 1)
      break
    end
  end
  return joined
end

--- Is `dir` exactly Lightroom's Modules folder:
---   <user home>/Library/Application Support/Adobe/Lightroom/Modules   (macOS)
---   <user home>/AppData/Roaming/Adobe/Lightroom/Modules               (Windows)
--- or the system-wide /Library/Application Support/Adobe/Lightroom/Modules ?
--- Nothing is written anywhere that does not pass this test.
function M.isStandardModulesDir(dir, home)
  local lower = M.normalizePath(dir, home):lower()
  local homeLower = (home and home ~= '') and M.normalizePath(home):lower() or nil
  local function userPrefix(prefix)
    return prefix == '' or prefix == homeLower
      or prefix:match('^/users/[^/]+$') ~= nil
      or prefix:match('^[a-z]:/users/[^/]+$') ~= nil
  end
  local mac = lower:match('^(.*)/library/application support/adobe/lightroom/modules$')
  if mac ~= nil and userPrefix(mac) then return true end
  local win = lower:match('^(.*)/appdata/roaming/adobe/lightroom/modules$')
  if win ~= nil and userPrefix(win) then return true end
  return false
end

--- Is the plug-in folder `pluginPath` a direct child of Lightroom's Modules folder?
--- ctx = { home = '/Users/x', modulesDirs = { '<expected Modules path>', ... } }
--- Decided by structure, so it does not depend on what the SDK reports as "appData".
--- Entries of ctx.modulesDirs count only if they themselves are a standard Modules dir.
function M.isInModulesFolder(pluginPath, ctx)
  ctx = ctx or {}
  local home = ctx.home
  local parent = M.parentPath(M.normalizePath(pluginPath, home))
  if M.isStandardModulesDir(parent, home) then return true end
  for _, dir in ipairs(ctx.modulesDirs or {}) do
    if dir and dir ~= '' and M.isStandardModulesDir(dir, home)
      and parent:lower() == M.normalizePath(dir, home):lower() then
      return true
    end
  end
  return false
end

--- True when the folder sits in a "Downloads" directory (easy to lose by tidying up).
function M.inDownloads(path)
  path = tostring(path or ''):lower()
  return path:find('/downloads/', 1, true) ~= nil or path:match('/downloads$') ~= nil
end

--- Basename without its last extension.
function M.stemOf(name)
  name = tostring(name or '')
  name = name:match('([^/\\]*)$') or name
  local stem = name:match('^(.*)%.[^%.]*$')
  if stem and stem ~= '' then return stem end
  return name
end

function M.leafOf(path)
  path = tostring(path or '')
  return path:match('([^/\\]*)$') or path
end

-- ---------------------------------------------------------------------------
-- Announcement text (案内文)
-- ---------------------------------------------------------------------------

--- Same shape as the invitation text of the web dashboard:
---   title / URL / passcode / expiry date / "open in the browser … press 確定".
function M.announcement(opts)
  local lines = { '写真をお送りします。' }
  if opts.title and opts.title ~= '' then lines[#lines + 1] = opts.title end
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'URL: ' .. opts.url
  lines[#lines + 1] = 'パスコード: ' .. opts.passcode
  if opts.expireText and opts.expireText ~= '' then
    lines[#lines + 1] = '公開期限: ' .. opts.expireText
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'ブラウザで開いて、気に入った写真に★を付けて「確定」を押してください。'
  return table.concat(lines, '\n')
end

-- ---------------------------------------------------------------------------
-- Dialog text layout
-- A static_text with a fixed height_in_lines silently cuts whatever wraps into more lines
-- (seen on a real machine: the intro of the "create gallery" dialog ended mid-sentence).
-- The plug-in cannot measure text, so the lines are estimated from the text itself, on the
-- cautious side: ~43 full-width characters fit into 520 px in practice, 37 are assumed.
-- ---------------------------------------------------------------------------

M.PX_PER_UNIT = 14       -- one full-width character
local ASCII_UNITS = 0.6  -- Latin letters and digits are narrower than Japanese characters
local SPACE_UNITS = 0.35

--- Display width of one line of text in full-width character units.
function M.displayUnits(s)
  local units = 0
  for i = 1, #s do
    local b = s:byte(i)
    if b >= 0xC0 then
      units = units + 1            -- lead byte of a multi-byte character (continuation bytes add nothing)
    elseif b < 0x80 then
      units = units + ((b == 32) and SPACE_UNITS or ASCII_UNITS)
    end
  end
  return units
end

--- Number of lines `s` needs when wrapped into `widthPx` (each \n starts a new line).
function M.wrappedLines(s, widthPx)
  local perLine = math.max(1, (widthPx or 520) / M.PX_PER_UNIT)
  local lines = 0
  for paragraph in (tostring(s) .. '\n'):gmatch('(.-)\n') do
    lines = lines + math.max(1, math.ceil(M.displayUnits(paragraph) / perLine - 1e-9))
  end
  return lines
end

--- height_in_lines for a text of fixed content: never fewer than `minLines`.
function M.linesFor(s, widthPx, minLines)
  return math.max(minLines or 1, M.wrappedLines(s, widthPx))
end

--- Intro of the "create gallery" dialog: the essentials only (what is sent, what the images carry).
--- The details are in the settings screen and in the confirmation shown once.
--- @param o table { longEdge, fast = bool, embedRights = bool }
function M.createIntro(count, o)
  local size = string.format('長辺 %d px', o.longEdge)
  if o.fast then size = size .. ' 前後（速さ優先）' end
  local carried = o.embedRights
    and '画像には、著作権・作成者・連絡先だけが入ります。'
    or '著作権・連絡先などは、画像に入れません。'
  return string.format('選択中の %d 枚を、%s の JPEG にして送ります（RAW 原本は送りません）。%s', count, size, carried)
end

-- ---------------------------------------------------------------------------
-- Import confirmation text
-- ---------------------------------------------------------------------------

--- @param o table { adopted, matched, collectionNames = {...}, options = {ja strings},
---                  unmatched = {labels}, ambiguous = {labels}, limit = number }
function M.importSummary(o)
  local limit = o.limit or 30
  local lines = {}
  local function add(s) lines[#lines + 1] = s end
  local function list(header, labels)
    if #labels == 0 then return end
    add('')
    add(header)
    for i = 1, math.min(#labels, limit) do add('  ・' .. labels[i]) end
    if #labels > limit then add(string.format('  … ほか %d 枚', #labels - limit)) end
  end

  add(string.format('クライアントが採用した写真: %d 枚', o.adopted))
  add(string.format('カタログで見つかった写真: %d 枚', o.matched))
  if o.matched > 0 then
    add('')
    add('【反映する内容】')
    for _, name in ipairs(o.collectionNames) do
      add('  ・コレクション「' .. name .. '」に追加')
    end
    for _, opt in ipairs(o.options) do add('  ・' .. opt) end
    add('  ※ レーティング・カラーラベルは変更しません。')
  end

  list(string.format('【見つからなかった写真（%d 枚）】カタログにない、または名前が変わっています。', #o.unmatched), o.unmatched)
  list(string.format('【同じ名前の写真が複数あり、反映しない写真（%d 枚）】', #o.ambiguous), o.ambiguous)

  return table.concat(lines, '\n')
end

return M
