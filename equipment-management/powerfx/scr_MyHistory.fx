// ============================================================
// scrMyHistory : マイ履歴（フェーズ3-10）
// ============================================================
// 優先度は「低」です。ただし作っておくと「終了し忘れ」を本人が見つけられます。
// 画面の先頭に「まだ終了していない使用」を出すのが要点です。


// ▼ scrMyHistory.OnVisible
Refresh('稼働ログ')


// ------------------------------------------------------------
// まだ終了していない使用（最優先で見せる）
// ------------------------------------------------------------

// ▼ galOpen.Items
Sort(
    Filter(
        '稼働ログ',
        使用者 = varMe,
        状態 = '状態 (稼働ログ)'.稼働中
    ),
    開始日時,
    SortOrder.Descending
)

// ▼ lblOpenHeader.Text
With(
    { 件数: CountRows(galOpen.AllItems) },
    If(
        件数 = 0,
        "終了し忘れはありません",
        "終了していない使用が " & 件数 & " 件あります"
    )
)

// ▼ lblOpenHeader.Color
If(CountRows(galOpen.AllItems) = 0, nfColorAvailable, nfColorBroken)

// ▼ galOpen 内 lblItem.Text
ThisItem.設備.短縮番号 & "  " & ThisItem.設備.設備名 & Char(10) &
Text(ThisItem.開始日時, "mm/dd hh:mm") & " から " &
RoundDown(DateDiff(ThisItem.開始日時, Now(), TimeUnit.Minutes) / 60, 0) & " 時間経過"

// ▼ galOpen 内 btnGoEnd.Text
"終了する"

// ▼ galOpen 内 btnGoEnd.OnSelect
Set(varEquipment, ThisItem.設備);
Navigate(scrDetail, ScreenTransition.None)


// ------------------------------------------------------------
// 過去の履歴
// ------------------------------------------------------------

// ▼ galHistory.Items
// 直近30日分に絞る。全期間にすると件数が増えて表示が重くなる。
Sort(
    Filter(
        '稼働ログ',
        使用者 = varMe,
        開始日時 >= DateAdd(Today(), -30, TimeUnit.Days)
    ),
    開始日時,
    SortOrder.Descending
)

// ▼ galHistory 内 lblLine1.Text
ThisItem.設備.短縮番号 & "  " & ThisItem.設備.設備名

// ▼ galHistory 内 lblLine2.Text
Text(ThisItem.開始日時, "mm/dd hh:mm") & " 〜 " &
Coalesce(Text(ThisItem.終了日時, "hh:mm"), "（未終了）") &
If(ThisItem.稼働時間 > 0, "　" & ThisItem.稼働時間 & " 分", "")

// ▼ galHistory 内 lblState.Text
ThisItem.状態

// ▼ lblTotal.Text
"直近30日の合計: " &
RoundDown(Sum(Filter(galHistory.AllItems, 状態 = '状態 (稼働ログ)'.完了), 稼働時間) / 60, 1) &
" 時間"

// ▼ btnBack.OnSelect
Back()
