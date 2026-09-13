/*
 * qr.js - 設備ラベル用の最小 QR コード生成（JIS X 0510 / ISO/IEC 18004 モデル2）
 *
 * 社内ネットワークでは CDN が遮断されていることがあるため、外部ライブラリを使わずに
 * 同梱しています。インターネットに出られない端末でもラベルが印刷できます。
 *
 * 対応: バージョン 1〜10 / 誤り訂正レベル L・M・Q・H / 数字・英数字・バイト(UTF-8) モード
 * 設備の短縮番号（4桁）はバージョン1に収まります。
 *
 * 使い方:
 *   var m = QRLite.encode("0101");           // m.size, m.modules[r][c] (true=黒)
 *   QRLite.draw(canvasElement, "0101", { quiet: 4, scale: 4 });
 */
var QRLite = (function () {
  'use strict';

  // ---------- GF(256) ----------
  var EXP = new Array(512), LOG = new Array(256);
  (function () {
    var x = 1;
    for (var i = 0; i < 255; i++) { EXP[i] = x; LOG[x] = i; x <<= 1; if (x & 0x100) { x ^= 0x11D; } }
    for (var j = 255; j < 512; j++) { EXP[j] = EXP[j - 255]; }
  })();
  function gmul(a, b) { return (a === 0 || b === 0) ? 0 : EXP[LOG[a] + LOG[b]]; }

  function rsGenPoly(deg) {
    var g = [1];
    for (var i = 0; i < deg; i++) {
      var ng = [];
      for (var k = 0; k <= g.length; k++) { ng[k] = 0; }
      for (var j = 0; j < g.length; j++) {
        ng[j] ^= g[j];                      // × x
        ng[j + 1] ^= gmul(g[j], EXP[i]);    // × a^i
      }
      g = ng;
    }
    return g;
  }

  function rsRemainder(data, ecLen) {
    var gen = rsGenPoly(ecLen), res = data.slice(), i, j;
    for (i = 0; i < ecLen; i++) { res.push(0); }
    for (i = 0; i < data.length; i++) {
      var coef = res[i];
      if (coef !== 0) {
        for (j = 0; j < gen.length; j++) { res[i + j] ^= gmul(gen[j], coef); }
      }
    }
    return res.slice(data.length);
  }

  // ---------- 仕様表（バージョン1〜10） ----------
  // [誤り訂正符号語数/ブロック, グループ1ブロック数, グループ1データ語数, グループ2ブロック数, グループ2データ語数]
  var RS = {
    L: [null, [7,1,19,0,0], [10,1,34,0,0], [15,1,55,0,0], [20,1,80,0,0], [26,1,108,0,0],
              [18,2,68,0,0], [20,2,78,0,0], [24,2,97,0,0], [30,2,116,0,0], [18,2,68,2,69]],
    M: [null, [10,1,16,0,0], [16,1,28,0,0], [26,1,44,0,0], [18,2,32,0,0], [24,2,43,0,0],
              [16,4,27,0,0], [18,4,31,0,0], [22,2,38,2,39], [22,3,36,2,37], [26,4,43,1,44]],
    Q: [null, [13,1,13,0,0], [22,1,22,0,0], [18,2,17,0,0], [26,2,24,0,0], [18,2,15,2,16],
              [24,4,19,0,0], [18,2,14,4,15], [22,4,18,2,19], [20,4,16,4,17], [24,6,19,2,20]],
    H: [null, [17,1,9,0,0], [28,1,16,0,0], [22,2,13,0,0], [16,4,9,0,0], [22,2,11,2,12],
              [28,4,15,0,0], [26,4,13,1,14], [26,4,14,2,15], [24,4,12,4,13], [28,6,15,2,16]]
  };
  var TOTAL_CODEWORDS = [0, 26, 44, 70, 100, 134, 172, 196, 242, 292, 346];
  var REMAINDER_BITS  = [0, 0, 7, 7, 7, 7, 7, 0, 0, 0, 0];
  var ALIGN = [null, [], [6,18], [6,22], [6,26], [6,30], [6,34], [6,22,38], [6,24,42], [6,26,46], [6,28,50]];
  var VERSION_INFO = { 7: 0x07C94, 8: 0x085BC, 9: 0x09A99, 10: 0x0A4D3 };
  var EC_BITS = { L: 1, M: 0, Q: 3, H: 2 };
  var ALNUM = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:';

  // ---------- ビット列 ----------
  function Bits() { this.bits = []; }
  Bits.prototype.put = function (value, length) {
    for (var i = length - 1; i >= 0; i--) { this.bits.push((value >>> i) & 1); }
  };
  Bits.prototype.length = function () { return this.bits.length; };

  // ---------- モード判定 ----------
  function utf8Bytes(str) {
    var out = [], i, c;
    for (i = 0; i < str.length; i++) {
      c = str.charCodeAt(i);
      if (c < 0x80) { out.push(c); }
      else if (c < 0x800) { out.push(0xC0 | (c >> 6), 0x80 | (c & 63)); }
      else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < str.length) {
        var c2 = str.charCodeAt(++i);
        var cp = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
        out.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
      } else { out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63)); }
    }
    return out;
  }

  function chooseMode(text) {
    if (/^[0-9]*$/.test(text)) { return 'numeric'; }
    for (var i = 0; i < text.length; i++) { if (ALNUM.indexOf(text[i]) < 0) { return 'byte'; } }
    return 'alnum';
  }

  function countBits(mode, version) {
    if (version <= 9) { return mode === 'numeric' ? 10 : (mode === 'alnum' ? 9 : 8); }
    return mode === 'numeric' ? 12 : (mode === 'alnum' ? 11 : 16);
  }

  function writeData(bits, text, mode, version) {
    var i;
    if (mode === 'numeric') {
      bits.put(1, 4);
      bits.put(text.length, countBits(mode, version));
      for (i = 0; i + 2 < text.length; i += 3) { bits.put(parseInt(text.substr(i, 3), 10), 10); }
      var rest = text.length - i;
      if (rest === 1) { bits.put(parseInt(text.substr(i, 1), 10), 4); }
      else if (rest === 2) { bits.put(parseInt(text.substr(i, 2), 10), 7); }
    } else if (mode === 'alnum') {
      bits.put(2, 4);
      bits.put(text.length, countBits(mode, version));
      for (i = 0; i + 1 < text.length; i += 2) {
        bits.put(ALNUM.indexOf(text[i]) * 45 + ALNUM.indexOf(text[i + 1]), 11);
      }
      if (i < text.length) { bits.put(ALNUM.indexOf(text[i]), 6); }
    } else {
      var bytes = utf8Bytes(text);
      bits.put(4, 4);
      bits.put(bytes.length, countBits(mode, version));
      for (i = 0; i < bytes.length; i++) { bits.put(bytes[i], 8); }
    }
  }

  function dataCapacityBits(version, ec) {
    var t = RS[ec][version];
    return (t[1] * t[2] + t[3] * t[4]) * 8;
  }

  function pickVersion(text, mode, ec, minVersion) {
    for (var v = minVersion || 1; v <= 10; v++) {
      var probe = new Bits();
      writeData(probe, text, mode, v);
      if (probe.length() <= dataCapacityBits(v, ec)) { return v; }
    }
    return -1;
  }

  // ---------- 符号語の組み立て ----------
  function buildCodewords(text, mode, version, ec) {
    var t = RS[ec][version];
    var capacity = dataCapacityBits(version, ec);
    var bits = new Bits();
    writeData(bits, text, mode, version);

    var i;
    for (i = 0; i < 4 && bits.length() < capacity; i++) { bits.bits.push(0); }   // 終端
    while (bits.length() % 8 !== 0) { bits.bits.push(0); }                        // バイト境界
    var pad = [0xEC, 0x11], p = 0;
    while (bits.length() < capacity) { bits.put(pad[p++ % 2], 8); }

    var data = [];
    for (i = 0; i < bits.length(); i += 8) {
      var b = 0;
      for (var j = 0; j < 8; j++) { b = (b << 1) | bits.bits[i + j]; }
      data.push(b);
    }

    // ブロック分割
    var blocks = [], ecBlocks = [], offset = 0, n;
    for (n = 0; n < t[1]; n++) { blocks.push(data.slice(offset, offset + t[2])); offset += t[2]; }
    for (n = 0; n < t[3]; n++) { blocks.push(data.slice(offset, offset + t[4])); offset += t[4]; }
    for (n = 0; n < blocks.length; n++) { ecBlocks.push(rsRemainder(blocks[n], t[0])); }

    // インターリーブ
    var result = [], maxData = Math.max(t[2], t[4]), k;
    for (k = 0; k < maxData; k++) {
      for (n = 0; n < blocks.length; n++) { if (k < blocks[n].length) { result.push(blocks[n][k]); } }
    }
    for (k = 0; k < t[0]; k++) {
      for (n = 0; n < ecBlocks.length; n++) { result.push(ecBlocks[n][k]); }
    }
    return result;
  }

  // ---------- 行列 ----------
  function newMatrix(size) {
    var m = [], r, c;
    for (r = 0; r < size; r++) { m[r] = []; for (c = 0; c < size; c++) { m[r][c] = null; } }
    return m;
  }

  function placeFunctionPatterns(m, version) {
    var size = m.length, r, c, i;

    function finder(top, left) {
      for (r = -1; r <= 7; r++) {
        for (c = -1; c <= 7; c++) {
          var rr = top + r, cc = left + c;
          if (rr < 0 || rr >= size || cc < 0 || cc >= size) { continue; }
          var on = (r >= 0 && r <= 6 && (c === 0 || c === 6)) ||
                   (c >= 0 && c <= 6 && (r === 0 || r === 6)) ||
                   (r >= 2 && r <= 4 && c >= 2 && c <= 4);
          m[rr][cc] = on;
        }
      }
    }
    finder(0, 0); finder(0, size - 7); finder(size - 7, 0);

    // タイミングパターン
    for (i = 8; i < size - 8; i++) {
      if (m[6][i] === null) { m[6][i] = (i % 2 === 0); }
      if (m[i][6] === null) { m[i][6] = (i % 2 === 0); }
    }

    // 位置合わせパターン
    var pos = ALIGN[version];
    for (var a = 0; a < pos.length; a++) {
      for (var b = 0; b < pos.length; b++) {
        var pr = pos[a], pc = pos[b];
        if (m[pr][pc] !== null) { continue; }   // ファインダーと重なる位置は置かない
        for (r = -2; r <= 2; r++) {
          for (c = -2; c <= 2; c++) {
            m[pr + r][pc + c] = (Math.max(Math.abs(r), Math.abs(c)) !== 1);
          }
        }
      }
    }

    m[size - 8][8] = true;   // 常に黒のモジュール
  }

  function reserveFormatAreas(m) {
    var size = m.length, i;
    for (i = 0; i <= 8; i++) {
      if (m[8][i] === null) { m[8][i] = false; }
      if (m[i][8] === null) { m[i][8] = false; }
    }
    for (i = 0; i < 8; i++) {
      if (m[8][size - 1 - i] === null) { m[8][size - 1 - i] = false; }
      if (m[size - 1 - i][8] === null) { m[size - 1 - i][8] = false; }
    }
  }

  function placeVersionInfo(m, version) {
    if (version < 7) { return; }
    var size = m.length, bits = VERSION_INFO[version];
    for (var i = 0; i < 18; i++) {
      var on = ((bits >> i) & 1) === 1;
      var r = Math.floor(i / 3), c = i % 3;
      m[size - 11 + c][r] = on;
      m[r][size - 11 + c] = on;
    }
  }

  function placeData(m, codewords, version) {
    var size = m.length, bitIndex = 0, total = codewords.length * 8;
    var remainder = REMAINDER_BITS[version];

    function nextBit() {
      if (bitIndex < total) {
        var b = (codewords[bitIndex >> 3] >> (7 - (bitIndex & 7))) & 1;
        bitIndex++;
        return b === 1;
      }
      if (bitIndex < total + remainder) { bitIndex++; return false; }
      return false;
    }

    var upward = true;
    for (var right = size - 1; right >= 1; right -= 2) {
      if (right === 6) { right = 5; }     // 縦のタイミングパターン列は飛ばす
      for (var step = 0; step < size; step++) {
        var row = upward ? (size - 1 - step) : step;
        for (var k = 0; k < 2; k++) {
          var col = right - k;
          if (m[row][col] === null) { m[row][col] = nextBit(); }
        }
      }
      upward = !upward;
    }
  }

  function maskFn(id, r, c) {
    switch (id) {
      case 0: return (r + c) % 2 === 0;
      case 1: return r % 2 === 0;
      case 2: return c % 3 === 0;
      case 3: return (r + c) % 3 === 0;
      case 4: return (Math.floor(r / 2) + Math.floor(c / 3)) % 2 === 0;
      case 5: return ((r * c) % 2) + ((r * c) % 3) === 0;
      case 6: return ((((r * c) % 2) + ((r * c) % 3)) % 2) === 0;
      default: return (((((r + c) % 2)) + ((r * c) % 3)) % 2) === 0;
    }
  }

  function formatBits(ec, mask) {
    var data = (EC_BITS[ec] << 3) | mask;
    var rem = data;
    for (var i = 0; i < 10; i++) { rem = (rem << 1) ^ (((rem >> 9) & 1) * 0x537); }
    return ((data << 10) | rem) ^ 0x5412;
  }

  function placeFormat(m, ec, mask) {
    var size = m.length, bits = formatBits(ec, mask), i;
    function bit(k) { return ((bits >> k) & 1) === 1; }

    // 1つ目の複製: 左上ファインダーの右と下（縦がビット0〜、横がビット14まで）
    for (i = 0; i <= 5; i++) { m[i][8] = bit(i); }
    m[7][8] = bit(6);
    m[8][8] = bit(7);
    m[8][7] = bit(8);
    for (i = 9; i <= 14; i++) { m[8][14 - i] = bit(i); }

    // 2つ目の複製: 右上（横）と左下（縦）
    for (i = 0; i <= 7; i++) { m[8][size - 1 - i] = bit(i); }
    for (i = 8; i <= 14; i++) { m[size - 15 + i][8] = bit(i); }

    m[size - 8][8] = true;   // 常に黒のモジュール（2つ目の複製で上書きされるため最後に置き直す）
  }

  function penalty(m) {
    var size = m.length, score = 0, r, c, i, run, last;

    // 規則1: 同色の連続
    function scanLine(get) {
      run = 1; last = get(0);
      for (i = 1; i < size; i++) {
        var v = get(i);
        if (v === last) { run++; }
        else { if (run >= 5) { score += 3 + (run - 5); } run = 1; last = v; }
      }
      if (run >= 5) { score += 3 + (run - 5); }
    }
    for (r = 0; r < size; r++) { (function (rr) { scanLine(function (i) { return m[rr][i]; }); })(r); }
    for (c = 0; c < size; c++) { (function (cc) { scanLine(function (i) { return m[i][cc]; }); })(c); }

    // 規則2: 2×2 の同色ブロック
    for (r = 0; r < size - 1; r++) {
      for (c = 0; c < size - 1; c++) {
        var v0 = m[r][c];
        if (v0 === m[r][c + 1] && v0 === m[r + 1][c] && v0 === m[r + 1][c + 1]) { score += 3; }
      }
    }

    // 規則3: 1:1:3:1:1 に続く4モジュールの空白
    var p1 = [true, false, true, true, true, false, true, false, false, false, false];
    var p2 = [false, false, false, false, true, false, true, true, true, false, true];
    function matches(get, start, pat) {
      for (var k = 0; k < 11; k++) { if (get(start + k) !== pat[k]) { return false; } }
      return true;
    }
    for (r = 0; r < size; r++) {
      for (c = 0; c + 11 <= size; c++) {
        (function (rr, cc) {
          var get = function (i) { return m[rr][i]; };
          if (matches(get, cc, p1) || matches(get, cc, p2)) { score += 40; }
        })(r, c);
      }
    }
    for (c = 0; c < size; c++) {
      for (r = 0; r + 11 <= size; r++) {
        (function (rr, cc) {
          var get = function (i) { return m[i][cc]; };
          if (matches(get, rr, p1) || matches(get, rr, p2)) { score += 40; }
        })(r, c);
      }
    }

    // 規則4: 黒白の比率
    var dark = 0;
    for (r = 0; r < size; r++) { for (c = 0; c < size; c++) { if (m[r][c]) { dark++; } } }
    var percent = (dark * 100) / (size * size);
    score += Math.floor(Math.abs(percent - 50) / 5) * 10;

    return score;
  }

  // ---------- 本体 ----------
  function encode(text, options) {
    options = options || {};
    var ec = options.ec || 'M';
    if (!RS[ec]) { throw new Error('誤り訂正レベルは L / M / Q / H のいずれかです: ' + ec); }
    text = String(text === null || text === undefined ? '' : text);

    var mode = chooseMode(text);
    var version = pickVersion(text, mode, ec, options.minVersion);
    if (version < 0) {
      throw new Error('データが長すぎます（このQR実装はバージョン10までです）: ' + text.length + ' 文字');
    }

    var codewords = buildCodewords(text, mode, version, ec);
    if (codewords.length !== TOTAL_CODEWORDS[version]) {
      throw new Error('符号語数が合いません（内部エラー）: ' + codewords.length + ' / ' + TOTAL_CODEWORDS[version]);
    }

    var size = version * 4 + 17;
    var base = newMatrix(size);
    placeFunctionPatterns(base, version);
    placeVersionInfo(base, version);
    reserveFormatAreas(base);

    // 予約領域（形式情報）は後で上書きするので、データ配置前に「埋まっている」状態にする
    var reserved = [];
    for (var r = 0; r < size; r++) { reserved[r] = []; for (var c = 0; c < size; c++) { reserved[r][c] = base[r][c] !== null; } }

    placeData(base, codewords, version);

    // 8通りのマスクを試して最も減点の少ないものを選ぶ
    var best = null, bestScore = Infinity;
    for (var mask = 0; mask < 8; mask++) {
      var cand = [];
      for (var rr = 0; rr < size; rr++) {
        cand[rr] = [];
        for (var cc = 0; cc < size; cc++) {
          var v = base[rr][cc];
          cand[rr][cc] = reserved[rr][cc] ? v : (maskFn(mask, rr, cc) ? !v : v);
        }
      }
      placeFormat(cand, ec, mask);
      var s = penalty(cand);
      if (s < bestScore) { bestScore = s; best = cand; }
    }

    return { size: size, version: version, ec: ec, mode: mode, modules: best };
  }

  function draw(canvas, text, options) {
    options = options || {};
    var quiet = options.quiet === undefined ? 4 : options.quiet;
    var m = encode(text, options);
    var n = m.size + quiet * 2;
    var scale = options.scale || Math.max(1, Math.floor((options.pixels || 160) / n));

    canvas.width = n * scale;
    canvas.height = n * scale;
    var ctx = canvas.getContext('2d');
    ctx.fillStyle = options.light || '#ffffff';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.fillStyle = options.dark || '#000000';
    for (var r = 0; r < m.size; r++) {
      for (var c = 0; c < m.size; c++) {
        if (m.modules[r][c]) { ctx.fillRect((c + quiet) * scale, (r + quiet) * scale, scale, scale); }
      }
    }
    return m;
  }

  return { encode: encode, draw: draw };
})();

if (typeof module !== 'undefined' && module.exports) { module.exports = QRLite; }
