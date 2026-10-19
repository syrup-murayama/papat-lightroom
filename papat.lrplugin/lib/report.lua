--[[
  lib/report.lua — "送信の記録": with permission, one small report after each "create gallery"
  operation (every segment of a split send counts as one operation; a later "続きから送る" is
  its own, separate operation), telling papat how fast and how reliably the send went.
  Opt-in, asked once; a failure to send it is only logged — the photographer is never told,
  and it is never retried.

  What is sent (the papat server decides
  the authoritative shape — this file only needs to send a subset of what it
  allows): client name/version, Lightroom/OS/arch (as short version-only tokens), the
  gallery's sid(s), counts (total/preview/export/failed/retries), why a preview fell back to
  export, timings (wall/render/photo PUT/thumb PUT/sips), bytes sent, whether similarity
  grouping was used, the split segment count, and errors as {code, where, count} only — never
  a message. There is no field for a filename, title, passcode, path, username or computer
  name; this file never builds one.

  Audit 16 (docs/audit/A2-review-release-16.md) flagged exactly this: the server's sanitizer
  cannot tell "macOS-15.1" apart from "Daisukes-MacBook" — both are valid `[A-Za-z0-9._-]`
  tokens to it. That distinction is enforced here, on the way out: os/lightroom/arch are never
  a raw system string, only version digits pulled out of one, or a value from a closed
  allow-list; `tag()` does the same for every machine-chosen code (error code, "where").
]]

local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrSystemInfo = import 'LrSystemInfo'

local function load(name) return dofile(_PLUGIN.path .. '/lib/' .. name .. '.lua') end
local config = load('config')
local api = load('api')
local log = load('log')

local M = {}

M.CONSENT_TEXT = '送信の速さとエラーの記録を、papat に送ってよいですか？ 写真・ファイル名・題・パスコードは含みません。'
  .. 'プラグインの改善だけに使います。'
M.SETTINGS_INTRO = '送信の速さや、起きたエラーの種類（内容の文は含みません）を papat に送るかどうかを、ここでいつでも変更できます。'

local MAX_ERRORS = 20

-- ---------------------------------------------------------------------------
-- Safe system tokens: version digits / a closed allow-list only — never a raw string
-- (audit 16; see the file header).
-- ---------------------------------------------------------------------------

--- Keeps only digits and '.', so nothing but a version number can ever come out, whatever the
--- SDK or the OS actually puts in the string it hands back (LrSystemInfo.osVersion() is
--- documented as "for reporting only, do not parse" — this also protects against its shape
--- changing on some future OS, not only against it ever containing a computer name).
local function versionDigits(s)
  if type(s) ~= 'string' then return nil end
  local digits = s:match('%d[%d%.]*')
  if not digits then return nil end
  return (digits:gsub('%.+$', '')) -- no trailing dot
end

--- @return string|nil  "macOS-15.1" / "Windows-10.0", or nil if no version could be read
function M.osToken()
  local ok, raw = pcall(function() return LrSystemInfo.osVersion() end)
  local v = ok and versionDigits(raw) or nil
  if not v then return nil end
  if WIN_ENV then return 'Windows-' .. v end
  return 'macOS-' .. v -- the only other platform this plug-in supports
end

local ARCH_ALLOW = { x86 = true, x64 = true, arm64 = true, aarch64 = true, ppc = true, ppc64 = true }

--- @return string|nil  one of ARCH_ALLOW's keys, or nil (never an unrecognized raw value)
function M.archToken()
  local ok, a = pcall(function() return LrSystemInfo.architecture() end)
  if ok and type(a) == 'string' and ARCH_ALLOW[a] then return a end
  return nil
end

--- @return string|nil  "14.5.1" from LrApplication.versionTable()'s major/minor/revision
function M.lightroomToken()
  local ok, v = pcall(function() return LrApplication.versionTable() end)
  if ok and type(v) == 'table' and tonumber(v.major) then
    return string.format('%d.%d.%d', tonumber(v.major), tonumber(v.minor) or 0, tonumber(v.revision) or 0)
  end
  return nil
end

