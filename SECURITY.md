# セキュリティについて / Security

## 脆弱性の報告

papat for Lightroom Classic に、セキュリティ上の問題（API キーやパスコードの漏えい、意図しないファイルの書き込み・送信、
インストーラの不備など）を見つけた場合は、**公開の Issue・SNS・掲示板には書かず**、次のメールアドレスへご連絡ください。

**hello@papat.app**（件名の先頭に `[security]` と付けてください）

次の内容を、わかる範囲で書いてください。

- 問題の内容と、どう困るか
- 再現の手順（Lightroom Classic と macOS のバージョン、プラグインのバージョン）
- ログ（`~/Documents/LrClassicLogs/papat-lightroom.log`。API キーとパスコードは記録されませんが、念のため内容を確認してください）

**API キー・パスコード・お客様の写真は、メールに添付しないでください。**
すでに漏えいした可能性がある API キーは、papat のダッシュボード（https://papat.app/app）で発行し直すと、古いキーは無効になります。

使い方の質問、アカウント、請求についてもメールで受け付けています。不具合と機能要望は GitHub Issues をお使いください。運営は1人のため、対応は届いた順になります。脆弱性の内容は公開 Issue に書かないでください。

## 対象

- このリポジトリのプラグインとインストーラ（最新の公開バージョン）
- Lightroom Classic や macOS そのものの問題は、Adobe・Apple へお知らせください

## このプラグインの安全面の考え方

- API キーは Lightroom のパスワード保管領域（macOS の Keychain）に保存し、画面・ログには出しません
- 通信は HTTPS のみです。RAW 原本は送りません。送る JPEG の Lightroom 由来のメタデータ（位置情報・シリアル番号・現像設定など）は、送る前に取り除きます（取り除けない場合は、その写真を送りません）。Lightroom に登録した著作権・作成者・連絡先だけを入れ直します（初回に内容を確認し、設定でオフにできます）
- プラグイン自身が、自分のファイルを自動で入れ替えることはありません（更新は署名・公証済みのインストーラで行います）

---

## Reporting a vulnerability

If you find a security problem in papat for Lightroom Classic, **please do not open a public issue**. Email
**hello@papat.app** with the subject starting with `[security]`, including the plug-in version, your Lightroom Classic and
macOS versions, and steps to reproduce. Do not include API keys, passcodes, gallery URLs, client names, or photos. For bugs
and feature requests, use GitHub Issues. For usage questions, account matters, and billing, email hello@papat.app. This
project is operated by one person, so reports are handled in order; no response time is promised.
