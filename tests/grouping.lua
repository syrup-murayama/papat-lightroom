-- Cross-checks lib/grouping.lua against the real JS it is a port of: papat's own gallery
-- page's `autoGroups`, the browser-side function served from papat.app that decides where a
-- gallery's "グループ" view breaks. The text below is that function, copied verbatim (frozen
-- here so this test is self-contained); tests/run.lua pins the same constants from the Lua side.
--
-- Needs `node` on PATH. Skipped (not failed) without it, so `scripts/check.sh` still
-- passes on a machine that has `lua` but not `node`.
--
--   lua tests/grouping.lua   (from the repository root)

local root = arg and arg[0] and arg[0]:match('^(.*)/tests/[^/]+$') or '.'
_PLUGIN = { path = root .. '/papat.lrplugin' }

local function load(name) return dofile(_PLUGIN.path .. '/lib/' .. name .. '.lua') end
local grouping = load('grouping')
local json = load('json')

local failed, total = 0, 0
local function eq(actual, expected, label)
  total = total + 1
  if actual ~= expected then
    failed = failed + 1
    print(string.format('FAIL %s\n  expected: %s\n  actual:   %s', label, tostring(expected), tostring(actual)))
  end
end

local function hasNode()
  return os.execute('command -v node >/dev/null 2>&1') and true or false
end

if not hasNode() then
  print('SKIP grouping: node not found on PATH (lua tests/run.lua already checks lib/grouping.lua without it)')
  os.exit(0)
end

-- the gallery's autoGroups, verbatim
local JS_REFERENCE = [[
const GROUP_BURST_SEC = 3;
const GROUP_MIN_SEC = 20;
const GROUP_MAX_SEC = 600;
const GROUP_DEFAULT_SEC = 90;
const GROUP_RATIO = 4;
const GROUP_WINDOW = 25;
const GROUP_MIN_SAMPLES = 8;
const GROUP_MIN_AVG = 2;

function groupWallSeconds(s) {
  const m = /^(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d)(?::(\d\d))?/.exec(String(s || ''));
  if (!m) return null;
  const y = +m[1], mo = +m[2], d = +m[3], h = +m[4], mi = +m[5], sec = +(m[6] || 0);
  if (y < 1990 || mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || sec > 60) return null;
  return Date.UTC(y, mo - 1, d, h, mi, sec) / 1000;
}
function groupUsualGap(gaps) {
  const v = gaps.filter(g => g > GROUP_BURST_SEC && g <= GROUP_MAX_SEC).sort((a, b) => a - b);
  if (v.length < GROUP_MIN_SAMPLES) return null;
  const mid = v.length >> 1;
  return v.length % 2 ? v[mid] : (v[mid - 1] + v[mid]) / 2;
}
function autoGroups(datetimes) {
  const groups = new Array(datetimes.length).fill(0);
  const dated = [];
  datetimes.forEach((s, i) => { const t = groupWallSeconds(s); if (t !== null) dated.push({ i, t }); });
  if (!dated.length) return { groups, count: 0 };
  dated.sort((a, b) => a.t - b.t || a.i - b.i);
  const gaps = dated.slice(1).map((d, k) => d.t - dated[k].t);
  const overall = groupUsualGap(gaps);
  let g = 1;
  groups[dated[0].i] = g;
  gaps.forEach((gap, k) => {
    const near = groupUsualGap(gaps.slice(Math.max(0, k - GROUP_WINDOW), k + GROUP_WINDOW + 1));
    const usual = near !== null ? near : overall;
    const limit = usual === null ? GROUP_DEFAULT_SEC
      : Math.min(GROUP_MAX_SEC, Math.max(GROUP_MIN_SEC, usual * GROUP_RATIO));
    if (gap > limit) g++;
    groups[dated[k + 1].i] = g;
  });
  if (dated.length / g < GROUP_MIN_AVG) {
    dated.forEach(d => { groups[d.i] = 1; });
    g = 1;
  }
  return { groups, count: g };
}
]]

local DRIVER = JS_REFERENCE .. [[
const fs = require('fs');
const cases = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const out = cases.map(autoGroups);
fs.writeFileSync(process.argv[3], JSON.stringify(out));
]]

-- ---------------------------------------------------------------------------
-- Test cases: the same worked examples as tests/run.lua, plus a random fuzz of
-- synthetic shoots (bursts / item-internal gaps / item breaks / undated photos mixed
-- in / shuffled manifest order), generated with a fixed seed so a failure reproduces.
-- ---------------------------------------------------------------------------

local BASE = 1790000000 -- an arbitrary but fixed UTC epoch second (2026-09-16ish)

local function iso(epoch)
  return os.date('!%Y-%m-%dT%H:%M:%S', epoch)
end

