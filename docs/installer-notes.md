# インストーラ（.pkg）の設計メモ

対象: `scripts/build-pkg.sh` で作る `papat-lightroom-<version>.pkg`。署名・公証の手順は `docs/guide-signing.md`。

## 1. 仕組み

```
papat.lrplugin/ ──pkgbuild──▶ component.pkg  (identifier app.papat.lightroom.pkg, version = Info.lua の VERSION)
                                 payload:         papat.lrplugin/
                                 install-location: /Library/Application Support/Adobe/Lightroom/Modules
                                 scripts:          preinstall / postinstall
component.pkg + distribution.xml + resources ──productbuild──▶ unsigned.pkg
unsigned.pkg ──productsign (Developer ID Installer)──▶ signed.pkg
signed.pkg   ──notarytool submit --wait──▶ Accepted ──stapler staple──▶ papat-lightroom-<version>.pkg
```

- **管理者権限なし・ユーザー領域のみ**: `distribution.xml` の
  `<domains enable_anywhere="false" enable_currentUserHome="true" enable_localSystem="false"/>`。
  Apple の Distribution XML リファレンスによると、`enable_currentUserHome` の導入は「root ではなく現在のユーザーとして行われ、
  ホームディレクトリの外には書き込めない」。`customize="never"` で、インストール先の選択画面は出さない。
- **インストール先**: component の `install-location` は `/Library/Application Support/Adobe/Lightroom/Modules`。
  ホーム領域へのインストールでは、このパスがユーザーのホーム配下（`~/Library/Application Support/…`）に読み替えられる
  （電子書籍等の事例では `/Applications` → `~/Applications`、`/Library` → `~/Library`。ただし**この読み替えの規則を明記した
  Apple の一次資料は確認できていない**）。
- **失敗を黙って成功にしない**: `postinstall` が `~/Library/Application Support/Adobe/Lightroom/Modules/papat.lrplugin/Info.lua`
  の存在を確認し、無ければ失敗を返す。`preinstall` は root で実行されていたら（＝システム領域へのインストールになった場合）失敗を返す。
- **退避**: `preinstall` は既存の `papat.lrplugin` を `~/Library/Application Support/Adobe/Lightroom/papat-lightroom-backups/papat.lrplugin.<日時>` へ
  `mv`（削除はしない）。古いファイルが残らず、元に戻せる。退避先は Modules の**外**（Modules の中に複製があると二重に読み込まれるため）。
  プラグイン自身の「標準の場所にコピー」機能（`lib/location.lua`）と ZIP 用 skill も、同じ退避先を使う。

## 1.1 使用許諾の画面（1.0.3）

`distribution.xml` の `<license file="license.html" …/>`（welcome と conclusion の間）。`installer/resources/{ja,en}.lproj/license.html`。

- 本文（送るもの・料金・API キー・保証）の下に **MIT License の原文**を載せる。原文は HTML に書き写さず、
  テンプレートの `@@MIT_LICENSE@@` の行を、ビルド時に `LICENSE` から差し込む（`scripts/license-html.sh embed`）。
  差し込み結果が `LICENSE` とバイト単位で一致することを、`scripts/build-pkg.sh`（ビルド時）、`scripts/verify-pkg.sh`（.pkg の中身）、
  `scripts/check.sh`（テンプレート）が確かめる。`papat.lrplugin/LICENSE` も同じファイルであること
- インストーラーの使用許諾の画面は、いつも「同意する／同意しない」を聞く。MIT は同意を条件にしないので、画面の文面は
  MIT で認められた権利（利用・複製・改変・再配布）を制限しない内容にとどめる。ZIP とソースは、この画面を通らずに使える
- **版の管理**: 題のすぐ下に「第N版　日付」（英語は "Version N — Month D, YYYY"）。N は 1 から始まる整数で、プラグインの版とは別。
  版と日付は `installer/license-version.txt` の 1 か所（日本語・英語で同じ）。テンプレートの `@@LICENSE_VERSION_LINE@@` に差し込む。
  文（MIT 原文込み・版の行を除く）の SHA-256 を `docs/license-history.md` に版ごとに記録し、`scripts/check-license.sh`
  （`check.sh`・`build-pkg.sh`・`verify-pkg.sh` から呼ぶ）が「文が変わったのに版が同じ」「日英で版が違う」「履歴に行が無い」を失敗にする。
  だれが同意したかは記録しない
