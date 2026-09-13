# 5-1 返却期限・延滞通知（日次）

`設備-返却期限・延滞通知`

返却予定日が**明日**のものは事前連絡、**過ぎている**ものは延滞として扱います。
延滞は毎日送ると読まれなくなるので、「延滞通知済み」フラグで初回だけ個人宛にし、
以降は管理者向けの一覧にだけ載せます。

## トリガー

**繰り返し** / 間隔 1 / 頻度 日 / タイムゾーン (UTC+09:00) 大阪、札幌、東京 / 時刻 8:00

## 変数

「変数を初期化する」で日本時間の日付を作っておきます。

| 名前 | 種類 | 値 |
|---|---|---|
| `今日` | 文字列 | `convertTimeZone(utcNow(),'UTC','Tokyo Standard Time','yyyy-MM-dd')` |
| `明日` | 文字列 | `convertTimeZone(addDays(utcNow(),1),'UTC','Tokyo Standard Time','yyyy-MM-dd')` |

## 手順1：返却予定日が明日の貸出（事前連絡）

**Dataverse > 行を一覧する**

| 項目 | 値 |
|---|---|
| テーブル名 | 貸出 (`eqm_loans`) |
| 選択列 | `eqm_name,eqm_duedate,eqm_state` |
| フィルター行 | `statecode eq 0 and eqm_state eq 1 and eqm_duedate eq @{variables('明日')}` |
| 展開クエリ | `eqm_EquipmentId($select=eqm_shortnumber,eqm_name),eqm_CarrierUserId($select=eqm_name,eqm_upn)` |

**Apply to each** → **メールを送信する (V2)**

| 項目 | 値 |
|---|---|
| 宛先 | `items('明日返却分')?['eqm_CarrierUserId']?['eqm_upn']` |
| 件名 | `【明日が返却期限です】@{items('明日返却分')?['eqm_EquipmentId']?['eqm_shortnumber']} @{items('明日返却分')?['eqm_EquipmentId']?['eqm_name']}` |
| 本文 | 下記 |

```
@{items('明日返却分')?['eqm_CarrierUserId']?['eqm_name']} さん

お借りいただいている設備の返却期限が明日（@{variables('明日')}）です。

  設備番号 : @{items('明日返却分')?['eqm_EquipmentId']?['eqm_shortnumber']}
  設備名   : @{items('明日返却分')?['eqm_EquipmentId']?['eqm_name']}
  返却期限 : @{items('明日返却分')?['eqm_duedate']}

返却したら、設備管理アプリで番号を入力して「返却を登録する」を押してください。
```

## 手順2：返却予定日を過ぎた貸出（延滞）

**Dataverse > 行を一覧する**

| 項目 | 値 |
|---|---|
| テーブル名 | 貸出 (`eqm_loans`) |
| フィルター行 | `statecode eq 0 and eqm_state ne 2 and eqm_duedate lt @{variables('今日')}` |
| 展開クエリ | `eqm_EquipmentId($select=eqm_shortnumber,eqm_name),eqm_CarrierUserId($select=eqm_name,eqm_upn)` |

**Apply to each**（`延滞分`）の中で：

### 2-1. 状態を「延滞」に更新

**Dataverse > 行を更新する** / テーブル 貸出 / 行 ID `items('延滞分')?['eqm_loanid']`

| 列 | 値 |
|---|---|
| 状態 | `3`（延滞） |

### 2-2. 初回だけ本人に通知

**条件**: `items('延滞分')?['eqm_overduenotified']` **が次の値に等しい** `false`

はいの場合 → **メールを送信する (V2)**

| 項目 | 値 |
|---|---|
| 宛先 | `items('延滞分')?['eqm_CarrierUserId']?['eqm_upn']` |
| 件名 | `【返却期限を過ぎています】@{items('延滞分')?['eqm_EquipmentId']?['eqm_shortnumber']}` |
| 重要度 | 高 |

本文に経過日数を入れます。

```
返却期限を @{div(sub(ticks(variables('今日')),ticks(items('延滞分')?['eqm_duedate'])),864000000000)} 日 過ぎています。
```

続けて **行を更新する**（同じ貸出行）で `延滞通知済み = true` にします。

## 手順3：管理者へ一覧で報告

Apply to each の外で、手順2の結果をまとめて1通送ります。

**データ操作 > 選択** で `body('延滞分を一覧')?['value']` から必要な列だけ取り出し、
**データ操作 > 作成** で HTML 表にしてから送ると読みやすくなります。

| 項目 | 値 |
|---|---|
| 宛先 | 管理者グループのメールアドレス |
| 件名 | `【設備】延滞 @{length(body('延滞分を一覧')?['value'])} 件 / @{variables('今日')}` |
| 送信条件 | `length(body('延滞分を一覧')?['value'])` が 0 **より大きい** とき |

**0件のときは送らない**でください。毎朝「0件です」というメールが届くと、本当に届いた日も読まれなくなります。

## 最後に

このフロー全体を **5-4 のスコープ構成**で包んでください。
