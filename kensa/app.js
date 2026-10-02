/* 製品検査アプリ ----------------------------------------------------------
 * - 閲覧モード: 誰でも検索・閲覧できる（読み取り専用）
 * - 管理者モード: パスワードで解錠したときだけ追加・編集・削除ができる
 * - データは data.json を初期値として読み込み、編集内容はブラウザ(localStorage)
 *   に自動保存。全員へ反映するには「データ書き出し」で data.json を保存し
 *   リポジトリにコミットする。
 * ------------------------------------------------------------------------ */

const STORAGE_KEY = "kensa-app-data-v1";
const SESSION_ADMIN_KEY = "kensa-app-admin";

let state = { settings: {}, products: [] };
let isAdmin = false;
let editCtx = { productId: null, itemId: null }; // 編集中の対象

/* ---------- ユーティリティ ---------- */
const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => Array.from(document.querySelectorAll(sel));
const uid = (p) => p + "-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 7);

function esc(s) {
  return String(s == null ? "" : s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

async function sha256(text) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function toast(msg) {
  const t = $("#toast");
  t.textContent = msg;
  t.classList.add("show");
  clearTimeout(toast._t);
  toast._t = setTimeout(() => t.classList.remove("show"), 2200);
}

/* ---------- データ読み込み / 保存 ---------- */
async function loadData() {
  // 1) ブラウザに保存された編集内容を優先（管理者が端末で編集した結果）
  try {
    const local = localStorage.getItem(STORAGE_KEY);
    if (local) {
      state = JSON.parse(local);
      return;
    }
  } catch (e) { /* ignore */ }

  // 2) なければリポジトリの data.json を読み込む
  try {
    const res = await fetch("data.json?_=" + Date.now(), { cache: "no-store" });
    if (res.ok) {
      state = await res.json();
      return;
    }
  } catch (e) { /* ignore */ }

  // 3) どちらも無ければ空データ
  state = {
    settings: { title: "製品検査アプリ", subtitle: "", adminPasswordHash: "" },
    products: [],
  };
}

function persistLocal() {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
  } catch (e) {
    toast("ブラウザへの保存に失敗しました");
  }
}

/* ---------- 描画 ---------- */
function applySettings() {
  const s = state.settings || {};
  if (s.title) { $("#appTitle").textContent = s.title; document.title = s.title; }
  $("#appSubtitle").textContent = s.subtitle || "";
}

function renderProductFilter() {
  const sel = $("#productFilter");
  const cur = sel.value;
  sel.innerHTML = '<option value="">すべての製品</option>' +
    state.products.map((p) => `<option value="${esc(p.id)}">${esc(p.name)}</option>`).join("");
  sel.value = cur;
}

function matchItem(item, q) {
  if (!q) return true;
  const e = item.equipment || {};
  const hay = [
    item.name, item.method, item.notes, item.other,
    e.testerPartNo, e.testerName, e.peripherals, e.harness, e.software,
  ].join(" ").toLowerCase();
  return hay.includes(q);
}

function fieldBlock(label, value) {
  const empty = !value || !String(value).trim();
  return `<div class="field">
    <div class="field-label">${esc(label)}</div>
    <div class="field-value${empty ? " empty" : ""}">${empty ? "（未記入）" : esc(value)}</div>
  </div>`;
}

function equipBlock(e = {}) {
  const rows = [
    ["テスター品番", e.testerPartNo],
    ["テスター名", e.testerName],
    ["周辺設備", e.peripherals],
    ["ハーネス", e.harness],
    ["ソフトウェア", e.software],
  ];
  const body = rows.map(([k, v]) => {
    const empty = !v || !String(v).trim();
    return `<tr><th>${esc(k)}</th><td class="${empty ? "field-value empty" : ""}">${empty ? "（未記入）" : esc(v)}</td></tr>`;
  }).join("");
  return `<div class="field">
    <div class="field-label">使用する設備</div>
    <table class="equip-table"><tbody>${body}</tbody></table>
  </div>`;
}

function render() {
  applySettings();
  renderProductFilter();

  const q = $("#searchInput").value.trim().toLowerCase();
  const pf = $("#productFilter").value;
  const list = $("#list");
  list.innerHTML = "";

  let shownProducts = 0;

  state.products.forEach((product) => {
    if (pf && product.id !== pf) return;
    const items = (product.items || []).filter((it) => matchItem(it, q));
    // 検索語がある場合、該当項目が無い製品は非表示（管理者モードでは常に表示）
    if (q && items.length === 0 && !isAdmin) return;

    shownProducts++;
    const prodEl = document.createElement("section");
    prodEl.className = "product";
    prodEl.innerHTML = `
      <div class="product-head">
        <h2>${esc(product.name)}</h2>
        ${product.code ? `<span class="product-code">${esc(product.code)}</span>` : ""}
        <span class="spacer"></span>
        <button class="btn btn-sm admin-only" data-act="add-item" data-p="${esc(product.id)}">＋ 検査項目</button>
        <button class="btn btn-sm admin-only" data-act="edit-product" data-p="${esc(product.id)}">製品を編集</button>
        <button class="btn btn-sm btn-danger admin-only" data-act="del-product" data-p="${esc(product.id)}">削除</button>
        ${product.note ? `<div class="product-note">${esc(product.note)}</div>` : ""}
      </div>
      <div class="items"></div>`;

    const itemsWrap = prodEl.querySelector(".items");
    const srcItems = isAdmin ? (product.items || []) : items;

    if (srcItems.length === 0) {
      itemsWrap.innerHTML = `<div class="empty-state" style="padding:24px">検査項目がありません</div>`;
    }

    srcItems.forEach((item, idx) => {
      const itEl = document.createElement("div");
      itEl.className = "item";
      itEl.innerHTML = `
        <div class="item-head" data-toggle>
          <span class="item-no">${idx + 1}</span>
          <span class="item-name">${esc(item.name)}</span>
          <span class="chevron">▶</span>
        </div>
        <div class="item-body">
          ${fieldBlock("検査方法", item.method)}
          ${equipBlock(item.equipment)}
          ${fieldBlock("特記事項", item.notes)}
          ${fieldBlock("その他", item.other)}
          <div class="item-admin-bar admin-only-block" style="display:none">
            <button class="btn btn-sm" data-act="edit-item" data-p="${esc(product.id)}" data-i="${esc(item.id)}">編集</button>
            <button class="btn btn-sm btn-danger" data-act="del-item" data-p="${esc(product.id)}" data-i="${esc(item.id)}">削除</button>
          </div>
        </div>`;
      itEl.querySelector("[data-toggle]").addEventListener("click", () => itEl.classList.toggle("open"));
      itemsWrap.appendChild(itEl);
    });

    list.appendChild(prodEl);
  });

  if (shownProducts === 0) {
    list.innerHTML = `<div class="empty-state">
      ${state.products.length === 0
        ? (isAdmin ? "「＋ 製品を追加」から登録してください。" : "登録されている製品がありません。")
        : "該当する検査項目が見つかりませんでした。"}
    </div>`;
  }

  // 管理者バーの表示制御
  $$(".admin-only-block").forEach((el) => { el.style.display = isAdmin ? "flex" : "none"; });
}

/* ---------- 管理者モード ---------- */
function setAdmin(on) {
  isAdmin = on;
  document.body.classList.toggle("admin", on);
  document.body.classList.toggle("view", !on);
  $("#modeBadge").textContent = on ? "管理者モード" : "閲覧モード";
  $("#modeBadge").className = "mode-badge " + (on ? "mode-admin" : "mode-view");
  $("#btnAdmin").textContent = on ? "ログアウト" : "管理者ログイン";
  try {
    if (on) sessionStorage.setItem(SESSION_ADMIN_KEY, "1");
    else sessionStorage.removeItem(SESSION_ADMIN_KEY);
  } catch (e) { /* ignore */ }
  render();
}

async function tryLogin(pw) {
  const hash = (state.settings && state.settings.adminPasswordHash) || "";
  if (!hash) { toast("パスワードが未設定です"); return false; }
  const h = await sha256(pw);
  return h === hash;
}

/* ---------- モーダル制御 ---------- */
function openModal(id) { $(id).classList.add("show"); }
function closeModal(id) { $(id).classList.remove("show"); }
function closeAllModals() { $$(".modal-backdrop").forEach((m) => m.classList.remove("show")); }

/* ---------- 製品編集 ---------- */
function openProductModal(productId) {
  editCtx = { productId: productId || null, itemId: null };
  const p = productId ? state.products.find((x) => x.id === productId) : null;
  $("#productModalTitle").textContent = p ? "製品を編集" : "製品を追加";
  $("#pName").value = p ? p.name : "";
  $("#pCode").value = p ? (p.code || "") : "";
  $("#pNote").value = p ? (p.note || "") : "";
  openModal("#productModal");
  setTimeout(() => $("#pName").focus(), 50);
}

function saveProduct() {
  const name = $("#pName").value.trim();
  if (!name) { toast("製品名は必須です"); return; }
  const data = { name, code: $("#pCode").value.trim(), note: $("#pNote").value.trim() };
  if (editCtx.productId) {
    const p = state.products.find((x) => x.id === editCtx.productId);
    Object.assign(p, data);
  } else {
    state.products.push({ id: uid("p"), ...data, items: [] });
  }
  persistLocal();
  closeModal("#productModal");
  render();
  toast("製品を保存しました");
}

/* ---------- 検査項目編集 ---------- */
function openItemModal(productId, itemId) {
  editCtx = { productId, itemId: itemId || null };
  const p = state.products.find((x) => x.id === productId);
  const it = itemId ? (p.items || []).find((x) => x.id === itemId) : null;
  const e = (it && it.equipment) || {};
  $("#itemModalTitle").textContent = it ? "検査項目を編集" : "検査項目を追加";
  $("#iName").value = it ? it.name : "";
  $("#iMethod").value = it ? (it.method || "") : "";
  $("#eTesterNo").value = e.testerPartNo || "";
  $("#eTesterName").value = e.testerName || "";
  $("#ePeripherals").value = e.peripherals || "";
  $("#eHarness").value = e.harness || "";
  $("#eSoftware").value = e.software || "";
  $("#iNotes").value = it ? (it.notes || "") : "";
  $("#iOther").value = it ? (it.other || "") : "";
  openModal("#itemModal");
  setTimeout(() => $("#iName").focus(), 50);
}

function saveItem() {
  const name = $("#iName").value.trim();
  if (!name) { toast("検査項目は必須です"); return; }
  const p = state.products.find((x) => x.id === editCtx.productId);
  if (!p) return;
  const data = {
    name,
    method: $("#iMethod").value.trim(),
    equipment: {
      testerPartNo: $("#eTesterNo").value.trim(),
      testerName: $("#eTesterName").value.trim(),
      peripherals: $("#ePeripherals").value.trim(),
      harness: $("#eHarness").value.trim(),
      software: $("#eSoftware").value.trim(),
    },
    notes: $("#iNotes").value.trim(),
    other: $("#iOther").value.trim(),
  };
  p.items = p.items || [];
  if (editCtx.itemId) {
    const it = p.items.find((x) => x.id === editCtx.itemId);
    Object.assign(it, data);
  } else {
    p.items.push({ id: uid("i"), ...data });
  }
  persistLocal();
  closeModal("#itemModal");
  render();
  toast("検査項目を保存しました");
}

/* ---------- 削除 ---------- */
function deleteProduct(productId) {
  const p = state.products.find((x) => x.id === productId);
  if (!p) return;
  if (!confirm(`製品「${p.name}」と、その検査項目をすべて削除します。よろしいですか？`)) return;
  state.products = state.products.filter((x) => x.id !== productId);
  persistLocal();
  render();
  toast("製品を削除しました");
}

function deleteItem(productId, itemId) {
  const p = state.products.find((x) => x.id === productId);
  if (!p) return;
  const it = (p.items || []).find((x) => x.id === itemId);
  if (!it) return;
  if (!confirm(`検査項目「${it.name}」を削除します。よろしいですか？`)) return;
  p.items = p.items.filter((x) => x.id !== itemId);
  persistLocal();
  render();
  toast("検査項目を削除しました");
}

/* ---------- 書き出し / 取り込み ---------- */
function exportData() {
  state.settings = state.settings || {};
  state.settings.updatedAt = new Date().toISOString().slice(0, 10);
  const blob = new Blob([JSON.stringify(state, null, 2)], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = "data.json";
  a.click();
  URL.revokeObjectURL(url);
  toast("data.json を書き出しました");
}

function importData(file) {
  const reader = new FileReader();
  reader.onload = () => {
    try {
      const obj = JSON.parse(reader.result);
      if (!obj || !Array.isArray(obj.products)) throw new Error("形式が不正です");
      state = obj;
      persistLocal();
      render();
      toast("データを取り込みました");
    } catch (e) {
      alert("取り込みに失敗しました: " + e.message);
    }
  };
  reader.readAsText(file);
}

/* ---------- パスワード変更 ---------- */
async function changePassword() {
  const a = $("#newPw").value, b = $("#newPw2").value;
  if (!a) { toast("パスワードを入力してください"); return; }
  if (a !== b) { toast("確認用パスワードが一致しません"); return; }
  state.settings = state.settings || {};
  state.settings.adminPasswordHash = await sha256(a);
  persistLocal();
  closeModal("#pwModal");
  $("#newPw").value = ""; $("#newPw2").value = "";
  toast("パスワードを変更しました。データ書き出しで反映してください");
}

/* ---------- イベント登録 ---------- */
function bindEvents() {
  $("#searchInput").addEventListener("input", render);
  $("#productFilter").addEventListener("change", render);

  // 管理者ログイン / ログアウト
  $("#btnAdmin").addEventListener("click", () => {
    if (isAdmin) { setAdmin(false); toast("ログアウトしました"); }
    else { $("#pwInput").value = ""; openModal("#loginModal"); setTimeout(() => $("#pwInput").focus(), 50); }
  });
  $("#pwSubmit").addEventListener("click", async () => {
    if (await tryLogin($("#pwInput").value)) {
      closeModal("#loginModal");
      setAdmin(true);
      toast("管理者モードになりました");
    } else {
      toast("パスワードが違います");
    }
  });
  $("#pwInput").addEventListener("keydown", (e) => { if (e.key === "Enter") $("#pwSubmit").click(); });

  // ツールバー
  $("#btnAddProduct").addEventListener("click", () => openProductModal(null));
  $("#btnExport").addEventListener("click", exportData);
  $("#btnImport").addEventListener("click", () => $("#importFile").click());
  $("#importFile").addEventListener("change", (e) => { if (e.target.files[0]) importData(e.target.files[0]); e.target.value = ""; });
  $("#btnChangePw").addEventListener("click", () => { $("#newPw").value = ""; $("#newPw2").value = ""; openModal("#pwModal"); });

  // モーダル保存
  $("#productSave").addEventListener("click", saveProduct);
  $("#itemSave").addEventListener("click", saveItem);
  $("#pwChangeSave").addEventListener("click", changePassword);

  // モーダルを閉じる（×/キャンセル/背景クリック）
  $$("[data-close]").forEach((b) => b.addEventListener("click", () => b.closest(".modal-backdrop").classList.remove("show")));
  $$(".modal-backdrop").forEach((m) => m.addEventListener("click", (e) => { if (e.target === m) m.classList.remove("show"); }));
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") closeAllModals(); });

  // リスト内のアクション（イベント委譲）
  $("#list").addEventListener("click", (e) => {
    const btn = e.target.closest("[data-act]");
    if (!btn) return;
    const act = btn.dataset.act, pid = btn.dataset.p, iid = btn.dataset.i;
    if (act === "add-item") openItemModal(pid, null);
    else if (act === "edit-item") openItemModal(pid, iid);
    else if (act === "del-item") deleteItem(pid, iid);
    else if (act === "edit-product") openProductModal(pid);
    else if (act === "del-product") deleteProduct(pid);
  });
}

/* ---------- 起動 ---------- */
(async function init() {
  await loadData();
  bindEvents();
  // セッション中に管理者ログイン済みなら維持（タブを閉じると解除）
  try { if (sessionStorage.getItem(SESSION_ADMIN_KEY) === "1") isAdmin = true; } catch (e) {}
  setAdmin(isAdmin);
})();