- 暗い表示のため、`color-scheme: light dark` だけを指定し、文字色・背景色は指定しない（ブラウザの既定に任せる）

## 2. 実機で確認する項目

インストーラの挙動のうち、Apple の一次資料だけでは断定できない点です（結果は `docs/manual-test.md` の L 章に記録します）。

1. **ホーム領域への読み替え**: `install-location` の `/Library/…` が、ユーザーのホーム配下（`~/Library/…`）に読み替えられること。
   読み替えられない場合は `postinstall` が失敗を返して画面に出る。代替は、payload を `--install-location /` ＋
   `Library/Application Support/Adobe/Lightroom/Modules/papat.lrplugin` の完全な階層にする（`build-pkg.sh` の `PAYLOAD` と
   `INSTALL_LOCATION` を変更）、または postinstall で `$HOME` 配下へコピーする。
2. **管理者パスワードの要否**: `pkgbuild` は component の `PackageInfo` に `auth="root"` を書く。distribution の
   `domains` がホームのみなら不要になるはずだが、求められる場合は、`pkgutil --expand` → `PackageInfo` の
   `auth="root"` を `auth="none"` に変更 → `pkgutil --flatten` で組み直す手順を署名前に挟む。
3. **Lightroom の読み込み**: Modules フォルダ内のプラグインは起動時に自動で読み込まれる。Plug-in Manager 上では、
   Modules 内のプラグインは「削除」ボタンが使えず、無効化はできるが削除はフォルダを消して再起動する、という報告が複数ある
   （Adobe コミュニティ。公式文書ではない）。
4. **同じ ID のプラグインが2か所から読まれた場合**（「追加」で別フォルダから登録済み ＋ Modules）の Lightroom の挙動。
   プラグインは「標準の場所へコピー後、一覧に2つ並んだら今の場所のほうを『削除』」と案内している。

## 3. 署名・公証の前提

- 署名は **Developer ID Installer** 証明書（`productsign`）。Mach-O（実行形式）を含まない（Lua ファイルのみ）ため、
  Developer ID Application 署名・Hardened Runtime は不要。
- 公証は `.pkg` そのものを `xcrun notarytool submit --wait` に出し、`Accepted` 後に `xcrun stapler staple` でチケットを添付する
  （オフラインでも Gatekeeper が通る）。
- 確認: `pkgutil --check-signature <pkg>`、`spctl -a -vv -t install <pkg>`（`source=Notarized Developer ID` が出る）、
  `xcrun stapler validate <pkg>`。
- 資格情報はキーチェーンのみ（`notarytool store-credentials` のプロファイル）。リポジトリ・スクリプトに値は置かない。
  CI で署名する場合は App Store Connect API キー（`--key/--key-id/--issuer`）をシークレットとして渡す。

## 4. ZIP と .pkg の使い分け

| | ZIP | .pkg |
|---|---|---|
| 対象 | AI エージェント（skill）／手動で「追加」したい人／.pkg を使えない環境 | 通常の利用者（ダブルクリック） |
| 置き場所の迷い | 「はじめにお読みください.txt」と、プラグイン画面の「標準の場所にコピー」で補助 | なし（標準の場所に入る） |
| 署名 | なし（チェックサムで改ざん確認） | Developer ID ＋ 公証 |

## 5. .dmg にしない理由 / 将来

- dmg に「Modules フォルダへのエイリアス」を入れてドラッグ＆ドロップさせる案は、ユーザーごとのホームのパスを
  エイリアスに固定できない（`~` は展開されない）。`/Library/Application Support/Adobe/Lightroom/Modules`
  （システム全体）へのシンボリックリンクなら作れるが、管理者権限が要り、ユーザー領域の Modules とは別の場所になる。
- したがって「ダブルクリックだけで入る」は .pkg（ユーザー領域）が最も確実。dmg は .pkg を入れる箱としてなら使える
  （`hdiutil create -srcfolder`、dmg 自体も署名・公証する）が、必須ではない。
