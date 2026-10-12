-- Plain-Lua unit tests for the LrC-independent modules.
-- Run:  lua tests/run.lua   (from the repository root)
local root = arg and arg[0] and arg[0]:match('^(.*)/tests/[^/]+$') or '.'
_PLUGIN = { path = root .. '/papat.lrplugin' }

local function load(name) return dofile(_PLUGIN.path .. '/lib/' .. name .. '.lua') end
local sha256 = load('sha256')
local text = load('text')
local json = load('json')
local selections = load('selections')
local matching = load('matching')
local jpeg = load('jpeg')
local icc = load('icc')
local rights = load('rights')

local failed, total = 0, 0
local function eq(actual, expected, label)
  total = total + 1
  if actual ~= expected then
    failed = failed + 1
    print(string.format('FAIL %s\n  expected: %s\n  actual:   %s', label, tostring(expected), tostring(actual)))
  end
end

-- SHA-256 -----------------------------------------------------------------
eq(sha256.hex(''), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', 'sha256 empty')
eq(sha256.hex('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', 'sha256 abc')
eq(sha256.hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
   '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1', 'sha256 two-block')
eq(sha256.hex(string.rep('a', 55)), '9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318', 'sha256 55 bytes')
eq(sha256.hex(string.rep('a', 56)), 'b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a', 'sha256 56 bytes')
eq(sha256.hex(string.rep('a', 64)), 'ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb', 'sha256 64 bytes')
eq(sha256.hex('パスコード'), 'f0970bf19cafcb72b083d7e75ac99761795d4c5cdc983b5cf37bdfc9687d27f2', 'sha256 utf8')
eq(sha256.hex('ABC234'), '8c640c4e71f90160b2b3615af86739e6b15ddc877ae79e18aada753565f756c4', 'sha256 passcode')

-- text: price ---------------------------------------------------------------
eq(text.priceYen(1, 7), 88, 'price 1 photo 7d')
eq(text.priceYen(300, 7), 88, 'price 300 photos 7d')
eq(text.priceYen(301, 7), 176, 'price 301 photos 7d')
eq(text.priceYen(300, 14), 176, 'price 300 photos 14d')
eq(text.priceYen(900, 14), 352, 'price 900 photos 14d')

-- text: dates ---------------------------------------------------------------
eq(text.isoToEpoch('1970-01-02T00:00:00.000Z'), 86400, 'isoToEpoch day 2')
eq(text.isoToEpoch('2026-10-17T01:00:00.000Z'), 1792198800, 'isoToEpoch 2026-10-17')
local y, m, d = text.isoToLocalDate('2026-10-16T16:30:00.000Z', 9 * 3600)
eq(text.isoDate(y, m, d), '2026-10-17', 'JST rollover')
y, m, d = text.isoToLocalDate('2026-03-01T00:00:00Z', 0)
eq(text.isoDate(y, m, d), '2026-03-01', 'march 1')
y, m, d = text.isoToLocalDate('2028-02-29T23:59:59Z', 0)
eq(text.isoDate(y, m, d), '2028-02-29', 'leap day')
eq(text.jaDate(2026, 10, 7), '2026年10月7日', 'jaDate')
eq(text.daysUntil('2026-10-17T01:00:00.000Z', text.isoToEpoch('2026-10-10T01:00:00Z')), 7, 'daysUntil 7')
eq(text.daysUntil('2026-10-24T01:00:00.000Z', text.isoToEpoch('2026-10-10T01:00:00Z')), 14, 'daysUntil 14')
eq(text.isoToEpoch('garbage'), nil, 'isoToEpoch garbage')

-- text: strings -------------------------------------------------------------
eq(text.urlEncodeSegment('DSC 0123 写真.jpg'), 'DSC%200123%20%E5%86%99%E7%9C%9F.jpg', 'urlencode')
eq(text.maskKey('sk_live_abc123_abcdefghijklmnop'), '••••••••mnop', 'maskKey')
eq(text.maskKey(''), '', 'maskKey empty')
eq(text.looksLikeApiKey('sk_live_abc123_Zx9-_Qw'), true, 'api key ok')
eq(text.looksLikeApiKey('hello'), false, 'api key bad')
eq(text.trimKey('  sk_live_a_b \n'), 'sk_live_a_b', 'trimKey')
eq(text.cleanTitle('  a\nb  '), 'a b', 'cleanTitle control')
eq(text.cleanTitle(string.rep('あ', 100), 10), 'あああ', 'cleanTitle utf8 boundary')
eq(text.stemOf('IMG_0001.CR3'), 'IMG_0001', 'stemOf')
eq(text.stemOf('/a/b/photo.v2.jpg'), 'photo.v2', 'stemOf dots')
eq(text.stemOf('.hidden'), '.hidden', 'stemOf dotfile')
eq(text.starText(3), '★★★', 'starText')
eq(text.nameKey('IMG_0001.JPG'), 'img_0001.jpg', 'nameKey lower')
-- decomposed か + ゛ (U+304B U+3099) must equal composed が (U+304C)
eq(text.nameKey('\227\129\139\227\130\153.jpg'), '\227\129\140.jpg', 'nameKey compose ga')
eq(text.nameKey('\227\131\143\227\130\154.jpg'), '\227\131\145.jpg', 'nameKey compose pa (katakana)')
eq(text.nameKey('\227\130\166\227\130\153.jpg'), '\227\131\180.jpg', 'nameKey compose vu')

local ann = text.announcement({ title = '春の撮影', url = 'https://papat.app/t/x/s/y/', passcode = 'ABC234', expireText = '10月17日まで' })
eq(ann, '写真をお送りします。\n春の撮影\n\nURL: https://papat.app/t/x/s/y/\nパスコード: ABC234\n公開期限: 10月17日まで\n\nブラウザで開いて、気に入った写真に★を付けて「確定」を押してください。', 'announcement layout')
eq(ann:find('登録', 1, true), nil, 'announcement: no "登録は要りません"')
eq(text.announcement({ url = 'u', passcode = 'p' }), '写真をお送りします。\n\nURL: u\nパスコード: p\n\nブラウザで開いて、気に入った写真に★を付けて「確定」を押してください。', 'announcement without title/expiry')
eq(text.jaMonthDay(10, 7), '10月7日', 'jaMonthDay')
eq(text.compareVersions('1.0.0', '1.0.1'), -1, 'version lt')
eq(text.compareVersions('1.10.0', '1.9.9'), 1, 'version gt')
eq(text.compareVersions('1.0', '1.0.0'), 0, 'version eq')

local sum = text.importSummary({ adopted = 5, matched = 3, collectionNames = { 'papat 採用 A 2026-10-10' },
  options = { '採用フラグを付ける' }, unmatched = { 'X.jpg', 'Y.jpg' }, ambiguous = { 'Z.jpg' }, limit = 1 })
eq(sum:find('採用した写真: 5 枚', 1, true) ~= nil, true, 'summary adopted')
eq(sum:find('コレクション「papat 採用 A 2026-10-10」に追加', 1, true) ~= nil, true, 'summary collection')
eq(sum:find('採用フラグを付ける', 1, true) ~= nil, true, 'summary option')
eq(sum:find('ほか 1 枚', 1, true) ~= nil, true, 'summary truncated list')
eq(sum:find('レーティング・カラーラベルは変更しません', 1, true) ~= nil, true, 'summary promise')

eq(text.appendMemo('', '余白を残す'), '— papat: 余白を残す', 'appendMemo empty caption')
eq(text.appendMemo('夕景 f/8', '余白を残す'), '夕景 f/8\n— papat: 余白を残す', 'appendMemo keeps caption')
local once = text.appendMemo('夕景', '余白を残す')
eq(text.appendMemo(once, '余白を残す'), nil, 'appendMemo idempotent')
eq(text.appendMemo(nil, ''), nil, 'appendMemo empty memo')
local twice = text.appendMemo(once, '別のメモ')
eq(twice, '夕景\n— papat: 余白を残す\n— papat: 別のメモ', 'appendMemo different memo appends')
eq(text.appendMemo('x', '1行目\n2行目') ~= nil and text.appendMemo(text.appendMemo('x', '1行目\n2行目'), '1行目\n2行目') == nil, true, 'appendMemo multi-line idempotent')

eq(text.parentPath('/a/b/papat.lrplugin'), '/a/b', 'parentPath')
eq(text.parentPath('/a/b/papat.lrplugin/'), '/a/b', 'parentPath trailing slash')
eq(text.samePath('/Users/x/Library/Application Support/', '/users/x/library/application support'), true, 'samePath case/slash')
eq(text.relativePath('/a/b', '/a/b/lib/x.lua'), 'lib/x.lua', 'relativePath')
eq(text.relativePath('/a/b', '/a/bc/x.lua'), nil, 'relativePath sibling prefix')
eq(text.inDownloads('/Users/x/Downloads/papat.lrplugin'), true, 'inDownloads')
eq(text.inDownloads('/Users/x/Documents/Lightroom Plugins/papat.lrplugin'), false, 'not inDownloads')
eq(text.inDownloads('/Users/x/Downloads'), true, 'inDownloads bare')

eq(text.normalizeKeyColor('#0066CC'), '#0066cc', 'keyColor normalizes case')
eq(text.normalizeKeyColor(' 0066cc '), '#0066cc', 'keyColor accepts missing #')
eq(text.normalizeKeyColor(''), '', 'keyColor empty = none')
eq(text.normalizeKeyColor('#06c'), nil, 'keyColor rejects 3 digits')
eq(text.normalizeKeyColor('#GG66CC'), nil, 'keyColor rejects non-hex')
eq(text.normalizeKeyColor('red'), nil, 'keyColor rejects names')
eq(text.normalizeKeyColor('#0066CC00'), nil, 'keyColor rejects 8 digits')
eq(text.rememberColor('#111111,#222222', '#333333'), '#333333,#111111,#222222', 'rememberColor prepends')
eq(text.rememberColor('#111111,#222222', '#222222'), '#222222,#111111', 'rememberColor moves to front')
eq(text.rememberColor('#111111,#222222,#333333,#444444,#555555', '#666666'), '#666666,#111111,#222222,#333333,#444444', 'rememberColor bounded to 5')
eq(text.rememberColor('junk,#111111', '#222222'), '#222222,#111111', 'rememberColor drops junk')
eq(#text.recentColors('#111111,xx,#222222'), 2, 'recentColors filters')

-- Modules folder detection (regression: a plug-in already in Modules was flagged)
local HOME = '/Users/example'
local MODS = '/Users/example/Library/Application Support/Adobe/Lightroom/Modules'
local ctx = { home = HOME, modulesDirs = { MODS } }
local function inModules(p, c) return text.isInModulesFolder(p, c or ctx) end
eq(inModules(MODS .. '/papat.lrplugin'), true, 'modules: absolute path')
eq(inModules(MODS .. '/papat.lrplugin/'), true, 'modules: trailing slash')
eq(inModules('~/Library/Application Support/Adobe/Lightroom/Modules/papat.lrplugin'), true, 'modules: ~ notation')
eq(inModules('~/Library/Application Support/Adobe/Lightroom/Modules/papat.lrplugin/'), true, 'modules: ~ with trailing slash')
eq(inModules('/System/Volumes/Data' .. MODS .. '/papat.lrplugin'), true, 'modules: /System/Volumes/Data prefix')
eq(inModules('/private/var/root/Library/Application Support/Adobe/Lightroom/Modules/papat.lrplugin', { home = '/var/root' }), true, 'modules: /private/var via home')
eq(inModules('/users/EXAMPLE/library/application support/adobe/lightroom/modules/papat.lrplugin'), true, 'modules: case-insensitive')
eq(inModules('/Users/example/Downloads/../Library/Application Support/Adobe/Lightroom/Modules/./papat.lrplugin'), true, 'modules: . and .. segments')
eq(inModules('/Users/example//Library//Application Support/Adobe/Lightroom/Modules//papat.lrplugin'), true, 'modules: doubled slashes')
eq(inModules('/Users/someone/Library/Application Support/Adobe/Lightroom/Modules/papat.lrplugin', { home = HOME }), true, 'modules: another user folder, same structure')
eq(inModules('/Library/Application Support/Adobe/Lightroom/Modules/papat.lrplugin', { home = HOME }), true, 'modules: system-wide Modules')
eq(inModules('/Volumes/Mac/home/me/Library/Application Support/Adobe/Lightroom/Modules/papat.lrplugin', { home = '/Volumes/Mac/home/me' }), true, 'modules: unusual home location')
eq(inModules('/weird/where/papat.lrplugin', { home = HOME, modulesDirs = { '/weird/where' } }), false, 'modules: an arbitrary "expected" dir does not count')
eq(inModules(MODS .. '/papat.lrplugin', { home = HOME, modulesDirs = { MODS } }), true, 'modules: expected dir that is standard')
eq(inModules('/Users/example/Library/Application Support/Adobe/Lightroom/Adobe/Lightroom/Modules/papat.lrplugin'), false, 'modules: the doubled Adobe/Lightroom path of 1.0.1 is not standard')

-- the only accepted copy target
eq(text.isStandardModulesDir(MODS, HOME), true, 'standardDir: user Modules')
eq(text.isStandardModulesDir('~/Library/Application Support/Adobe/Lightroom/Modules/', HOME), true, 'standardDir: ~ and trailing slash')
eq(text.isStandardModulesDir('/Library/Application Support/Adobe/Lightroom/Modules', HOME), true, 'standardDir: system-wide')
eq(text.isStandardModulesDir('/Users/example/Library/Application Support/Adobe/Lightroom/Adobe/Lightroom/Modules', HOME), false, 'standardDir: doubled Adobe/Lightroom (1.0.1 bug)')
eq(text.isStandardModulesDir('/Users/example/Library/Application Support/Adobe/Lightroom', HOME), false, 'standardDir: the Lightroom folder itself')
eq(text.isStandardModulesDir('/Users/example/Library/Application Support/Adobe/Lightroom/Modules/papat.lrplugin', HOME), false, 'standardDir: a child of Modules')
eq(text.isStandardModulesDir('/Users/example/Library/Application Support/Adobe/Modules', HOME), false, 'standardDir: Adobe/Modules')
eq(text.isStandardModulesDir('', HOME), false, 'standardDir: empty')
eq(inModules('/Users/example/Downloads/papat.lrplugin'), false, 'modules: Downloads is not standard')
eq(inModules('/Users/example/Documents/Lightroom Plugins/papat.lrplugin'), false, 'modules: Documents is not standard')
eq(inModules(MODS .. '/Other/papat.lrplugin'), false, 'modules: nested deeper is not standard')
eq(inModules(MODS .. 'X/papat.lrplugin'), false, 'modules: look-alike folder name')
eq(inModules('/Users/example/Library/Application Support/Adobe/Lightroom/papat-lightroom-backups/papat.lrplugin.20261010'), false, 'modules: backups folder')
eq(inModules('/tmp/x/Library/Application Support/Adobe/Lightroom/Modules/papat.lrplugin', { home = HOME }), false, 'modules: structure under an unrelated prefix')
eq(text.normalizePath('~/a/../b/', HOME), '/Users/example/b', 'normalizePath ~ and ..')
eq(text.normalizePath('/private/tmp/x'), '/tmp/x', 'normalizePath /private/tmp')
eq(text.normalizePath('/private/Users/x'), '/private/Users/x', 'normalizePath leaves other /private paths')
eq(text.normalizePath('C:\\Users\\x'), 'C:/Users/x', 'normalizePath backslashes')

eq(text.formatDuration(45), '45秒', 'duration seconds')
eq(text.formatDuration(250), '4分10秒', 'duration minutes')
eq(text.formatDuration(3700), '1時間1分40秒', 'duration hours')
eq(text.formatDuration(0.4), '0秒', 'duration rounds')
eq(text.formatDuration(-3), '0秒', 'duration clamps')

-- update decision / notice
local function decide(current, info) return text.updateDecision(current, info) end
eq(decide('1.0.1', { minimum = '1.0.0', latest = '1.0.1' }), 'none', 'update: up to date')
eq(decide('1.0.1', { minimum = '1.0.0', latest = '1.0.2' }), 'optional', 'update: newer exists, minimum not reached')
eq(decide('1.0.0', { minimum = '1.0.1', latest = '1.0.2' }), 'required', 'update: below the minimum')
eq(decide('1.0.1', { minimum = '1.0.2', latest = '1.0.2' }), 'optional', 'update: minimum == latest is only an announcement')
eq(decide('1.0.1', { minimum = '1.0.2' }), 'required', 'update: minimum alone (no latest) is a floor')
eq(decide('1.0.1', { minimum = '1.0.0', latest = '1.0.2', required = true }), 'required', 'update: explicit required flag')
eq(decide('1.0.2', { minimum = '1.0.0', latest = '1.0.2', required = true }), 'required', 'update: explicit flag wins')
eq(decide('1.0.1', { available = true }), 'optional', 'update: server says an update is available')
eq(decide('1.0.1', nil), 'none', 'update: no info')
eq(decide('1.0.1', {}), 'none', 'update: empty info')
eq(decide('1.0.1', { minimum = 'garbage', latest = 'x' }), 'none', 'update: unparsable versions')
eq(decide('1.10.0', { minimum = '1.9.0', latest = '1.10.0' }), 'none', 'update: numeric, not lexical, comparison')
eq(decide('1.0.9', { minimum = '1.0.10', latest = '1.1.0' }), 'required', 'update: 1.0.9 < 1.0.10')
eq(text.updateNoticeDue(nil, 1000), true, 'notice: never shown')
eq(text.updateNoticeDue(1000, 1000 + 3600), false, 'notice: within a day')
eq(text.updateNoticeDue(1000, 1000 + 86399), false, 'notice: just under a day')
eq(text.updateNoticeDue(1000, 1000 + 86400), true, 'notice: after a day')
eq(text.updateNoticeDue(5000, 1000), true, 'notice: clock moved back')
eq(text.updateNoticeDue('abc', 1000), true, 'notice: junk value')

-- jpeg: metadata removal ----------------------------------------------------
local function seg(marker, payload)
  local len = #payload + 2
  return '\255' .. string.char(marker) .. string.char(math.floor(len / 256), len % 256) .. payload
end
local SCAN = 'ENTROPY-DATA \255\0 with Exif and GPS words inside the picture data \255\0\1\2'
local function fakeJpeg(parts)
  local sof = '\8' .. '\0\16' .. '\0\32' .. '\1' .. '\1\17\0'      -- 8-bit, 16 high x 32 wide, 1 component
  local out = { '\255\216' }
  for _, p in ipairs(parts) do out[#out + 1] = p end
  out[#out + 1] = seg(0xDB, '\0' .. string.rep('\16', 64))                  -- DQT
  out[#out + 1] = seg(0xC0, sof)                                              -- SOF0
  out[#out + 1] = seg(0xC4, '\0' .. string.rep('\1', 16) .. '\0')          -- DHT
  out[#out + 1] = seg(0xDA, '\1\1\0\0\63\0')                            -- SOS header
  out[#out + 1] = SCAN
  out[#out + 1] = '\255\217'                                                -- EOI
  return table.concat(out)
end
local ORIGINAL = fakeJpeg({
  seg(0xE0, 'JFIF\0\1\1\0\0\1\0\1\0\0'),
  seg(0xE1, 'Exif\0\0MM\0*GPSLatitude=35.0 SerialNumber=12345 Artist=Someone'),
  seg(0xE1, 'http://ns.adobe.com/xap/1.0/\0<x:xmpmeta crs:Exposure2012="+0.5" xmpMM:History="..."/>'),
  seg(0xE2, 'ICC_PROFILE\0\1\1' .. string.rep('P', 40)),
  seg(0xE2, 'MPF\0multi-picture-data'),
  seg(0xED, 'Photoshop 3.0\0' .. '8BIM\4\4 CreatorWorkEmail=person-at-example'),
  seg(0xEE, 'Adobe\0\100\0\0\0\0\1'),
  seg(0xFE, 'comment with a phone number 03-0000-0000'),
})
local clean, rep, jerr = jpeg.sanitize(ORIGINAL)
eq(jerr, nil, 'jpeg: sanitize ok')
eq(clean ~= nil and #clean < #ORIGINAL, true, 'jpeg: smaller')
eq(rep and rep.removed.exif, 1, 'jpeg: Exif removed')
eq(rep and rep.removed.xmp, 1, 'jpeg: XMP removed')
eq(rep and rep.removed.iptc, 1, 'jpeg: IPTC removed')
eq(rep and rep.removed.comment, 1, 'jpeg: COM removed')
eq(rep and rep.removed['app2-other'], 1, 'jpeg: non-ICC APP2 (MPF) removed')
eq(rep and rep.icc, true, 'jpeg: ICC profile kept')
eq(rep and rep.width, 32, 'jpeg: width')
eq(rep and rep.height, 16, 'jpeg: height')
eq(clean:find('ICC_PROFILE', 1, true) ~= nil, true, 'jpeg: ICC bytes present')
eq(clean:find('JFIF', 1, true) ~= nil and clean:find('Adobe', 1, true) ~= nil, true, 'jpeg: JFIF and Adobe markers kept')
eq(clean:find('GPSLatitude', 1, true), nil, 'jpeg: GPS gone')
eq(clean:find('SerialNumber', 1, true), nil, 'jpeg: serial number gone')
eq(clean:find('crs:Exposure2012', 1, true), nil, 'jpeg: develop settings gone')
eq(clean:find('CreatorWorkEmail', 1, true), nil, 'jpeg: IPTC contact gone')
eq(clean:find('03-0000-0000', 1, true), nil, 'jpeg: comment gone')
eq(clean:sub(-#SCAN - 2), SCAN .. '\255\217', 'jpeg: picture data and EOI byte for byte')
eq(clean:sub(1, 2), '\255\216', 'jpeg: starts with SOI')
eq(jpeg.longEdge(clean), 32, 'jpeg: longEdge')
local again, rep2 = jpeg.sanitize(clean)
eq(again, clean, 'jpeg: sanitizing twice changes nothing')
eq(next(rep2.removed), nil, 'jpeg: second pass removes nothing')

-- fill bytes before a marker, and a file without metadata at all
local padded = '\255\216\255\255' .. string.char(0xE1) .. '\0\8Exif\0\0' .. ORIGINAL:sub(3 + #seg(0xE0, 'JFIF\0\1\1\0\0\1\0\1\0\0')):gsub('^.-(\255\219)', '%1')
local okPad = jpeg.sanitize(padded)
eq(okPad ~= nil, true, 'jpeg: fill bytes before a marker are accepted')
eq(jpeg.sanitize(fakeJpeg({})) ~= nil, true, 'jpeg: metadata-free file passes')

-- anything unexpected is refused (callers must not upload the original)
eq(select(3, jpeg.sanitize('not a jpeg')) ~= nil, true, 'jpeg: not a JPEG refused')
eq(select(3, jpeg.sanitize(ORIGINAL:sub(1, 60))) ~= nil, true, 'jpeg: truncated header refused')
eq(select(3, jpeg.sanitize('\255\216' .. seg(0xE1, 'Exif\0\0') .. '\255\217')) ~= nil, true, 'jpeg: EOI before SOS refused')
eq(select(3, jpeg.sanitize('\255\216\255\225\255\255abc')) ~= nil, true, 'jpeg: segment longer than the file refused')
eq(select(3, jpeg.sanitize('\255\216' .. seg(0xE0, 'JFIF\0') .. seg(0xDA, '\1\1\0\0\63\0') .. 'x')) ~= nil, true, 'jpeg: no frame header refused')
eq(jpeg.longEdge('garbage'), nil, 'jpeg: longEdge of garbage')
eq(select(3, jpeg.sanitize(ORIGINAL:sub(1, #ORIGINAL - 2))) ~= nil, true, 'jpeg: file without EOI (truncated download) refused')
eq(jpeg.sanitize(ORIGINAL .. '\0\0\0\0') ~= nil, true, 'jpeg: trailing zero padding tolerated')
eq(select(2, jpeg.withSegments(ORIGINAL:sub(1, #ORIGINAL - 2), 'x')) ~= nil or jpeg.withSegments(ORIGINAL:sub(1, #ORIGINAL - 2), 'x') == nil, true, 'jpeg: withSegments does not accept garbage')

-- icc: generated sRGB profile and tagging
local profile = icc.srgb()
eq(#profile, 2532, 'icc: profile size')
eq(profile:sub(37, 40), 'acsp', 'icc: signature')
eq(profile:sub(13, 20), 'mntrRGB ', 'icc: class and colour space')
eq(profile:byte(1) * 16777216 + profile:byte(2) * 65536 + profile:byte(3) * 256 + profile:byte(4), #profile, 'icc: size field')
eq(icc.srgb(), profile, 'icc: cached')
local plain = fakeJpeg({ seg(0xE0, 'JFIF\0\1\1\0\0\1\0\1\0\0') })
local tagged = jpeg.withIcc(plain, profile)
eq(tagged ~= nil and jpeg.parse(tagged).icc, true, 'icc: tagged file has a profile')
eq(tagged:sub(1, 2), '\255\216', 'icc: SOI first')
eq(tagged:find('ICC_PROFILE', 1, true) ~= nil and tagged:find('JFIF', 1, true) < tagged:find('ICC_PROFILE', 1, true), true, 'icc: after JFIF')
eq(tagged:sub(-#SCAN - 2), SCAN .. '\255\217', 'icc: picture data untouched')
eq(jpeg.withIcc(tagged, profile), tagged, 'icc: already tagged files are left alone')
eq(jpeg.longEdge(tagged), 32, 'icc: still readable')
eq(select(2, jpeg.withIcc('junk', profile)) ~= nil, true, 'icc: junk refused')

-- capture time and gallery order
eq(text.isoWallTime('2026-10-12T05:33:21'), '2026-10-12T05:33:21', 'datetime: plain')
eq(text.isoWallTime('2026-10-12T05:33:21+09:00'), '2026-10-12T05:33:21', 'datetime: zone dropped')
eq(text.isoWallTime('2026-10-12T05:33:21Z'), '2026-10-12T05:33:21', 'datetime: Z dropped (wall clock kept)')
eq(text.isoWallTime('2026-10-12T05:33:21.123456'), '2026-10-12T05:33:21', 'datetime: fraction dropped')
eq(text.isoWallTime('2026-10-12 05:33:21'), '2026-10-12T05:33:21', 'datetime: space separator')
eq(text.isoWallTime('2026-10-12T05:33'), '2026-10-12T05:33:00', 'datetime: no seconds')
eq(text.isoWallTime('2026-13-12T05:33:21'), nil, 'datetime: bad month')
eq(text.isoWallTime('1900-01-01T00:00:00'), nil, 'datetime: implausible year')
eq(text.isoWallTime('garbage'), nil, 'datetime: garbage')
eq(text.isoWallTime(nil), nil, 'datetime: nil')
eq(text.cocoaToWallTime(0), '2001-01-01T00:00:00', 'cocoa: epoch')
eq(text.cocoaToWallTime(86400 * 365), '2002-01-01T00:00:00', 'cocoa: one year')
local cocoa = text.isoToEpoch('2026-10-12T05:33:21Z') - text.isoToEpoch('2001-01-01T00:00:00Z')
eq(text.cocoaToWallTime(cocoa), '2026-10-12T05:33:21', 'cocoa: round trip')
eq(text.cocoaToWallTime('x'), nil, 'cocoa: junk')
local function ph(dt, name, order) return { datetime = dt, sortName = name, order = order } end
local list = {
  ph('', 'z_scan.jpg', 1), ph('2026-10-12T10:00:05', 'cam2_001.jpg', 2), ph('2026-10-12T10:00:00', 'img_a002.jpg', 3),
  ph('2026-10-12T10:00:00', 'img_a001.jpg', 4), ph('', 'a_scan.jpg', 5), ph('2026-10-11T23:59:59', 'img_old.jpg', 6),
}
table.sort(list, text.photoOrderLess)
local names = {}
for _, p in ipairs(list) do names[#names + 1] = p.sortName end
eq(table.concat(names, ','), 'img_old.jpg,img_a001.jpg,img_a002.jpg,cam2_001.jpg,a_scan.jpg,z_scan.jpg', 'order: time, then name; undated last by name')

-- rights: copyright / creator / contact segments
local R = rights.collect(function(key, raw)
  local values = {
    copyright = '  © 2026 山田 太郎 & Co.  ', copyrightState = 'copyrighted', creator = '山田 太郎',
    rightsUsageTerms = 'Contact before use', creatorEmail = 'taro-at-example', creatorPhone = '03-0000-0000',
    creatorAddress = "1-2-3 <Shibuya>", creatorCity = '', creatorCountry = 'Japan', creatorUrl = 'https://example.org/',
    creatorJobTitle = 'Photographer', copyrightInfoUrl = '', creatorPostalCode = '000-0000', creatorStateProvince = 'Tokyo',
  }
  return values[key]
end)
eq(R.copyright, '© 2026 山田 太郎 & Co.', 'rights: trimmed copyright')
eq(R.state, 'copyrighted', 'rights: state kept')
eq(R.city, nil, 'rights: empty values are dropped')
eq(rights.collect(function(k) if k == 'copyrightState' then return 'unknown' end end).state, nil, 'rights: unknown state is not a value')
eq(rights.isEmpty(rights.collect(function() return nil end)), true, 'rights: nothing registered')
local xmp = rights.xmp(R)
eq(xmp:find('<dc:rights>', 1, true) ~= nil and xmp:find('© 2026 山田 太郎 &amp; Co.', 1, true) ~= nil, true, 'rights: XMP copyright, escaped')
eq(xmp:find('&lt;Shibuya&gt;', 1, true) ~= nil, true, 'rights: XMP escapes markup in values')
eq(xmp:find('<dc:creator><rdf:Seq><rdf:li>山田 太郎</rdf:li>', 1, true) ~= nil, true, 'rights: XMP creator')
eq(xmp:find('CiEmailWork>taro-at-example<', 1, true) ~= nil and xmp:find('CiTelWork>03-0000-0000<', 1, true) ~= nil, true, 'rights: XMP contact info')
eq(xmp:find('xmpRights:Marked="True"', 1, true) ~= nil, true, 'rights: XMP copyright status')
eq(xmp:find('GPS', 1, true), nil, 'rights: no location in XMP')
local tiff = rights.exifTiff(R)
local function le16(s, i) return s:byte(i) + s:byte(i + 1) * 256 end
local function le32(s, i) return le16(s, i) + le16(s, i + 2) * 65536 end
eq(tiff:sub(1, 4), 'II*\0', 'rights: TIFF header')
eq(le32(tiff, 5), 8, 'rights: IFD0 offset')
eq(le16(tiff, 9), 2, 'rights: two entries (Artist, Copyright)')
local function ifdText(tag)
  for i = 0, 1 do
    local at = 11 + i * 12
    if le16(tiff, at) == tag then
      local n, off = le32(tiff, at + 4), le32(tiff, at + 8)
      return tiff:sub(off + 1, off + n - 1)
    end
  end
end
eq(ifdText(0x013B), '山田 太郎', 'rights: Exif Artist')
eq(ifdText(0x8298), '© 2026 山田 太郎 & Co.', 'rights: Exif Copyright')
eq(rights.segments({}), '', 'rights: nothing to say, no segments')
local segs = rights.segments(R)
local plain2 = fakeJpeg({ seg(0xE0, 'JFIF\0\1\1\0\0\1\0\1\0\0') })
local withRights = jpeg.withSegments(plain2, segs)
eq(withRights ~= nil and jpeg.longEdge(withRights), 32, 'rights: file still reads after adding segments')
eq(withRights:find('Exif\0\0II', 1, true) ~= nil and withRights:find('http://ns.adobe.com/xap/1.0/', 1, true) ~= nil, true, 'rights: Exif and XMP present')
eq(withRights:sub(-#SCAN - 2), SCAN .. '\255\217', 'rights: picture data untouched')
-- the full path: a "dirty" export is stripped, then only ours is added back
local dirty = fakeJpeg({
  seg(0xE0, 'JFIF\0\1\1\0\0\1\0\1\0\0'),
  seg(0xE1, 'Exif\0\0MM\0*GPSLatitude=35.0 SerialNumber=SN1 Artist=Someone'),
  seg(0xE1, 'http://ns.adobe.com/xap/1.0/\0<x:xmpmeta crs:Exposure2012="+1" xmpMM:History="x" aux:SerialNumber="9"/>'),
  seg(0xED, 'Photoshop 3.0\0' .. '8BIM CreatorWorkEmail=old-at-example'),
})
local cleaned = jpeg.sanitize(dirty)
local rebuilt = jpeg.withSegments(cleaned, segs)
eq(rebuilt:find('GPSLatitude', 1, true), nil, 'rights: location gone after rebuild')
eq(rebuilt:find('SerialNumber', 1, true), nil, 'rights: serial numbers gone after rebuild')
eq(rebuilt:find('crs:Exposure2012', 1, true), nil, 'rights: develop settings gone after rebuild')
eq(rebuilt:find('old-at-example', 1, true), nil, 'rights: Lightroom\'s own contact block gone, only ours remains')
eq(rebuilt:find('CiEmailWork>taro-at-example<', 1, true) ~= nil, true, 'rights: our contact info is present')
-- very long values still fit one segment
local longFields = { copyright = string.rep('c', 1000), creator = 'x', terms = string.rep('t', 1000),
  address = string.rep('a', 1000), city = string.rep('b', 1000), url = string.rep('u', 1000) }
for i = 1, 40 do longFields['f' .. i] = nil end
local longSeg = rights.segments(longFields)
eq(#longSeg > 0 and #longSeg < 4 * 65536, true, 'rights: long values produce segments')

-- the export session must not be created inside pcall (Lightroom refuses: "must not call on main UI task")
do
  local f = io.open(_PLUGIN.path .. '/lib/export.lua', 'rb')
  local source = f:read('*a')
  f:close()
  eq(source:find('pcall%s*%(%s*LrExportSession') == nil, true, 'export: LrExportSession is not called through pcall')
  eq(source:find('LR_embeddedMetadataOption%s*=') == nil, true, 'export: no embedded-metadata option is passed')
end

-- selections ----------------------------------------------------------------
local v1 = json.decode([[{"ok":true,"schema":"papat.selections/v1","sid":"S1","title":"案件","finalized_at":"2026-10-10T02:00:00.000Z",
  "adopted":[{"source_id":"u1","filename":"DSC_0001.jpg","stem":"DSC_0001","adopted":true,"rating":5,"tags":["表紙候補"],"memo":"右に余白"},
             {"source_id":null,"filename":null,"stem":"OLD_01","adopted":true,"rating":9,"tags":[],"memo":""}]}]])
local n = selections.normalize(v1)
eq(#n.items, 2, 'v1 items')
eq(n.sid, 'S1', 'v1 sid')
eq(n.items[1].sourceId, 'u1', 'v1 source id')
eq(n.items[1].tags[1], '表紙候補', 'v1 tag')
eq(n.items[2].sourceId, '', 'v1 null source id')
eq(n.items[2].rating, 5, 'v1 rating clamp')
local legacy = json.decode('{"version":1,"adopted":[{"stem":"A","rating":2,"tags":"x, y","memo":"m"}]}')
n = selections.normalize(legacy)
eq(#n.items, 1, 'legacy items')
eq(#n.items[1].tags, 2, 'legacy tags split')
local full = json.decode('{"ok":true,"gallery":{"id":"G","title":"T"},"photos":[{"stem":"A","adopted":true},{"stem":"B","adopted":false}]}')
n = selections.normalize(full)
eq(#n.items, 1, 'photos variant only adopted')
eq(n.sid, 'G', 'photos variant gallery id')
eq(select(2, selections.normalize({ ok = true })) ~= nil, true, 'normalize error')

-- matching ------------------------------------------------------------------
local function item(o)
  return { sourceId = o.sourceId or '', filename = o.filename or '', stem = o.stem or text.stemOf(o.filename or ''),
           rating = o.rating or 0, tags = o.tags or {}, memo = o.memo or '' }
end
local p1 = { handle = 'p1', sourceId = 'u1', sid = 'S1', papatFilename = 'DSC_0001.jpg', fileName = 'DSC_0001.NEF' }
local p2 = { handle = 'p2', sourceId = 'u2', sid = 'S1', papatFilename = 'DSC_0002.jpg', fileName = 'DSC_0002.NEF' }
local p3 = { handle = 'p3', sourceId = '', sid = '', papatFilename = '', fileName = 'LEGACY_01.CR3' }
local p4 = { handle = 'p4', sourceId = '', sid = '', papatFilename = '', fileName = 'DUP_01.CR3' }
local p5 = { handle = 'p5', sourceId = '', sid = '', papatFilename = '', fileName = 'DUP_01.JPG' }
local all = { p1, p2, p3, p4, p5 }
local loads = 0
local function loadAll() loads = loads + 1; return all end

local r = matching.match({ item{ sourceId = 'u1', filename = 'whatever.jpg' } }, 'S1', { p1, p2 }, loadAll)
eq(#r.matched, 1, 'match by source id')
eq(r.matched[1].handle, 'p1', 'match by source id handle')
eq(loads, 0, 'no catalog scan when linked match')

r = matching.match({ item{ filename = 'dsc_0002.JPG' } }, 'S1', { p1, p2 }, loadAll)
eq(r.matched[1] and r.matched[1].handle, 'p2', 'match by sid + filename (case-insensitive)')
eq(r.matched[1] and r.matched[1].how, 'sid', 'how = sid')

r = matching.match({ item{ stem = 'LEGACY_01' } }, 'S9', { p1, p2 }, loadAll)
eq(r.matched[1] and r.matched[1].handle, 'p3', 'stem fallback over whole catalog')
eq(r.matched[1] and r.matched[1].how, 'stem', 'how = stem')
eq(loads, 1, 'catalog scanned once')

r = matching.match({ item{ stem = 'DUP_01' } }, 'S9', {}, loadAll)
eq(#r.matched, 0, 'ambiguous not applied')
eq(#r.ambiguous, 1, 'ambiguous reported')
eq(r.ambiguous[1].count, 2, 'ambiguous count')

r = matching.match({ item{ filename = 'DUP_01.JPG' } }, 'S9', {}, loadAll)
eq(r.matched[1] and r.matched[1].handle, 'p5', 'exact filename beats stem')

r = matching.match({ item{ stem = 'NOPE' } }, 'S1', { p1 }, loadAll)
eq(#r.unmatched, 1, 'unmatched reported')

r = matching.match({ item{ stem = 'NOPE' } }, 'S1', { p1 }, nil)
eq(#r.unmatched, 1, 'unmatched without catalog scan')

-- duplicate results for one photo: identical -> collapse, differing -> hold back
r = matching.match({ item{ sourceId = 'u1', rating = 2 }, item{ sourceId = 'u1', rating = 2 } }, 'S1', { p1 }, loadAll)
eq(#r.matched, 1, 'duplicate identical collapses')
eq(#r.ambiguous, 0, 'duplicate identical not ambiguous')
r = matching.match({ item{ sourceId = 'u1', rating = 2 }, item{ sourceId = 'u1', rating = 3 }, item{ sourceId = 'u2', rating = 1 } }, 'S1', { p1, p2 }, loadAll)
eq(#r.matched, 1, 'conflict holds back photo')
eq(r.matched[1].handle, 'p2', 'other photo still applied')
eq(#r.ambiguous, 2, 'conflict reported')

-- same source id on two photos (e.g. virtual copy): narrowed by sid, else ambiguous
local v1p = { handle = 'v1', sourceId = 'uX', sid = 'S1', papatFilename = 'X.jpg', fileName = 'X.NEF' }
local v2p = { handle = 'v2', sourceId = 'uX', sid = 'S0', papatFilename = 'X.jpg', fileName = 'X.NEF' }
r = matching.match({ item{ sourceId = 'uX' } }, 'S1', { v1p, v2p }, nil)
eq(r.matched[1] and r.matched[1].handle, 'v1', 'source id narrowed by sid')
r = matching.match({ item{ sourceId = 'uX' } }, 'S9', { v1p, v2p }, nil)
eq(#r.ambiguous, 1, 'source id ambiguous')

-- collection plan ------------------------------------------------------------
local mm = {
  { item = { rating = 3 }, handle = 'a' },
  { item = { rating = 1 }, handle = 'b' },
  { item = { rating = 0 }, handle = 'c' },
  { item = { rating = 3 }, handle = 'd' },
}
local plan = matching.collectionPlan(mm, '春の撮影', '2026-10-10', false)
eq(#plan, 1, 'flat plan: one collection')
eq(plan[1].name, 'papat 採用 春の撮影 2026-10-10', 'flat plan: name')
eq(plan[1].set, nil, 'flat plan: no set')
eq(#plan[1].handles, 4, 'flat plan: all photos')
plan = matching.collectionPlan(mm, '春の撮影', '2026-10-10', true)
eq(#plan, 3, 'star plan: 採用 + ★3 + ★1')
eq(plan[1].name, '採用', 'star plan: first is 採用')
eq(plan[1].set, 'papat 春の撮影 2026-10-10', 'star plan: set name')
eq(plan[2].name, '★3', 'star plan: ★3 child')
eq(#plan[2].handles, 2, 'star plan: ★3 count')
eq(plan[3].name, '★1', 'star plan: ★1 child')
plan = matching.collectionPlan(mm, '', '2026-10-10', false)
eq(plan[1].name, 'papat 採用 2026-10-10', 'flat plan: no title')


-- Free galleries come from the server, never from the plug-in ---------------
eq(text.parseFreeRemaining(5), 5, 'free: number')
eq(text.parseFreeRemaining('8'), 8, 'free: numeric string')
eq(text.parseFreeRemaining(0), 0, 'free: zero is a number')
eq(text.parseFreeRemaining(nil), nil, 'free: missing')
eq(text.parseFreeRemaining('many'), nil, 'free: not a number')
eq(text.parseFreeRemaining(-1), nil, 'free: negative')
eq(text.parseFreeRemaining(2.9), 2, 'free: whole galleries')
eq(text.priceLine(9, 7, 5), '目安 88 円（税込）　※無料の残り 5 ギャラリー', 'priceLine: free remaining')
eq(text.priceLine(9, 14, 0), '目安 176 円（税込）　※無料の残りはありません', 'priceLine: none left')
eq(text.priceLine(9, 7, nil), '目安 88 円（税込）', 'priceLine: unknown = the free allowance is not mentioned')
eq(text.priceLine(301, 7, 8), '目安 176 円（税込）　※無料の残り 8 ギャラリー', 'priceLine: units')

-- Dialog text layout (fixed height_in_lines must not cut the text) -------------
eq(text.displayUnits('あいう'), 3, 'displayUnits: Japanese counts 1 per character')
eq(math.abs(text.displayUnits('abc') - 1.8) < 1e-9, true, 'displayUnits: ASCII is narrower')
eq(text.wrappedLines('', 520), 1, 'wrappedLines: empty is one line')
eq(text.wrappedLines('あ\nい\nう', 520), 3, 'wrappedLines: newlines')
eq(text.wrappedLines(string.rep('あ', 37), 520), 1, 'wrappedLines: fits 37 per line at 520 px')
eq(text.wrappedLines(string.rep('あ', 38), 520), 2, 'wrappedLines: wraps at 38')
eq(text.linesFor('あ', 520, 3), 3, 'linesFor: not below the minimum')
eq(text.linesFor(string.rep('あ', 100), 520, 2), 3, 'linesFor: grows with the text')
do
  -- the intro of the "create gallery" dialog stays within its two lines for every
  -- combination and for 1 to 5 digit photo counts
  local worst = 0
  for _, fast in ipairs({ false, true }) do
    for _, rightsOn in ipairs({ false, true }) do
      for _, n in ipairs({ 1, 9, 99, 299, 900, 9999 }) do
        local s = text.createIntro(n, { longEdge = 2048, fast = fast, embedRights = rightsOn })
        worst = math.max(worst, text.wrappedLines(s, 520))
      end
    end
  end
  eq(worst <= 2, true, 'createIntro: at most 2 lines at 520 px (worst ' .. worst .. ')')
  eq(text.createIntro(9, { longEdge = 2048, embedRights = true }),
    '選択中の 9 枚を、長辺 2048 px の JPEG にして送ります（RAW 原本は送りません）。画像には、著作権・作成者・連絡先だけが入ります。',
    'createIntro: default text')
end

print(string.format('%d checks, %d failed', total, failed))
os.exit(failed == 0 and 0 or 1)
