# Changelog

## 1.2.3

- 使用許諾：第3版のまま（この版の直しによる変更はなし）
- **採用を読み込むときに、メモ付きの写真で止まる不具合を直しました**。「セレクトを読み込む」で、メモのある写真を
  読み込むと「内部エラーが発生しました。Unknown key: "caption"」と表示され、途中で止まっていました
  （1.0.0 から。メモのない採用だけのときは出ません）。説明（キャプション）の読み方を直しました。あわせて、
  1 枚の説明を読めない・書けないときは、その写真のメモだけを飛ばして続けます（ほかの写真の採用フラグ・
  コレクション・タグは止まりません）。飛ばした枚数は、読み込み後の表示に「（N 枚は説明にメモを追記できませんでした）」
  と出ます
- 写真の情報の読み方を Lightroom の仕様に合わせて見直しました。その結果、**長辺が約 2,000 px に満たない小さい写真（強く切り抜いた写真を含む）は、これまで書き出して送っていたものが、カタログのプレビューから送られるようになり、速くなります**（プレビューが元より小さいときは、これまでどおり書き出します）。送る写真の大きさは変わりません
- タグをキーワードに入れるときも、1 枚で失敗したらその写真のタグだけを飛ばして続けます。飛ばした枚数は、読み込み後の表示に「（N 枚はタグを追加できませんでした）」と出ます

## 1.2.2

- 使用許諾：第3版のまま（この版の直しによる変更はなし）
- **feat: ギャラリーを作る要求に expected_photos を追加** (`lib/api.lua`, `CreateGallery.lua`)。
  `POST /galleries` の本文に、そのギャラリーに送る予定の枚数（0〜1,000の整数。分けたときは
  各ギャラリー自身の枚数）を添える。サーバー側がこれで月の上限とカードの要否を、何も送る前に
  先に確かめられるようにするため（枚数が範囲外のときは付けない＝古いプラグイン・CLI相当の
  挙動）。画面の文言に変更はなし。テストを `tests/smoke.lua` に2件追加
- **feat: 料金の全体設計（決定 2026-10-20）に合わせた直し**。1 ギャラリー 88 円・88 枚までは 8 円・
  延長は +88 円に（`lib/text.lua`。枚数で額が増える「300 枚ごとに1単位」の仕組みは廃止）。無料の残りが
  あるときは、写真の分を 0 円で表示する（分けたときは、無料の数だけ先頭のギャラリーから 0 円にする）。
  自動の分割（`lib/split.lua`）は、1,000 枚を超えたときだけ分けるように変更（以前は 888 枚）。分ける
  境目の探し方も、760〜800 枚→800〜1,000 枚→（無ければ）800 枚で切る、の3段に整理し、撮影時刻の間が
  いちばん空いた所で切る段（グループが使えるときは出番が無い）は外した。保存期間の選択を「7泊8日
  （8日目の11:00まで）」「14泊15日（15日目の11:00まで）」に、公開期限の表示を「10月27日（火）11:00まで」
  （曜日・時刻つき）に変更（`CreateGallery.lua`、`RecentGalleries.lua`、`lib/text.lua` に
  `expireText`／`jaDateTimeWithWeekday` を追加）。テストを `tests/run.lua`・`tests/smoke.lua` に追加・更新。
  文言は `docs/ui-copy-1.2.0.md` → `docs/ui-copy-1.2.2.md` に〔1.2.2〕の印で記録。校正が戻るまで配らない
