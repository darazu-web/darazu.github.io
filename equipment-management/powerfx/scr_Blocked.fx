// ============================================================
// scrBlocked : 未登録者のブロック画面（フェーズ3-1）
// ============================================================
// 使用者マスタにいない人がここに来ます。
// 「使えません」だけだと問い合わせ先が分からず現場が止まるので、
// 誰に連絡すればよいかを画面に書いておきます。


// ▼ lblTitle.Text
"このアプリはまだご利用いただけません"


// ▼ lblMessage.Text
"設備管理システムの使用者マスタに、あなたのアカウントが登録されていません。" & Char(10) & Char(10) &
"サインイン中のアカウント: " & User().Email & Char(10) & Char(10) &
"設備管理担当（保全部）に、上のアカウントで登録を依頼してください。"


// ▼ btnRetry.Text
"登録が済んだら、ここを押す"


// ▼ btnRetry.OnSelect
// 登録直後はキャッシュが残っていることがあるので、明示的に取り直す
Set(
    varMe,
    LookUp('使用者', Lower(UPN) = Lower(User().Email) And 有効 = true)
);
Set(varIsRegistered, !IsBlank(varMe));
Set(varIsAdmin, varIsRegistered And varMe.役割 = '役割 (使用者)'.管理者);

If(
    varIsRegistered,
    Set(
        varLocation,
        Coalesce(varMe.既定の場所, First(Sort(Filter('場所', 有効 = true), 並び順)))
    );
    Navigate(scrHome, ScreenTransition.Fade),
    Notify("まだ登録が確認できません。担当者にお問い合わせください。", NotificationType.Warning)
)