-- a chronological series from `gapsSec` (n gaps -> n+1 photos), as ISO strings
local function series(gapsSec)
  local t, out = BASE, { iso(BASE) }
  for _, gap in ipairs(gapsSec) do
    t = t + gap
    out[#out + 1] = iso(t)
  end
  return out
end

math.randomseed(20261015)

local function randomShoot()
  local items = 2 + math.random(0, 8)
  local burstP = math.random() * 0.6
  local gaps = {}
  for item = 1, items do
    local photos = 1 + math.random(0, 25)
    for i = 1, photos - 1 do
      if math.random() < burstP then
        gaps[#gaps + 1] = math.random(0, 2)
      else
        gaps[#gaps + 1] = math.random(4, 180)
      end
    end
    if item < items then
      -- a break: usually a few minutes, sometimes short enough not to matter, sometimes long
      local kind = math.random(1, 3)
      if kind == 1 then gaps[#gaps + 1] = math.random(30, 600)
      elseif kind == 2 then gaps[#gaps + 1] = math.random(600, 3000)
      else gaps[#gaps + 1] = math.random(5, 25) end
    end
  end
  return series(gaps)
end

local cases, labels = {}, {}
local function addCase(label, datetimes)
  cases[#cases + 1] = datetimes
  labels[#cases] = label
end

addCase('empty', {})
addCase('one undated', { '' })
addCase('one dated', series({}))
addCase('all garbage', { '', 'abc', '2026-13-99T99:99:99' })

for n = 1, 60 do
  local shoot = randomShoot()
  addCase('random shoot ' .. n, shoot)

  -- the same photos, manifest order shuffled (datetime order must not depend on it)
  local shuffled = {}
  for i, v in ipairs(shoot) do shuffled[i] = v end
  for i = #shuffled, 2, -1 do
    local j = math.random(i)
    shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
  end
  addCase('random shoot ' .. n .. ' (shuffled)', shuffled)

  -- a few of these with some photos undated (no capture time), mixed in anywhere
  if n % 4 == 0 then
    local withUndated = {}
    for i, v in ipairs(shoot) do
      withUndated[#withUndated + 1] = v
      if math.random() < 0.15 then withUndated[#withUndated + 1] = '' end
    end
    addCase('random shoot ' .. n .. ' (some undated)', withUndated)
  end
end

-- ---------------------------------------------------------------------------
-- Run: write the cases, run node once, compare every case to the Lua port
-- ---------------------------------------------------------------------------

local tmp = (os.getenv('TMPDIR') or '/tmp'):gsub('/+$', '') .. '/papat-grouping-test-' .. tostring(os.time())
os.execute('mkdir -p "' .. tmp .. '"')

local function writeFile(path, content)
  local fh = io.open(path, 'wb')
  fh:write(content)
  fh:close()
end

writeFile(tmp .. '/driver.js', DRIVER)
writeFile(tmp .. '/input.json', json.encode(cases))

local function runNode(tz)
  local prefix = tz and ('TZ=' .. tz .. ' ') or ''
  local cmd = prefix .. 'node ' .. tmp .. '/driver.js ' .. tmp .. '/input.json ' .. tmp .. '/output.json'
  local ok = os.execute(cmd)
  if ok ~= true and ok ~= 0 then error('node failed: ' .. cmd) end
  local fh = io.open(tmp .. '/output.json', 'rb')
  local raw = fh:read('*a')
  fh:close()
  return json.decode(raw)
end

local results = runNode(nil)

for i, case in ipairs(cases) do
  local jsResult = results[i]
  local luaResult = grouping.autoGroups(case)
  local label = labels[i]

  eq(luaResult.count, jsResult.count, label .. ': count')
  local mismatch = nil
  for k = 1, #case do
    if luaResult.groups[k] ~= (jsResult.groups[k] or 0) then mismatch = k; break end
  end
  total = total + 1
  if mismatch then
    failed = failed + 1
    print(string.format('FAIL %s: groups differ at photo %d (lua=%s js=%s)',
      label, mismatch, tostring(luaResult.groups[mismatch]), tostring(jsResult.groups[mismatch])))
  end
end

-- TZ independence (design doc §1.7.2①): the same input, run under a different time zone
-- (including one with a DST transition), must give byte-identical results — both sides
-- read the datetime string as UTC regardless of where the code runs.
do
  -- 2026-03-08T05:00:00Z is the night of the 2026 US "spring forward" (America/New_York
  -- turns 02:00 into 03:00 that morning, local time); Date.UTC must not care either way.
  local dstBase = grouping.wallSeconds('2026-03-08T05:00:00')
  local dstCase = { iso(dstBase) }
  local t = dstBase
  for _, gap in ipairs({ 30, 30, 30, 7200, 30, 30 }) do
    t = t + gap
    dstCase[#dstCase + 1] = iso(t)
  end
  writeFile(tmp .. '/input.json', json.encode({ dstCase }))
  local rUtc, rNy = runNode('UTC')[1], runNode('America/New_York')[1]
  eq(json.encode(rUtc), json.encode(rNy), 'TZ independence: UTC vs America/New_York, same result')
  eq(json.encode(grouping.autoGroups(dstCase)), json.encode(rUtc), 'TZ independence: Lua matches JS under UTC')
end

os.execute('rm -rf "' .. tmp .. '"')

print(string.format('%d checks, %d failed (%d cases cross-checked against node)', total, failed, #cases))
os.exit(failed == 0 and 0 or 1)