- **feat: 案内文に {パスコード入りURL}** (`lib/text.lua`). 案内文のテンプレートに新しい印
  `{パスコード入りURL}` を追加（`https://papat.app/t/{tenant}/s/{sid}/#p={パスコード}`。ギャラリー
  側の対応は別の担当。鍵の名前 `p` が変わったら伝えられる予定で、`text.PASSCODE_URL_KEY` の1か所
  を直せばよい）。既定のテンプレートの「URL:」行は、この印を使う形にした（パスコードの行は
  そのまま残す。文言は校正待ちなので、ラベルや文は変えていない）。分割したときの
  「1/2：URL」の行も、ギャラリーごとに同じパスコードを付ける。保存した案内文からテンプレートを
  作り直すとき（`M.templateFromAnnouncement`）も、パスコード入りの形をまず探して正しく
  `{パスコード入りURL}` に戻す（古い `{URL}` だけの保存済みテンプレートはそのまま動く）。
  テストを `tests/run.lua` に14件、`tests/smoke.lua` に2件追加。文言はまだ校正待ち：この版は
  準備のみで、校正が来たら合わせて配る

## 1.2.1

- 使用許諾：第3版（2026-10-20）。「3. プラグインが送るもの」の
  末尾に、「送信の記録」（許可した場合だけ、改善のために送る送信の速さ・エラーの種類など。写真・
  ファイル名・ギャラリーの題・パスコードは含まない）についての1文を追記（日英）。版と履歴は `docs/license-history.md`
- **feat: 送信の記録（オプトイン）** (`lib/report.lua`, `lib/sender.lua`, `CreateGallery.lua`,
  `PluginInfoProvider.lua`). 初めてギャラリーを作るときに一度だけ確認し、許可した人だけ、送信が
  終わるたびに1件（分割したら1回の操作で1件）、送信の速さとエラーの記録を `POST
  /api/v1/integration/report` に送る（papat のサーバーが、許した項目だけを保存する）。写真・ファイル名・ギャラリーの題・パスコード・パス・ユーザー名・Mac の名前は
  送らない。`os`/`lightroom`/`arch` は版の数字だけ、またはあらかじめ決めた値だけに絞って作り、
  システムの文字列をそのまま渡さない（監査16の申し送り）。記録の送信に失敗しても、利用者には
  何も出さず、やり直しもしない。あとからプラグインマネージャーの設定で変更できる。
  `export_reasons` に `preview_first_big`／`preview_small_then_big`／`preview_small_timeout`
  （小さく速い最初の callback のあと、待った結果どうだったか。上の speed-first の直しそのものの
  実測）を追記し、`probe` に最初の3枚の `{w,h,seconds,reason}` を追記（`lib/preview.lua`,
  `lib/pipeline.lua`）
