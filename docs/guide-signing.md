# .pkg インストーラの署名・公証ガイド（メンテナー向け）

papat for Lightroom Classic の `.pkg`（ダブルクリックで入るインストーラ）を、メンテナー自身の Apple Developer ID で
**署名**し、Apple に**公証**してもらって配布用に仕上げる手順です。所要時間はおよそ30〜40分（初回のみ。2回目からは ③ だけ）。

> **秘密の値の扱い**
> 証明書の秘密鍵・Apple ID のパスワード・App 用パスワードは、**チャット・メール・ファイル・リポジトリに書かないでください**。
> このガイドの操作では、それらは macOS の「キーチェーン」の中だけに保存され、スクリプトには「証明書の名前」と
> 「プロファイル名」だけを渡します（どちらも秘密ではありません）。他の人や AI に値を伝える必要はありません。

準備するもの: Apple Developer Program への加入／この Mac に papat-lightroom のリポジトリ（以下 `<リポジトリ>` と書きます）／Xcode（またはコマンドラインツール）。

---

## ① Developer ID Installer 証明書を用意する

`.pkg` の署名には **Developer ID Installer** という種類の証明書が必要です（「Developer ID Application」や
「Mac Installer Distribution」とは別物です。間違えやすいので注意してください）。

### 方法A: Xcode で作る（かんたん）

1. Xcode を開き、メニュー **Xcode › Settings…**（設定）を開く
2. **Accounts**（アカウント）タブで、自分の Apple ID を選ぶ（なければ左下の「+」で追加）
3. 右側の **Team** の一覧から自分のチームを選び、**Manage Certificates…**（証明書を管理）を押す
4. 左下の **「+」** を押し、**Developer ID Installer** を選ぶ
5. 一覧に「Developer ID Installer」が追加されれば完了

### 方法B: developer.apple.com で作る

1. <https://developer.apple.com/account/resources/certificates/list> を開いてサインイン
2. **Certificates** の **「+」** → **Developer ID Installer** を選んで Continue
3. 画面の案内に従い、Mac の **キーチェーンアクセス › 証明書アシスタント › 認証局に証明書を要求…** で
   CSR（`.certSigningRequest`）を作り、アップロードする
4. 発行された `.cer` をダウンロードし、**ダブルクリック**してキーチェーンに入れる

### 確認する

1. **キーチェーンアクセス**を開き、左の「ログイン」→ 上の「**自分の証明書**」を選ぶ
2. **Developer ID Installer: Your Name (XXXXXXXXXX)** が表示されていて、左の ▶ を開くと「秘密鍵」がある
3. この名前（`Developer ID Installer: …` から `)` まで）を、後の ③ で使います。メモしておいてください
   - ターミナルで確かめるなら: `security find-identity -v | grep "Developer ID Installer"`（名前が表示されるだけです）

> 秘密鍵を書き出して（.p12）他の人に渡す必要はありません。**渡さないでください。**

---

## ①b Developer ID Application 証明書を用意する（papat-fprint を署名するとき。1.2.0〜）

1.2.0 からは、`papat.lrplugin/bin/papat-fprint`（似ている写真を調べる、同梱の小さな実行ファイル。Mac のみ、通信しない）も
署名します。**①の Developer ID Installer とは別の種類**（`.pkg` 全体の署名／1 本の実行ファイルの署名、という違い）。
**公証する（③ で `PAPAT_NOTARY_PROFILE` を付ける）なら、この証明書と `PAPAT_APP_IDENTITY` は必須**です。Apple の公証は、
署名の無い（または hardened runtime の無い）実行ファイルが .pkg の中にあると、それだけで拒否します。省略できるのは、
公証も配布もしない、手元の確認用ビルド（`scripts/build-pkg.sh` を何も指定せず実行）だけです。

1. ①の「方法A」「方法B」と同じ手順で、**Developer ID Installer** の代わりに **Developer ID Application** を選んで作る
2. キーチェーンアクセスで `Developer ID Application: Your Name (XXXXXXXXXX)` を確認する
   （`security find-identity -v | grep "Developer ID Application"`）
3. この名前を、③ の `PAPAT_APP_IDENTITY` に使う

---

## ② 公証用の資格情報をキーチェーンに保存する（初回だけ）

Apple の公証サービスにログインするための情報を、`notarytool` の「プロファイル」としてキーチェーンに保存します。
以降は、プロファイル名だけで使えます。

1. **App 用パスワードを作る**
   1. <https://account.apple.com>（旧 appleid.apple.com）を開いてサインイン
   2. **サインインとセキュリティ › App 用パスワード** を開く
   3. **「+」**（または「App 用パスワードを生成」）を押し、名前に `papat-notary` と入力して作成
   4. `xxxx-xxxx-xxxx-xxxx` の形のパスワードが表示される（**この画面でしか見られません**）。次の手順 3 で貼り付けるまで、
      画面を閉じないでください。どこにも書き留めないでください
2. **Team ID を調べる**
   1. <https://developer.apple.com/account> を開き、**Membership details**（メンバーシップの詳細）を開く
   2. **Team ID**（10文字の英数字）を控える（秘密ではありません）
3. **ターミナル**で次を実行する（`<…>` を置き換えます）

   ```sh
   xcrun notarytool store-credentials "papat-notary" \
     --apple-id "<Apple ID のメールアドレス>" \
     --team-id "<Team ID>"
   ```

4. 「Password for …」と聞かれたら、手順 1 の **App 用パスワードを貼り付けて** Return（入力した文字は画面に表示されません）
5. `Credentials saved to Keychain.` と表示されれば完了。プロファイル名は **`papat-notary`** です
   - パスワードをコマンドの行に直接書く（`--password`）のはやめてください。履歴に残ります

