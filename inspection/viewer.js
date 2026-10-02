/* 検査情報ビューア（閲覧専用） */
(function () {
  'use strict';

  var esc = Insp.esc;
  var $ = function (id) { return document.getElementById(id); };
  var LAST_KEY = 'insp.lastProduct';

  var data = null;
  var state = { productId: '', itemId: '', view: 'items', query: '' };

  function storageGet(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
  function storageSet(k, v) { try { localStorage.setItem(k, v); } catch (e) { /* ignore */ } }

  function currentProduct() {
    return data.products.find(function (p) { return p.id === state.productId; }) || data.products[0] || null;
  }

  function itemText(it) {
    var eq = it.equipment;
    var parts = [it.no, it.name, it.category, it.method, it.criteria, it.notes, it.other, eq.testerNo, eq.testerName];
    Insp.EQ_TYPES.forEach(function (t) {
      eq[t.key].forEach(function (r) { parts.push(r.code, r.name, r.note); });
    });
    return parts.join('\n').toLowerCase();
  }

  function filteredItems(p) {
    if (!p) return [];
    var q = state.query.trim().toLowerCase();
    if (!q) return p.items;
    var words = q.split(/\s+/);
    return p.items.filter(function (it) {
      var t = itemText(it);
      return words.every(function (w) { return t.indexOf(w) !== -1; });
    });
  }

  /* ---------- URL hash ---------- */
  function readHash() {
    var h = new URLSearchParams(location.hash.slice(1));
    if (h.get('p')) state.productId = h.get('p');
    state.itemId = h.get('i') || '';
    state.view = h.get('v') === 'equipment' ? 'equipment' : 'items';
  }
  function writeHash() {
    var h = new URLSearchParams();
    if (state.productId) h.set('p', state.productId);
    if (state.view === 'equipment') h.set('v', 'equipment');
    else if (state.itemId) h.set('i', state.itemId);
    var s = '#' + h.toString();
    if (location.hash !== s) history.replaceState(null, '', s);
  }

  /* ---------- render ---------- */
  function renderProducts() {
    var sel = $('productSelect');
    sel.innerHTML = data.products.map(function (p) {
      return '<option value="' + esc(p.id) + '">' + esc((p.code ? p.code + '  ' : '') + p.name) + '</option>';
    }).join('');
    var p = currentProduct();
    if (p) { state.productId = p.id; sel.value = p.id; }
  }

  function renderList() {
    var p = currentProduct();
    document.querySelectorAll('.tabs button').forEach(function (b) {
      b.classList.toggle('active', b.dataset.view === state.view);
    });
    var list = $('itemList');
    if (!p) {
      $('listHead').textContent = '製品が登録されていません';
      list.innerHTML = '';
      return;
    }
    var items = filteredItems(p);
    $('listHead').textContent = state.query
      ? '検索結果 ' + items.length + ' / ' + p.items.length + ' 件'
      : '検査項目 ' + p.items.length + ' 件';
    list.innerHTML = items.map(function (it) {
      var active = state.view === 'items' && it.id === state.itemId;
      return '<li><button type="button" data-id="' + esc(it.id) + '"' + (active ? ' class="active"' : '') + '>' +
        '<span class="item-no">' + esc(it.no) + '</span>' +
        '<span>' + esc(it.name || '(名称未設定)') +
        (it.category ? '<span class="item-cat">' + esc(it.category) + '</span>' : '') +
        '</span></button></li>';
    }).join('') || '<li class="placeholder">該当する項目がありません</li>';
  }

  function textOrEmpty(t) {
    return t && t.trim() ? '<div class="text-block">' + esc(t) + '</div>' : '<div class="empty">なし</div>';
  }

  function eqTable(type, rows) {
    if (!rows.length) return '';
    return '<div class="table-wrap"><table class="eq"><caption>' + esc(type.label) + '</caption>' +
      '<thead><tr>' + type.cols.map(function (c) { return '<th>' + esc(c) + '</th>'; }).join('') + '</tr></thead><tbody>' +
      rows.map(function (r) {
        return '<tr><td class="code">' + esc(r.code) + '</td><td>' + esc(r.name) + '</td><td>' + esc(r.note) + '</td></tr>';
      }).join('') + '</tbody></table></div>';
  }

  function renderItem(p, it) {
    var eq = it.equipment;
    var steps = Insp.lines(it.method);
    var hasTester = eq.testerNo || eq.testerName;
    var eqHtml = '';
    if (hasTester) {
      eqHtml += '<dl class="kv"><dt>テスター品番</dt><dd>' + esc(eq.testerNo || '—') + '</dd>' +
        '<dt>テスター名</dt><dd>' + esc(eq.testerName || '—') + '</dd></dl>';
    }
    Insp.EQ_TYPES.forEach(function (t) { eqHtml += eqTable(t, eq[t.key]); });
    if (!eqHtml) eqHtml = '<div class="empty">なし</div>';

    var all = p.items;
    var idx = all.indexOf(it);
    var prev = all[idx - 1], next = all[idx + 1];

    var html = '';
    if (it.notes.trim()) {
      html += '<div class="section"><h3>特記事項 <span class="n">必ず確認</span></h3><div class="notice">' + esc(it.notes) + '</div></div>';
    }
    html +=
      '<div class="section"><h3>検査方法</h3>' +
      (steps.length
        ? '<ol class="steps">' + steps.map(function (s) { return '<li>' + esc(s) + '</li>'; }).join('') + '</ol>'
        : '<div class="empty">なし</div>') +
      '</div>' +
      (it.criteria.trim() ? '<div class="section"><h3>判定基準</h3>' + textOrEmpty(it.criteria) + '</div>' : '') +
      '<div class="section"><h3>使用設備</h3>' + eqHtml + '</div>' +
      (it.other.trim() ? '<div class="section"><h3>その他</h3>' + textOrEmpty(it.other) + '</div>' : '');

    $('detail').innerHTML =
      '<div class="detail-head"><h2>' + esc((it.no ? it.no + '. ' : '') + (it.name || '(名称未設定)')) + '</h2>' +
      (it.category ? '<span class="badge">' + esc(it.category) + '</span>' : '') + '</div>' +
      '<div class="product-line">' + esc((p.code ? p.code + ' ' : '') + p.name) + '</div>' +
      html +
      '<div class="pager no-print">' +
      (prev ? '<button class="btn" type="button" data-go="' + esc(prev.id) + '">← ' + esc(prev.no + ' ' + prev.name) + '</button>' : '<span></span>') +
      (next ? '<button class="btn primary" type="button" data-go="' + esc(next.id) + '">' + esc(next.no + ' ' + next.name) + ' →</button>' : '<span></span>') +
      '</div>';
  }

  function renderEquipmentSummary(p) {
    var testers = {};
    var groups = {};
    Insp.EQ_TYPES.forEach(function (t) { groups[t.key] = {}; });
    p.items.forEach(function (it) {
      var eq = it.equipment;
      if (eq.testerNo || eq.testerName) {
        var k = eq.testerNo + '\u0000' + eq.testerName;
        (testers[k] = testers[k] || { code: eq.testerNo, name: eq.testerName, used: [] }).used.push(it.no || it.name);
      }
      Insp.EQ_TYPES.forEach(function (t) {
        eq[t.key].forEach(function (r) {
          var k = r.code + '\u0000' + r.name;
          (groups[t.key][k] = groups[t.key][k] || { code: r.code, name: r.name, used: [] }).used.push(it.no || it.name);
        });
      });
    });

    function table(label, cols, map) {
      var rows = Object.keys(map).map(function (k) { return map[k]; });
      if (!rows.length) return '';
      return '<div class="table-wrap"><table class="eq"><caption>' + esc(label) + '（' + rows.length + '）</caption>' +
        '<thead><tr><th>' + esc(cols[0]) + '</th><th>' + esc(cols[1]) + '</th><th>使用する検査項目No.</th></tr></thead><tbody>' +
        rows.map(function (r) {
          return '<tr><td class="code">' + esc(r.code) + '</td><td>' + esc(r.name) + '</td><td>' + esc(r.used.join(', ')) + '</td></tr>';
        }).join('') + '</tbody></table></div>';
    }

    var body = table('テスター', ['テスター品番', 'テスター名'], testers);
    Insp.EQ_TYPES.forEach(function (t) { body += table(t.label, t.cols, groups[t.key]); });

    $('detail').innerHTML =
      '<div class="detail-head"><h2>使用設備まとめ</h2></div>' +
      '<div class="product-line">' + esc((p.code ? p.code + ' ' : '') + p.name) + ' ・検査準備時の確認用</div>' +
      (p.description ? '<div class="section text-block">' + esc(p.description) + '</div>' : '') +
      '<div class="section">' + (body || '<div class="empty">登録された設備はありません</div>') + '</div>';
  }

  function renderDetail() {
    var p = currentProduct();
    var layout = $('layout');
    if (!p) {
      $('detail').innerHTML = '<div class="placeholder">製品が登録されていません。管理者に登録を依頼してください。</div>';
      return;
    }
    if (state.view === 'equipment') {
      renderEquipmentSummary(p);
      return;
    }
    var it = p.items.find(function (x) { return x.id === state.itemId; });
    if (!it) {
      layout.classList.remove('show-detail');
      $('detail').innerHTML =
        '<div class="detail-head"><h2>' + esc(p.name) + '</h2></div>' +
        '<div class="product-line">' + esc(p.code) + '</div>' +
        (p.description ? '<div class="text-block">' + esc(p.description) + '</div>' : '') +
        '<div class="placeholder">左の一覧から検査項目を選択してください</div>';
      return;
    }
    renderItem(p, it);
  }

  function render() {
    renderList();
    renderDetail();
    writeHash();
  }

  function selectItem(id) {
    state.view = 'items';
    state.itemId = id;
    $('layout').classList.add('show-detail');
    render();
    window.scrollTo(0, 0);
  }

  /* ---------- events ---------- */
  function bind() {
    $('productSelect').addEventListener('change', function (e) {
      state.productId = e.target.value;
      state.itemId = '';
      storageSet(LAST_KEY, state.productId);
      $('layout').classList.remove('show-detail');
      render();
    });
    $('search').addEventListener('input', function (e) {
      state.query = e.target.value;
      renderList();
    });
    $('itemList').addEventListener('click', function (e) {
      var b = e.target.closest('button[data-id]');
      if (b) selectItem(b.dataset.id);
    });
    $('detail').addEventListener('click', function (e) {
      var b = e.target.closest('button[data-go]');
      if (b) selectItem(b.dataset.go);
    });
    document.querySelectorAll('.tabs button').forEach(function (b) {
      b.addEventListener('click', function () {
        state.view = b.dataset.view;
        if (state.view === 'equipment') $('layout').classList.add('show-detail');
        render();
      });
    });
    $('backBtn').addEventListener('click', function () {
      $('layout').classList.remove('show-detail');
      state.itemId = '';
      if (state.view === 'equipment') state.view = 'items';
      render();
    });
    $('printBtn').addEventListener('click', function () { window.print(); });
    document.addEventListener('keydown', function (e) {
      if (e.target.matches('input, select, textarea') || state.view !== 'items') return;
      var p = currentProduct();
      if (!p) return;
      var idx = p.items.findIndex(function (x) { return x.id === state.itemId; });
      if (e.key === 'ArrowRight' && idx < p.items.length - 1) selectItem(p.items[idx + 1].id);
      if (e.key === 'ArrowLeft' && idx > 0) selectItem(p.items[idx - 1].id);
    });
  }

  Insp.loadData().then(function (d) {
    data = d;
    state.productId = storageGet(LAST_KEY) || '';
    readHash();
    renderProducts();
    if (state.itemId || state.view === 'equipment') $('layout').classList.add('show-detail');
    $('updated').textContent = data.updatedAt ? '最終更新: ' + Insp.formatDate(data.updatedAt) : '';
    bind();
    render();
  }).catch(function (err) {
    $('detail').innerHTML = '<div class="placeholder">' + esc(err.message) + '</div>';
  });
})();