- **fix: speed-first — a bad probe sample no longer exports the whole gallery** (`lib/pipeline.lua`,
  `lib/preview.lua`). 2026-10-19 field report: 582 photos, "speed first" on, a probe logged
  `0.01s small` for a photo whose catalog preview setting was Auto/4112px — far too fast and far
  too small to be the real preview — and the whole gallery (all 582) fell back to export because
  the probe's 3-photo sample decided for everyone up front. Fixed:
  - the probe (first/middle/last) is now diagnostic only — logged, but it no longer decides
    whether the rest of the gallery even tries a preview; every photo gets its own attempt and
    its own export fallback
  - the probe log shows the preview's actual size for a rejected photo instead of `-`
  - a first callback that is both too small and suspiciously fast (< 0.3 s) now holds the
    request open for up to 5 more seconds, in case Lightroom answers again with the real,
    properly rendered preview (`lib/preview.lua`'s `opts.minEdge`) — not yet confirmed against
    the real SDK; see `spike/preview-freshness`'s "Freshness15s" tool, used to check whether a
    second callback actually happens on a real Mac
  - a genuinely small preview (not suspiciously fast) is still trusted immediately, so a catalog
    whose standard preview size is set low does not pay the extra wait on every photo for nothing
  - **audit 17 §4.1**: once a send has seen 3 `small_timeout` outcomes and 0 `small_then_big`,
    the 5s wait stops for the rest of that send (trusts the first callback immediately from
    then on) — without this, a send whose "2nd callback" theory never pays off could pay the
    full 5s on every small photo (1,000 photos, half placeholders that never improve: ~42
    minutes on top of the export itself). Bounds the worst case at 3 × 5s = 15s per send. A
    single `small_then_big` keeps the wait on for the rest of the send regardless of how many
    timeouts pile up alongside it (the theory is confirmed for that send, so it keeps paying off)

## 1.2.0

- 使用許諾：第2版（2026-10-15 に承認）。「3. プラグインが送るもの」の末尾に、
  「似た写真をまとめるための区切り（グループの番号）も送ります。まとめる計算は、この Mac の中で行います。写真は、そのために
  どこにも送りません。同梱の小さな実行ファイルは通信せず、ソースを MIT で公開しています。」（英語も同じ内容）を追記。
  版と履歴は `docs/license-history.md`
- **Group boundaries from capture time** (`lib/grouping.lua`): a line-for-line Lua port of the gallery's own
  `autoGroups` (the usual-gap-times-4 rule), cross-checked against the real JS through node (`tests/grouping.lua`).
  The plug-in sends nothing new because of
  this on its own; it is the shared building block for the two features below (both need the same group boundaries
  the browser itself will show, before anything is sent)
- **Similar photos grouped on the photographer's Mac** (`lib/similarity.lua`, a small bundled helper:
  `papat.lrplugin/bin/papat-fprint`, built from `tools/papat-fprint/main.swift`). macOS only: Apple Vision's
  `VNGenerateImageFeaturePrintRequest` refines the time groups above, splitting further where the picture changes
  sharply within one of them (minimum 2 photos, a window of 3; tuned on one real shoot). The helper has no networking
  code at all (only Foundation and Vision are imported) and writes nothing but 1-based group numbers; the plug-in
  never stores or sends a feature print. Computed in its own task, next to the send, from small previews made just
  for this (never the ones being uploaded), so it never adds to a send's own wait; not macOS, no helper, too few
  usable previews, a failure or an unreadable answer just leaves the gallery on time groups alone — nothing is ever
  shown about it. `scripts/build-pkg.sh` builds and bundles a universal (arm64 + x86_64) binary, signed when the
  commissioning party has set `PAPAT_APP_IDENTITY` (a Developer ID Application certificate, distinct from the
  installer's own `PAPAT_INSTALLER_IDENTITY`). The 使用許諾 screen now discloses this (第2版, below); the root
  `LICENSE` (MIT, covering the source) is unchanged — only the installer's licence screen gained a sentence
- **A selection over 888 photos is split into several galleries** (`lib/split.lua`; 2026-10-15 の決定). The
  cut is chosen from the group boundaries above — closest to 888, first within 750-888 photos, then within
  888-max_photos — falling back to the single largest capture-time gap in that range, then to a fixed 888th photo,
  when there is no boundary or no grouping at all to go on. A last piece under 100 photos folds back into the one
  before it rather than making a small gallery on its own. The settings dialog shows one line before creating
  ("888 枚を 2 つのギャラリーに分けて送ります（750枚・138枚）") and prices each gallery on its own (300 photos per
  unit) before adding them up. Titles get a "（1/2）" / "（2/2）" suffix; the invitation's `{URL}` becomes one
  "N/M：url" line per gallery (a single gallery is unchanged). The galleries are created up front (so the one result
  window can show every URL at once) and sent one after another in the background (`lib/sender.lua`'s new
  `M.startMany`; a single send is now its n=1 case) — a failure in one does not stop the rest. `lib/update.lua`'s
  own assumption for the server's `max_photos` (used until the status call says otherwise) is now 1000, matching
  what the server is expected to use too (B52)
- "写真が多すぎます" no longer refuses a large selection outright: it refuses only the (expected to be rare) case
  where even the auto-split could not keep a gallery at or under `max_photos`

## 1.1.0

- 使用許諾：第1版（変更なし）
- **Default: send from Lightroom's preview** ("速く送る", formerly "速さ優先"). The create dialog has a check box
  "この回だけ、書き出して送る" to export once; the Plug-in Manager switch turns the preview off for good. A value stored by
  1.0.x is dropped once so that everybody starts from the new default (`config.migrate`). The result still says
  "プレビューから N 枚・書き出しで M 枚"; the probe of three photos and the per-photo fall-backs are unchanged. README, the
  settings text and the dialogs say plainly that a preview can be older than the last edit (the plug-in cannot tell)
- **Small versions for the gallery's overview** (`lib/thumb.lua`, a side channel in `lib/pipeline.lua`), never on the
  photos' way. The bytes that were sent (preview or export, already cleaned) are shrunk by macOS `sips` in batches of 10
  to 20 files by a separate task (short edge 400 px, long edge at most 800 px, JPEG 80; about 8.5 s in total for 296
  photos on the test Mac), cleaned again and given the copyright / creator / contact segments and the sRGB profile.
  Lightroom's small previews (`requestJpegThumbnail(400, 400)`) are deliberately NOT used: on a real machine, after an
  edit the big preview level was new while the small one was still the old picture. They are PUT to
  `thumbs/<same name>` by their own tasks after their photo (the server takes <= 256 KB and only after the photo, and
  does not count them against 300 PUTs a minute); the manifest names them (`thumb`) in a later manifest, once they
  have arrived (entries are sent again at the end, 100 at a time). Photos whose short edge is already <= 400 px get
  none. A failure never fails a photo; three in a row stop it for the send. Photos and manifests are started at most
  every 0.22 s; against a server that still counts the small versions, the first 429 is waited out (`Retry-After`) and
  the small versions keep the interval for the rest of that send. The log breaks the time down (photo PUT, sips, small
  version PUT, tail, manifest pass)
- Late pass for the small versions: whether an entry already carried its `thumb` is noted before the manifest PUT
  (a small version that arrives while the PUT waits is added by the pass), and the pass leaves `key_color` out, so the
  server uses the gallery's current color (changed in the browser meanwhile) instead of the one the send started with
- The create dialog no longer offers a client colour ("色（任意）", the recent colours, `#RRGGBB`): it is set in the
  dashboard, and the create request carries none. (The stored recent colours, `text.normalizeKeyColor` and the
  server's `key_color` handling are left in place; a gallery made by an earlier version keeps its colour.)
- Announcement text: the SDK has no way to type a line break in an edit field (Return presses the dialog's default
  button). The field is now a tall field in a scrolling window; in the result window and "最近のギャラリー" a
  "編集中" check box disables the closing button so that Return is no longer swallowed; and "テキストエディタで開く" /
  "編集した内容を反映" (here and in the Plug-in Manager) edit the text in the macOS text editor (`lib/editor.lua`,
  `open -t` on a temporary .txt file)
- Photo limit before creating: `max_photos` of the status call (cached with the update check) is used when the
  server sends one, otherwise 900; the number in the "写真が多すぎます" sentence is the one in use
- **Announcement template**: marks `{題} {URL} {パスコード} {期限}` (English names work too) in a template that is
  edited in the Plug-in Manager (with a reset button) or from the result window ("この文面を、次回から使う" turns the
  edited text back into a template). Lines whose marks are all empty are left out; a template without `{URL}` /
  `{パスコード}` gets them appended; unusable templates are the default text, which is the old text
- "この文面を、次回から使う": a short passcode (e.g. 2024) is turned back into `{パスコード}` only where it stands as the
  passcode (the line that names it, as a whole token), the expiry date once, so the same digits in a title or a
  sentence stay as written
- Server messages: whatever the server wrote is shown as one line of at most 300 characters (line breaks removed,
  cut with "…")
- Server messages: `monthly_limit` shows the server's Japanese wording (a sentence without a number when there is
  none); `active_gallery_limit` names its number only when the server sent it; "14 days" and "20 units" are no longer
  written in the plug-in's own sentences

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
