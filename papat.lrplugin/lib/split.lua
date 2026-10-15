--[[
  lib/split.lua — decide whether a gallery is too big for one, and where to cut it

  Decided 2026-10-15: a gallery of more than 888 photos is sent as several galleries instead.
  The cut point comes from the same groups lib/similarity.lua / lib/grouping.lua compute
  (never from counting photos alone), so a sub-gallery never splits mid-scene when a
  reasonable place to cut exists nearby. All values below are provisional; pure module, no
  LrC — CreateGallery.lua supplies the already-gathered groups and datetimes, in the gallery's
  own order (lib/pipeline.lua's M.order).

  M.plan(n, groups, datetimes, maxPhotos) -> array of segment sizes (sums to n). A single
  segment (array of 1 element) means "do not split"; everything else about a gallery's
  creation, pricing and sending that already works for one applies to each segment as if it
  were its own selection — lib/split.lua only ever answers "how many, how big".
]]

local grouping = dofile(_PLUGIN.path .. '/lib/grouping.lua')

local M = {}

M.TRIGGER = 888    -- split only once the selection is larger than this
M.LOWER = 750      -- the first range to look for a cut in, counted from this segment's start
M.TARGET = 888     -- the count a cut is chosen to be closest to
M.MIN_LAST = 100   -- a last segment smaller than this is folded into the one before it instead

--- The position (1-based, between photo k and k+1) in [lo, hi] closest to M.TARGET where
--- `groups[k] ~= groups[k + 1]` — i.e. an existing group boundary. nil when there is none, or
--- when `groups` itself is nil (no usable grouping at all for this selection).
local function boundaryClosest(groups, n, lo, hi)
  if not groups then return nil end
  lo, hi = math.max(1, lo), math.min(n - 1, hi)
  if lo > hi then return nil end
  local best, bestDist
  for k = lo, hi do
    if groups[k] ~= groups[k + 1] then
      local dist = math.abs(k - M.TARGET)
      if not best or dist < bestDist then
        best, bestDist = k, dist
      end
    end
  end
  return best
end

--- The position in [lo, hi] with the largest gap between two (both dated) consecutive
--- capture times. nil when none of them have two consecutive dated photos to compare.
local function largestGapCut(datetimes, n, lo, hi)
  lo, hi = math.max(1, lo), math.min(n - 1, hi)
  if lo > hi then return nil end
  local best, bestGap
  for k = lo, hi do
    local ta = grouping.wallSeconds(datetimes[k])
    local tb = grouping.wallSeconds(datetimes[k + 1])
    if ta and tb then
      local gap = tb - ta
      if not bestGap or gap > bestGap then best, bestGap = k, gap end
    end
  end
  return best
end

--- Where to cut a run of `n` photos (n > M.TRIGGER) that must be split at least once more.
--- `groups`/`datetimes` are this segment's own slice (1-based, length n): the combined
--- (similarity-refined, else time-only) group number per photo (0 = no capture time), and the
--- capture-time string per photo. `groups` may be nil (no grouping could be computed at all).
--- @return number cut  1 <= cut < n (a photo count: first `cut` photos go to this gallery)
function M.findCut(n, groups, datetimes, maxPhotos)
  -- every candidate stays within maxPhotos, even in the (unexpected) case that it is below
  -- M.TARGET: CreateGallery.lua still checks the final plan against it before using it.
  local upperTarget = math.min(M.TARGET, maxPhotos)
  local cut = boundaryClosest(groups, n, M.LOWER, upperTarget)
    or boundaryClosest(groups, n, upperTarget, math.min(maxPhotos, n - 1))
  if cut then return cut end

  cut = largestGapCut(datetimes, n, M.LOWER, math.min(maxPhotos, n - 1))
  if cut then return cut end

  return math.min(upperTarget, n - 1) -- no capture time anywhere: a fixed cut, in the given order
end

--- A last segment under M.MIN_LAST photos is not worth a gallery of its own: folded into the
--- one before it, unless that would make the combined gallery too big. Only ever touches the
--- last two segments (a single merge is already the common case: two segments collapsing
--- into the one-gallery original when the whole selection barely passed M.TRIGGER).
function M.mergeSmallTail(segments, maxPhotos)
  if #segments < 2 then return segments end
  local last = segments[#segments]
  if last >= M.MIN_LAST then return segments end
  local combined = segments[#segments - 1] + last
  if combined > maxPhotos then return segments end
  local merged = {}
  for i = 1, #segments - 2 do merged[i] = segments[i] end
  merged[#merged + 1] = combined
  return merged
end

--- @param n number  total selected photos
--- @param groups table|nil  length n, in the gallery's own order; the combined group number
---   per photo (0 = no capture time), or nil when no grouping could be computed at all
--- @param datetimes table  length n, same order; capture-time string per photo ('' = none)
--- @param maxPhotos number  the most one gallery may hold (lib/update.lua's M.maxPhotos())
--- @return table segments  photo counts, in send order, summing to n ({n} = do not split)
function M.plan(n, groups, datetimes, maxPhotos)
  if n <= M.TRIGGER then return { n } end

  local function slice(arr, from, len)
    if not arr then return nil end
    local out = {}
    for i = 1, len do out[i] = arr[from + i] end
    return out
  end

  local segments = {}
  local offset = 0
  while n - offset > M.TRIGGER do
    local remaining = n - offset
    local cut = M.findCut(remaining, slice(groups, offset, remaining), slice(datetimes, offset, remaining), maxPhotos)
    segments[#segments + 1] = cut
    offset = offset + cut
  end
  segments[#segments + 1] = n - offset

  return M.mergeSmallTail(segments, maxPhotos)
end

--- Segment-local 1-based group numbers (restarting at 1 for each segment, 0 kept as 0), from
--- the combined group array `groups` (length n, the whole selection) and one segment's
--- [start, finish] (1-based, inclusive, into `groups`). Used to fill in each sub-gallery's own
--- groupsNow once M.plan has decided where the cuts are — the display groups of a 2nd+ gallery
--- must not pick up where the 1st gallery's numbers left off.
--- @return table out  [localIndex] = group number, localIndex = 1 .. (finish - start + 1)
function M.renumberSegment(groups, start, finish)
  local out = {}
  local g, prev, any = 0, nil, false
  for i = start, finish do
    local v = groups and groups[i] or 0
    if not v or v == 0 then
      out[#out + 1] = 0
    else
      if not any or v ~= prev then g = g + 1 end
      out[#out + 1] = g
      prev, any = v, true
    end
  end
  return out
end

return M
