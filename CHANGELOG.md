# Changelog

## 1.0.3

- Fix: the metadata of exported JPEGs was not what the plug-in claimed (Exif, XMP develop settings and edit history,
  IPTC contact details, camera / lens serial numbers and the embedded thumbnail were sent). Lightroom's metadata is
  now always stripped (`lib/jpeg.lua`; a file whose structure cannot be read is not sent) and only what the
  photographer registered as copyright, creator and contact details is written back (`lib/rights.lua`: Exif Artist /
  Copyright and XMP dc:rights, dc:creator, xmpRights, IPTC Core contact info), for exports and for speed-first
  previews alike. The content is shown once for confirmation ("入れずに送る" / cancel) and can be switched off; location,
  serial numbers, develop settings and edit history are never embedded
- The photographer's star rating is sent as the manifest `rating` ("撮影者" in the gallery; switchable); the color
  label is not sent
- Speed-first mode: a probe of three photos (first / middle / last) decides up front whether previews are usable in
  this catalog (otherwise everything is exported); per photo, previews that are missing, unreadable, still carry Exif
  (the camera's embedded JPEG), or are outside 1900-2560 px are exported instead; 10 s timeout; after 3 failures in
  a row the rest is exported; the result shows "N from previews / M exported" with a hint to build standard
  previews, and the log lists why previews were rejected, the long-edge range and the average size
- Speed-first: a probe that takes 0.8 s per photo or more (previews rendered on demand) switches to export for
  the whole run; probe sizes and times are logged
- Speed-first: measured with a colour chart, the preview's pixels are sRGB (not Adobe RGB). The JPEG has no
  profile, so the generated sRGB profile (`lib/icc.lua`) is added, as a normal export has one; a preview smaller
  than 1900 px is accepted when the photo itself (cropped size) is that small
- Manifest: `datetime` (camera wall-clock time, `YYYY-MM-DDTHH:MM:SS`, no zone; adjusted capture time preferred) is
  filled in again, so the gallery's capture-time sort and grouping work; the gallery order is decided once
  (capture time, file name, selection order) and manifests publish a prefix of it, independent of which upload
  finishes first; names are remembered for a resume only once published
- Billing messages: `card_required` (also raised for paid units, not only when the free galleries are used up),
  `monthly_limit` (initial invoice, 20 units a month), `paid_country_blocked` / `billing_country_required` /
  `invite_only` stop the send with the server's words; the unsent photos are kept ("続きから送る")
- JPEG rewrite checks: EOI present, picture data byte-identical before and after (also after adding segments)
- Plug-in Manager: sections now follow the work, connection → "アタリ送付" (sending) → "セレクト受け取り 反映設定"
  (receiving) → version; titles renamed accordingly
- Videos in the selection are not sent
- Installer: a licence screen ("使用許諾", Japanese / English) between the welcome and the completion screens. It
  states the pricing, the terms, what the plug-in sends, what it writes to the catalog, the API key and the
  warranty in a few lines, followed by the MIT License. The MIT text is inserted from `LICENSE` at build time and
  `scripts/verify-pkg.sh` / `scripts/check.sh` compare it byte for byte. The plug-in itself is unchanged
- 使用許諾：第1版（2026-10-12）。版と履歴は `docs/license-history.md`、版の管理は `scripts/check-license.sh`
- Installer: the completion screen names where the API key is issued (「連携」 in the dashboard), where the menu
  command is, and adds "don't give it to an AI"
- Pricing: the free allowance is no longer written in the plug-in. The create dialog shows the server's
  `free_galleries_remaining` ("無料の残り N ギャラリー", from the status call, refreshed by every create response)
  and says nothing about it when the server did not send a number; the card-required message no longer names a
  number. The licence screen of the installer says "the first 8 galleries" (the allowance as of this release)
- Dialogs: text boxes with a fixed `height_in_lines` cut long sentences (the intro of "papat でギャラリーを作る"
  ended mid-sentence). The intro is shortened to the essentials (what is sent, what the images carry), and every
  fixed-height text now takes its height from its text (`text.linesFor`); the result window's status / note boxes
  are sized for the longest messages, and the smoke test checks all dialogs
- Sending: transient errors (HTTP 429 / 500 / 502 / 503 / 504, `temporarily_unavailable`, lost connections) are
  retried after 1 s / 3 s / 9 s with jitter and never sooner than `Retry-After`; `gallery_limit_reached` is asked once
  more after a pause and, if it stays, the stop message shows the server's numbers; only 401 / 402 (`card_required`,
  `monthly_limit`) / 403 / 404 / 410 and the gallery codes stop the whole send; repeated trouble lowers the parallel
  uploads from 3 to 1 (restored after five clean uploads); six failed photos in a row pause the send with a pointer
  to "続きから送る"; the log has retry counts and the final status / code of each failed photo
