// ============================================================
// scrScan : QRスキャン（フェーズ3-11）
// ============================================================
// 優先度は「低」です。ラベルの貼付が進んでから着手して構いません。
// QRコード値には短縮番号と同じ4桁を入れてあります（フェーズ2-4 の採番時に自動で入ります）。
// そのため、スキャン結果はテンキー入力とまったく同じ経路で処理できます。


// ▼ bcScanner.OnScan
With(
    { 読取値: Trim(bcScanner.Value) },
    With(
        {
            // QRコード値と短縮番号のどちらでも引けるようにしておく。
            // ラベルを作り直す前後で両方が混在する期間があるため。
            見つかった設備: Coalesce(
                LookUp('設備', QRコード値 = 読取値),
                LookUp('設備', 短縮番号 = 読取値)
            )
        },
        If(
            IsBlank(見つかった設備),
            Notify(
                "読み取った値（" & 読取値 & "）に一致する設備がありません。テンキーで番号を入力してください。",
                NotificationType.Error
            ),
            Set(varEquipment, 見つかった設備);
            Navigate(scrDetail, ScreenTransition.None)
        )
    )
)

// ▼ bcScanner.BarcodeType
BarcodeType.Any

// ▼ lblHint.Text
"設備のラベルにあるQRコードを枠に入れてください"

// ▼ btnKeypadFallback.Text
"うまく読めないときは番号入力へ"

// ▼ btnKeypadFallback.OnSelect
Set(varKeypadInput, "");
Navigate(scrKeypad, ScreenTransition.None)

// ▼ btnBack.OnSelect
Back()
