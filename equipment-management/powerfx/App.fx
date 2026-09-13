// ============================================================
// アプリ本体の設定（フェーズ3-1）
// ============================================================
// varMe の取得と、使用者マスタに未登録の人をブロックします。
//
// 【重要】未登録者のブロックは App.OnStart の Navigate ではなく
// App.StartScreen で行います。StartScreen は OnStart より先に評価されるため、
// OnStart で作った変数は使えません。ここでは自己完結した LookUp を書いています。


// ▼ App.StartScreen
// 使用者マスタに有効なレコードがなければブロック画面へ送る
If(
    IsBlank(
        LookUp('使用者', Lower(UPN) = Lower(User().Email) And 有効 = true)
    ),
    scrBlocked,
    scrHome
)


// ▼ App.OnStart
// 画面遷移はここではしない。アプリ全体で使う変数だけを用意する。
Set(varAppVersion, "1.0.0");

// サインインしている人の使用者マスタ。UPN は小文字で突合する（フェーズ2-2）
Set(
    varMe,
    LookUp('使用者', Lower(UPN) = Lower(User().Email) And 有効 = true)
);

Set(varIsRegistered, !IsBlank(varMe));
Set(varIsAdmin, varIsRegistered And varMe.役割 = '役割 (使用者)'.管理者);

// ホーム画面の初期表示場所。使用者マスタの「既定の場所」があればそれを選ぶ
Set(
    varLocation,
    Coalesce(
        varMe.既定の場所,
        First(Sort(Filter('場所', 有効 = true), 並び順))
    )
);

// 画面間で持ち回る「いま見ている設備」
Set(varEquipment, Blank());
Set(varKeypadInput, "");


// ▼ App.Formulas
// 名前付き数式。Set と違って起動を遅くしないので、定数はこちらに置く。
// 「数式バー > App > Formulas」に貼り付けます。

// 色（現場で見るので彩度は高め、文字は黒に近い色で）
nfColorAvailable = RGBA(16, 124, 16, 1);      // 空き = 緑
nfColorInUse     = RGBA(196, 89, 17, 1);      // 使用中 = オレンジ
nfColorLoaned    = RGBA(0, 99, 177, 1);       // 貸出中 = 青
nfColorMaint     = RGBA(96, 94, 92, 1);       // メンテ中 = グレー
nfColorBroken    = RGBA(168, 0, 0, 1);        // 故障 = 赤
nfColorText      = RGBA(32, 31, 30, 1);
nfColorBg        = RGBA(243, 242, 241, 1);

// 手袋をしたまま押せる大きさ（現場で効く数字なので小さくしない）
nfButtonHeight   = 88;
nfKeypadSize     = 96;
nfFontLarge      = 28;
nfFontHuge       = 48;

// 注意: 名前付き数式に「選択肢を受け取る関数」は作れません。
// ステータスの色分けは各画面の Switch で書きます（scr_Home.fx を参照）。
// 色の定義をここに集約しておけば、変えるときは1か所で済みます。
