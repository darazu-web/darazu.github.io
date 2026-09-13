# 設備管理システム（Power Platform）

設備の使用開始・終了、貸出、メンテナンスを管理する Power Platform ソリューション一式です。
Windows の PowerShell から実行できるスクリプトで、Dataverse のテーブル・権限・初期データを構築します。

## これは何か

| 作るもの | 使う人 | 実体 |
|---|---|---|
| 使用者アプリ | 現場 | キャンバスアプリ（番号を入れて使用開始・終了） |
| 管理者アプリ | 保全部など | モデル駆動アプリ（マスタ保守・状態の修正） |
| 自動化 | — | Power Automate フロー5本（通知・整合性チェック） |
| 印刷物 | 現場 | 設備ラベル（QR付き）と A4 1枚の操作説明 |

## 最短ルート

```
フェーズ1（データ層）→ 2-3/2-4（設備マスタと採番）→ 3-1〜3-6（使用者アプリ）→ 6（パイロット）
```

ここに集中すれば、他のタスクは並行または後置できます。

止まりやすいのは2箇所です。**設備マスタの初期データ整備**（台帳が最新でないことが多く、現物確認が発生する）と、
**ラベル貼付**（人手と時間が読みにくい）。この2つは早めに着手して、実所要時間を掴んでください。

## 進め方

| フェーズ | 内容 | 手順書 |
|---|---|---|
| 0 | 準備（環境・グループ・ソリューション・サービスアカウント） | [docs/phase0-preparation.md](docs/phase0-preparation.md) |
| 1 | データ層（テーブル・代替キー・権限・ビジネスルール） | [docs/phase1-data.md](docs/phase1-data.md) |
| 2 | 初期データ投入（マスタ・短縮番号の採番） | [docs/phase2-initial-data.md](docs/phase2-initial-data.md) |
| 3 | 使用者アプリ | [docs/phase3-user-app.md](docs/phase3-user-app.md) |
| 4 | 管理者アプリ | [docs/phase4-admin-app.md](docs/phase4-admin-app.md) |
| 5 | 自動化（フロー5本） | [docs/phase5-automation.md](docs/phase5-automation.md) |
| 6 | パイロット（1エリア・20台・4週間） | [docs/phase6-pilot.md](docs/phase6-pilot.md) |
| 7 | 本展開 | [docs/phase7-rollout.md](docs/phase7-rollout.md) |
| 運用 | 管理者向け運用手順書 | [docs/operations-manual.md](docs/operations-manual.md) |
| 困ったとき | トラブルシュート | [docs/troubleshooting.md](docs/troubleshooting.md) |

## 必要なもの

| 項目 | 内容 |
|---|---|
| OS | Windows（PowerShell 5.1 または PowerShell 7）。追加モジュールのインストールは不要 |
| 環境 | Power Platform の環境2つ（開発・本番）。Dataverse あり、基本言語は日本語 |
| 権限 | 開発環境のシステム管理者ロール |
| ライセンス | Power Apps（使用者数分）、Power Automate（サービスアカウント分） |

サインインはデバイスコード方式です。画面に出たコードをブラウザに入力するだけで、
認証用のモジュールを入れる必要はありません。

## はじめかた

```powershell
cd equipment-management\scripts

# 0. 定義に矛盾がないか確認する（通信しない・数秒）
.\Test-Solution.ps1

# 1. 何が作られるか確認する（書き込まない）
.\Deploy-Schema.ps1 -EnvironmentUrl 'https://<組織名>.crm7.dynamics.com' -WhatIfOnly

# 2. テーブル・代替キーを作る（15〜30分）
.\Deploy-Schema.ps1 -EnvironmentUrl 'https://<組織名>.crm7.dynamics.com'

# 3. セキュリティロールと列レベルセキュリティ
.\Deploy-Security.ps1 -EnvironmentUrl 'https://<組織名>.crm7.dynamics.com' `
    -UserGroupObjectId '<設備-使用者のオブジェクトID>' `
    -AdminGroupObjectId '<設備-管理者のオブジェクトID>'

# 4. 短縮番号を採番する（通信しない）
.\New-ShortNumber.ps1

# 5. 初期データを投入する
.\Import-MasterData.ps1 -EnvironmentUrl 'https://<組織名>.crm7.dynamics.com' -All
```

