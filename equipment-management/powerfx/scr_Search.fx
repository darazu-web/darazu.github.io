// ============================================================
// scrSearch : 設備検索（フェーズ3-6）
// ============================================================
// 「どこにあるか分からない設備を探す」ための画面です。
// 部分一致（Search 関数）は委任されないため、前方一致（StartsWith）で作っています。
// 現場は番号・設備名の頭から入力するので、実用上これで足ります。


// ▼ scrSearch.OnVisible
Set(varFilterLocation, Blank());
Set(varFilterType, Blank());
Set(varFilterAvailableOnly, false);
Reset(txtSearch)


// ------------------------------------------------------------
// 検索条件
// ------------------------------------------------------------

// ▼ txtSearch.HintText
"番号・設備名・設備コードの先頭を入力"

// ▼ cmbLocation.Items
Sort(Filter('場所', 有効 = true), 並び順)

// ▼ cmbLocation.OnChange
Set(varFilterLocation, cmbLocation.Selected)

// ▼ cmbType.Items
Sort(Filter('設備種別', 有効 = true), 並び順)

// ▼ cmbType.OnChange
Set(varFilterType, cmbType.Selected)

// ▼ tglAvailableOnly.OnChange
Set(varFilterAvailableOnly, tglAvailableOnly.Value)

// ▼ btnClearFilter.OnSelect
Set(varFilterLocation, Blank());
Set(varFilterType, Blank());
Set(varFilterAvailableOnly, false);
Reset(cmbLocation);
Reset(cmbType);
Reset(tglAvailableOnly);
Reset(txtSearch)


// ------------------------------------------------------------
// 結果
// ------------------------------------------------------------

// ▼ galResult.Items
// 条件が未指定のときは true になる式を並べて、全体を1つの Filter に収める。
// Filter を入れ子にすると内側だけ委任されて件数がずれるので、この形を崩さないこと。
Sort(
    Filter(
        '設備',
        ステータス <> 'ステータス (設備)'.廃棄,

        IsBlank(txtSearch.Text)
            Or StartsWith(短縮番号, txtSearch.Text)
            Or StartsWith(設備名, txtSearch.Text)
            Or StartsWith(設備コード, txtSearch.Text),

        IsBlank(varFilterLocation) Or 場所 = varFilterLocation,
        IsBlank(varFilterType)     Or 種別 = varFilterType,
        Not varFilterAvailableOnly Or ステータス = 'ステータス (設備)'.空き
    ),
    短縮番号
)

// ▼ lblResultCount.Text
CountRows(galResult.AllItems) & " 件"

// ▼ galResult 内 lblShortNumber.Text
ThisItem.短縮番号

// ▼ galResult 内 lblName.Text
ThisItem.設備名

// ▼ galResult 内 lblWhere.Text
ThisItem.場所.場所名 & " / " & ThisItem.種別.種別名

// ▼ galResult 内 lblStatus.Text
ThisItem.ステータス

// ▼ galResult 内 lblStatus.Fill
Switch(
    ThisItem.ステータス,
    'ステータス (設備)'.空き,     nfColorAvailable,
    'ステータス (設備)'.使用中,   nfColorInUse,
    'ステータス (設備)'.貸出中,   nfColorLoaned,
    'ステータス (設備)'.メンテ中, nfColorMaint,
    'ステータス (設備)'.故障,     nfColorBroken,
    RGBA(150, 150, 150, 1)
)

// ▼ galResult 内 btnSelect.OnSelect
Set(varEquipment, ThisItem);
Navigate(scrDetail, ScreenTransition.None)

// ▼ lblEmpty.Visible
CountRows(galResult.AllItems) = 0

// ▼ lblEmpty.Text
"条件に合う設備がありません。番号の先頭から入力しているか確認してください。"

// ▼ btnBack.OnSelect
Back()
