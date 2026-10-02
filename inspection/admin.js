/* 検査情報 管理画面
 * 保存は GitHub Contents API で data.json を更新する。
 * 書き込み権限のあるトークンを持つ管理者だけが変更を公開できる。 */
(function () {
  'use strict';

  var esc = Insp.esc;
  var $ = function (id) { return document.getElementById(id); };

  var DEFAULTS = { repo: 'darazu-web/darazu.github.io', branch: 'main', path: 'inspection/data.json' };
  var CFG_KEY = 'insp.admin.cfg';
  var TOKEN_KEY = 'insp.admin.token';

  var cfg = loadCfg();
  var token = '';
  var userLogin = '';
  var fileSha = '';
  var data = null;
  var dirty = false;
  var sel = { productId: '', itemId: '' }; // itemId '' = 製品情報

  /* ---------- storage ---------- */
  function loadCfg() {
    try {
      var c = JSON.parse(localStorage.getItem(CFG_KEY) || '{}');
      return { repo: c.repo || DEFAULTS.repo, branch: c.branch || DEFAULTS.branch, path: c.path || DEFAULTS.path };
    } catch (e) { return Object.assign({}, DEFAULTS); }
  }
  function saveCfg() { try { localStorage.setItem(CFG_KEY, JSON.stringify(cfg)); } catch (e) { /* ignore */ } }
  function ssGet(k) { try { return sessionStorage.getItem(k) || ''; } catch (e) { return ''; } }
  function ssSet(k, v) { try { if (v) sessionStorage.setItem(k, v); else sessionStorage.removeItem(k); } catch (e) { /* ignore */ } }

  /* ---------- messages ---------- */
  function showMsg(el, text, kind) {
    el.innerHTML = text ? '<div class="msg ' + (kind || 'err') + '">' + esc(text) + '</div>' : '';
  }
  var msgTimer = null;
  function flash(text, kind) {
    showMsg($('globalMsg'), text, kind);
    clearTimeout(msgTimer);
    if (kind === 'ok') msgTimer = setTimeout(function () { showMsg($('globalMsg'), ''); }, 5000);
  }

  /* ---------- GitHub API ---------- */
  function gh(method, url, body) {
    return fetch('https://api.github.com' + url, {
      method: method,
      headers: {
        'Accept': 'application/vnd.github+json',
        'Authorization': 'Bearer ' + token,
        'X-GitHub-Api-Version': '2022-11-28'
      },
      body: body ? JSON.stringify(body) : undefined,
      cache: 'no-store'
    }).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (j) {
        if (!r.ok) {
          var e = new Error(j.message || ('HTTP ' + r.status));
          e.status = r.status;
          throw e;
        }
        return j;
      });
    });
  }
  function b64ToUtf8(b64) {
    var bin = atob(b64.replace(/\s/g, ''));
    var bytes = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return new TextDecoder().decode(bytes);
  }
  function utf8ToB64(str) {
    var bytes = new TextEncoder().encode(str);
    var bin = '';
    for (var i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(bin);
  }
  function contentsUrl() {
    return '/repos/' + cfg.repo + '/contents/' + cfg.path.split('/').map(encodeURIComponent).join('/');
  }
  function fetchRemote() {
    return gh('GET', contentsUrl() + '?ref=' + encodeURIComponent(cfg.branch)).then(function (f) {
      fileSha = f.sha;
      return Insp.normalize(JSON.parse(b64ToUtf8(f.content)));
    });
  }

  /* ---------- login ---------- */
  function login() {
    token = $('tokenInput').value.trim();
    cfg.repo = $('repoInput').value.trim() || DEFAULTS.repo;
    cfg.branch = $('branchInput').value.trim() || DEFAULTS.branch;
    cfg.path = $('pathInput').value.trim() || DEFAULTS.path;
    if (!token) { showMsg($('loginMsg'), 'トークンを入力してください'); return; }
    saveCfg();
    $('loginBtn').disabled = true;
    showMsg($('loginMsg'), '確認中…', 'ok');
    Promise.all([gh('GET', '/user'), gh('GET', '/repos/' + cfg.repo)])
      .then(function (res) {
        userLogin = res[0].login;
        if (!res[1].permissions || !res[1].permissions.push) {
          throw new Error('このアカウント（' + userLogin + '）にはリポジトリへの書き込み権限がありません。管理者のみ編集できます。');
        }
        return fetchRemote();
      })
      .then(function (d) {
        ssSet(TOKEN_KEY, token);
        startEditing(d, userLogin);
      })
      .catch(function (e) {
        token = '';
        ssSet(TOKEN_KEY, '');
        var m = e.status === 401 ? 'トークンが無効です' : e.status === 404 ? 'リポジトリまたはデータファイルが見つからないか、アクセス権がありません' : e.message;
        showMsg($('loginMsg'), m);
      })
      .then(function () { $('loginBtn').disabled = false; });
  }

  function offline() {
    token = '';
    Insp.loadData().then(function (d) { startEditing(d, ''); })
      .catch(function (e) { showMsg($('loginMsg'), e.message); });
  }

  function logout() {
    if (dirty && !confirm('保存していない変更があります。破棄してログアウトしますか？')) return;
    dirty = false;
    token = '';
    ssSet(TOKEN_KEY, '');
    location.reload();
  }

  function startEditing(d, who) {
    data = d;
    userLogin = who;
    sel.productId = data.products[0] ? data.products[0].id : '';
    sel.itemId = '';
    $('loginView').hidden = true;
    $('editView').hidden = false;
    $('whoami').textContent = who ? who + ' でログイン中' : 'オフライン編集（保存不可・JSON出力のみ）';
    $('saveBtn').hidden = !who;
    setDirty(false);
    renderAll();
  }

  /* ---------- model helpers ---------- */
  function product() { return data.products.find(function (p) { return p.id === sel.productId; }) || null; }
  function item() {
    var p = product();
    return p ? p.items.find(function (i) { return i.id === sel.itemId; }) || null : null;
  }
  function setDirty(v) {
    dirty = v;
    $('dirtyFlag').textContent = v ? '● 未保存の変更あり' : '';
  }
  function changed() { setDirty(true); }
  function getPath(obj, path) { return path.split('.').reduce(function (o, k) { return o[k]; }, obj); }
  function setPath(obj, path, v) {
    var ks = path.split('.'), last = ks.pop();
    ks.reduce(function (o, k) { return o[k]; }, obj)[last] = v;
  }

  /* ---------- render ---------- */
  function renderAll() {
    renderProducts();
    renderList();
    renderEditor();
  }

  function renderProducts() {
    var s = $('productSelect');
    s.innerHTML = data.products.map(function (p) {
      return '<option value="' + esc(p.id) + '">' + esc((p.code ? p.code + '  ' : '') + (p.name || '(製品名未設定)')) + '</option>';
    }).join('') || '<option value="">（製品なし）</option>';
    s.value = sel.productId;
  }

  function renderList() {
    var p = product();
    var ul = $('editList');
    $('addItemBtn').disabled = !p;
    if (!p) { ul.innerHTML = '<li class="placeholder">「＋ 製品追加」から製品を登録してください</li>'; return; }
    var html = '<li><button type="button" data-sel=""' + (sel.itemId === '' ? ' class="active"' : '') + '>' +
      '<span class="item-no">◆</span><span>製品情報</span></button></li>';
    html += p.items.map(function (it, i) {
      return '<li class="edit-item-row">' +
        '<button type="button" data-sel="' + esc(it.id) + '"' + (it.id === sel.itemId ? ' class="active"' : '') + '>' +
        '<span class="item-no">' + esc(it.no) + '</span><span>' + esc(it.name || '(名称未設定)') + '</span></button>' +
        '<button type="button" class="icon-btn" title="上へ" data-act="up" data-idx="' + i + '"' + (i === 0 ? ' disabled' : '') + '>▲</button>' +
        '<button type="button" class="icon-btn" title="下へ" data-act="down" data-idx="' + i + '"' + (i === p.items.length - 1 ? ' disabled' : '') + '>▼</button>' +
        '</li>';
    }).join('');
    ul.innerHTML = html;
  }

  function input(label, path, value, attrs) {
    return '<label class="field"><span>' + esc(label) + '</span><input type="text" data-f="' + path + '" value="' + esc(value) + '"' + (attrs || '') + '></label>';
  }
  function area(label, path, value, help, rows) {
    return '<label class="field"><span>' + esc(label) + '</span>' +
      (help ? '<span class="help">' + esc(help) + '</span>' : '') +
      '<textarea data-f="' + path + '" rows="' + (rows || 4) + '">' + esc(value) + '</textarea></label>';
  }

  function rowsTable(type, rows) {
    return '<div class="field"><span>' + esc(type.label) + '</span>' +
      '<table class="rows"><thead><tr>' + type.cols.map(function (c) { return '<th>' + esc(c) + '</th>'; }).join('') + '<th></th></tr></thead><tbody>' +
      rows.map(function (r, i) {
        return '<tr>' + ['code', 'name', 'note'].map(function (col) {
          return '<td><input type="text" data-row="' + type.key + '" data-idx="' + i + '" data-col="' + col + '" value="' + esc(r[col]) + '"></td>';
        }).join('') +
          '<td class="act"><button type="button" class="icon-btn" title="削除" data-delrow="' + type.key + '" data-idx="' + i + '">✕</button></td></tr>';
      }).join('') +
      '</tbody></table>' +
      '<div><button type="button" class="btn small" data-addrow="' + type.key + '">＋ ' + esc(type.label) + 'を追加</button></div></div>';
  }

  function renderEditor() {
    var ed = $('editor');
    var p = product();
    if (!p) { ed.innerHTML = '<div class="placeholder">製品がありません。「＋ 製品追加」から登録してください。</div>'; return; }
    var it = item();
    if (!it) {
      ed.innerHTML =
        '<h2>製品情報</h2>' +
        '<div class="field-row">' + input('製品品番', 'p.code', p.code) + input('製品名', 'p.name', p.name) + '</div>' +
        area('説明・備考', 'p.description', p.description, '閲覧画面の製品トップと「設備まとめ」に表示されます', 3) +
        '<p class="help">検査項目数: ' + p.items.length + '</p>' +
        '<div style="display:flex;gap:8px;flex-wrap:wrap">' +
        '<button type="button" class="btn small" data-cmd="renumber">検査項目No.を上から 1, 2, 3… に振り直す</button>' +
        '<button type="button" class="btn small" data-cmd="dupProduct">この製品を複製</button>' +
        '<button type="button" class="btn small danger" data-cmd="delProduct">この製品を削除</button></div>';
      return;
    }
    var eq = it.equipment;
    ed.innerHTML =
      '<h2>検査項目の編集</h2>' +
      '<fieldset><legend>検査項目</legend><div class="field-row">' +
      input('No.', 'i.no', it.no) + input('検査項目名', 'i.name', it.name) + input('分類', 'i.category', it.category, ' placeholder="例：外観／電気特性／機能"') +
      '</div></fieldset>' +
      '<fieldset><legend>検査方法</legend>' +
      area('手順', 'i.method', it.method, '1行が1ステップになり、閲覧画面では番号付きで表示されます', 6) +
      area('判定基準', 'i.criteria', it.criteria, '', 3) +
      '</fieldset>' +
      '<fieldset><legend>使用設備</legend><div class="field-row">' +
      input('テスター品番', 'i.equipment.testerNo', eq.testerNo) + input('テスター名', 'i.equipment.testerName', eq.testerName) +
      '</div>' +
      Insp.EQ_TYPES.map(function (t) { return rowsTable(t, eq[t.key]); }).join('') +
      '</fieldset>' +
      '<fieldset><legend>特記事項・その他</legend>' +
      area('特記事項', 'i.notes', it.notes, '閲覧画面で目立つ警告枠として先頭に表示されます', 3) +
      area('その他', 'i.other', it.other, '', 3) +
      '</fieldset>' +
      '<div style="display:flex;gap:8px;flex-wrap:wrap">' +
      '<button type="button" class="btn small" data-cmd="dupItem">この項目を複製</button>' +
      '<button type="button" class="btn small danger" data-cmd="delItem">この項目を削除</button></div>';
  }

  /* ---------- editing actions ---------- */
  function onEditorInput(e) {
    var t = e.target;
    var p = product(), it = item();
    if (t.dataset.f) {
      var target = t.dataset.f.charAt(0) === 'p' ? p : it;
      setPath(target, t.dataset.f.slice(2), t.value);
      changed();
      if (/^i\.(no|name)$/.test(t.dataset.f)) renderList();
      if (/^p\.(code|name)$/.test(t.dataset.f)) renderProducts();
    } else if (t.dataset.row) {
      it.equipment[t.dataset.row][+t.dataset.idx][t.dataset.col] = t.value;
      changed();
    }
  }

  function nextNo(p) {
    var max = 0;
    p.items.forEach(function (i) { var n = parseInt(i.no, 10); if (n > max) max = n; });
    return String(max + 1);
  }

  function onEditorClick(e) {
    var b = e.target.closest('button');
    if (!b) return;
    var p = product(), it = item();
    if (b.dataset.addrow) {
      it.equipment[b.dataset.addrow].push({ code: '', name: '', note: '' });
      changed(); renderEditor();
      var inputs = document.querySelectorAll('input[data-row="' + b.dataset.addrow + '"][data-col="code"]');
      if (inputs.length) inputs[inputs.length - 1].focus();
    } else if (b.dataset.delrow) {
      it.equipment[b.dataset.delrow].splice(+b.dataset.idx, 1);
      changed(); renderEditor();
    } else if (b.dataset.cmd === 'delItem') {
      if (!confirm('検査項目「' + (it.no + ' ' + it.name).trim() + '」を削除しますか？')) return;
      p.items.splice(p.items.indexOf(it), 1);
      sel.itemId = '';
      changed(); renderAll();
    } else if (b.dataset.cmd === 'dupItem') {
      var copy = Insp.normItem(JSON.parse(JSON.stringify(it)));
      copy.id = Insp.uid('i');
      copy.no = nextNo(p);
      copy.name = it.name + '（コピー）';
      p.items.splice(p.items.indexOf(it) + 1, 0, copy);
      sel.itemId = copy.id;
      changed(); renderAll();
    } else if (b.dataset.cmd === 'delProduct') {
      if (!confirm('製品「' + p.name + '」と、その検査項目 ' + p.items.length + ' 件をすべて削除しますか？')) return;
      data.products.splice(data.products.indexOf(p), 1);
      sel.productId = data.products[0] ? data.products[0].id : '';
      sel.itemId = '';
      changed(); renderAll();
    } else if (b.dataset.cmd === 'renumber') {
      if (!confirm('現在の並び順で No. を 1 から振り直しますか？')) return;
      p.items.forEach(function (i, n) { i.no = String(n + 1); });
      changed(); renderList();
    } else if (b.dataset.cmd === 'dupProduct') {
      var cp = JSON.parse(JSON.stringify(p));
      cp.id = Insp.uid('p');
      cp.name = p.name + '（コピー）';
      cp.items.forEach(function (i) { i.id = Insp.uid('i'); });
      data.products.splice(data.products.indexOf(p) + 1, 0, cp);
      sel.productId = cp.id;
      sel.itemId = '';
      changed(); renderAll();
    }
  }

  function onListClick(e) {
    var b = e.target.closest('button');
    if (!b) return;
    var p = product();
    if (b.dataset.act) {
      var i = +b.dataset.idx, j = b.dataset.act === 'up' ? i - 1 : i + 1;
      if (j < 0 || j >= p.items.length) return;
      var tmp = p.items[i]; p.items[i] = p.items[j]; p.items[j] = tmp;
      changed(); renderList();
    } else if ('sel' in b.dataset) {
      sel.itemId = b.dataset.sel;
      renderList(); renderEditor();
      window.scrollTo(0, 0);
    }
  }

  function addProduct() {
    var p = { id: Insp.uid('p'), code: '', name: '新しい製品', description: '', items: [] };
    data.products.push(p);
    sel.productId = p.id;
    sel.itemId = '';
    changed(); renderAll();
    var f = document.querySelector('[data-f="p.code"]');
    if (f) f.focus();
  }

  function addItem() {
    var p = product();
    if (!p) return;
    var it = Insp.normItem({ no: nextNo(p) });
    p.items.push(it);
    sel.itemId = it.id;
    changed(); renderAll();
    var f = document.querySelector('[data-f="i.name"]');
    if (f) f.focus();
  }

  /* ---------- save / import / export ---------- */
  function serialize() {
    return JSON.stringify(data, null, 2) + '\n';
  }

  function save() {
    if (!token) return;
    var msg = prompt('変更内容のメモ（履歴に残ります）', '検査情報を更新');
    if (msg === null) return;
    data.updatedAt = new Date().toISOString();
    data.updatedBy = userLogin;
    $('saveBtn').disabled = true;
    flash('保存中…', 'ok');
    gh('PUT', contentsUrl(), {
      message: msg || '検査情報を更新',
      content: utf8ToB64(serialize()),
      sha: fileSha,
      branch: cfg.branch
    }).then(function (res) {
      fileSha = res.content.sha;
      setDirty(false);
      flash('保存しました。閲覧画面への反映には数分かかる場合があります。', 'ok');
    }).catch(function (e) {
      if (e.status === 409) {
        flash('他の管理者が先に更新したため保存できませんでした。「JSON出力」で手元に控えてから、ログインし直して最新の内容に反映してください。');
      } else {
        flash('保存に失敗しました: ' + e.message);
      }
    }).then(function () { $('saveBtn').disabled = false; });
  }

  function exportJson() {
    var blob = new Blob([serialize()], { type: 'application/json' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'data.json';
    document.body.appendChild(a);
    a.click();
    setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 0);
  }

  function importJson(file) {
    var r = new FileReader();
    r.onload = function () {
      try {
        var d = Insp.normalize(JSON.parse(r.result));
        if (!confirm('読み込んだ内容（製品 ' + d.products.length + ' 件）で編集中のデータを置き換えますか？')) return;
        data = d;
        sel.productId = data.products[0] ? data.products[0].id : '';
        sel.itemId = '';
        changed(); renderAll();
        flash('読み込みました。内容を確認して「保存（公開）」してください。', 'ok');
      } catch (e) {
        flash('JSONファイルを読み込めませんでした: ' + e.message);
      }
    };
    r.readAsText(file, 'utf-8');
  }

  /* ---------- init ---------- */
  $('repoInput').value = cfg.repo;
  $('branchInput').value = cfg.branch;
  $('pathInput').value = cfg.path;
  $('loginBtn').addEventListener('click', login);
  $('tokenInput').addEventListener('keydown', function (e) { if (e.key === 'Enter') login(); });
  $('offlineBtn').addEventListener('click', offline);
  $('logoutBtn').addEventListener('click', logout);
  $('saveBtn').addEventListener('click', save);
  $('exportBtn').addEventListener('click', exportJson);
  $('importBtn').addEventListener('click', function () { $('importFile').click(); });
  $('importFile').addEventListener('change', function (e) {
    if (e.target.files[0]) importJson(e.target.files[0]);
    e.target.value = '';
  });
  $('addProductBtn').addEventListener('click', addProduct);
  $('addItemBtn').addEventListener('click', addItem);
  $('productSelect').addEventListener('change', function (e) {
    sel.productId = e.target.value;
    sel.itemId = '';
    renderList(); renderEditor();
  });
  $('editList').addEventListener('click', onListClick);
  $('editor').addEventListener('input', onEditorInput);
  $('editor').addEventListener('click', onEditorClick);
  window.addEventListener('beforeunload', function (e) {
    if (dirty) { e.preventDefault(); e.returnValue = ''; }
  });

  var saved = ssGet(TOKEN_KEY);
  if (saved) { $('tokenInput').value = saved; login(); }
})();
