// ============================================================
// scrDetail : 設備詳細とボタンの出し分け（フェーズ3-4）＋ 使用開始／終了（フェーズ3-5）
// ============================================================
// このアプリの中心です。ここが分かりにくいと、使用開始・終了が定着しません。
//
// 設計の原則:
//   1. いま押せるボタンだけを出す（押せないボタンをグレーで並べない）
//   2. 押した結果は Notify で必ず知らせる
//   3. Patch の前に必ず最新の状態を取り直す
//      → 2人が同時に同じ設備を触ったとき、後から押した人が黙って上書きしてしまうのを防ぐ


// ▼ scrDetail.OnVisible
// 一覧から渡ってきた varEquipment は少し古い可能性があるので取り直す
Set(varEquipment, LookUp('設備', 短縮番号 = varEquipment.短縮番号));
Reset(txtEndComment)


// ------------------------------------------------------------
// 表示
// ------------------------------------------------------------

// ▼ lblShortNumber.Text
varEquipment.短縮番号

// ▼ lblShortNumber.Size
nfFontHuge

// ▼ lblName.Text
varEquipment.設備名

// ▼ lblMeta.Text
varEquipment.種別.種別名 & " / " & varEquipment.場所.場所名 & " / " & varEquipment.設備コード

// ▼ lblStatus.Text
varEquipment.ステータス

// ▼ lblStatus.Fill
Switch(
    varEquipment.ステータス,
    'ステータス (設備)'.空き,     nfColorAvailable,
    'ステータス (設備)'.使用中,   nfColorInUse,
    'ステータス (設備)'.貸出中,   nfColorLoaned,
    'ステータス (設備)'.メンテ中, nfColorMaint,
    'ステータス (設備)'.故障,     nfColorBroken,
    RGBA(150, 150, 150, 1)
)

// ▼ lblCurrentUser.Text
// 使用中なら「誰が・いつから」を出す。終了忘れに本人が気づく唯一の手がかり。
If(
    varEquipment.ステータス = 'ステータス (設備)'.使用中,
    varEquipment.現在の使用者.氏名 & " さんが使用中" & Char(10) &
    Text(varEquipment.現在の使用開始日時, "yyyy/mm/dd hh:mm") & " から（" &
    RoundDown(DateDiff(varEquipment.現在の使用開始日時, Now(), TimeUnit.Minutes) / 60, 0) & " 時間経過）",
    ""
)

// ▼ lblNextMaintenance.Text
If(
    IsBlank(varEquipment.次回メンテ予定日),
    "",
    "次回メンテ予定: " & Text(varEquipment.次回メンテ予定日, "yyyy/mm/dd") &
    If(varEquipment.次回メンテ予定日 < Today(), "（期限切れ）", "")
)

// ▼ lblNextMaintenance.Color
If(varEquipment.次回メンテ予定日 < Today(), nfColorBroken, nfColorText)


// ------------------------------------------------------------
// ボタンの出し分け（フェーズ3-4）
// ------------------------------------------------------------

// ▼ btnStart.Visible          ... 使用開始
varEquipment.ステータス = 'ステータス (設備)'.空き

// ▼ btnEnd.Visible            ... 使用終了
// 自分が借りている設備か、管理者のときだけ出す。
// （他人の使用を勝手に終わらせられると、ログが誰のものか分からなくなる）
varEquipment.ステータス = 'ステータス (設備)'.使用中
And (
    varEquipment.現在の使用者.社員番号 = varMe.社員番号
    Or varIsAdmin
)

// ▼ lblOtherUserNote.Visible  ... 他人が使用中のときの案内
varEquipment.ステータス = 'ステータス (設備)'.使用中
And varEquipment.現在の使用者.社員番号 <> varMe.社員番号
And Not varIsAdmin

// ▼ lblOtherUserNote.Text
"この設備は他の方が使用中です。終了は使用した本人か管理者が行ってください。"

// ▼ btnLoan.Visible           ... 貸出登録（フェーズ3-7）
varEquipment.ステータス = 'ステータス (設備)'.空き And varEquipment.貸出可否

// ▼ btnReturn.Visible         ... 返却（フェーズ3-8）
varEquipment.ステータス = 'ステータス (設備)'.貸出中

// ▼ btnMaintStart.Visible     ... メンテ開始（フェーズ3-9、管理者のみ）
varIsAdmin
And (
    varEquipment.ステータス = 'ステータス (設備)'.空き
    Or varEquipment.ステータス = 'ステータス (設備)'.故障
)

// ▼ btnMaintEnd.Visible       ... メンテ完了（フェーズ3-9、管理者のみ）
varIsAdmin And varEquipment.ステータス = 'ステータス (設備)'.メンテ中


// ------------------------------------------------------------
// 用途の選択（使用開始時）
// ------------------------------------------------------------

// ▼ cmbPurpose.Items
Choices('稼働ログ'.用途)

// ▼ cmbPurpose.DefaultSelectedItems
[ '用途 (稼働ログ)'.通常作業 ]

// ▼ cmbPurpose.Visible
btnStart.Visible


// ------------------------------------------------------------
// 使用開始（フェーズ3-5）
// ------------------------------------------------------------

// ▼ btnStart.Text
"使用を開始する"

// ▼ btnStart.Fill
nfColorAvailable

// ▼ btnStart.OnSelect
UpdateContext({ locBusy: true });