---

## ③ インストーラを作る（署名 → 公証 → 検証）

1. **ターミナル**を開き、リポジトリに移動する

   ```sh
   cd <リポジトリ>
   ```

2. （任意）テストを通す: `scripts/check.sh`
3. 次を実行する。`PAPAT_INSTALLER_IDENTITY` には ① でメモした証明書の名前を、そのまま入れます。
   `PAPAT_APP_IDENTITY`（①b の証明書）は、**公証する（`PAPAT_NOTARY_PROFILE` を付ける）ならここでは必須**です
   （Apple の公証は、未署名の実行ファイルが .pkg の中にあると受け付けません）。省略できるのは、公証しない・配布しない
   確認用のビルドだけです

   ```sh
   PAPAT_INSTALLER_IDENTITY="Developer ID Installer: Your Name (XXXXXXXXXX)" \
   PAPAT_APP_IDENTITY="Developer ID Application: Your Name (XXXXXXXXXX)" \
   PAPAT_NOTARY_PROFILE="papat-notary" \
   scripts/build-pkg.sh
   ```

4. 次の順に進みます（公証の「待ち」に数分かかります）

   | 表示 | 意味 |
   |---|---|
   | `== signing the similarity helper` | papat-fprint の署名中（③ の手順どおりなら必ず出る） |
   | `error: PAPAT_NOTARY_PROFILE is set but PAPAT_APP_IDENTITY is not …` | `PAPAT_APP_IDENTITY` を付け忘れている。③ の手順どおりに付けてやり直す |
   | `== signing` | .pkg 自体の署名中。キーチェーンのアクセス許可を聞かれたら「常に許可」を選ぶ |
   | `== notarizing` | Apple に送信して結果待ち（通常 2〜10分） |
   | `submission: … status: Accepted` | 公証 OK |
   | `== stapling` | 公証のチケットを .pkg に添付 |
   | `== verification` … `accepted` / `source=Notarized Developer ID` | 検証 OK |
   | `built: dist/papat-lightroom-<バージョン>.pkg` | 完成 |

5. できあがり: `dist/papat-lightroom-<バージョン>.pkg` と `dist/papat-lightroom-<バージョン>.pkg.sha256`

### うまくいかないとき

| 症状 | 対処 |
|---|---|
| `the specified item could not be found in the keychain` など署名で失敗 | 証明書の名前が違うか、種類が違う。① の確認をやり直し、名前を**そのまま**コピー |
| 署名中に `errSecInternalComponent` | キーチェーンがロックされている。Mac の画面上のターミナルから実行し、ログインパスワードでキーチェーンを解除 |
| `status: Invalid` で止まる | `dist/notary-logs/<バージョン>-<日時>/notary-log.json` に Apple のログが保存されている。原因（`issues`）を読んで直す（秘密の値は入っていません） |
| `HTTP status code: 401` など認証エラー | App 用パスワードの失効や Apple ID の変更。② をやり直す（同じプロファイル名で上書きできます） |
| Apple の利用規約の更新を求められる | <https://developer.apple.com/account> にサインインして新しい規約に同意してから、再実行 |
| `PAPAT_NOTARY_PROFILE` を付けずに実行した | 「署名のみ」の .pkg が `dist/not-notarized/` にできる。**配布はしないでください**（Gatekeeper の警告が出ます） |

---

## ④ できた .pkg をダブルクリックして確かめる

実際の「自分の Mac」で、次を番号どおりに確認してください。

1. Finder で `dist/papat-lightroom-<バージョン>.pkg` を**ダブルクリック**する
   - 「開発元を確認できません」などの警告が**出ない**こと（出る場合は署名か公証が不完全です）
2. インストーラのタイトルが **papat for Lightroom Classic** で、最初の画面に「インストール先（管理者パスワードは不要です）」と出る
3. **続ける** を押す。次の確認も行います
   - 「インストール先の選択」「ディスクの選択」が**出ない**こと
   - **管理者パスワードを求められない**こと（求められたら、いったん中止して `docs/installer-notes.md` の §2 を参照）
4. **インストール** を押す → 「インストールが完了しました」と、再起動・プラグインマネージャー・API キーの案内が出る
5. Finder で、メニュー **移動 › フォルダへ移動…** に次を貼り付けて開く
   `~/Library/Application Support/Adobe/Lightroom/Modules`
   → **papat.lrplugin** があること
6. **Lightroom Classic を再起動**し、**ファイル › プラグインマネージャー** で **papat** が
   「インストール済みで実行中」になっていること。「インストール場所」の欄が「標準の場所から読み込まれています」になっていること
7. もう一度 .pkg を実行（上書き）→ `~/Library/Application Support/Adobe/Lightroom/papat-lightroom-backups/` に
   `papat.lrplugin.<日時>` が退避されていること

うまくいったら、`dist/papat-lightroom-<バージョン>.pkg` と `.pkg.sha256` を配布ページに掲載します。

---

## 補足

- 2回目以降（バージョンを上げたとき）は ③ → ④ だけです。バージョンは `papat.lrplugin/Info.lua` の `VERSION` で決まります。
- 署名・公証をせずに作った .pkg（`dist/unsigned/…-unsigned.pkg`）は、中身の確認用です。配布しないでください。
- 証明書は有効期限があります（Developer ID Installer は通常5年）。期限が近づいたら ① で更新します。
  署名済みの古い .pkg は、期限後も（公証済みなら）引き続き開けます。
