// ============================================================
// scrHome : ホーム画面（フェーズ3-2）
// ============================================================
// 場所別ギャラリーが主役です。
// 「自分のいる場所を選ぶ → 目の前の設備を押す」で使用開始まで到達できます。
// 番号入力（3-3）は、目の前にない設備を扱うときの近道として併置します。


// ▼ scrHome.OnVisible
// 他の画面で状態を変えて戻ってきたときに、ギャラリーを最新にする
Refresh('設備');


// ------------------------------------------------------------
// 場所の切り替え（横スクロールのギャラリー）
// ------------------------------------------------------------

// ▼ galLocations.Items
Sort(Filter('場所', 有効 = true), 並び順)

// ▼ galLocations.OnSelect
Set(varLocation, ThisItem)

// ▼ galLocations 内 btnLocation.Text
ThisItem.場所名

// ▼ galLocations 内 btnLocation.Fill
// 選択中の場所を塗りつぶしで示す
If(
    ThisItem.場所コード = varLocation.場所コード,
    RGBA(0, 99, 177, 1),
    RGBA(255, 255, 255, 1)
)

// ▼ galLocations 内 btnLocation.Color
If(
    ThisItem.場所コード = varLocation.場所コード,
    RGBA(255, 255, 255, 1),
    nfColorText
)


// ------------------------------------------------------------
// 選択中の場所にある設備の一覧
// ------------------------------------------------------------

// ▼ galEquipment.Items
// 参照列はレコードそのものと比較する（委任のため）
Sort(
    Filter(
        '設備',
        場所 = varLocation,
        ステータス <> 'ステータス (設備)'.廃棄
    ),
    短縮番号
)

// ▼ galEquipment 内 lblShortNumber.Text
// 現場は番号で設備を呼ぶので、いちばん大きく出す
ThisItem.短縮番号

// ▼ galEquipment 内 lblShortNumber.Size
nfFontLarge

// ▼ galEquipment 内 lblName.Text
ThisItem.設備名

// ▼ galEquipment 内 lblStatus.Text
ThisItem.ステータス

// ▼ galEquipment 内 lblStatus.Fill
// 色の値は App.Formulas に定義してある（変えたいときはそちらを直す）
Switch(
    ThisItem.ステータス,
    'ステータス (設備)'.空き,     nfColorAvailable,
    'ステータス (設備)'.使用中,   nfColorInUse,
    'ステータス (設備)'.貸出中,   nfColorLoaned,
    'ステータス (設備)'.メンテ中, nfColorMaint,
    'ステータス (設備)'.故障,     nfColorBroken,
    RGBA(150, 150, 150, 1)
)

// ▼ galEquipment 内 lblStatus.Color
RGBA(255, 255, 255, 1)

// ▼ galEquipment 内 lblUser.Text
// 使用中なら誰が使っているかを出す。これが分かるだけで「探す」手間が消える。
If(
    ThisItem.ステータス = 'ステータス (設備)'.使用中,
    "使用中: " & ThisItem.現在の使用者.氏名,
    ""
)

// ▼ galEquipment 内 btnSelect.OnSelect
Set(varEquipment, ThisItem);
Navigate(scrDetail, ScreenTransition.None)


// ------------------------------------------------------------
// 場所ごとの空き台数（見出しに出す）
// ------------------------------------------------------------

// ▼ lblSummary.Text
With(
    {
        全体: CountRows(Filter('設備', 場所 = varLocation, ステータス <> 'ステータス (設備)'.廃棄)),
        空き: CountRows(Filter('設備', 場所 = varLocation, ステータス = 'ステータス (設備)'.空き))
    },
    varLocation.場所名 & "  空き " & 空き & " / " & 全体 & " 台"
)


// ------------------------------------------------------------
// 画面下部の導線
// ------------------------------------------------------------

// ▼ btnKeypad.OnSelect
Set(varKeypadInput, "");
Navigate(scrKeypad, ScreenTransition.None)

// ▼ btnSearch.OnSelect
Navigate(scrSearch, ScreenTransition.None)

// ▼ btnMyHistory.OnSelect
Navigate(scrMyHistory, ScreenTransition.None)

// ▼ lblGreeting.Text
varMe.氏名 & " さん"