スクリプトは**何度実行しても安全**です。既にあるものは作らずスキップし、
データは代替キーによる upsert なので重複しません。途中で失敗したら、直して同じコマンドを流し直してください。

その前に [docs/phase0-preparation.md](docs/phase0-preparation.md) を読んでください。
**接頭辞（`eqm`）は後から変更できません。**

## 中身

```
equipment-management/
  schema/                     定義ファイル（ここが唯一の正）
    dataverse-schema.json       テーブル8・列60・リレーション17・代替キー8
    security.json               セキュリティロール3種・列レベルセキュリティ
  scripts/                    Windows で実行する PowerShell
    Dataverse.psm1              共通モジュール（認証・Web API 呼び出し）
    Deploy-Schema.ps1           フェーズ1-1〜1-7
    Deploy-Security.ps1         フェーズ1-8, 1-9
    Import-MasterData.ps1       フェーズ2-1〜2-3
    New-ShortNumber.ps1         フェーズ2-4（通信しない）
    Test-Solution.ps1           整合性チェック（通信しない）
  powerfx/                    キャンバスアプリの数式（フェーズ3）
  flows/                      Power Automate フローの仕様（フェーズ5）
  data/                       初期データの CSV 雛形
  docs/                       フェーズ別の手順書
  print/                      設備ラベルと操作説明（ブラウザで開く）
```

## データモデル

```
設備種別 ─┐
場所 ─────┼─→ 設備 ←─── 稼働ログ ───→ 使用者
部署 ─────┘     ↑                        ↑
                └──── 貸出 ──→ 貸出先 ───┘
```

**設備テーブルが「現在の状態」を持つ唯一の場所**です。稼働ログを毎回集計すると
一覧表示が委任されず2000件で頭打ちになるため、意図的に非正規化しています。

その代わり、設備の状態とログの実体がずれる可能性が生まれます。
これを毎朝直すのが**フェーズ5-3 の整合性チェック**です。セットで考えてください。

## スキーマを変えるとき

列の表示名を1つ変えると、**数式・CSV の見出し・セキュリティ定義の3か所がずれます。**

```powershell
.\Test-Solution.ps1
```

このスクリプトが次を検査します。通信しないので数秒で終わります。

1. スキーマ定義そのものの整合性（重複・参照先の欠落・代替キーの指定ミス）
2. Power Fx が参照している選択肢・列・テーブルが実在するか
3. CSV の見出しがスキーマの表示名と一致しているか
4. セキュリティ定義が実在するテーブル・列を指しているか
5. 表示名が Power Fx でそのまま書けるか（空白・記号・数字始まりがないか）

**スキーマを触ったら必ず流してください。**

## 落とし穴（先に読んでおくと得をするもの）

| 内容 | 場所 |
|---|---|
| 接頭辞は後から変更できない | [phase0](docs/phase0-preparation.md) |
| 既定のソリューションに作ると本番移送できない | [phase0](docs/phase0-preparation.md) |
| フローを個人アカウントで作ると、その人の異動で全部止まる | [phase0](docs/phase0-preparation.md) |
| セキュリティロールを後回しにすると追えなくなる | [phase1](docs/phase1-data.md) |
| Excel で短縮番号の先頭のゼロが消える | [phase2](docs/phase2-initial-data.md) |
| 委任の警告を放置すると2000件で設備が消える | [powerfx/README.md](powerfx/README.md) |
| **フローの失敗通知（5-4）を省略すると、止まったことに誰も気づかない** | [flows/04](flows/04-flow-failure-notice.md) |
| 操作説明を動画やマニュアルにすると読まれない | [phase6](docs/phase6-pilot.md) |
| 稼働可能時間の定義を実データより先に決めると数字が独り歩きする | [phase7](docs/phase7-rollout.md) |