--- A short, machine-chosen tag (an error code, a "where" location) — never free text. Strips
--- anything that is not a letter, digit, '.', '_' or '-', and cuts to `max` characters.
--- @return string|nil  nil for '' or a non-string input
function M.tag(s, max)
  if type(s) ~= 'string' or s == '' then return nil end
  local cleaned = s:gsub('[^A-Za-z0-9._%-]', '_')
  if #cleaned > max then cleaned = cleaned:sub(1, max) end
  return cleaned ~= '' and cleaned or nil
end

-- ---------------------------------------------------------------------------
-- Consent: asked once, changeable afterwards in the Plug-in Manager
-- ---------------------------------------------------------------------------

--- Shown at most once in the plug-in's lifetime (CreateGallery.lua calls this right before its
--- first gallery after updating to 1.2.1). No-op once `reportAsked` is set, whichever way the
--- choice went, or once the Plug-in Manager checkbox has been touched directly.
function M.askOnce()
  if config.reportStatus().asked then return end
  local choice = LrDialogs.confirm('papat', M.CONSENT_TEXT, '送る', '送らない')
  config.setReportConsent(choice == 'ok')
end

-- ---------------------------------------------------------------------------
-- Collecting one report across every segment of one operation
-- ---------------------------------------------------------------------------

--- @return table  a fresh accumulator; M.addSegment folds each segment's outcome into it,
---   M.finish sends the total once every segment is done.
function M.newCollector()
  return {
    startedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    sids = {},
    segments = 0,
    total = 0, preview = 0, export = 0, failedUpload = 0, failedRender = 0, retries = 0,
    reasons = {},
    renderSeconds = 0, wallSeconds = 0,
    uploadSeconds = 0, uploadCalls = 0,
    thumbPutSeconds = 0, thumbPutCalls = 0,
    sipsSeconds = 0,
    sentBytes = 0, thumbBytes = 0,
    similarityUsed = false,
    probe = nil, -- the first segment's own probe samples only (see M.addSegment)
    errors = {}, -- [code .. '|' .. where] = { code, where, count }
  }
end

--- preview.jpeg's own outcome names -> the export_reasons key for it (the server
--- allows any key, up to 16 — see M.finish). "送信の記録" (1.2.1), the question about
--- the 2026-10-19 field report: does waiting past a small, suspiciously fast first callback
--- turn up a bigger one often, rarely, or never, across real sends?
local WAIT_OUTCOME_KEY = {
  first_big = 'preview_first_big',
  small_then_big = 'preview_small_then_big',
  small_timeout = 'preview_small_timeout',
}

local function addError(c, code, where, n)
  code = M.tag(code, 48)
  if not code then return end
  where = M.tag(where, 48)
  local key = code .. '|' .. (where or '')
  local e = c.errors[key]
  if not e then
    e = { code = code, where = where, count = 0 }
    c.errors[key] = e
  end
  e.count = e.count + (n or 1)
end

