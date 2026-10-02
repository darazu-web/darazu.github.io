/* 検査情報 管理画面（スタンドアロン版）
 * サーバーにログインした管理者だけがデータを保存できる。 */
(function () {
  'use strict';

  var esc = Insp.esc;
  var $ = function (id) { return document.getElementById(id); };

  var userLogin = '';
  var etag = '';
  var data = null;
  var dirty = false;
  var sel = { productId: '', itemId: '' }; // itemId '' = 製品情報

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

  /* ---------- server API ---------- */
  function api(method, url, body, headers) {
    var h = { 'X-Insp-Request': '1' };
    if (body !== undefined) h['Content-Type'] = 'application/json';
    Object.keys(headers || {}).forEach(function (k) { h[k] = headers[k]; });
    return fetch(url, {
      method: method,
      headers: h,
      body: body !== undefined ? JSON.stringify(body) : undefined,
      credentials: 'same-origin',
      cache: 'no-store'
    }).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (j) {
        if (!r.ok) {
          var e = new Error(j.error || ('HTTP ' + r.status));
          e.status = r.status;
          throw e;
        }
        j._etag = r.headers.get('ETag') || '';
        return j;
      });
    });
  }

  function fetchData() {
    return fetch('data.json', { cache: 'no-store', credentials: 'same-origin' }).then(function (r) {
      if (!r.ok) throw new Error('データの読み込みに失敗しました (HTTP ' + r.status + ')');
      etag = r.headers.get('ETag') || '';
      return r.json();
    }).then(Insp.normalize);
  }

  /* ---------- login ---------- */
  function login(e) {
    if (e) e.preventDefault();
    var u = $('userInput').value.trim(), p = $('passInput').value;
    if (!u || !p) { showMsg($('loginMsg'), 'ユーザー名とパスワードを入力してください'); return; }
    $('loginBtn').disabled = true;
    api('POST', 'api/login', { username: u, password: p })
      .then(function (res) {
        $('passInput').value = '';
        showMsg($('loginMsg'), '');
        return fetchData().then(function (d) { startEditing(d, res.user); });
      })
      .catch(function (err) { showMsg($('loginMsg'), err.message); })
      .then(function () { $('loginBtn').disabled = false; });
  }

  function logout() {
    if (dirty && !confirm('保存していない変更があります。破棄してログアウトしますか？')) return;
    dirty = false;
    api('POST', 'api/logout').catch(function () { /* ignore */ }).then(function () { location.reload(); });
  }

  function sessionExpired() {
    flash('ログインの有効期限が切れました。「JSON出力」で編集内容を控えてから、ログインし直してください。');
  }

  function startEditing(d, who) {
    data = d;
    userLogin = who;
    sel.productId = data.products[0] ? data.products[0].id : '';
    sel.itemId = '';
    $('loginView').hidden = true;
    $('editView').hidden = false;
    $('whoami').textContent = who + ' でログイン中';
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
    var msg = prompt('変更内容のメモ（履歴に残ります）', '検査情報を更新');
    if (msg === null) return;
    $('saveBtn').disabled = true;
    flash('保存中…', 'ok');
    api('PUT', 'api/data', { data: data, message: msg || '検査情報を更新' }, { 'If-Match': etag })
      .then(function (res) {
        etag = res.etag;
        data.updatedAt = res.updatedAt;
        data.updatedBy = userLogin;
        setDirty(false);
        flash('保存しました。閲覧画面を開き直すと反映されます。', 'ok');
      })
      .catch(function (e) {
        if (e.status === 409) {
          flash('他の管理者が先に更新したため保存できませんでした。「JSON出力」で手元に控えてから、ページを再読み込みして最新の内容に反映してください。');
        } else if (e.status === 401) {
          sessionExpired();
        } else {
          flash('保存に失敗しました: ' + e.message);
        }
      })
      .then(function () { $('saveBtn').disabled = false; });
  }

  /* ---------- history ---------- */
  function openHistory() {
    var body = $('historyBody');
    body.innerHTML = '<p class="help">読み込み中…</p>';
    $('historyDialog').showModal();
    api('GET', 'api/history').then(function (res) {
      if (!res.history.length) { body.innerHTML = '<p class="help">まだ履歴はありません。</p>'; return; }
      body.innerHTML = '<table class="eq"><thead><tr><th>保存日時</th><th>保存した人</th><th>メモ</th><th></th></tr></thead><tbody>' +
        res.history.map(function (h, i) {
          return '<tr><td>' + esc(Insp.formatDate(h.savedAt) || '—') + (i === 0 ? ' <span class="badge">現在</span>' : '') + '</td>' +
            '<td>' + esc(h.user || '—') + '</td><td>' + esc(h.message) + '</td>' +
            '<td><button type="button" class="btn small" data-hid="' + esc(h.id) + '">この版を読み込む</button></td></tr>';
        }).join('') + '</tbody></table>';
    }).catch(function (e) {
      if (e.status === 401) { $('historyDialog').close(); sessionExpired(); return; }
      body.innerHTML = '<div class="msg err">' + esc(e.message) + '</div>';
    });
  }

  function loadHistory(hid) {
    if (dirty && !confirm('保存していない変更は失われます。この版を読み込みますか？')) return;
    api('GET', 'api/history/' + encodeURIComponent(hid)).then(function (d) {
      delete d._etag;
      data = Insp.normalize(d);
      sel.productId = data.products[0] ? data.products[0].id : '';
      sel.itemId = '';
      changed(); renderAll();
      $('historyDialog').close();
      flash('過去の版を読み込みました。内容を確認して「保存（公開）」すると、この版に戻ります。', 'ok');
    }).catch(function (e) { flash('読み込めませんでした: ' + e.message); });
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
  $('loginForm').addEventListener('submit', login);
  $('logoutBtn').addEventListener('click', logout);
  $('saveBtn').addEventListener('click', save);
  $('historyBtn').addEventListener('click', openHistory);
  $('historyClose').addEventListener('click', function () { $('historyDialog').close(); });
  $('historyBody').addEventListener('click', function (e) {
    var b = e.target.closest('button[data-hid]');
    if (b) loadHistory(b.dataset.hid);
  });
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

  // すでにログインしていれば、そのまま編集画面へ
  api('GET', 'api/me').then(function (res) {
    return fetchData().then(function (d) { startEditing(d, res.user); });
  }).catch(function () { $('userInput').focus(); });
})();
