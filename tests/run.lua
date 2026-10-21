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

-- text: price (decided 2026-10-20: 1 ギャラリー
-- 88 円・88 枚までは 8 円・延長 +88 円。枚数で額が増える仕組みは廃止） ------------------------
eq(text.priceYen(1, 7), 8, 'price 1 photo 7d (88 枚までは 8 円)')
eq(text.priceYen(88, 7), 8, 'price exactly 88 photos 7d (8 円の上限)')
eq(text.priceYen(89, 7), 88, 'price 89 photos 7d (89 枚目から 88 円)')
eq(text.priceYen(300, 7), 88, 'price 300 photos 7d')
eq(text.priceYen(1000, 7), 88, 'price 1,000 photos 7d (サーバーの上限でも 88 円)')
eq(text.priceYen(9, 14), 96, 'price 9 photos 14d (8 + 88)')
eq(text.priceYen(300, 14), 176, 'price 300 photos 14d (88 + 88)')
eq(text.priceYen(900, 14), 176, 'price 900 photos 14d (枚数では増えない)')
eq(text.priceYenSplit({ 750, 138 }, 7), text.priceYen(750, 7) + text.priceYen(138, 7), 'priceYenSplit: sums each gallery')
eq(text.priceYenSplit({ 800, 800, 400 }, 7), 88 * 3, 'priceYenSplit: 2,000 枚を分けた 3 ギャラリー分（264円）')
eq(text.priceLineYen(88, nil), '目安 88 円（税込）', 'priceLineYen: no free count')
eq(text.priceLineYen(88, 0), '目安 88 円（税込）　※無料の残りはありません', 'priceLineYen: free exhausted')
eq(text.priceLineYen(88, 3), '目安 88 円（税込）　※無料の残り 3 ギャラリー', 'priceLineYen: free remaining')
-- 無料の残りがあるときは、写真の分を 0 円で出す（延長は無料の 8 本の中でも +88 円のまま）
eq(text.priceLine(10, 7, 5), '目安 0 円（税込）　※無料の残り 5 ギャラリー', 'priceLine: free remaining -> photos are 0 yen')
eq(text.priceLine(1000, 7, 1), '目安 0 円（税込）　※無料の残り 1 ギャラリー', 'priceLine: free remaining -> 0 yen even at 1,000 photos')
eq(text.priceLine(10, 14, 5), '目安 88 円（税込）　※無料の残り 5 ギャラリー', 'priceLine: free remaining, 14 days -> extension still +88 yen')
eq(text.priceLine(10, 7, 0), '目安 8 円（税込）　※無料の残りはありません', 'priceLine: no free remaining -> the real price')
-- 2,000 枚を分けて、無料が 2 本残っていれば、1・2 本目が 0 円、3 本目が 88 円
eq(text.priceYenSplit({ 800, 800, 400 }, 7, 2), 88, 'priceYenSplit: free covers the first 2 of 3 segments')
eq(text.splitLine({ 750, 138 }), '888 枚を 2 つのギャラリーに分けて送ります（750枚・138枚）', 'splitLine: two galleries')
eq(text.splitLine({ 888, 888, 224 }), '2000 枚を 3 つのギャラリーに分けて送ります（888枚・888枚・224枚）', 'splitLine: three galleries')

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

-- 2026-10-20 (pricing-plans-v0.1.md §10.6, B54): the expiry line needs the day of week and the
-- time — 10/27 (the pricing doc's own worked example, created 2026-10-20 + 7 days) is a Tuesday
eq(text.jaDateTimeWithWeekday('2026-10-27T02:00:00Z', 9 * 3600), '10月27日（火）11:00',
  'jaDateTimeWithWeekday: the pricing doc\'s own example (8 日目の 11:00 JST)')
eq(text.expireText('2026-10-27T02:00:00Z', 9 * 3600), '10月27日（火）11:00まで', 'expireText: appends まで')
eq(text.jaDateTimeWithWeekday('2026-11-03T02:00:00Z', 9 * 3600), '11月3日（火）11:00', 'jaDateTimeWithWeekday: 14泊15日 の例')
eq(text.jaDateTimeWithWeekday('garbage', 9 * 3600), nil, 'jaDateTimeWithWeekday: unparsable = nil')
eq(text.expireText('garbage', 9 * 3600), '', 'expireText: unparsable = empty string (no line at all)')
eq(text.expireText(nil, 9 * 3600), '', 'expireText: nil = empty string')

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
eq(ann, '写真をお送りします。\n春の撮影\n\nURL: https://papat.app/t/x/s/y/#p=ABC234\nパスコード: ABC234\n公開期限: 10月17日まで\n\nブラウザで開いて、気に入った写真に★を付けて「確定」を押してください。', 'announcement layout')
eq(ann:find('登録', 1, true), nil, 'announcement: no "登録は要りません"')
eq(text.announcement({ url = 'u', passcode = 'p' }), '写真をお送りします。\n\nURL: u#p=p\nパスコード: p\n\nブラウザで開いて、気に入った写真に★を付けて「確定」を押してください。', 'announcement without title/expiry')

-- announcement: 1.2.0's auto-split (several URLs, "N/M：URL" per line; opts.urls wins over opts.url)
-- 1.2.2: the URL line is {パスコード入りURL} by default, so each one also carries "#p=<passcode>"
eq(text.announcement({ urls = { 'https://a/' }, passcode = 'p' }),
  '写真をお送りします。\n\nURL: https://a/#p=p\nパスコード: p\n\nブラウザで開いて、気に入った写真に★を付けて「確定」を押してください。',
  'announcement: a single-entry urls behaves exactly like url')
eq(text.announcement({ title = '春の撮影', urls = { 'https://a/', 'https://b/' }, passcode = 'ABC234', expireText = '10月17日まで' }),
  '写真をお送りします。\n春の撮影\n\nURL: 1/2：https://a/#p=ABC234\n2/2：https://b/#p=ABC234\nパスコード: ABC234\n公開期限: 10月17日まで\n\n'
    .. 'ブラウザで開いて、気に入った写真に★を付けて「確定」を押してください。',
  'announcement: two URLs, one per line, each numbered')
eq(text.announcement({ urls = { 'https://a/', 'https://b/', 'https://c/' } }):find('1/3：https://a/', 1, true) ~= nil
  and text.announcement({ urls = { 'https://a/', 'https://b/', 'https://c/' } }):find('3/3：https://c/', 1, true) ~= nil,
  true, 'announcement: three URLs, all numbered out of 3')
eq(text.announcement({ url = 'https://single/', urls = {}, passcode = 'p' }):find('https://single/', 1, true) ~= nil,
  true, 'announcement: an empty urls table falls back to url')

-- 1.2.2: {パスコード入りURL} — a gallery URL with the passcode folded in (added 2026-10-20;
-- https://papat.app/t/{tenant}/s/{sid}/#p={パスコード}; gallery-side support is separate work)
eq(text.passcodeUrl('https://papat.app/t/x/s/y/', 'ABC234'), 'https://papat.app/t/x/s/y/#p=ABC234', 'passcodeUrl: basic')
eq(text.passcodeUrl('https://papat.app/t/x/s/y/', 'a b&c'), 'https://papat.app/t/x/s/y/#p=a%20b%26c',
  'passcodeUrl: the passcode is percent-encoded (a fragment, not a bare path segment)')
eq(text.passcodeUrl('https://x/', nil), 'https://x/', 'passcodeUrl: no passcode = the bare URL, no "#p="')
eq(text.passcodeUrl('https://x/', ''), 'https://x/', 'passcodeUrl: empty passcode = the bare URL, no "#p="')
eq(text.passcodeUrl(nil, 'ABC234'), nil, 'passcodeUrl: no URL = nil, not "#p=" on its own')
eq(text.PASSCODE_URL_KEY, 'p', 'passcodeUrl: the fragment key is "p" (subject to change)')

-- a template that asks for {パスコード入りURL} explicitly gets the same value the default does
-- (none of these name {パスコード} separately, so the missing-passcode fallback still appends
-- its own line, same as a template that only names {URL} would — nothing new about that part)
eq(text.announcement({ url = 'https://papat.app/t/x/s/y/', passcode = 'ABC234', template = 'どうぞ: {パスコード入りURL}' }),
  'どうぞ: https://papat.app/t/x/s/y/#p=ABC234\nパスコード: ABC234', 'announcement: {パスコード入りURL} mark, own wording')
eq(text.announcement({ url = 'https://papat.app/t/x/s/y/', passcode = 'ABC234', template = '{urlwithpasscode}' }),
  '{urlwithpasscode}\n\nURL: https://papat.app/t/x/s/y/\nパスコード: ABC234',
  'announcement: unknown mark name stays literal (not an alias) and the real URL/passcode still get appended')
eq(text.announcement({ url = 'https://papat.app/t/x/s/y/', passcode = 'ABC234', template = '{passcodeurl}' }),
  'https://papat.app/t/x/s/y/#p=ABC234\nパスコード: ABC234', 'announcement: the English mark name (lowercase) also works')
-- a template using {パスコード入りURL} does not ALSO get a redundant plain "URL:" fallback line
eq(text.announcement({ url = 'https://papat.app/t/x/s/y/', passcode = 'ABC234', template = '{パスコード入りURL}' })
  :find('URL:', 1, true), nil, 'announcement: {パスコード入りURL} alone does not trigger the missing-URL fallback')
-- a template with neither URL mark still gets the (plain) URL appended, as before
eq(text.announcement({ url = 'https://papat.app/t/x/s/y/', passcode = 'ABC234', template = 'こんにちは。' }),
  'こんにちは。\n\nURL: https://papat.app/t/x/s/y/\nパスコード: ABC234',
  'announcement: the missing-URL fallback still uses the plain URL, not the passcode-embedded one')
-- the split case: each numbered line carries its own gallery\'s passcode-embedded URL
eq(text.announcement({ urls = { 'https://a/', 'https://b/' }, passcode = 'ABC234', template = '{パスコード入りURL}' }),
  '1/2：https://a/#p=ABC234\n2/2：https://b/#p=ABC234\nパスコード: ABC234',
  'announcement: {パスコード入りURL} numbers every gallery, split')
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


-- Announcement template (1.1.0) --------------------------------------------------
do
  local url, pass = 'https://papat.app/t/x/s/y/', 'ABC234'
  local urlWithPasscode = url .. '#p=' .. pass -- 1.2.2: the default template's URL line now
  local function ann(template, extra)
    local o = { title = '春の撮影', url = url, passcode = pass, expireText = '10月17日まで', template = template }
    for k, v in pairs(extra or {}) do o[k] = v end
    return text.announcement(o)
  end
  -- the default template: URL line carries the passcode folded in (1.2.2)
  eq(ann(nil), '写真をお送りします。\n春の撮影\n\nURL: ' .. urlWithPasscode .. '\nパスコード: ' .. pass
    .. '\n公開期限: 10月17日まで\n\nブラウザで開いて、気に入った写真に★を付けて「確定」を押してください。', 'template: default = the old text, URL with the passcode folded in')
  eq(ann(nil, { title = '', expireText = '' }), '写真をお送りします。\n\nURL: ' .. urlWithPasscode .. '\nパスコード: ' .. pass
    .. '\n\nブラウザで開いて、気に入った写真に★を付けて「確定」を押してください。', 'template: lines with empty marks are left out')
  -- own wording
  eq(ann('{題} の写真です。\n{URL}\nパスコードは {パスコード} です（{期限}）。'),
    '春の撮影 の写真です。\n' .. url .. '\nパスコードは ABC234 です（10月17日まで）。', 'template: own wording')
  eq(ann('{title}: {url} / {passcode} / {expire}'), '春の撮影: ' .. url .. ' / ABC234 / 10月17日まで', 'template: English mark names')
  -- missing URL / passcode are added at the end; unknown and broken marks stay
  eq(ann('こんにちは。'), 'こんにちは。\n\nURL: ' .. url .. '\nパスコード: ' .. pass, 'template: missing URL and passcode are added')
  eq(ann('{URL} だけ'), url .. ' だけ\nパスコード: ' .. pass, 'template: missing passcode is added')
  eq(ann('{URL} {unknown} {パスコード {題'), url .. ' {unknown} {パスコード {題\nパスコード: ' .. pass,
    'template: unknown / broken marks stay as written (and the passcode is added)')
  -- unusable templates are the default
  eq(ann(''), ann(nil), 'template: empty = default')
  eq(ann('   \n  '), ann(nil), 'template: blank = default')
  eq(ann(42), ann(nil), 'template: not a string = default')
  eq(ann(string.rep('あ', 2001)), ann(nil), 'template: too long = default')
  eq(ann('{題}\r\n{URL}\r{パスコード}'), '春の撮影\n' .. url .. '\n' .. pass, 'template: Windows / old Mac line ends')
  eq(text.announcement({ url = 'u', passcode = 'p' }),
    '写真をお送りします。\n\nURL: u#p=p\nパスコード: p\n\nブラウザで開いて、気に入った写真に★を付けて「確定」を押してください。', 'template: no opts beyond url/passcode')

  -- an edited announcement becomes a template again
  local edited = '春の撮影です。\n春の撮影\n' .. url .. '\nパスコード ABC234\n10月17日まで開けます。'
  local template = text.templateFromAnnouncement(edited, { title = '春の撮影', url = url, passcode = pass, expireText = '10月17日まで' })
  eq(template, '春の撮影です。\n{題}\n{URL}\nパスコード {パスコード}\n{期限}開けます。',
    'fromAnnouncement: values become marks; the title only on a line of its own')
  eq(ann(template, { title = 'また別の撮影' }), '春の撮影です。\nまた別の撮影\n' .. url .. '\nパスコード ABC234\n10月17日まで開けます。',
    'fromAnnouncement: and renders again')
  eq(text.templateFromAnnouncement('', { url = url }), text.DEFAULT_ANNOUNCEMENT_TEMPLATE, 'fromAnnouncement: empty = default')
  eq(text.templateFromAnnouncement(nil, {}), text.DEFAULT_ANNOUNCEMENT_TEMPLATE, 'fromAnnouncement: nil = default')
  -- a title that is a common word does not break sentences
  eq(text.templateFromAnnouncement('写真をお送りします。\n写真\n' .. url, { title = '写真', url = url, passcode = pass, expireText = '' }),
    '写真をお送りします。\n{題}\n{URL}', 'fromAnnouncement: a short title is only replaced as a whole line')
end

-- Audit 15 (必須②): a split send's 2nd+ URL must never survive into a saved template -------
do
  local url1, url2, url3 = 'https://papat.app/t/a/s/1/', 'https://papat.app/t/b/s/2/', 'https://papat.app/t/c/s/3/'

  -- two galleries: round-trips back to one {URL} mark, neither URL survives
  local ann2 = text.announcement({ title = '春の撮影', urls = { url1, url2 }, passcode = 'ABC234', expireText = '10月17日まで' })
  local tpl2 = text.templateFromAnnouncement(ann2, {
    title = '春の撮影', urls = { url1, url2 }, passcode = 'ABC234', expireText = '10月17日まで',
  })
  eq(tpl2, text.DEFAULT_ANNOUNCEMENT_TEMPLATE, 'fromAnnouncement: two URLs fold back to exactly the default template')
  eq(tpl2:find(url1, 1, true), nil, 'fromAnnouncement: the 1st URL does not survive')
  eq(tpl2:find(url2, 1, true), nil, 'fromAnnouncement: the 2nd URL does not survive (this was the bug)')
  eq(tpl2:find('{パスコード入りURL}', 1, true) ~= nil, true, 'fromAnnouncement: exactly one {パスコード入りURL} mark is left')
  eq(select(2, tpl2:gsub('{パスコード入りURL}', '')), 1,
    'fromAnnouncement: {パスコード入りURL} appears exactly once, not once per gallery')
  eq(tpl2:find('{URL}', 1, true), nil, 'fromAnnouncement: the bare {URL} mark is not also left behind')

  -- three galleries: same, and it still renders correctly afterwards (round-trip)
  local ann3 = text.announcement({ title = '夏の撮影', urls = { url1, url2, url3 }, passcode = 'XYZ999', expireText = '11月1日まで' })
  local tpl3 = text.templateFromAnnouncement(ann3, {
    title = '夏の撮影', urls = { url1, url2, url3 }, passcode = 'XYZ999', expireText = '11月1日まで',
  })
  eq(tpl3, text.DEFAULT_ANNOUNCEMENT_TEMPLATE, 'fromAnnouncement: three URLs also fold back to the default template')
  local rendered3 = text.announcement({ title = '次の撮影', url = 'https://papat.app/t/z/s/9/', passcode = 'NEXT01', expireText = '12月1日まで', template = tpl3 })
  eq(rendered3:find(url1, 1, true), nil, 'fromAnnouncement: the saved template renders the NEXT client\'s own URL, not the old ones')
  eq(rendered3:find('https://papat.app/t/z/s/9/', 1, true) ~= nil, true, 'fromAnnouncement: … and does carry the new URL')
  -- 1.2.2: the URL mark is now {パスコード入りURL} — a saved template must not carry an OLD
  -- client's passcode forward either, and must fold in the NEXT client's own passcode
  eq(rendered3:find('XYZ999', 1, true), nil, 'fromAnnouncement: the old passcode does not survive into the next client\'s announcement')
  eq(rendered3:find('https://papat.app/t/z/s/9/#p=NEXT01', 1, true) ~= nil, true,
    'fromAnnouncement: … and the new URL carries the NEW client\'s own passcode')

  -- a single gallery (urls with one entry) behaves exactly like the plain url= case (regression)
  local ann1 = text.announcement({ title = '春の撮影', urls = { url1 }, passcode = 'ABC234', expireText = '10月17日まで' })
  local annPlain = text.announcement({ title = '春の撮影', url = url1, passcode = 'ABC234', expireText = '10月17日まで' })
  eq(ann1, annPlain, 'announcement: a one-entry urls table renders identically to url=')
  local tpl1 = text.templateFromAnnouncement(ann1, { title = '春の撮影', urls = { url1 }, passcode = 'ABC234', expireText = '10月17日まで' })
  eq(tpl1, text.DEFAULT_ANNOUNCEMENT_TEMPLATE, 'fromAnnouncement: a single gallery still folds back to the default template')
  eq(tpl1:find(url1, 1, true), nil, 'fromAnnouncement: single gallery — its own URL does not survive either')

  -- an empty urls table is the same as not passing one (falls back to url=)
  eq(text.templateFromAnnouncement(url1, { url = url1, urls = {} }), '{URL}',
    'fromAnnouncement: empty urls table falls back to url=')

  -- 後でよい (audit 15): a hand-edited 2nd+ line no longer matches the exact "N/M：url" shape
  -- the line-by-line fold looks for — the URL must still not survive into the saved template
  local handEdited = '写真をお送りします。\n春の撮影\n\nURL: 1/2：' .. url1 .. '\n2本目: ' .. url2 .. '（こちらもご覧ください）\n'
    .. 'パスコード: ABC234\n公開期限: 10月17日まで\n\nブラウザで開いて、気に入った写真に★を付けて「確定」を押してください。'
  local tplHand = text.templateFromAnnouncement(handEdited, {
    title = '春の撮影', urls = { url1, url2 }, passcode = 'ABC234', expireText = '10月17日まで',
  })
  eq(tplHand:find(url1, 1, true), nil, 'fromAnnouncement: hand-edited 2nd line — the 1st URL still does not survive')
  eq(tplHand:find(url2, 1, true), nil, 'fromAnnouncement: hand-edited 2nd line — the 2nd URL does not survive either')
end

-- Audit 11 (low): short passcodes, text from the server -------------------------------
do
  local url = 'https://papat.app/t/x/s/y/'
  -- a short numeric passcode that also appears in sentences is only replaced where it is the passcode
  local edited = '2024年の春の撮影です。\n2024年 春\n' .. url .. '\nパスコード: 2024\n開けるのは 10月17日まで（10月17日までです）'
  eq(text.templateFromAnnouncement(edited, { title = '2024年 春', url = url, passcode = '2024', expireText = '10月17日まで' }),
    '2024年の春の撮影です。\n{題}\n{URL}\nパスコード: {パスコード}\n開けるのは {期限}（10月17日までです）',
    'fromAnnouncement: a short passcode is replaced on the passcode line only; the date once')
  -- without a line that names it: the first whole token, not a digit inside a longer number
  eq(text.templateFromAnnouncement('番号 12024 と 2024 です', { url = url, passcode = '2024' }),
    '番号 12024 と {パスコード} です', 'fromAnnouncement: not inside a longer run of digits')
  -- the URL is replaced everywhere
  eq(text.templateFromAnnouncement(url .. ' / ' .. url, { url = url, passcode = 'ZZ' }), '{URL} / {URL}', 'fromAnnouncement: the URL everywhere')

  -- the server's wording: one line, at most 300 characters
  eq(text.oneLine('a\r\nb\n\nc'), 'a b c', 'oneLine: line breaks become one space')
  eq(text.oneLine('  あ\t\tい  '), 'あ い', 'oneLine: control characters, runs of spaces, trim')
  eq(text.oneLine(string.rep('あ', 300)), string.rep('あ', 300), 'oneLine: 300 characters stay')
  eq(text.oneLine(string.rep('あ', 301)), string.rep('あ', 300) .. '…', 'oneLine: cut at 300 characters, marked')
  eq(text.oneLine(nil), '', 'oneLine: nil')
  eq(text.oneLine(42), '', 'oneLine: not a string')
end

-- The photo limit: the server's number when it sends one ------------------------------
eq(text.parseMaxPhotos(900), 900, 'maxPhotos: number')
eq(text.parseMaxPhotos('1200'), 1200, 'maxPhotos: numeric string')
eq(text.parseMaxPhotos(299.9), 299, 'maxPhotos: whole photos')
eq(text.parseMaxPhotos(0), nil, 'maxPhotos: zero is no limit to trust')
eq(text.parseMaxPhotos(-5), nil, 'maxPhotos: negative')
eq(text.parseMaxPhotos(1e9), nil, 'maxPhotos: absurd')
eq(text.parseMaxPhotos('lots'), nil, 'maxPhotos: not a number')
eq(text.parseMaxPhotos(nil), nil, 'maxPhotos: missing')

-- Free galleries come from the server, never from the plug-in ---------------
eq(text.parseFreeRemaining(5), 5, 'free: number')
eq(text.parseFreeRemaining('8'), 8, 'free: numeric string')
eq(text.parseFreeRemaining(0), 0, 'free: zero is a number')
eq(text.parseFreeRemaining(nil), nil, 'free: missing')
eq(text.parseFreeRemaining('many'), nil, 'free: not a number')
eq(text.parseFreeRemaining(-1), nil, 'free: negative')
eq(text.parseFreeRemaining(2.9), 2, 'free: whole galleries')
eq(text.priceLine(9, 7, 5), '目安 0 円（税込）　※無料の残り 5 ギャラリー', 'priceLine: free remaining -> 0 yen')
eq(text.priceLine(9, 14, 0), '目安 96 円（税込）　※無料の残りはありません', 'priceLine: none left')
eq(text.priceLine(9, 7, nil), '目安 8 円（税込）', 'priceLine: unknown = the free allowance is not mentioned')
eq(text.priceLine(301, 7, 8), '目安 0 円（税込）　※無料の残り 8 ギャラリー', 'priceLine: free remaining -> 0 yen even for a large gallery')

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
    '選択中の 9 枚を、長辺 2048 px の JPEG に書き出して送ります（RAW 原本は送りません）。画像には、著作権・作成者・連絡先だけが入ります。',
    'createIntro: export text')
  eq(text.createIntro(9, { longEdge = 2048, embedRights = true, fast = true }),
    '選択中の 9 枚を Lightroom のプレビュー（長辺 2048 px 前後）から送ります。RAW 原本は送りません。画像には、著作権・作成者・連絡先だけが入ります。',
    'createIntro: preview text')
end

-- grouping: a line-for-line port of papat's own gallery page's autoGroups.
-- tests/grouping.lua cross-checks it against the real JS through node; these are curated
-- worked examples, checked without node.
do
  local grouping = load('grouping')

  eq(grouping.BURST_SEC, 3, 'grouping: BURST_SEC pinned')
  eq(grouping.MIN_SEC, 20, 'grouping: MIN_SEC pinned')
  eq(grouping.MAX_SEC, 600, 'grouping: MAX_SEC pinned')
  eq(grouping.DEFAULT_SEC, 90, 'grouping: DEFAULT_SEC pinned')
  eq(grouping.RATIO, 4, 'grouping: RATIO pinned')
  eq(grouping.WINDOW, 25, 'grouping: WINDOW pinned')
  eq(grouping.MIN_SAMPLES, 8, 'grouping: MIN_SAMPLES pinned')
  eq(grouping.MIN_AVG, 2, 'grouping: MIN_AVG pinned')

  eq(grouping.wallSeconds('2026-10-01T09:00:00'), grouping.wallSeconds('2026-10-01 09:00:00'),
    'grouping: wallSeconds T and space are the same')
  eq(grouping.wallSeconds('2026-10-01'), nil, 'grouping: wallSeconds date only is nil')
  eq(grouping.wallSeconds(''), nil, 'grouping: wallSeconds empty is nil')
  eq(grouping.wallSeconds(nil), nil, 'grouping: wallSeconds nil is nil')
  eq(grouping.wallSeconds('abc'), nil, 'grouping: wallSeconds garbage is nil')
  eq(grouping.wallSeconds('2026-13-45T99:99:99'), nil, 'grouping: wallSeconds out of range is nil')
  -- day-across-month-end rolls over the same way Date.UTC does (both sides are pure day counts)
  eq(grouping.wallSeconds('2026-03-01T00:00:00') - grouping.wallSeconds('2026-02-28T00:00:00'),
    86400, 'grouping: wallSeconds day arithmetic (non-leap Feb)')

  -- a sequence of ISO datetimes `startEpoch + gapsSec[1], + gapsSec[2], ...` (first = startEpoch)
  local function series(startEpoch, gapsSec)
    local t, out = startEpoch, {}
    out[1] = os.date('!%Y-%m-%dT%H:%M:%S', t)
    for i, gap in ipairs(gapsSec) do
      t = t + gap
      out[i + 1] = os.date('!%Y-%m-%dT%H:%M:%S', t)
    end
    return out
  end
  local function repGaps(gap, n) -- n gaps, all equal to `gap` (n+1 photos)
    local g = {}
    for i = 1, n do g[i] = gap end
    return g
  end
  local function sizes(groups, count)
    local n = {}
    for i = 1, count do n[i] = 0 end
    for _, g in ipairs(groups) do if g > 0 then n[g] = n[g] + 1 end end
    return n
  end
  local BASE = grouping.wallSeconds('2026-10-01T00:00:00')

  -- all burst: never cut on gaps this short
  do
    local gaps = {}
    for i = 1, 29 do gaps[i] = (i % 2 == 0) and 1 or 2 end
    local r = grouping.autoGroups(series(BASE, gaps))
    eq(r.count, 1, 'grouping: 30 photos, all 0-2s gaps -> one group')
  end

  -- item-internal gaps (8s) x3 items of 12 photos, items 120s apart -> 3 groups of 12
  do
    local gaps = {}
    for item = 1, 3 do
      for i = 1, 11 do gaps[#gaps + 1] = 8 end
      if item < 3 then gaps[#gaps + 1] = 120 end
    end
    local r = grouping.autoGroups(series(BASE, gaps))
    eq(r.count, 3, 'grouping: 3 items of 12, 8s/120s -> 3 groups')
    local s = sizes(r.groups, r.count)
    eq(s[1] == 12 and s[2] == 12 and s[3] == 12, true, 'grouping: 3 items of 12, sizes 12/12/12')
  end

  -- slower rhythm (45s/6min): fixed 60s would cut every photo; the ratio does not
  do
    local gaps = {}
    for item = 1, 3 do
      for i = 1, 9 do gaps[#gaps + 1] = 45 end
      if item < 3 then gaps[#gaps + 1] = 360 end
    end
    local r = grouping.autoGroups(series(BASE, gaps))
    eq(r.count, 3, 'grouping: 3 items of 10, 45s/6min -> 3 groups (not one per photo)')
  end

  -- a break (>10 min) always cuts, unless it would leave too-small groups
  do
    local r = grouping.autoGroups(series(BASE, { 5, 1200, 5 })) -- 2+2 photos, 20 min apart
    eq(r.count, 2, 'grouping: 2+2 across a 20-minute break -> 2 groups')
    local r2 = grouping.autoGroups(series(BASE, { 1200 })) -- 1+1, only 2 photos total
    eq(r2.count, 1, 'grouping: 2 photos 20 minutes apart -> average below 2, not split')
  end

  -- a sparse, real-world-shaped example
  do
    local r = grouping.autoGroups(series(BASE, { 1, 3, 1, 2, 5, 115, 10, 2 })) -- gaps of [0,1,4,5,7,12,127,137,139]
    eq(r.count, 2, 'grouping: sparse series -> 2 groups (6+3)')
    local s = sizes(r.groups, r.count)
    eq(s[1] == 6 and s[2] == 3, true, 'grouping: sparse series sizes 6+3')
  end
  eq(grouping.autoGroups(series(BASE, { 49, 467, 252, 243 })).count, 1,
    'grouping: 5 photos minutes apart -> one group (too few samples, default 90s, no break)')
  eq(grouping.autoGroups(series(BASE, { 10, 2, 16, 4, 1 })).count, 1,
    'grouping: 6 photos within a minute -> one group')

  -- edges
  eq(grouping.autoGroups({}).count, 0, 'grouping: 0 photos -> count 0')
  eq(grouping.autoGroups({ '' }).count, 0, 'grouping: 1 undated photo -> count 0')
  eq(grouping.autoGroups({ series(BASE, {})[1] }).count, 1, 'grouping: 1 dated photo -> count 1')
  eq(grouping.autoGroups(series(BASE, repGaps(0, 50))).count, 1, 'grouping: same second repeated -> one group')
  eq(grouping.autoGroups(series(BASE, repGaps(30, 99))).count, 1, 'grouping: 100 photos every 30s -> one group')
  eq(grouping.autoGroups(series(BASE, repGaps(900, 19))).count, 1,
    'grouping: 20 photos every 15 minutes -> one group (would be 1-each, undone by MIN_AVG)')
  eq(grouping.autoGroups(series(BASE, repGaps(1, 199))).count, 1, 'grouping: 200 photos all bursts -> one group')
  -- day rollover: a 15s gap across midnight is just a 15s gap
  eq(grouping.autoGroups({ '2026-10-01T23:59:50', '2026-10-02T00:00:05' }).count, 1,
    'grouping: midnight rollover is not special')

  -- manifest order does not matter: the function sorts by time itself
  do
    local dates = series(BASE, { 5, 400, 5 })
    local reversed = { dates[4], dates[3], dates[2], dates[1] }
    local r1 = grouping.autoGroups(dates)
    local r2 = grouping.autoGroups(reversed)
    eq(r1.groups[1] == r1.groups[2] and r1.groups[3] == r1.groups[4] and r1.groups[1] ~= r1.groups[3],
      true, 'grouping: order sanity (forward)')
    eq(r2.groups[4] == r2.groups[3] and r2.groups[2] == r2.groups[1] and r2.groups[4] ~= r2.groups[2],
      true, 'grouping: reversed input gives the same grouping, mapped back to its own order')
  end

  -- undated photos mixed in: they are 0, never counted, and never affect the dated ones
  do
    local dates = series(BASE, { 5, 400, 5 })
    local withGaps = { dates[1], '', dates[2], dates[3], 'not a date', dates[4] }
    local r = grouping.autoGroups(withGaps)
    eq(r.groups[2], 0, 'grouping: undated photo stays 0')
    eq(r.groups[5], 0, 'grouping: unparsable datetime stays 0')
    eq(r.count, 2, 'grouping: undated photos mixed in do not change the dated count')
  end
end

-- split: where to cut a gallery larger than 1,000 photos (2026-10-20, pricing-plans-v0.1.md
-- 1 ギャラリー 88 円なので、1,000 枚までは分けない;
-- splitting only when it does not fit in one gallery at all, cutting at ~800 so each half is
-- comfortably its own gallery). Pure; no LrC.
do
  local split = load('split')

  eq(split.TRIGGER, 1000, 'split: TRIGGER pinned')
  eq(split.LOWER, 760, 'split: LOWER pinned')
  eq(split.TARGET, 800, 'split: TARGET pinned')
  eq(split.MIN_LAST, 100, 'split: MIN_LAST pinned')

  local function eqArr(actual, expected, label)
    local ok = #actual == #expected
    if ok then for i = 1, #expected do if actual[i] ~= expected[i] then ok = false end end end
    eq(ok, true, label .. ' (got [' .. table.concat(actual, ',') .. '])')
  end

  -- no split below/at the trigger
  eqArr(split.plan(1, nil, { '' }, 1000), { 1 }, 'split: 1 photo never splits')
  eqArr(split.plan(900, nil, {}, 1000), { 900 }, 'split: 900 photos does not split (was 176 yen at TRIGGER 888; now one gallery)')
  eqArr(split.plan(1000, nil, {}, 1000), { 1000 }, 'split: exactly 1,000 does not split')

  -- two worked examples
  eqArr(split.plan(2000, nil, {}, 1000), { 800, 800, 400 }, 'split: 2,000 -> 800/800/400')
  eqArr(split.plan(2500, nil, {}, 1000), { 800, 800, 900 }, 'split: 2,500 -> 800/800/900 (§10.5 の例の表)')

  -- a group boundary inside [760,800]: used as is, closest to 800 wins among several
  do
    local n = 1200
    local groups = {}
    for i = 1, n do groups[i] = 1 end
    for i = 781, n do groups[i] = 2 end -- boundary at 780 (dist 20)
    for i = 791, n do groups[i] = 3 end -- boundary at 790 (dist 10): closer, should win
    eqArr(split.plan(n, groups, {}, 1000), { 790, 410 }, 'split: closest-of-several boundary in [760,800]')
  end

  -- no boundary in [760,800], one in [800,1000]: used
  do
    local n = 1100
    local groups = {}
    for i = 1, n do groups[i] = (i <= 950) and 1 or 2 end -- boundary only at 950
    eqArr(split.plan(n, groups, {}, 1000), { 950, 150 }, 'split: no boundary in [760,800] -> the one in [800,1000] is used')
  end

  -- a remainder of exactly MIN_LAST is kept, not merged
  do
    local n = 1100
    local groups = {}
    for i = 1, n do groups[i] = (i <= 1000) and 1 or 2 end -- boundary at 1000, remainder 100
    eqArr(split.plan(n, groups, {}, 1000), { 1000, 100 }, 'split: a remainder of exactly MIN_LAST is kept')
  end

  -- a remainder under MIN_LAST merges back — only possible when the server's maxPhotos allows
  -- the merged size (here 1,000+50, under a server max of 1,200): with maxPhotos == TRIGGER
  -- (the usual case), merging back would always exceed maxPhotos by definition, so this can
  -- only happen when the server reports more room than the plug-in's own TRIGGER assumes.
  do
    local n, maxPhotos = 1050, 1200
    local groups = {}
    for i = 1, n do groups[i] = (i <= 960) and 1 or 2 end -- boundary at 960, remainder 90 (<100)
    eqArr(split.plan(n, groups, {}, maxPhotos), { 1050 }, 'split: a remainder under MIN_LAST merges back when the server allows the combined size')
  end

  -- 760〜800 に境目が無く、800〜1,000 の 830 にある場合
  do
    local n = 1200
    local groups = {}
    for i = 1, n do groups[i] = (i <= 830) and 1 or 2 end -- the only boundary is at 830
    eqArr(split.plan(n, groups, {}, 1000), { 830, 370 }, 'split: no boundary in [760,800], one at 830 -> cut at 830')
  end

  -- グループが働かない（nil）場合は 800 で切る。datetimes はもう見ない（largestGapCut は
  -- 2026-10-20 に外した — 時刻のグループがあれば、その境目はすでに上の手順で見つかっている）
  do
    local n = 1200
    eqArr(split.plan(n, nil, {}, 1000), { 800, 400 }, 'split: no grouping at all -> a flat cut at 800')
    -- datetimes are accepted but ignored: the same input with "interesting" timestamps still
    -- just cuts at 800, confirming the largest-gap fallback is gone
    local dts = {}
    for i = 1, n do dts[i] = os.date('!%Y-%m-%dT%H:%M:%S', 1790000000 + i * 10) end
    eqArr(split.plan(n, nil, dts, 1000), { 800, 400 }, 'split: datetimes no longer change the outcome')
  end

  -- a merge that would exceed maxPhotos never happens (mergeSmallTail directly; unaffected by
  -- the TRIGGER/TARGET change — pure function of segment sizes)
  do
    local segs = split.mergeSmallTail({ 900, 50 }, 940)
    eqArr(segs, { 900, 50 }, 'split: mergeSmallTail refuses when the combined size is too big')
    segs = split.mergeSmallTail({ 900, 50 }, 950)
    eqArr(segs, { 950 }, 'split: mergeSmallTail merges when it fits exactly')
    segs = split.mergeSmallTail({ 500 }, 1000)
    eqArr(segs, { 500 }, 'split: mergeSmallTail leaves a single segment alone')
  end

  -- renumbering: each segment's display groups restart at 1, 0 (no capture time) stays 0
  -- (unaffected by the TRIGGER/TARGET change)
  do
    local groups = { 1, 1, 2, 2, 3, 0, 0, 5, 5 }
    eqArr(split.renumberSegment(groups, 1, 5), { 1, 1, 2, 2, 3 }, 'split: renumberSegment, first segment')
    eqArr(split.renumberSegment(groups, 6, 7), { 0, 0 }, 'split: renumberSegment, all undated')
    eqArr(split.renumberSegment(groups, 5, 9), { 1, 0, 0, 2, 2 }, 'split: renumberSegment, undated in the middle')
    eqArr(split.renumberSegment(nil, 1, 3), { 0, 0, 0 }, 'split: renumberSegment with no groups at all')
  end

  -- findCut directly: an exact-800 boundary needs no fallback
  do
    local n = 1200
    local groups = {}
    for i = 1, n do groups[i] = (i <= 800) and 1 or 2 end
    eq(split.findCut(n, groups, {}, 1000), 800, 'split: findCut, boundary exactly at the target')

    -- two boundaries in the same [760,800] range: the closer of the two wins
    groups = {}
    for i = 1, n do groups[i] = 1 end
    for i = 771, n do groups[i] = 2 end -- boundary at 770 (dist 30)
    for i = 781, n do groups[i] = 3 end -- boundary at 780 (dist 20): closer, should win
    eq(split.findCut(n, groups, {}, 1000), 780, 'split: findCut, the closer of two in the same range wins')

    -- [760,800] takes strict priority over [800,1000], even when [800,1000] has a closer one
    groups = {}
    for i = 1, n do groups[i] = 1 end
    for i = 766, n do groups[i] = 2 end -- boundary at 765 (dist 35), only candidate in [760,800]
    for i = 811, n do groups[i] = 3 end -- boundary at 810 (dist 10): closer overall, but out of range
    eq(split.findCut(n, groups, {}, 1000), 765,
      'split: findCut, [760,800] wins over a closer boundary that only falls in [800,1000]')
  end
end

print(string.format('%d checks, %d failed', total, failed))
os.exit(failed == 0 and 0 or 1)
