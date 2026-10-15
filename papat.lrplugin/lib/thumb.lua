--[[
  lib/thumb.lua — the small version of a photo for the gallery's overview (thumbs/<name>)

  papat's gallery shows a grid of small pictures; the big JPEG is only for the single view. The
  server accepts one small JPEG per photo (PUT .../files/thumbs/<same name>):
    - at most 256 KB, long edge at most 800 px, JPEG;
    - only after the photo itself is there (otherwise 409).
  It is made from the JPEG that was just prepared for the photo (the preview, or the export, with
  its metadata already cleaned), so it always looks like the big one. macOS `sips` does the
  shrinking (it ships with the system; the CLI uses it too). Short edge 400 px, long edge at most
  800 px, JPEG quality 80. A photo that is already that small gets none (the server shows the big
  one). Everything here is best effort: the caller sends the photo whether or not this works.
]]

local LrFileUtils = import 'LrFileUtils'
local LrTasks = import 'LrTasks'

local M = {}

M.SHORT_EDGE = 400     -- the grid's square cells are filled by the short edge
M.MAX_LONG_EDGE = 800  -- the server refuses longer ones (415)
M.MAX_BYTES = 256 * 1024 -- the server refuses bigger ones (413)
M.QUALITY = 80

--- Long edge for `sips -Z`, or nil when the photo is already small enough (no thumbnail).
function M.targetLong(width, height)
  width, height = tonumber(width) or 0, tonumber(height) or 0
  local short, long = math.min(width, height), math.max(width, height)
  if short <= 0 then return nil end
  local scale = math.min(1, M.SHORT_EDGE / short, M.MAX_LONG_EDGE / long)
  if scale >= 1 then return nil end
  return math.max(1, math.floor(long * scale + 0.5))
end

local function quote(path)
  return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

--- The shell command for one call with many files (exposed for the tests). sips writes
--- <outDir>/<file name> for every input; one call costs about 20 ms per file against about 75 ms
--- per file when called one by one (measured).
function M.command(inPaths, outDir, long)
  local quoted = {}
  for i, path in ipairs(inPaths) do quoted[i] = quote(path) end
  return string.format('sips -Z %d -s format jpeg -s formatOptions %d %s --out %s >/dev/null 2>&1',
    long, M.QUALITY, table.concat(quoted, ' '), quote(outDir))
end

--- Shrink several JPEGs in one call: their long edge becomes `long`. Yields (runs a command).
--- @param jobs table  array of { tag = unique string, bytes = JPEG }
--- @param dir string  a folder that exists (the pipeline's temp folder)
--- @param long number target long edge for all of them
--- @return table results  [tag] = bytes, or false when that file produced nothing
--- @return table info     { ok = boolean (exit status 0), seconds = elapsed, files = n, why = string|nil }
function M.shrinkMany(jobs, dir, long, clock)
  local info = { files = #jobs, ok = false, seconds = 0 }
  local results = {}
  if WIN_ENV then info.why = 'unsupported'; return results, info end
  local outDir = dir .. '/thumbs-out'
  LrFileUtils.createAllDirectories(outDir)

  local inPaths, names = {}, {}
  for _, job in ipairs(jobs) do
    local name = 'thumb-' .. job.tag .. '.jpg'
    local path = dir .. '/' .. name
    local fh = io.open(path, 'wb')
    if fh then
      fh:write(job.bytes)
      fh:close()
      inPaths[#inPaths + 1] = path
      names[job.tag] = name
    else
      results[job.tag] = false
    end
  end
  if #inPaths == 0 then info.why = 'write'; return results, info end

  local t0 = clock and clock() or 0
  local rc = LrTasks.execute(M.command(inPaths, outDir, long))
  info.seconds = clock and (clock() - t0) or 0
  info.ok = (rc == 0)
  if rc ~= 0 then info.why = 'sips' end

  for _, job in ipairs(jobs) do
    local name = names[job.tag]
    if name then
      local data
      local out = io.open(outDir .. '/' .. name, 'rb')
      if out then
        data = out:read('*a')
        out:close()
      end
      results[job.tag] = (data and #data >= 4) and data or false
    end
  end

  -- leave nothing behind
  for _, path in ipairs(inPaths) do
    if LrFileUtils.exists(path) then LrFileUtils.delete(path) end
  end
  for _, job in ipairs(jobs) do
    local name = names[job.tag]
    if name and LrFileUtils.exists(outDir .. '/' .. name) then LrFileUtils.delete(outDir .. '/' .. name) end
  end
  return results, info
end

return M
