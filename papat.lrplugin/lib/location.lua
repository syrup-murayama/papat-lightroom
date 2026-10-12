--[[
  lib/location.lua — where the plug-in is loaded from, and copying it to Lightroom's
  standard Modules folder

  Lightroom loads every plug-in found in
    ~/Library/Application Support/Adobe/Lightroom/Modules/
  at start-up. A plug-in added with "Add" from another folder (Downloads, Desktop…)
  only works while that folder stays where it is. install() copies the running
  plug-in into Modules so the original can be deleted after a restart.

  Only LrFileUtils / LrPathUtils are used (no shell). Files are copied one by one,
  because LrFileUtils.copy / move are documented for single files. Nothing outside
  <Modules>/papat.lrplugin and the backups folder is ever written or deleted.
]]

local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'

local text = dofile(_PLUGIN.path .. '/lib/text.lua')
local ids = dofile(_PLUGIN.path .. '/lib/ids.lua')
local log = dofile(_PLUGIN.path .. '/lib/log.lua')

local M = {}

local PLUGIN_FOLDER = 'papat.lrplugin'

local function homeDir()
  return LrPathUtils.getStandardFilePath('home')
end

--- <Application Support>/Adobe/Lightroom, built from the home folder. The SDK's
--- "appData" is NOT used: on macOS it already ends in "Adobe/Lightroom" (1.0.1 appended
--- it twice and proposed .../Adobe/Lightroom/Adobe/Lightroom/Modules).
local function lightroomDir()
  local home = homeDir()
  local base
  if MAC_ENV == false or (MAC_ENV == nil and WIN_ENV == true) then
    base = LrPathUtils.child(LrPathUtils.child(home, 'AppData'), 'Roaming')
  else
    base = LrPathUtils.child(home, 'Library/Application Support')
  end
  return LrPathUtils.child(LrPathUtils.child(base, 'Adobe'), 'Lightroom')
end

function M.modulesDir()
  return LrPathUtils.child(lightroomDir(), 'Modules')
end

function M.backupsDir()
  return LrPathUtils.child(lightroomDir(), 'papat-lightroom-backups')
end

function M.targetDir()
  return LrPathUtils.child(M.modulesDir(), PLUGIN_FOLDER)
end

function M.currentDir()
  return LrPathUtils.standardizePath(_PLUGIN.path)
end

--- @return table { path, standard, downloads, target, modules }
function M.status()
  local current = M.currentDir()
  local modules = M.modulesDir()
  local ctx = { home = homeDir(), modulesDirs = { modules } }
  -- the folder may be reached through a link: either spelling counts
  local standard = text.isInModulesFolder(current, ctx) or text.isInModulesFolder(_PLUGIN.path, ctx)
  return {
    path = current,
    standard = standard,
    downloads = text.inDownloads(current),
    target = M.targetDir(),
    modules = modules,
  }
end

-- ---------------------------------------------------------------------------
-- File-level helpers
-- ---------------------------------------------------------------------------

local function isVisible(rel)
  return not (rel:sub(1, 1) == '.' or rel:find('/%.', 1))
end

