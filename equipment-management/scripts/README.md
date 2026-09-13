# スクリプト

Windows の PowerShell から実行します。**追加モジュールのインストールは不要**です。
Windows PowerShell 5.1 と PowerShell 7 の両方で動きます。

| スクリプト | 用途 | 通信 | フェーズ |
|---|---|---|---|
| `Test-Solution.ps1` | 定義の整合性チェック | しない | 随時 |
| `Deploy-Schema.ps1` | テーブル・列・リレーション・代替キーの作成 | する | 1-1〜1-7 |
| `Deploy-Security.ps1` | セキュリティロール・列レベルセキュリティ | する | 1-8, 1-9 |
| `New-ShortNumber.ps1` | 短縮番号の採番と重複チェック | しない | 2-4 |
| `Import-MasterData.ps1` | CSV からのマスタ投入 | する | 2-1〜2-3 |
| `Dataverse.psm1` | 共通モジュール（各スクリプトが読み込む） | — | — |

## 共通の引数

| 引数 | 説明 |
|---|---|
| `-EnvironmentUrl` | 環境の URL（例: `https://contoso.crm7.dynamics.com`）。必須 |
| `-TenantId` | 既定は `organizations`。ゲスト招待されている場合はテナント ID を指定 |
| `-ClientId` / `-ClientSecret` | アプリ登録を使う場合。省略するとデバイスコード方式でサインイン |
| `-WhatIfOnly` | 何が行われるか表示するだけで、書き込まない |

## サインイン

既定はデバイスコード方式です。実行すると画面にコードが出るので、
開いたブラウザ（自動で開きます）に入力してサインインしてください。

無人実行したい場合はアプリ登録を作り、クライアントシークレットを使います。

```powershell
$secret = Read-Host -AsSecureString 'クライアントシークレット'
.\Deploy-Schema.ps1 -EnvironmentUrl 'https://contoso.crm7.dynamics.com' `
    -TenantId '<テナントID>' -ClientId '<アプリID>' -ClientSecret $secret
```

アプリ登録には Dataverse の `user_impersonation` 権限と、
環境内のアプリケーションユーザー登録（＋「設備-システム」ロール）が必要です。

## 何度実行しても安全です

- `Deploy-Schema.ps1` / `Deploy-Security.ps1` … 既にあるものは作らずスキップします
- `Import-MasterData.ps1` … 代替キーによる upsert なので重複しません

途中で失敗しても、原因を直して同じコマンドを流し直せば続きから進みます。

**例外**: `Deploy-Security.ps1` はロールの権限を `schema/security.json` の内容で**上書き**します。
メーカーポータルで手で足した権限は消えます。これは意図した動作です
（「誰かが手で足した権限」が残り続けるほうが危険なため）。

## 文字コード

| 対象 | 扱い |
|---|---|
| 送信・受信 | UTF-8 を明示（PowerShell 5.1 でも日本語が化けません） |
| CSV の読み書き | 既定 UTF-8（BOM 付き）。Shift_JIS の場合は `-Encoding Default` |
| コンソール出力 | 化ける場合は `chcp 65001` を実行してから PowerShell を起動 |

## 困ったとき

[docs/troubleshooting.md](../docs/troubleshooting.md) を参照してください。
