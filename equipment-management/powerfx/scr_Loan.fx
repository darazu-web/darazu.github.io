// ============================================================
// scrLoan : 貸出登録（フェーズ3-7）
// ============================================================
// 優先度は「中」です。使用開始・終了が定着してから作って構いません。
// 貸出区分によって必須項目が変わります（フェーズ1-10 のビジネスルールと同じ条件を
// アプリ側でも出し分けています。Dataverse 側のルールが最後の砦です）。


// ▼ scrLoan.OnVisible
Set(varLoanType, '貸出区分 (貸出)'.社内);
Set(varBorrower, Blank());
Set(varLoanDepartment, Blank());
Set(varDueDate, DateAdd(Today(), 7, TimeUnit.Days));
Reset(txtConditionOut)


// ------------------------------------------------------------
// 入力
// ------------------------------------------------------------

// ▼ lblEquipment.Text
varEquipment.短縮番号 & "  " & varEquipment.設備名

// ▼ cmbLoanType.Items
Choices('貸出'.貸出区分)

// ▼ cmbLoanType.DefaultSelectedItems
[ '貸出区分 (貸出)'.社内 ]

// ▼ cmbLoanType.OnChange
Set(varLoanType, cmbLoanType.Selected);
Set(varBorrower, Blank());
Set(varLoanDepartment, Blank())

// ▼ cmbBorrower.Visible        ... 社外のときだけ
varLoanType = '貸出区分 (貸出)'.社外

// ▼ cmbBorrower.Items
Sort(Filter('貸出先', 有効 = true), 貸出先名)

// ▼ cmbBorrower.OnChange
Set(varBorrower, cmbBorrower.Selected)

// ▼ cmbDepartment.Visible      ... 社内のときだけ
varLoanType = '貸出区分 (貸出)'.社内

// ▼ cmbDepartment.Items
Sort(Filter('部署', 有効 = true), 並び順)

// ▼ cmbDepartment.OnChange
Set(varLoanDepartment, cmbDepartment.Selected)

// ▼ dtpDueDate.DefaultDate
DateAdd(Today(), 7, TimeUnit.Days)

// ▼ dtpDueDate.OnChange
Set(varDueDate, dtpDueDate.SelectedDate)

// ▼ txtConditionOut.HintText
"貸出時の状態（傷・付属品の有無など）"


// ------------------------------------------------------------
// 入力チェック
// ------------------------------------------------------------

// ▼ lblValidation.Text
With(
    {
        不足: Concat(
            Filter(
                Table(
                    { 条件: varLoanType = '貸出区分 (貸出)'.社外 And IsBlank(varBorrower), 文言: "貸出先" },
                    { 条件: varLoanType = '貸出区分 (貸出)'.社内 And IsBlank(varLoanDepartment), 文言: "貸出先部署" },
                    { 条件: IsBlank(varDueDate), 文言: "返却予定日" },
                    { 条件: varDueDate < Today(), 文言: "返却予定日（今日より後の日付）" }
                ),
                条件
            ),
            文言,
            "、"
        )
    },
    If(IsBlank(不足), "", "入力してください: " & 不足)
)

// ▼ lblValidation.Visible
Not IsBlank(lblValidation.Text)

// ▼ btnSubmit.DisplayMode
If(
    locBusy Or Not IsBlank(lblValidation.Text),
    DisplayMode.Disabled,
    DisplayMode.Edit
)


// ------------------------------------------------------------
// 登録
// ------------------------------------------------------------

// ▼ btnSubmit.Text
"貸出を登録する"

// ▼ btnSubmit.OnSelect
UpdateContext({ locBusy: true });

With(
    { 最新: LookUp('設備', 短縮番号 = varEquipment.短縮番号) },
    If(
        最新.ステータス <> 'ステータス (設備)'.空き,

        Set(varEquipment, 最新);
        Notify("この設備は今ほかの操作で状態が変わりました。画面を更新しました。", NotificationType.Warning),

        With(
            {
                貸出レコード: Patch(
                    '貸出',
                    Defaults('貸出'),
                    {
                        貸出番号: 最新.短縮番号 & "-" & Text(Now(), "yyyymmddhhmmss"),
                        設備: 最新,
                        貸出区分: varLoanType,
                        貸出先: If(varLoanType = '貸出区分 (貸出)'.社外, varBorrower, Blank()),
                        貸出先部署: If(varLoanType = '貸出区分 (貸出)'.社内, varLoanDepartment, Blank()),
                        持出者: varMe,
                        貸出日: Today(),
                        返却予定日: varDueDate,
                        状態: '状態 (貸出)'.貸出中,
                        貸出時メモ: txtConditionOut.Text,
                        延滞通知済み: false
                    }
                )
            },
            If(
                IsEmpty(Errors('貸出', 貸出レコード)),

                Set(
                    varEquipment,
                    Patch('設備', 最新, { ステータス: 'ステータス (設備)'.貸出中 })
                );
                Notify(
                    "貸出を登録しました。返却予定日は " & Text(varDueDate, "yyyy/mm/dd") & " です。",
                    NotificationType.Success
                );
                Back(),

                Notify("登録できませんでした。入力内容を確認してください。", NotificationType.Error)
            )
        )
    )
);

UpdateContext({ locBusy: false })

// ▼ btnCancel.OnSelect
Back()