--- All visible files under root as { path, rel }.
local function listFiles(root)
  local out = {}
  for path in LrFileUtils.recursiveFiles(root) do
    local rel = text.relativePath(root, path)
    if rel and isVisible(rel) then out[#out + 1] = { path = path, rel = rel } end
  end
  return out
end

local function sizeOf(path)
  local attrs = LrFileUtils.fileAttributes(path)
  return attrs and attrs.fileSize
end

--- Copy every file of `files` (from srcRoot) to dstRoot. Returns copied dest paths.
local function copyFiles(files, dstRoot)
  local copied = {}
  for _, f in ipairs(files) do
    local dest = LrPathUtils.child(dstRoot, f.rel)
    local dir = text.parentPath(dest)
    local okDir, dirErr = LrFileUtils.createAllDirectories(dir)
    if okDir == false then
      return copied, 'フォルダを作成できませんでした: ' .. tostring(dirErr)
    end
    local ok, err = LrFileUtils.copy(f.path, dest)
    if not ok then
      return copied, 'コピーできませんでした: ' .. f.rel .. ' ' .. tostring(err or '')
    end
    copied[#copied + 1] = dest
    local want, got = sizeOf(f.path), sizeOf(dest)
    if want == nil or got == nil or want ~= got then
      return copied, 'コピー後のサイズが一致しません: ' .. f.rel
    end
  end
  return copied, nil
end

--- Delete the listed files, then every now-empty sub-directory of `root` (deepest first).
--- `root` itself is kept. Only call with a folder this module created.
local function removeFilesAndEmptyDirs(files, root)
  for _, path in ipairs(files) do
    if LrFileUtils.exists(path) == 'file' then LrFileUtils.delete(path) end
  end
  local dirs = {}
  if LrFileUtils.exists(root) == 'directory' then
    for path in LrFileUtils.recursiveDirectoryEntries(root) do
      if LrFileUtils.exists(path) == 'directory' then dirs[#dirs + 1] = path end
    end
  end
  table.sort(dirs, function(a, b) return #a > #b end)
  for _, dir in ipairs(dirs) do
    if LrFileUtils.isEmptyDirectory(dir) then LrFileUtils.delete(dir) end
  end
end

-- ---------------------------------------------------------------------------
-- Install
-- ---------------------------------------------------------------------------

--- Copy the running plug-in folder to <Modules>/papat.lrplugin.
--- An existing copy there is first copied to the backups folder, then replaced.
---
--- @return table result  { ok = true, dest, backup|nil, count } or { ok = false, message }
function M.install()
  local st = M.status()
  if st.standard then
    return { ok = false, already = true, message = 'papat はすでに Lightroom の標準の場所から読み込まれています。' }
  end

  -- Never write anywhere but the known Modules folder.
  if not text.isStandardModulesDir(st.modules, homeDir()) then
    log.error('refusing to install: unexpected Modules path %s', tostring(st.modules))
    return {
      ok = false,
      message = 'コピー先の場所を確認できなかったため、コピーを中止しました（何も変更していません）。'
        .. '手動で ~/Library/Application Support/Adobe/Lightroom/Modules/ に papat.lrplugin を入れてください。',
    }
  end

  local src, dest = st.path, st.target
  local nsrc, ndest = text.normalizePath(src, nil), text.normalizePath(dest, nil)
  if text.samePath(nsrc, ndest)
    or text.relativePath(ndest, nsrc) or text.relativePath(nsrc, ndest) then
    return { ok = false, message = 'コピー元とコピー先が重なっています。' }
  end

  local files = listFiles(src)
  local hasInfo = false
  for _, f in ipairs(files) do
    if f.rel == 'Info.lua' then hasInfo = true end
  end
  if not hasInfo then
    return { ok = false, message = '現在のプラグインフォルダに Info.lua が見つかりません。' }
  end

  local okMod, modErr = LrFileUtils.createAllDirectories(st.modules)
  if okMod == false then
    return { ok = false, message = 'Lightroom の Modules フォルダを作成できませんでした: ' .. tostring(modErr) }
  end

  -- 1. back up what is there now (copy, verify, only then remove)
  local backup = nil
  local existing = LrFileUtils.exists(dest) and listFiles(dest) or {}
  if #existing > 0 then
    local stamp = os.date('%Y%m%d-%H%M%S')
    backup = LrPathUtils.child(M.backupsDir(), PLUGIN_FOLDER .. '.' .. stamp .. '-' .. ids.passcode(4))
    local _, err = copyFiles(existing, backup)
    if err then
      return { ok = false, message = '既存の papat.lrplugin を退避できませんでした（何も変更していません）。' .. err }
    end
    local paths = {}
    for _, f in ipairs(existing) do paths[#paths + 1] = f.path end
    removeFilesAndEmptyDirs(paths, dest)
  end

  -- 2. copy the running plug-in
  local copied, copyErr = copyFiles(files, dest)
  if copyErr then
    log.warn('install failed: %s', copyErr)
    removeFilesAndEmptyDirs(copied, dest)
    if backup then
      local saved = listFiles(backup)
      copyFiles(saved, dest)
    end
    return {
      ok = false,
      message = 'コピーに失敗したため、元の状態に戻しました。' .. copyErr,
    }
  end

  log.info('installed to Modules: %d files, backup=%s', #copied, tostring(backup))
  return { ok = true, dest = dest, backup = backup, count = #copied }
end

return M
