/* =====================================================================
   照合アプリ  Step1 + Step2
   ---------------------------------------------------------------------
   やること：
     - 「スキャン開始」を押すとカメラが起動する（Step1）
     - バーコードを読み取り、その値を画面に表示する（Step2）
     - 読み取った履歴を一覧に残し、件数を数える
   ※ Step3以降で「CSVリストとの照合」「一部照合」「保存・オフライン化」を足していきます。
   ===================================================================== */

// ---- 画面の部品を取得（HTML側のid名と対応）----
const startBtn    = document.getElementById("startBtn");
const stopBtn     = document.getElementById("stopBtn");
const lastResult  = document.getElementById("lastResult");
const historyList = document.getElementById("historyList");
const countBadge  = document.getElementById("count");
const statusEl    = document.getElementById("status");

// ---- このアプリで扱う状態（データ）----
let html5Qrcode = null;   // 読み取り機能の本体（あとで作る）
let isScanning  = false;  // 今カメラが動いているか
let history     = [];     // 読み取った値の履歴（配列）

// 同じコードを一瞬で何度も読んでしまうのを防ぐための記録
let lastCode     = "";
let lastReadTime = 0;
const IGNORE_SAME_MS = 1500; // 同じ値は1.5秒間は無視する

// ---------------------------------------------------------------------
// 読み取り対象のバーコード種類（商品バーコードやQRなど主要なものを指定）
// ---------------------------------------------------------------------
const formatsToSupport = [
  Html5QrcodeSupportedFormats.QR_CODE,
  Html5QrcodeSupportedFormats.EAN_13,   // 一般的な商品バーコード（日本のJANもこれ）
  Html5QrcodeSupportedFormats.EAN_8,
  Html5QrcodeSupportedFormats.UPC_A,
  Html5QrcodeSupportedFormats.UPC_E,
  Html5QrcodeSupportedFormats.CODE_128, // 物流・社内管理でよく使われる
  Html5QrcodeSupportedFormats.CODE_39,
  Html5QrcodeSupportedFormats.ITF,
  Html5QrcodeSupportedFormats.CODABAR,
];

// =====================================================================
// スキャン開始
// =====================================================================
async function startScan() {
  if (isScanning) return;

  // 読み取り機能の本体を作る（"reader" はHTMLの箱のid）
  html5Qrcode = new Html5Qrcode("reader", { formatsToSupport, verbose: false });

  // 読み取り時の設定
  const config = {
    fps: 10,                 // 1秒あたりの読み取り試行回数
    qrbox: { width: 250, height: 150 }, // 画面内の読み取り枠のおおよその大きさ
    aspectRatio: 1.0,
  };

  setStatus("カメラを起動しています…");

  try {
    await html5Qrcode.start(
      { facingMode: "environment" }, // スマホの外側（背面）カメラを使う
      config,
      onScanSuccess,   // 読み取れたとき
      onScanFailure    // 読み取れないフレーム（毎回呼ばれるので今は無視）
    );
    isScanning = true;
    startBtn.disabled = true;
    stopBtn.disabled  = false;
    setStatus("バーコードを枠に合わせてください");
  } catch (err) {
    // カメラが使えない・許可されなかった等
    setStatus("カメラを起動できませんでした：" + err, true);
  }
}

// =====================================================================
// スキャン停止
// =====================================================================
async function stopScan() {
  if (!isScanning || !html5Qrcode) return;
  try {
    await html5Qrcode.stop();
    await html5Qrcode.clear();
  } catch (_) {
    // 停止時の軽微なエラーは無視
  }
  isScanning = false;
  startBtn.disabled = false;
  stopBtn.disabled  = true;
  setStatus("停止しました");
}

// =====================================================================
// 読み取り成功したときの処理
//   decodedText … 読み取れた文字列（バーコードの中身）
// =====================================================================
function onScanSuccess(decodedText, decodedResult) {
  const now = Date.now();

  // 直前と同じコードを連続で拾ったら無視（数えすぎ防止）
  if (decodedText === lastCode && now - lastReadTime < IGNORE_SAME_MS) {
    return;
  }
  lastCode = decodedText;
  lastReadTime = now;

  // 画面に大きく表示
  lastResult.textContent = decodedText;
  lastResult.classList.remove("flash");
  void lastResult.offsetWidth;      // アニメをやり直すための「おまじない」
  lastResult.classList.add("flash");

  // 履歴に追加（新しいものを先頭へ）
  history.unshift({ code: decodedText, time: new Date() });
  renderHistory();

  // ピッと鳴らす（読み取れた合図）
  beep();
}

// 読み取れないフレームごとに呼ばれるが、今は何もしない
function onScanFailure(error) {
  // 何もしない（毎フレーム呼ばれるため、ここでログを出すと大量になる）
}

// =====================================================================
// 履歴の表示を更新
// =====================================================================
function renderHistory() {
  countBadge.textContent = history.length + " 件";

  if (history.length === 0) {
    historyList.innerHTML = '<li class="history-empty">まだありません</li>';
    return;
  }

  // 配列を <li> のHTMLに変換して表示
  historyList.innerHTML = history
    .map((item) => {
      const t = item.time;
      const hh = String(t.getHours()).padStart(2, "0");
      const mm = String(t.getMinutes()).padStart(2, "0");
      const ss = String(t.getSeconds()).padStart(2, "0");
      return `<li>${escapeHtml(item.code)}<span class="time">${hh}:${mm}:${ss}</span></li>`;
    })
    .join("");
}

// =====================================================================
// 補助的な小さな関数たち
// =====================================================================

// 状況メッセージを表示（isError=true で赤字）
function setStatus(message, isError = false) {
  statusEl.textContent = message;
  statusEl.classList.toggle("error", isError);
}

// 読み取り値に < > などが入っていても安全に表示するための変換
function escapeHtml(str) {
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

// 「ピッ」という短い音を鳴らす（読み取れた合図）
function beep() {
  try {
    const ctx = new (window.AudioContext || window.webkitAudioContext)();
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.connect(gain);
    gain.connect(ctx.destination);
    osc.frequency.value = 880;      // 音の高さ
    gain.gain.value = 0.1;          // 音量（控えめ）
    osc.start();
    osc.stop(ctx.currentTime + 0.12); // 0.12秒だけ鳴らす
  } catch (_) {
    // 音が出せない環境でも、アプリは問題なく動く
  }
}

// ---- ボタンに動きを割り当てる ----
startBtn.addEventListener("click", startScan);
stopBtn.addEventListener("click", stopScan);

// 最初に一度、履歴（空）を表示しておく
renderHistory();