--- Folds one segment's outcome — `sid` and `result` (lib/pipeline.lua's own return value,
--- unchanged by this call) — into the collector `c`. `opts.similarityUsed`: true if
--- lib/similarity.lua actually produced usable groups for this segment (or for the selection
--- it was cut from); sticky — once true for any segment, it stays true for the whole report.
function M.addSegment(c, sid, result, opts)
  c.segments = c.segments + 1
  if type(sid) == 'string' and sid ~= '' then c.sids[#c.sids + 1] = sid end
  local t = result.timings or {}

  c.preview = c.preview + (t.previewOk or 0)
  c.export = c.export + (t.previewFallback or 0)
  c.total = c.total + (t.previewOk or 0) + (t.previewFallback or 0)
  c.failedUpload = c.failedUpload + #(result.failedUpload or {})
  c.failedRender = c.failedRender + #(result.failedRender or {})
  c.retries = c.retries + (result.retries or 0)

  for reason, n in pairs(t.reasons or {}) do
    local key = M.tag(reason, 32)
    if key then c.reasons[key] = (c.reasons[key] or 0) + n end
  end
  for outcome, n in pairs(t.waitOutcomes or {}) do
    local key = WAIT_OUTCOME_KEY[outcome]
    if key then c.reasons[key] = (c.reasons[key] or 0) + n end
  end
  -- the first segment's probe only ("最初の3枚"): a split send's later segments probe again,
  -- but one small sample per report is enough, and the server only keeps 3 anyway
  if not c.probe and type(result.probe) == 'table' and #result.probe > 0 then
    c.probe = result.probe
  end

  c.renderSeconds = c.renderSeconds + (t.render or 0)
  c.wallSeconds = c.wallSeconds + (t.total or 0)
  if (t.uploadCalls or 0) > 0 then
    c.uploadSeconds = c.uploadSeconds + t.uploadSeconds
    c.uploadCalls = c.uploadCalls + t.uploadCalls
  end
  if (t.thumbPutCalls or 0) > 0 then
    c.thumbPutSeconds = c.thumbPutSeconds + t.thumbPutSeconds
    c.thumbPutCalls = c.thumbPutCalls + t.thumbPutCalls
  end
  c.sipsSeconds = c.sipsSeconds + (t.sipsSeconds or 0)
  c.sentBytes = c.sentBytes + (t.sentBytes or 0)
  c.thumbBytes = c.thumbBytes + (t.thumbBytes or 0)

  if opts and opts.similarityUsed then c.similarityUsed = true end

  if result.fatal then
    addError(c, result.fatal.code or ('http_' .. tostring(result.fatal.status or 0)), 'fatal', 1)
  end
  if result.manifestError then
    addError(c, result.manifestError.code or ('http_' .. tostring(result.manifestError.status or 0)), 'manifest', 1)
  end
  for key, n in pairs(t.failedStatus or {}) do
    addError(c, key, 'photo_put', n)
  end
end

--- Builds the report body (matching plugin-report.ts's CleanReport) and sends it once. Never
--- raises: any failure (building the body, the network call, a non-2xx answer) is only logged.
--- No-op without consent, without an API key, or when nothing was actually sent (0 segments).
function M.finish(apiKey, c, opts)
  if not apiKey or not c or c.segments == 0 then return end
  if not config.reportStatus().consent then return end

  local ok, err = pcall(function()
    local reasons = {}
    for k, n in pairs(c.reasons) do reasons[k] = n end

    local errors = {}
    for _, e in pairs(c.errors) do
      errors[#errors + 1] = { code = e.code, where = e.where, count = e.count }
      if #errors >= MAX_ERRORS then break end
    end

    -- 最初の3枚の {w,h,seconds,reason}（lib/pipeline.lua's probe; the server keeps 3 at most)
    local probe = nil
    if c.probe then
      probe = {}
      for _, p in ipairs(c.probe) do
        probe[#probe + 1] = {
          w = tonumber(p.w), h = tonumber(p.h), seconds = tonumber(p.seconds), reason = M.tag(p.reason, 32),
        }
      end
    end

    local timings = {
      wall = c.wallSeconds,
      render = c.renderSeconds,
      sips_total = c.sipsSeconds,
    }
    if c.uploadCalls > 0 then timings.photo_put_each = c.uploadSeconds / c.uploadCalls end
    if c.thumbPutCalls > 0 then timings.thumb_put_each = c.thumbPutSeconds / c.thumbPutCalls end
    if opts and opts.similaritySeconds then timings.similarity = opts.similaritySeconds end

    local body = {
      client = { name = config.CLIENT_ID, version = config.VERSION },
      lightroom = M.lightroomToken(),
      os = M.osToken(),
      arch = M.archToken(),
      sid = c.sids,
      started_at = c.startedAt,
      finished_at = os.date('!%Y-%m-%dT%H:%M:%SZ'),
      counts = {
        total = c.total, preview = c.preview, export = c.export,
        failed_upload = c.failedUpload, failed_render = c.failedRender, retries = c.retries,
      },
      export_reasons = reasons,
      probe = probe,
      timings = timings,
      bytes = { photos = c.sentBytes, thumbs = c.thumbBytes },
      similarity = { used = c.similarityUsed },
      split = { segments = c.segments },
      errors = errors,
    }

    local res = api.sendReport(apiKey, body)
    if not res.ok then
      log.info('report: not sent (status=%s code=%s)', tostring(res.status), tostring(res.code))
    end
  end)
  if not ok then log.warn('report: failed to build/send (%s)', tostring(err)) end
end

return M
