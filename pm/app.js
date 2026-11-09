/* =====================================================================
   プロジェクト管理ツール  ① マイタスク
   ---------------------------------------------------------------------
   やること：
     - やることを入力して「追加」すると「未着手」に並ぶ
     - カードのボタンで 未着手 → 作業中 → 完了 と動かせる（← で戻せる）
     - 不要なカードは削除できる
     - 入力内容は localStorage に保存され、再読み込みしても残る
   ===================================================================== */

// ---- 保存に使う「鍵（キー）」の名前。将来 v2 にしたいとき用に番号を付けておく ----
const STORAGE_KEY = "pm_tasks_v1";

// ---- このアプリで扱うデータ本体（タスクの配列）----
// 1件のタスクの形： { id, title, due, status }
//   status は "todo"（未着手） / "doing"（作業中） / "done"（完了）のどれか
let tasks = [];

// ---- 画面の部品を取得（HTML側の id と対応）----
const titleInput = document.getElementById("titleInput");
const dueInput   = document.getElementById("dueInput");
const addBtn     = document.getElementById("addBtn");

// =====================================================================
// 起動時：保存データを読み込んで画面に表示する
// =====================================================================
function init() {
  load();     // localStorage から読み込む
  render();   // 画面に描く
}

// =====================================================================
// 保存データの読み込み／書き込み
// =====================================================================
function load() {
  const saved = localStorage.getItem(STORAGE_KEY);
  // 保存がなければ空の配列から始める
  tasks = saved ? JSON.parse(saved) : [];
}

function save() {
  // 配列を文字列に変換して保存する
  localStorage.setItem(STORAGE_KEY, JSON.stringify(tasks));
}

// =====================================================================
// タスクを追加する
// =====================================================================
function addTask() {
  const title = titleInput.value.trim();

  // 空のときは何もしない
  if (title === "") {
    alert("やることを入力してください。");
    return;
  }

  // 新しいタスクを作って配列の先頭に追加
  tasks.unshift({
    id: Date.now(),          // 重複しない番号として「今の時刻」を使う
    title: title,
    due: dueInput.value,     // 期限（未入力なら空文字）
    status: "todo",          // 最初は必ず「未着手」
  });

  // 入力欄をリセット
  titleInput.value = "";
  dueInput.value   = "";

  save();
  render();
}

// =====================================================================
// タスクの状態を動かす（dir: +1 で進める / -1 で戻す）
// =====================================================================
const ORDER = ["todo", "doing", "done"]; // 並び順

function moveTask(id, dir) {
  const task = tasks.find((t) => t.id === id);
  if (!task) return;

  const current = ORDER.indexOf(task.status);
  const next    = current + dir;

  // 端（未着手より前・完了より後ろ）には動かさない
  if (next < 0 || next >= ORDER.length) return;

  task.status = ORDER[next];
  save();
  render();
}

// =====================================================================
// タスクを削除する
// =====================================================================
function deleteTask(id) {
  if (!confirm("このタスクを削除しますか？")) return;
  // 指定したid「以外」だけを残す
  tasks = tasks.filter((t) => t.id !== id);
  save();
  render();
}

// =====================================================================
// 画面を描く（データ → HTML）
// =====================================================================
function render() {
  // 3つの列をいったん空にする
  ORDER.forEach((status) => {
    document.getElementById("list-" + status).innerHTML = "";
  });

  // タスクを1件ずつ、対応する列に置く
  tasks.forEach((task) => {
    const card = createCard(task);
    document.getElementById("list-" + task.status).appendChild(card);
  });

  // 各列の件数を更新する
  ORDER.forEach((status) => {
    const n = tasks.filter((t) => t.status === status).length;
    document.getElementById("count-" + status).textContent = n;
  });
}

// ---- カード1枚のHTMLを組み立てる ----
function createCard(task) {
  const card = document.createElement("div");
  card.className = "card";

  // タイトル
  const title = document.createElement("div");
  title.className = "card-title";
  title.textContent = task.title;
  card.appendChild(title);

  // 期限（入力があるときだけ表示）
  if (task.due) {
    const due = document.createElement("div");
    due.className = "card-due";
    due.textContent = "期限: " + task.due;
    card.appendChild(due);
  }

  // 操作ボタン（← 戻す / → 進める / 削除）
  const actions = document.createElement("div");
  actions.className = "card-actions";

  const backBtn = document.createElement("button");
  backBtn.textContent = "←";
  backBtn.title = "前の状態に戻す";
  backBtn.onclick = () => moveTask(task.id, -1);
  // 未着手のときは「戻す」を押せないようにする
  if (task.status === "todo") backBtn.disabled = true;

  const fwdBtn = document.createElement("button");
  fwdBtn.textContent = "→";
  fwdBtn.title = "次の状態に進める";
  fwdBtn.onclick = () => moveTask(task.id, +1);
  // 完了のときは「進める」を押せないようにする
  if (task.status === "done") fwdBtn.disabled = true;

  const delBtn = document.createElement("button");
  delBtn.className = "del";
  delBtn.textContent = "🗑";
  delBtn.title = "削除";
  delBtn.onclick = () => deleteTask(task.id);

  actions.appendChild(backBtn);
  actions.appendChild(fwdBtn);
  actions.appendChild(delBtn);
  card.appendChild(actions);

  return card;
}

// =====================================================================
// ボタンやキー操作の割り当て
// =====================================================================
addBtn.addEventListener("click", addTask);

// 入力欄で Enter を押しても追加できるようにする
titleInput.addEventListener("keydown", (e) => {
  if (e.key === "Enter") addTask();
});

// アプリ起動
init();
