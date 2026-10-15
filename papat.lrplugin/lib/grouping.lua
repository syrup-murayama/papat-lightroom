--[[
  lib/grouping.lua — group photos by capture-time gaps

  A line-for-line port of papat's own gallery page's `autoGroups` (the browser-side function,
  served from papat.app, that decides where a gallery's "グループ" view breaks). Given the
  same capture times, in the same order, it returns the same group numbers — checked against
  the real JS by tests/grouping.lua (runs the reference through `node`; skipped, not failed,
  where node is not installed).

  This does not change what is sent to the server (groupThreshold stays 3; the gallery's
  own autoGroups call is untouched). It exists so the plug-in can find the same time-group
  boundaries the client's browser will show, for two 1.2.0 features that both need them
  before anything is sent:
    - lib/similarity.lua refines them with Vision feature prints
    - CreateGallery.lua picks a gallery-split point at one of them (when > 888 photos)
]]

local text = dofile(_PLUGIN.path .. '/lib/text.lua')

local M = {}

-- Must stay equal to the gallery page's own GROUP_* constants.
-- tests/run.lua pins these numbers so an accidental change here is caught immediately.
M.BURST_SEC = 3     -- a gap this short or shorter is a burst: never counted as a "usual" gap
M.MIN_SEC = 20      -- never cut on a gap shorter than this
M.MAX_SEC = 600     -- always cut on a gap longer than this (break / travel)
M.DEFAULT_SEC = 90  -- cutting distance when no "usual gap" could be measured
M.RATIO = 4         -- cut when a gap exceeds this many times the usual gap
M.WINDOW = 25       -- how many neighbouring gaps feed the local "usual gap"
M.MIN_SAMPLES = 8   -- gaps required (locally, else overall) before a "usual gap" exists
M.MIN_AVG = 2       -- groups average fewer photos than this: treated as too fine, undone

--- "YYYY-MM-DDTHH:MM:SS" (camera wall clock, no zone) -> UTC seconds, exactly as the
--- browser's `groupWallSeconds` reads it (Date.UTC, never the viewer's own time zone).
--- nil for '', nil, or anything the same bounds as the browser reject (not a plausible
--- calendar date/time, or year before 1990). text.isoWallTime already enforces those
--- bounds (lib/capture.lua uses it for the same manifest field), and text.isoToEpoch
--- does the same UTC day-count arithmetic as Date.UTC, so this is that pair composed.
function M.wallSeconds(s)
  local wall = text.isoWallTime(s)
  if not wall then return nil end
  return text.isoToEpoch(wall)
end

--- The "usual gap": the median of the gaps in `gaps` that are neither a burst nor a
--- break (BURST_SEC < gap <= MAX_SEC). nil when fewer than MIN_SAMPLES of them qualify.
function M.usualGap(gaps)
  local v = {}
  for _, g in ipairs(gaps) do
    if g > M.BURST_SEC and g <= M.MAX_SEC then v[#v + 1] = g end
  end
  if #v < M.MIN_SAMPLES then return nil end
  table.sort(v)
  local n = #v
  local mid = math.floor(n / 2) -- matches JS's `v.length >> 1` (0-indexed); see the +1s below
  if n % 2 == 1 then return v[mid + 1] end
  return (v[mid] + v[mid + 1]) / 2
end

--- @param datetimes array of per-photo capture-time strings, in the gallery's order
---   ('' / nil / unparsable = no capture time, exactly like the manifest's own `datetime`)
--- @return table { groups = {same order, 1-based group numbers; 0 = no capture time},
---                  count = number of groups among the dated photos (0 when none are dated) }
function M.autoGroups(datetimes)
  local n = #datetimes
  local groups = {}
  for i = 1, n do groups[i] = 0 end

  local dated = {}
  for i = 1, n do
    local t = M.wallSeconds(datetimes[i])
    if t ~= nil then dated[#dated + 1] = { i = i, t = t } end
  end
  if #dated == 0 then return { groups = groups, count = 0 } end

  table.sort(dated, function(a, b)
    if a.t ~= b.t then return a.t < b.t end
    return a.i < b.i
  end)

  local gaps = {}
  for k = 2, #dated do gaps[#gaps + 1] = dated[k].t - dated[k - 1].t end

  local overall = M.usualGap(gaps)
  local g = 1
  groups[dated[1].i] = g
  for j = 1, #gaps do
    -- window: the JS slices gaps[max(0,k-WINDOW) .. k+WINDOW] (0-indexed, k = j-1 here)
    local lo = math.max(0, j - 1 - M.WINDOW) + 1
    local hi = math.min(#gaps, j + M.WINDOW)
    local window = {}
    for idx = lo, hi do window[#window + 1] = gaps[idx] end
    local near = M.usualGap(window)
    local usual = near
    if usual == nil then usual = overall end
    local limit
    if usual == nil then
      limit = M.DEFAULT_SEC
    else
      limit = math.min(M.MAX_SEC, math.max(M.MIN_SEC, usual * M.RATIO))
    end
    if gaps[j] > limit then g = g + 1 end
    groups[dated[j + 1].i] = g
  end

  if (#dated / g) < M.MIN_AVG then -- too fine: undo it, back to one group
    for _, d in ipairs(dated) do groups[d.i] = 1 end
    g = 1
  end

  return { groups = groups, count = g }
end

return M
