// ============================================================
// scrKeypad : 番号入力（テンキー）（フェーズ3-3）
// ============================================================
// ラベルの4桁を入力して設備を呼び出します。
// キーボードではなく画面上のテンキーにするのは、手袋のままでも押せるようにするためです。
// ボタンの一辺は nfKeypadSize（96）以上を守ってください。小さくすると誤打が一気に増えます。


// ▼ scrKeypad.OnVisible
Set(varKeypadInput, "")


// ------------------------------------------------------------
// 入力欄
// ------------------------------------------------------------

// ▼ lblInput.Text
// 入力済みは数字、未入力はアンダースコアで「あと何桁か」を見せる
Left(varKeypadInput & "____", 4)

// ▼ lblInput.Size
nfFontHuge

// ▼ lblHint.Text
"設備に貼ってある4桁の番号を入れてください"


// ------------------------------------------------------------
// 数字ボタン 0〜9
// ------------------------------------------------------------
// 下は「1」の例です。btn0〜btn9 に同じ式を貼り、"1" の部分だけ各数字に変えてください。

// ▼ btn1.OnSelect
Set(varKeypadInput, Left(varKeypadInput & "1", 4))

// ▼ btn1.Text
"1"

// ▼ btn1.Size
nfFontLarge


// ------------------------------------------------------------
// 訂正ボタン
// ------------------------------------------------------------

// ▼ btnBackspace.OnSelect
// 1文字だけ消す。全消しより訂正の回数が少なくて済む。
Set(varKeypadInput, Left(varKeypadInput, Max(Len(varKeypadInput) - 1, 0)))

// ▼ btnClear.OnSelect
Set(varKeypadInput, "")


// ------------------------------------------------------------
// 決定
// ------------------------------------------------------------

// ▼ btnEnter.DisplayMode
If(Len(varKeypadInput) = 4, DisplayMode.Edit, DisplayMode.Disabled)

// ▼ btnEnter.OnSelect
If(
    Len(varKeypadInput) < 4,
    Notify("4桁すべて入力してください。", NotificationType.Warning),

    // 短縮番号は代替キーなので、完全一致の LookUp で1件に決まる（委任される）
    With(
        { 見つかった設備: LookUp('設備', 短縮番号 = varKeypadInput) },
        If(
            IsBlank(見つかった設備),
            Notify(
                "番号 " & varKeypadInput & " の設備は見つかりませんでした。ラベルの番号を確認してください。",
                NotificationType.Error
            ),

            If(
                見つかった設備.ステータス = 'ステータス (設備)'.廃棄,
                Notify("この設備は廃棄済みです。管理者に連絡してください。", NotificationType.Error),

                Set(varEquipment, 見つかった設備);
                Set(varKeypadInput, "");
                Navigate(scrDetail, ScreenTransition.None)
            )
        )
    )
)


// ------------------------------------------------------------
// 戻る
// ------------------------------------------------------------

// ▼ btnBack.OnSelect
Back()
