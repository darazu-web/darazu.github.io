// ============================================================
// scrReturn : 返却（フェーズ3-8）
// ============================================================


// ▼ scrReturn.OnVisible
// 対象の貸出レコードを1件に確定させる。参照列はレコードと比較する（委任のため）
Set(
    varLoan,
    First(
        Sort(
            Filter(
                '貸出',
                設備 = varEquipment,
                状態 <> '状態 (貸出)'.返却済
            ),
            貸出日,
            SortOrder.Descending
        )
    )
);
Reset(txtConditionIn)


// ------------------------------------------------------------
// 表示
// ------------------------------------------------------------

// ▼ lblEquipment.Text
varEquipment.短縮番号 & "  " & varEquipment.設備名

// ▼ lblLoanInfo.Text
If(
    IsBlank(varLoan),
    "この設備の貸出記録が見つかりません。管理者に連絡してください。",
    "貸出先: " & Coalesce(varLoan.貸出先.貸出先名, varLoan.貸出先部署.部署名, "（未設定）") & Char(10) &
    "持出者: " & varLoan.持出者.氏名 & Char(10) &
    "貸出日: " & Text(varLoan.貸出日, "yyyy/mm/dd") & Char(10) &
    "返却予定日: " & Text(varLoan.返却予定日, "yyyy/mm/dd") &
    If(
        varLoan.返却予定日 < Today(),
        "（" & DateDiff(varLoan.返却予定日, Today(), TimeUnit.Days) & " 日 延滞）",
        ""
    )
)

// ▼ lblLoanInfo.Color
If(varLoan.返却予定日 < Today(), nfColorBroken, nfColorText)

// ▼ txtConditionIn.HintText
"返却時の状態（破損・不足の有無など）"


// ------------------------------------------------------------
// 返却
// ------------------------------------------------------------

// ▼ btnReturn.Text
"返却を登録する"

// ▼ btnReturn.DisplayMode
If(locBusy Or IsBlank(varLoan), DisplayMode.Disabled, DisplayMode.Edit)

// ▼ btnReturn.OnSelect
UpdateContext({ locBusy: true });

Patch(
    '貸出',
    varLoan,
    {
        返却日: Today(),
        状態: '状態 (貸出)'.返却済,
        返却時メモ: txtConditionIn.Text
    }
);

Set(
    varEquipment,
    Patch(
        '設備',
        LookUp('設備', 短縮番号 = varEquipment.短縮番号),
        { ステータス: 'ステータス (設備)'.空き }
    )
);

If(
    IsEmpty(Errors('貸出', varLoan)) And IsEmpty(Errors('設備', varEquipment)),
    Notify("返却を登録しました。", NotificationType.Success);
    Back(),
    Notify("保存できませんでした。もう一度お試しください。", NotificationType.Error)
);

UpdateContext({ locBusy: false })

// ▼ btnCancel.OnSelect
Back()