- Text: the create dialog, README, plug-in manager and security notes describe what is really sent

## 1.0.2

- Update notice: when the status API reports a newer plug-in, the three menu commands tell about it at most once a day
  (open the download page / later) and carry on; a *required* update (server minimum above this version) stops
  "create" and "import" with instructions. Never blocks when the check fails. The plug-in never replaces its own files

- Speed / background: the gallery is created first and its URL, passcode and invitation text are shown at
  once; the photos are rendered and uploaded in the background (Lightroom's progress indicator, cancellable),
  rendering and uploading overlap, three uploads run at a time, the manifest is sent in small batches with a
  `complete` flag. Timings (render / upload / total, seconds per photo) are logged and shown
- "papat 最近のギャラリー…": URL / passcode / invitation again, and "続きから送る" for an interrupted upload
- Optional "速さ優先" mode (experimental): take the JPEG from Lightroom's preview instead of exporting
- Fix: the standard location was computed with `Adobe/Lightroom` twice (the SDK's appData already ends in it);
  it is built from the home folder and nothing is copied unless the target is exactly
  `~/Library/Application Support/Adobe/Lightroom/Modules`

- Fix: a plug-in installed in `~/Library/Application Support/Adobe/Lightroom/Modules/` (e.g. by the .pkg) was shown
  with the "copy to the standard location" warning. The location is now compared after normalizing the path
  (`~`, trailing slash, `.` / `..`, `/private`, `/System/Volumes/Data`, case, link vs. resolved path) and also by
  structure, independent of the SDK's "appData" path. When it is standard the Plug-in Manager shows one line,
  「標準の場所にインストールされています。」, with no warning and no button

- Optional "色（任意）" (#RRGGBB) in the gallery dialog: sent as `key_color` in the create request and the
  manifest (omitted when empty = papat's default color). Invalid input is never sent; the last five colors are remembered

- Gallery creation sends the passcode itself next to `passcode_hash` (the server verifies the pair and stores it
  encrypted, so the photographer can read it again in the dashboard); new error code `invalid_passcode`
- Invitation text now has the same shape as the dashboard's: title, `URL:`, `パスコード:`, `公開期限:`, and
  "ブラウザで開いて、気に入った写真に★を付けて「確定」を押してください。"
- Dialog / README wording: the passcode can be viewed again in the dashboard

## 1.0.1

- Plug-in Manager shows where the plug-in is loaded from (warns for Downloads) and can copy
  itself to Lightroom's Modules folder ("標準の場所にコピー…"); offered once on the first command
- Error messages are chosen by the server's error `code` (409 `active_gallery_limit` now says the 10-gallery
  limit instead of "already closed"; `idempotency_conflict`, `gallery_closed`, `extension_already_used` have their own text)
- The ZIP contains `はじめにお読みください.txt`
- Signed/notarized `.pkg` installer pipeline (`scripts/build-pkg.sh`, `docs/guide-signing.md`):
  per-user install, no admin password, existing copy moved to a backups folder first

## 1.0.0

- Create a papat gallery from the selected photos (LrExportSession, JPEG 2048px / sRGB / q80)
- Import the client's adopted photos (source_id / sid / filename / stem matching) into
  "papat 採用 <gallery> <date>"; pick flag, memo appended to the caption ("— papat: …", not
  repeated on re-import) and tags as keywords are on by default and switchable; star
  sub-collections are opt-in
- Plug-in Manager: API key (LrPasswords), connection check, import switches
- Never writes the star rating, never touches the color label
