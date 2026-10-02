/* 検査情報アプリ 共通処理 */
(function (global) {
  'use strict';

  var DATA_URL = 'data.json';

  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function uid(prefix) {
    return (prefix || 'id') + '-' + Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
  }

  function lines(text) {
    return String(text || '')
      .split(/\r?\n/)
      .map(function (l) { return l.trim(); })
      .filter(Boolean);
  }

  function normRows(rows) {
    return (Array.isArray(rows) ? rows : []).map(function (r) {
      return { code: String(r && r.code || ''), name: String(r && r.name || ''), note: String(r && r.note || '') };
    });
  }

  function normItem(it) {
    it = it || {};
    var eq = it.equipment || {};
    return {
      id: it.id || uid('i'),
      no: String(it.no || ''),
      name: String(it.name || ''),
      category: String(it.category || ''),
      method: String(it.method || ''),
      criteria: String(it.criteria || ''),
      equipment: {
        testerNo: String(eq.testerNo || ''),
        testerName: String(eq.testerName || ''),
        peripherals: normRows(eq.peripherals),
        harnesses: normRows(eq.harnesses),
        software: normRows(eq.software)
      },
      notes: String(it.notes || ''),
      other: String(it.other || '')
    };
  }

  function normalize(data) {
    data = data || {};
    return {
      version: 1,
      updatedAt: data.updatedAt || '',
      updatedBy: data.updatedBy || '',
      products: (Array.isArray(data.products) ? data.products : []).map(function (p) {
        p = p || {};
        return {
          id: p.id || uid('p'),
          code: String(p.code || ''),
          name: String(p.name || ''),
          description: String(p.description || ''),
          items: (Array.isArray(p.items) ? p.items : []).map(normItem)
        };
      })
    };
  }

  function loadData() {
    return fetch(DATA_URL + '?t=' + Date.now(), { cache: 'no-store' })
      .then(function (r) {
        if (!r.ok) throw new Error('データの読み込みに失敗しました (HTTP ' + r.status + ')');
        return r.json();
      })
      .then(normalize);
  }

  function formatDate(iso) {
    if (!iso) return '';
    var d = new Date(iso);
    if (isNaN(d)) return '';
    function p(n) { return (n < 10 ? '0' : '') + n; }
    return d.getFullYear() + '/' + p(d.getMonth() + 1) + '/' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
  }

  var EQ_TYPES = [
    { key: 'peripherals', label: '周辺設備', cols: ['品番', '名称', '備考'] },
    { key: 'harnesses', label: 'ハーネス', cols: ['品番', '名称', '備考'] },
    { key: 'software', label: 'ソフトウェア', cols: ['バージョン', '名称', '備考'] }
  ];

  global.Insp = {
    DATA_URL: DATA_URL,
    esc: esc,
    uid: uid,
    lines: lines,
    normalize: normalize,
    normItem: normItem,
    loadData: loadData,
    formatDate: formatDate,
    EQ_TYPES: EQ_TYPES
  };
})(window);
