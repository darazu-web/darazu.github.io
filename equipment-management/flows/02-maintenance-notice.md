# 5-2 メンテ期限通知（日次）

`設備-メンテ期限通知`

次回メンテ予定日が近い設備を管理者にまとめて知らせます。
個人宛にはしません。メンテは管理者の仕事だからです。

## トリガー

**繰り返し** / 1日 / (UTC+09:00) 大阪、札幌、東京 / 8:05

## 変数

| 名前 | 種類 | 値 |
|---|---|---|
| `今日` | 文字列 | `convertTimeZone(utcNow(),'UTC','Tokyo Standard Time','yyyy-MM-dd')` |
| `7日後` | 文字列 | `convertTimeZone(addDays(utcNow(),7),'UTC','Tokyo Standard Time','yyyy-MM-dd')` |

## 手順1：対象の設備を拾う

**Dataverse > 行を一覧する**

| 項目 | 値 |
|---|---|
| テーブル名 | 設備 (`eqm_equipments`) |
| 選択列 | `eqm_shortnumber,eqm_name,eqm_nextmaintenancedate,eqm_lastmaintenancedate,eqm_status` |
| フィルター行 | `statecode eq 0 and eqm_status ne 6 and eqm_nextmaintenancedate ne null and eqm_nextmaintenancedate le @{variables('7日後')}` |
| 展開クエリ | `eqm_LocationId($select=eqm_name),eqm_EquipmentTypeId($select=eqm_name)` |
| 並べ替え | `eqm_nextmaintenancedate asc` |

`eqm_status ne 6` で廃棄済みを除いています。ここを忘れると、廃棄した設備が毎日出続けます。

## 手順2：期限切れと期限間近に分ける

**データ操作 > 選択** で表示用の配列を作ります。

```
{
  "番号": @{item()?['eqm_shortnumber']},
  "設備名": @{item()?['eqm_name']},
  "場所": @{item()?['eqm_LocationId']?['eqm_name']},
  "予定日": @{item()?['eqm_nextmaintenancedate']},
  "状態": @{if(less(item()?['eqm_nextmaintenancedate'], variables('今日')), '期限切れ', '期限間近')}
}
```

**データ操作 > HTML テーブルの作成** に上の出力を渡します。

## 手順3：管理者へ送る

**条件**: `length(body('対象設備を一覧')?['value'])` が 0 **より大きい**

| 項目 | 値 |
|---|---|
| 宛先 | 管理者グループ |
| 件名 | `【設備】メンテ期限 @{length(body('対象設備を一覧')?['value'])} 件（7日以内）` |
| 本文 | HTML テーブルの出力 |

## 補足：次回メンテ予定日が入っていない設備

初期投入直後は `次回メンテ予定日` が空のままの設備があります。空のものはこのフローに拾われません。
月に1回、未設定の設備を洗い出すビューを管理者アプリに作っておくと取りこぼしません（フェーズ4-5）。

フィルター: `eqm_nextmaintenancedate eq null and eqm_status ne 6`

## 最後に

このフロー全体を **5-4 のスコープ構成**で包んでください。
