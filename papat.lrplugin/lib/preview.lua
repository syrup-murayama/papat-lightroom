--[[
  lib/preview.lua — "speed first" mode: take the JPEG from Lightroom's own preview
  (photo:requestJpegThumbnail) instead of running a full export.

  Experimental. It is much faster, but the image is the cached preview rendered
  to the requested size, not a fresh export: quality, sharpening and the exact colour
  conversion can differ, and the size is limited by the catalog's standard preview
  size. Callers fall back to a normal export when this returns nil.

  Yields (waits for the callback) — call from an async task, not inside pcall.

  2026-10-19 field report (582 photos, speed-first): a probe logged "0.01s small" for a
  photo whose catalog's standard preview setting was Auto/4112px — far too fast and far
  too small to be that catalog's real preview. requestJpegThumbnail is documented as
  calling back once, but the suspicion (not yet confirmed against the real SDK — see
  spike/preview-freshness) is that when the standard preview was not actually cached
  (evicted by the preview cache size limit, in this case), Lightroom answers first with
  whatever cheap placeholder it has on hand and calls back again once the real preview is
  ready. If so, the old code's single-callback wait was mistaking the placeholder for the
  final answer. `opts.minEdge` below lets a caller hold the request open for a second,
  hopefully bigger, callback in exactly that situation, without slowing down every other
  request: a first callback is only treated as a maybe-placeholder when it is BOTH smaller
  than `opts.minEdge` AND suspiciously fast (< opts.suspiciousFast) — a genuinely small
  preview (e.g. the catalog's standard preview size really is set low) still takes normal
  retrieval time and is trusted immediately, so a catalog like that does not pay the extra
  wait on every photo for nothing.
]]

local LrTasks = import 'LrTasks'

local function load(name) return dofile(_PLUGIN.path .. '/lib/' .. name .. '.lua') end
local jpeg = load('jpeg')

local M = {}

local JPEG_SIGNATURE = '\255\216\255'

local function looksLikeJpeg(data)
  return type(data) == 'string' and #data >= 4 and data:sub(1, 3) == JPEG_SIGNATURE
end

--- @param opts table|nil
---   minEdge          when given, a first callback whose JPEG's long edge is below this
---                     AND that arrived suspiciously fast (see suspiciousFast) is held back:
---                     the request stays open for one more callback, up to settleSeconds.
---                     Any later callback (whatever its size) ends the wait at once.
---   settleSeconds     extra time allowed past the first callback (default 5)
---   suspiciousFast    a first callback faster than this (default 0.3s) is what makes a
---                      small result worth waiting past, rather than trusting it outright
--- @return string|nil jpeg, string|nil reason, number callbacks, string|nil waitOutcome
---   callbacks: how many times the SDK actually called back (0 = the first callback itself
---     never arrived in time)
---   waitOutcome (only set when opts.minEdge is given and at least one callback arrived):
---     'first_big'      the first callback was not small (nothing was held back)
---     'small_then_big' the first callback was small and suspiciously fast, and the final
---                      callback (after waiting) turned out big after all — the
---                      question behind it, answered per photo: see the file header
---     'small_timeout'  same start, but the wait did not turn up a bigger one
---     nil              the first callback was small but not suspiciously fast (trusted
---                      immediately, no wait happened — a catalog whose preview size is
---                      genuinely set low) — or no callback arrived at all
function M.jpeg(photo, edge, timeoutSeconds, opts)
  opts = opts or {}
  local result = { done = false, calls = 0 }
  local waited = 0 -- an upvalue the callback below also reads, to time its own arrival
  -- The request object must stay referenced until the callback fires.
  local request = photo:requestJpegThumbnail(edge, edge, function(data, reason)
    result.calls = result.calls + 1
    result.data = data
    result.reason = reason
    if result.calls == 1 and opts.minEdge then
      local small = looksLikeJpeg(data) and (jpeg.longEdge(data) or 0) < opts.minEdge
      result.firstSmall = small
      result.holdForMore = small and waited < (opts.suspiciousFast or 0.3)
    end
    if not (result.calls == 1 and result.holdForMore) then result.done = true end
  end)

  local limit = timeoutSeconds or 30
  local settle = opts.settleSeconds or 5
  local firstAt = nil
  while not result.done do
    if result.calls == 0 then
      if waited >= limit then break end
    else
      firstAt = firstAt or waited
      if waited >= firstAt + settle then break end
    end
    LrTasks.sleep(0.05)
    waited = waited + 0.05
  end
  local _ = request

  local waitOutcome = nil
  if opts.minEdge and result.firstSmall ~= nil then
    if result.firstSmall then
      if result.holdForMore then
        local finalBig = looksLikeJpeg(result.data) and (jpeg.longEdge(result.data) or 0) >= opts.minEdge
        waitOutcome = finalBig and 'small_then_big' or 'small_timeout'
      end
    else
      waitOutcome = 'first_big'
    end
  end

  if result.calls == 0 then return nil, 'timeout', 0, waitOutcome end
  local data = result.data
  if not looksLikeJpeg(data) then
    return nil, tostring(result.reason or 'no data'), result.calls, waitOutcome
  end
  return data, nil, result.calls, waitOutcome
end

return M
