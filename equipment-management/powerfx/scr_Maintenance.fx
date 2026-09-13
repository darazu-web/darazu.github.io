// ============================================================
// scrMaintenance : メンテ開始／完了（フェーズ3-9）
// ============================================================
// 管理者だけが使います（btnMaintStart / btnMaintEnd の Visible で制御済み）。
// 次回メンテ予定日の再計算をここでやっておくと、フェーズ5-2 の通知がそのまま効きます。


// ▼ scrMaintenance.OnVisible
Set(varEquipment, LookUp('設備', 短縮番号 = varEquipment.短縮番号));
Reset(txtMaintNote)


// ▼ lblEquipment.Text
varEquipment.短縮番号 & "  " & varEquipment.設備名

// ▼ lblCurrent.Text
"現在の状態: " & varEquipment.ステータス & Char(10) &
"前回メンテ日: " & Coalesce(Text(varEquipment.前回メンテ日, "yyyy/mm/dd"), "記録なし") & Char(10) &
"メンテ周期: " & Coalesce(Text(varEquipment.メンテ周期日数), Text(varEquipment.種別.既定メンテ周期日数), "未設定") & " 日"

// ▼ txtMaintNote.HintText
"作業内容・部品交換など（備考に追記されます）"


// ------------------------------------------------------------
// メンテ開始
// ------------------------------------------------------------

// ▼ btnMaintStart.Visible
varIsAdmin
And (
    varEquipment.ステータス = 'ステータス (設備)'.空き
    Or varEquipment.ステータス = 'ステータス (設備)'.故障
)

// ▼ btnMaintStart.OnSelect
UpdateContext({ locBusy: true });

Set(
    varEquipment,
    Patch(
        '設備',
        LookUp('設備', 短縮番号 = varEquipment.短縮番号),
        { ステータス: 'ステータス (設備)'.メンテ中 }
    )
);
Notify("メンテナンスを開始しました。この設備は使用できなくなります。", NotificationType.Success);

UpdateContext({ locBusy: false })


// ------------------------------------------------------------
// メンテ完了
// ------------------------------------------------------------

// ▼ btnMaintEnd.Visible
varIsAdmin And varEquipment.ステータス = 'ステータス (設備)'.メンテ中

// ▼ btnMaintEnd.Text
"メンテ完了（空きに戻す）"

// ▼ btnMaintEnd.OnSelect
UpdateContext({ locBusy: true });

With(
    {
        // 設備に周期の指定がなければ種別の既定値を使う
        周期: Coalesce(varEquipment.メンテ周期日数, varEquipment.種別.既定メンテ周期日数, 0)
    },
    Set(
        varEquipment,
        Patch(
            '設備',
            LookUp('設備', 短縮番号 = varEquipment.短縮番号),
            {
                ステータス: 'ステータス (設備)'.空き,
                前回メンテ日: Today(),
                次回メンテ予定日: If(周期 > 0, DateAdd(Today(), 周期, TimeUnit.Days), Blank()),
                備考: Trim(
                    Coalesce(varEquipment.備考, "") & Char(10) &
                    Text(Today(), "yyyy/mm/dd") & " メンテ実施: " & txtMaintNote.Text
                )
            }
        )
    )
);

If(
    IsEmpty(Errors('設備', varEquipment)),
    Notify(
        "メンテ完了を記録しました。次回予定日: " &
        Coalesce(Text(varEquipment.次回メンテ予定日, "yyyy/mm/dd"), "未設定（周期が入っていません）"),
        NotificationType.Success
    );
    Back(),
    Notify("保存できませんでした。もう一度お試しください。", NotificationType.Error)
);

UpdateContext({ locBusy: false })


// ------------------------------------------------------------
// 故障として記録する（メンテ待ちの手前）
// ------------------------------------------------------------

// ▼ btnBroken.Visible
varIsAdmin And varEquipment.ステータス <> 'ステータス (設備)'.故障

// ▼ btnBroken.OnSelect
Set(
    varEquipment,
    Patch(
        '設備',
        LookUp('設備', 短縮番号 = varEquipment.短縮番号),
        {
            ステータス: 'ステータス (設備)'.故障,
            備考: Trim(
                Coalesce(varEquipment.備考, "") & Char(10) &
                Text(Today(), "yyyy/mm/dd") & " 故障として登録: " & txtMaintNote.Text
            )
        }
    )
);
Notify("故障として記録しました。", NotificationType.Success)

// ▼ btnBack.OnSelect
Back()