// 1. 押した瞬間の最新状態を取り直す
With(
    { 最新: LookUp('設備', 短縮番号 = varEquipment.短縮番号) },
    If(
        // 2. その間に他の人が使い始めていないか確認する
        最新.ステータス <> 'ステータス (設備)'.空き,

        Set(varEquipment, 最新);
        Notify(
            "この設備は、ちょうど今ほかの操作で状態が変わりました。画面の状態を更新しました。",
            NotificationType.Warning
        ),

        // 3. 稼働ログを1件つくる
        Set(
            varLog,
            Patch(
                '稼働ログ',
                Defaults('稼働ログ'),
                {
                    ログ名: 最新.短縮番号 & " " & varMe.氏名 & " " & Text(Now(), "yyyy/mm/dd hh:mm"),
                    設備: 最新,
                    使用者: varMe,
                    開始場所: 最新.場所,
                    開始日時: Now(),
                    状態: '状態 (稼働ログ)'.稼働中,
                    用途: cmbPurpose.Selected,
                    登録元: '登録元 (稼働ログ)'.アプリ,
                    長時間通知済み: false
                }
            )
        );

        // 4. 設備側の現在状態を更新する
        Set(
            varEquipment,
            Patch(
                '設備',
                最新,
                {
                    ステータス: 'ステータス (設備)'.使用中,
                    現在の使用者: varMe,
                    現在の稼働ログ: varLog,
                    現在の使用開始日時: varLog.開始日時
                }
            )
        );

        // 5. 結果を必ず知らせる
        If(
            IsEmpty(Errors('設備', varEquipment)) And IsEmpty(Errors('稼働ログ', varLog)),
            Notify(
                varEquipment.短縮番号 & " の使用を開始しました。終わったら必ず「使用を終了する」を押してください。",
                NotificationType.Success
            ),
            Notify(
                "保存できませんでした。電波状況を確認して、もう一度お試しください。",
                NotificationType.Error
            )
        )
    )
);

UpdateContext({ locBusy: false })


// ------------------------------------------------------------
// 使用終了（フェーズ3-5）
// ------------------------------------------------------------

// ▼ btnEnd.Text
"使用を終了する"

// ▼ btnEnd.Fill
nfColorInUse

// ▼ txtEndComment.HintText
"気づいたこと（任意）"

// ▼ btnEnd.OnSelect
UpdateContext({ locBusy: true });

With(
    { 最新: LookUp('設備', 短縮番号 = varEquipment.短縮番号) },
    With(
        {
            // 稼働中のログを取り直す。参照列はレコードと比較する（委任のため）
            稼働ログ実体: First(
                Sort(
                    Filter('稼働ログ', 設備 = 最新, 状態 = '状態 (稼働ログ)'.稼働中),
                    開始日時,
                    SortOrder.Descending
                )
            )
        },
        If(
            IsBlank(稼働ログ実体),

            // ログが見つからない = 設備側だけ「使用中」で取り残されている状態。
            // 現場を止めないよう設備側だけ空きに戻し、管理者が後で追えるよう知らせる。
            Set(
                varEquipment,
                Patch('設備', 最新, {
                    ステータス: 'ステータス (設備)'.空き,
                    現在の使用者: Blank(),
                    現在の稼働ログ: Blank(),
                    現在の使用開始日時: Blank()
                })
            );
            Notify(
                "稼働ログが見つからなかったため、設備の状態だけ「空き」に戻しました。管理者に連絡してください。",
                NotificationType.Warning
            ),

            // 通常の終了処理
            Patch(
                '稼働ログ',
                稼働ログ実体,
                {
                    終了日時: Now(),
                    稼働時間: RoundDown(DateDiff(稼働ログ実体.開始日時, Now(), TimeUnit.Minutes), 0),
                    状態: '状態 (稼働ログ)'.完了,
                    終了時コメント: txtEndComment.Text
                }
            );

            Set(
                varEquipment,
                Patch('設備', 最新, {
                    ステータス: 'ステータス (設備)'.空き,
                    現在の使用者: Blank(),
                    現在の稼働ログ: Blank(),
                    現在の使用開始日時: Blank()
                })
            );

            If(
                IsEmpty(Errors('設備', varEquipment)),
                Notify(
                    "使用を終了しました（" &
                    RoundDown(DateDiff(稼働ログ実体.開始日時, Now(), TimeUnit.Minutes), 0) &
                    " 分）。お疲れさまでした。",
                    NotificationType.Success
                ),
                Notify("保存できませんでした。電波状況を確認して、もう一度お試しください。", NotificationType.Error)
            );
            Reset(txtEndComment)
        )
    )
);

UpdateContext({ locBusy: false })


// ------------------------------------------------------------
// 二重押し防止（すべての操作ボタンに同じ式を入れる）
// ------------------------------------------------------------

// ▼ btnStart.DisplayMode / btnEnd.DisplayMode / btnLoan.DisplayMode / btnReturn.DisplayMode
If(locBusy, DisplayMode.Disabled, DisplayMode.Edit)


// ------------------------------------------------------------
// 他画面への導線
// ------------------------------------------------------------

// ▼ btnLoan.OnSelect
Navigate(scrLoan, ScreenTransition.None)

// ▼ btnReturn.OnSelect
Navigate(scrReturn, ScreenTransition.None)

// ▼ btnMaintStart.OnSelect / btnMaintEnd.OnSelect
Navigate(scrMaintenance, ScreenTransition.None)

// ▼ btnBack.OnSelect
Back()
