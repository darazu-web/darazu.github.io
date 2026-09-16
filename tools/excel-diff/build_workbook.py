# -*- coding: utf-8 -*-
"""
一覧差分チェッカー (list-diff-checker.xlsx) を生成するスクリプト。

  python3 build_workbook.py [出力パス]

マクロを一切使わず、数式だけで 2 つの一覧の差分（追加 / 削除 / 変更 / 一致）を抽出する
Excel テンプレートを組み立てる。数式は Excel 2019 以降 / Microsoft 365 を対象とし、
TEXTJOIN は _xlfn. プレフィックス付きの配列数式として書き込む。
"""
import sys
from openpyxl import Workbook
from openpyxl.comments import Comment
from openpyxl.formatting.rule import FormulaRule
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter as gc
from openpyxl.workbook.defined_name import DefinedName
from openpyxl.worksheet.datavalidation import DataValidation
from openpyxl.worksheet.formula import ArrayFormula as AF

# ---------------------------------------------------------------- 定数
NROW = int(__import__("os").environ.get("DIFF_NROW", "3000"))   # 1 つの一覧が扱えるデータ行数
NCOL = 20            # 1 つの一覧が扱える列数 (A..T)
R1, R2 = 2, NROW + 1              # リストシートのデータ行範囲
LAST = gc(NCOL)                   # "T"
SEP = "␟"       # 複合キーの区切り (表示不能文字ではなく印字可能な希少文字)
OCC = "␞"       # 同一キーの出現番号区切り

S_INTRO, S_CFG, S_A, S_B, S_SUM, S_RES, S_CA, S_CB = (
    "はじめに", "設定", "リストA", "リストB", "サマリー", "差分結果", "計算A", "計算B")

FONT = "Meiryo UI"
NAVY, BLUE, GRAY = "1F3864", "2E5C8A", "F2F2F2"
F_TITLE = Font(name=FONT, size=16, bold=True, color=NAVY)
F_H1    = Font(name=FONT, size=11, bold=True, color="FFFFFF")
F_SEC   = Font(name=FONT, size=11, bold=True, color=NAVY)
F_BODY  = Font(name=FONT, size=10)
F_NOTE  = Font(name=FONT, size=9, color="7F7F7F")
F_BOLD  = Font(name=FONT, size=10, bold=True)
FILL_H  = PatternFill("solid", fgColor=NAVY)
FILL_H2 = PatternFill("solid", fgColor="DDEBF7")
FILL_IN = PatternFill("solid", fgColor="FFF2CC")     # 利用者が入力するセル
FILL_SEC= PatternFill("solid", fgColor=GRAY)
THIN    = Side(style="thin", color="BFBFBF")
BOX     = Border(left=THIN, right=THIN, top=THIN, bottom=THIN)

# 「記号・空白をすべて無視」で取り除く文字
STRIP_CHARS = [" ", "　", "\t", "-", "－", "‐", "–", "—", "ー",
               "_", ".", "．", "・", "/", "／", "(", ")", "（", "）",
               ",", "、", "　"]


def strip_chain(inner):
    """記号除去の SUBSTITUTE 連鎖を組み立てる。"""
    out = inner
    for ch in dict.fromkeys(STRIP_CHARS):
        out = 'SUBSTITUTE(%s,"%s","")' % (out, ch)
    return out


def norm_row(sheet_range, idx_ref):
    """比較用に正規化した 1 行ぶんの配列式（横 1×NCOL）。"""
    raw = 'INDEX(%s,%s,0)' % (sheet_range, idx_ref)
    normed = 'UPPER(ASC(TRIM(SUBSTITUTE(""&%s,"　"," "))))' % raw
    return 'IF(cfg_valnorm="する",%s,""&%s)' % (normed, raw)


def main(path):
    wb = Workbook()
    wb.calculation.fullCalcOnLoad = True
    intro = wb.active; intro.title = S_INTRO
    cfg = wb.create_sheet(S_CFG)
    sa  = wb.create_sheet(S_A)
    sb  = wb.create_sheet(S_B)
    smy = wb.create_sheet(S_SUM)
    res = wb.create_sheet(S_RES)
    ca  = wb.create_sheet(S_CA)
    cb  = wb.create_sheet(S_CB)

    A_DATA = "%s!$A$%d:$%s$%d" % (S_A, R1, LAST, R2)                       # リストA のデータ矩形
    A_HEAD = "%s!$A$1:$%s$1" % (S_A, LAST)
    B_HEAD = "%s!$A$1:$%s$1" % (S_B, LAST)
    CACHE_C1, CACHE_C2 = 14, 14 + NCOL - 1                                 # 計算B の B キャッシュ列
    B_CACHE = "%s!$%s$%d:$%s$%d" % (S_CB, gc(CACHE_C1), R1, gc(CACHE_C2), R2)
    FLAG_C1, FLAG_C2 = 17, 17 + NCOL - 1                                   # 計算A の比較フラグ列
    FLAGS = "$%s$1:$%s$1" % (gc(FLAG_C1), gc(FLAG_C2))

    # ============================================================ 設定シート
    cfg["A1"] = "比較の設定"; cfg["A1"].font = F_TITLE
    cfg["A2"] = "黄色のセルを選ぶだけです。変更すると差分結果は自動で計算し直されます。"
    cfg["A2"].font = F_NOTE

    def section(ws, row, text):
        ws.cell(row, 1, text).font = F_SEC
        for c in range(1, 6):
            ws.cell(row, c).fill = FILL_SEC

    def cfg_row(row, label, desc):
        cfg.cell(row, 1, label).font = F_BODY
        c = cfg.cell(row, 3); c.fill = FILL_IN; c.border = BOX; c.font = F_BOLD
        cfg.cell(row, 5, desc).font = F_NOTE

    section(cfg, 4, "① 行を突き合わせるキー列（リストA の見出しから選択）")
    cfg_row(5, "キー列 1（必須）", "2 つの一覧で「同じ行」と見なす目印になる列。社員ID・商品コードなど。")
    cfg_row(6, "キー列 2（任意）", "1 列だけでは重複する場合に指定。例）店舗コード＋商品コード。")
    cfg_row(7, "キー列 3（任意）", "空欄なら使いません。")
    section(cfg, 9, "② 値の比較から除外する列")
    cfg_row(10, "除外列 1", "更新日時など、差分として見たくない列を指定します。")
    cfg_row(11, "除外列 2", "")
    cfg_row(12, "除外列 3", "")
    section(cfg, 14, "③ キー照合での表記ゆれの吸収")
    cfg_row(15, "全角・半角を区別しない", 'ＡＢ１２３ と AB123 を同じ扱いにします。')
    cfg_row(16, "前後・連続の空白を無視", '"A001 " と "A001" を同じ扱いにします。')
    cfg_row(17, "大文字・小文字を区別しない", "a001 と A001 を同じ扱いにします。")
    cfg_row(18, "記号・空白をすべて無視", "ハイフン・中黒・括弧などを消してから照合します（強力なので通常は「しない」）。")
    section(cfg, 20, "④ 値そのものの比較")
    cfg_row(21, "表記ゆれを無視して比較する", "全角/半角・大文字小文字・前後の空白の違いを「変更なし」と見なします。")

    cfg["C5"], cfg["C6"], cfg["C7"] = "社員ID", "", ""
    cfg["C10"] = cfg["C11"] = cfg["C12"] = ""
    cfg["C15"], cfg["C16"], cfg["C17"], cfg["C18"] = "する", "する", "しない", "しない"
    cfg["C21"] = "する"

    dv_cols = DataValidation(type="list", formula1=A_HEAD, allow_blank=True)
    dv_cols.showErrorMessage = True
    dv_cols.errorStyle = "warning"
    dv_cols.errorTitle = "列名を確認してください"
    dv_cols.error = "リストA の見出し（1 行目）にある列名を選んでください。空欄なら「使わない」の意味になります。"
    dv_cols.showInputMessage = True
    dv_cols.promptTitle = "列を選択"
    dv_cols.prompt = "リストA の見出しから選びます。空欄のままなら使用しません。"
    cfg.add_data_validation(dv_cols)
    for r in (5, 6, 7, 10, 11, 12):
        dv_cols.add(cfg.cell(r, 3))
    dv_yn = DataValidation(type="list", formula1='"する,しない"', allow_blank=False)
    dv_yn.showErrorMessage = True
    dv_yn.errorTitle = "「する」か「しない」を選んでください"
    dv_yn.error = "この欄は「する」または「しない」のどちらかです。"
    cfg.add_data_validation(dv_yn)
    for r in (15, 16, 17, 18, 21):
        dv_yn.add(cfg.cell(r, 3))

    # 内部：キー列の列番号（A 側 / B 側）
    cfg["F4"] = "（内部計算）キー列の列番号"; cfg["F4"].font = F_NOTE
    cfg["G4"], cfg["H4"] = "A側", "B側"
    for i, r in enumerate((5, 6, 7)):
        cfg.cell(r, 7, '=IF(cfg_key%d="",0,IFERROR(MATCH(cfg_key%d,%s,0),0))' % (i + 1, i + 1, A_HEAD))
        cfg.cell(r, 8, '=IF(cfg_key%d="",0,IFERROR(MATCH(cfg_key%d,%s,0),0))' % (i + 1, i + 1, B_HEAD))
    for r in (4, 5, 6, 7):
        for c in (6, 7, 8):
            cfg.cell(r, c).font = F_NOTE
    cfg.column_dimensions["A"].width = 30
    cfg.column_dimensions["B"].width = 2
    cfg.column_dimensions["C"].width = 22
    cfg.column_dimensions["D"].width = 2
    cfg.column_dimensions["E"].width = 68
    for col in ("F", "G", "H"):
        cfg.column_dimensions[col].width = 12

    names = {"cfg_key1": "$C$5", "cfg_key2": "$C$6", "cfg_key3": "$C$7",
             "cfg_ex1": "$C$10", "cfg_ex2": "$C$11", "cfg_ex3": "$C$12",
             "cfg_width": "$C$15", "cfg_trim": "$C$16", "cfg_case": "$C$17",
             "cfg_sym": "$C$18", "cfg_valnorm": "$C$21",
             "ka1": "$G$5", "ka2": "$G$6", "ka3": "$G$7",
             "kb1": "$H$5", "kb2": "$H$6", "kb3": "$H$7"}
    for n, ref in names.items():
        wb.defined_names.add(DefinedName(n, attr_text="%s!%s" % (S_CFG, ref)))

    # ============================================================ リストA / リストB
    headers = ["社員ID", "氏名", "部署", "役職", "入社日", "月額給与"]
    rows_a = [["E001", "田中 太郎", "営業部", "主任", "2020/04/01", 420000],
              ["E002", "佐藤 花子", "開発部", "", "2019/10/01", 380000],
              ["E003", "鈴木 一郎", "総務部", "課長", "2015/04/01", 560000],
              ["E004", "高橋 次郎", "営業部", "", "2022/04/01", 320000],
              ["E005", "伊藤 三郎", "開発部", "主任", "2018/04/01", 450000]]
    rows_b = [["E001", "田中 太郎", "営業部", "課長", "2020/04/01", 460000],
              ["E002", "佐藤　花子", "開発部", "", "2019/10/01", 380000],
              ["E003", "鈴木 一郎", "総務部", "課長", "2015/04/01", 560000],
              ["E005", "伊藤 三郎", "品質保証部", "主任", "2018/04/01", 450000],
              ["E006", "渡辺 四郎", "開発部", "", "2024/04/01", 300000]]

    for ws, rows, label in ((sa, rows_a, "A"), (sb, rows_b, "B")):
        for j, h in enumerate(headers, 1):
            c = ws.cell(1, j, h); c.font = F_BOLD; c.fill = FILL_H2; c.border = BOX
            c.alignment = Alignment(horizontal="center")
        for i, row in enumerate(rows, 2):
            for j, v in enumerate(row, 1):
                c = ws.cell(i, j, v); c.font = F_BODY
                if isinstance(v, int):
                    c.number_format = "#,##0"
        ws.freeze_panes = "A2"
        ws.cell(1, 1).comment = Comment(
            "1 行目＝見出し、2 行目以降＝データです。\n"
            "サンプルを削除して自分のデータを貼り付けてください。\n"
            "扱える範囲は %d 行 × %d 列（A〜%s列）です。" % (NROW, NCOL, LAST), "一覧差分チェッカー", 240, 320)
        for j in range(1, NCOL + 1):
            ws.column_dimensions[gc(j)].width = 14
        ws.column_dimensions["A"].width = 12
        ws.column_dimensions["B"].width = 16

    # ============================================================ 計算A / 計算B
    def build_calc(ws, side):
        """side='A' なら リストA を主、'B' なら リストB を主として突き合わせ表を作る。"""
        is_a = side == "A"
        src = S_A if is_a else S_B
        other = S_CB if is_a else S_CA
        kn = ("ka1", "ka2", "ka3") if is_a else ("kb1", "kb2", "kb3")
        head = ["行", "有効", "生キー", "全半角", "空白", "大小", "正規化キー",
                "出現番号", "同一キー数", "照合キー",
                "相手の行", "差異列数", "差異内容", "状態", "警告"] if is_a else \
               ["行", "有効", "生キー", "全半角", "空白", "大小", "正規化キー",
                "出現番号", "同一キー数", "照合キー", "相手の行", "状態", "警告"]
        for j, h in enumerate(head, 1):
            c = ws.cell(1, j, h); c.font = F_H1; c.fill = FILL_H

        for r in range(R1, R2 + 1):
            rowrange = "%s!$A%d:$%s%d" % (src, r, LAST, r)
            ws.cell(r, 1, "=ROW()-1")
            ws.cell(r, 2, '=IF(COUNTA(%s)>0,1,0)' % rowrange)
            parts = ['IF(%s=0,"",""&INDEX(%s,1,%s))' % (kn[0], rowrange, kn[0])]
            for k in (kn[1], kn[2]):
                parts.append('IF(%s=0,"","%s"&INDEX(%s,1,%s))' % (k, SEP, rowrange, k))
            ws.cell(r, 3, '=IF($B%d=0,"",%s)' % (r, "&".join(parts)))
            ws.cell(r, 4, '=IF(cfg_width="する",ASC(SUBSTITUTE($C%d,"　"," ")),$C%d)' % (r, r))
            ws.cell(r, 5, '=IF(cfg_trim="する",TRIM($D%d),$D%d)' % (r, r))
            ws.cell(r, 6, '=IF(cfg_case="する",UPPER($E%d),$E%d)' % (r, r))
            ws.cell(r, 7, '=IF($B%d=0,"",IF(cfg_sym="する",%s,$F%d))' % (r, strip_chain("$F%d" % r), r))
            ws.cell(r, 8, '=IF($B%d=0,"",COUNTIFS($B$%d:$B%d,1,$G$%d:$G%d,$G%d))' % (r, R1, r, R1, r, r))
            ws.cell(r, 9, '=IF($B%d=0,"",COUNTIFS($B$%d:$B$%d,1,$G$%d:$G$%d,$G%d))' % (r, R1, R2, R1, R2, r))
            ws.cell(r, 10, '=IF($B%d=0,"",$G%d&"%s"&$H%d)' % (r, r, OCC, r))
            ws.cell(r, 11, '=IF($B%d=0,0,IFERROR(MATCH($J%d,%s!$J$%d:$J$%d,0),0))' % (r, r, other, R1, R2))
            if is_a:
                na = norm_row(A_DATA, "$A%d" % r)
                nb = norm_row(B_CACHE, "$K%d" % r)
                ws.cell(r, 12, '=IF($K%d=0,"",SUMPRODUCT(%s*(%s<>%s)))' % (r, FLAGS, na, nb))
                detail = ('"【"&%s&"】"&(""&INDEX(%s,$A%d,0))&" → "&(""&INDEX(%s,$K%d,0))'
                          % (A_HEAD, A_DATA, r, B_CACHE, r))
                ws.cell(r, 13, AF("M%d" % r,
                        '=IF(OR($K%d=0,$L%d=0),"",_xlfn.TEXTJOIN(" / ",TRUE,IF((%s=1)*(%s<>%s),%s,"")))'
                        % (r, r, FLAGS, na, nb, detail)))
                ws.cell(r, 14, '=IF($B%d=0,"",IF($K%d=0,"Aのみ",IF($L%d=0,"一致","変更")))' % (r, r, r))
                ws.cell(r, 15,
                        '=IF($B{r}=0,"",IF($G{r}="","キーが空白",IF($I{r}>1,"Aでキー重複("&$I{r}&"件)",'
                        'IF($K{r}=0,"",IF(N(INDEX({o}!$I${a}:$I${b},$K{r}))>1,"Bでキー重複","")))))'
                        .format(r=r, o=S_CB, a=R1, b=R2))
            else:
                ws.cell(r, 12, '=IF($B%d=0,"",IF($K%d=0,"Bのみ",""))' % (r, r))
                ws.cell(r, 13,
                        '=IF($B{r}=0,"",IF($G{r}="","キーが空白",IF($I{r}>1,"Bでキー重複("&$I{r}&"件)","")))'
                        .format(r=r))

    build_calc(ca, "A")
    build_calc(cb, "B")

    # 計算A: 比較対象フラグ
    #   1 = 「見出しがある」「キー列でも除外列でもない」「リストB にも同じ見出しがある」列
    for j in range(1, NCOL + 1):
        L = gc(j)
        cl = gc(CACHE_C1 + j - 1)          # 計算B!<列>$1 に B 側の対応列番号が入る（0 なら B に無い列）
        ca.cell(1, FLAG_C1 + j - 1,
                '=IF({s}!{L}$1="",0,IF({cb}!{cl}$1=0,0,IF(OR({s}!{L}$1=cfg_key1,{s}!{L}$1=cfg_key2,'
                '{s}!{L}$1=cfg_key3,{s}!{L}$1=cfg_ex1,{s}!{L}$1=cfg_ex2,{s}!{L}$1=cfg_ex3),0,1)))'
                .format(s=S_A, L=L, cb=S_CB, cl=cl))

    # 計算B: 列名でリストA の並びに読み替えた B の値キャッシュ（列の並び順が違っても比較できる）
    for j in range(1, NCOL + 1):
        cl = gc(CACHE_C1 + j - 1)
        cb.cell(1, CACHE_C1 + j - 1,
                '=IF({a}!{L}$1="",0,IFERROR(MATCH({a}!{L}$1,{bh},0),0))'.format(a=S_A, L=gc(j), bh=B_HEAD))
        for r in range(R1, R2 + 1):
            ref = 'INDEX(%s!$A%d:$%s%d,1,%s$1)' % (S_B, r, LAST, r, cl)
            cb.cell(r, CACHE_C1 + j - 1,
                    '=IF($B%d=0,"",IF(%s$1=0,"",IF(%s="","",%s)))' % (r, cl, ref, ref))

    for ws in (ca, cb):
        ws.sheet_state = "hidden"
        ws.freeze_panes = "A2"

    # ============================================================ 差分結果
    res["A1"] = "差分結果"; res["A1"].font = F_TITLE
    res["A2"] = ("「状態」列でフィルターしてください（変更 / Aのみ＝Bで削除 / Bのみ＝Bで追加 / 一致）。"
                 "※このシートは数式です。並べ替えるときは値として別シートに貼り付けてから行ってください。")
    res["A2"].font = F_NOTE
    res["A3"] = ('="一致 "&{s}!$C$7&" 件 ／ 変更 "&{s}!$C$8&" 件 ／ Aのみ（削除）"&{s}!$C$9'
                '&" 件 ／ Bのみ（追加）"&{s}!$C$10&" 件"').format(s=S_SUM)
    res["A3"].font = F_BOLD
    res_head = ["状態", "参照元", "元の行", "キー", "差異列数", "差異内容", "警告"]
    for j, h in enumerate(res_head, 1):
        c = res.cell(4, j, h); c.font = F_H1; c.fill = FILL_H; c.border = BOX
        c.alignment = Alignment(horizontal="center", vertical="center")
    for j in range(1, NCOL + 1):
        c = res.cell(4, 7 + j, '=IF(%s!%s$1="","",%s!%s$1)' % (S_A, gc(j), S_A, gc(j)))
        c.font = F_H1; c.fill = PatternFill("solid", fgColor=BLUE); c.border = BOX
        c.alignment = Alignment(horizontal="center", vertical="center")

    top = 5
    for i in range(1, NROW + 1):                 # A 側ブロック
        r, cr = top + i - 1, R1 + i - 1
        res.cell(r, 1, '=IF(%s!$N%d="","",%s!$N%d)' % (S_CA, cr, S_CA, cr))
        res.cell(r, 2, '=IF($A%d="","","A")' % r)
        res.cell(r, 3, '=IF($A%d="","",%d)' % (r, cr))
        res.cell(r, 4, '=IF($A%d="","",SUBSTITUTE(%s!$C%d,"%s"," / "))' % (r, S_CA, cr, SEP))
        res.cell(r, 5, '=IF($A%d="","",IF(%s!$L%d="","",%s!$L%d))' % (r, S_CA, cr, S_CA, cr))
        res.cell(r, 6, '=IF($A%d="","",%s!$M%d)' % (r, S_CA, cr))
        res.cell(r, 7, '=IF($A%d="","",%s!$O%d)' % (r, S_CA, cr))
        for j in range(1, NCOL + 1):
            ref = '%s!%s%d' % (S_A, gc(j), cr)
            res.cell(r, 7 + j, '=IF($A%d="","",IF(%s="","",%s))' % (r, ref, ref))

    top2 = top + NROW
    for i in range(1, NROW + 1):                 # B 側ブロック（B にしかない行だけ表示）
        r, cr = top2 + i - 1, R1 + i - 1
        res.cell(r, 1, '=IF(%s!$L%d="","",%s!$L%d)' % (S_CB, cr, S_CB, cr))
        res.cell(r, 2, '=IF($A%d="","","B")' % r)
        res.cell(r, 3, '=IF($A%d="","",%d)' % (r, cr))
        res.cell(r, 4, '=IF($A%d="","",SUBSTITUTE(%s!$C%d,"%s"," / "))' % (r, S_CB, cr, SEP))
        res.cell(r, 7, '=IF($A%d="","",%s!$M%d)' % (r, S_CB, cr))
        for j in range(1, NCOL + 1):
            res.cell(r, 7 + j, '=IF($A%d="","",%s!%s%d)' % (r, S_CB, gc(CACHE_C1 + j - 1), cr))

    last_row = top2 + NROW - 1
    res.auto_filter.ref = "A4:%s%d" % (gc(7 + NCOL), last_row)
    res.freeze_panes = "H5"
    for w, col in ((10, "A"), (8, "B"), (8, "C"), (26, "D"), (9, "E"), (60, "F"), (20, "G")):
        res.column_dimensions[col].width = w
    for j in range(1, NCOL + 1):
        res.column_dimensions[gc(7 + j)].width = 14
    rng = "A%d:%s%d" % (top, gc(7 + NCOL), last_row)
    for cond, color in (('$A5="変更"', "FFF2CC"), ('$A5="Aのみ"', "FCE4E4"), ('$A5="Bのみ"', "E2EFDA")):
        res.conditional_formatting.add(rng, FormulaRule(formula=[cond],
                                       fill=PatternFill("solid", fgColor=color), stopIfTrue=False))
    res.conditional_formatting.add(rng, FormulaRule(formula=['$A5="一致"'],
                                   font=Font(name=FONT, size=10, color="A6A6A6"), stopIfTrue=False))
    res.conditional_formatting.add("G%d:G%d" % (top, last_row), FormulaRule(
        formula=['$G5<>""'], font=Font(name=FONT, size=10, bold=True, color="C00000"), stopIfTrue=False))

    # ============================================================ サマリー
    smy["A1"] = "サマリー"; smy["A1"].font = F_TITLE
    smy["A2"] = "設定を変えるとここも自動で更新されます。▲ が付いた行は設定やデータを見直してください。"
    smy["A2"].font = F_NOTE
    NA_ST = "%s!$N$%d:$N$%d" % (S_CA, R1, R2)
    NB_ST = "%s!$L$%d:$L$%d" % (S_CB, R1, R2)

    def put(row, label, formula, bold=False, fmt="#,##0"):
        c1 = smy.cell(row, 2, label); c1.font = F_BOLD if bold else F_BODY
        c2 = smy.cell(row, 3, formula); c2.font = F_BOLD if bold else F_BODY
        if fmt:
            c2.number_format = fmt
        c1.border = BOX; c2.border = BOX

    section(smy, 4, "件数")
    put(5, "リストA の有効行数", '=SUMPRODUCT(%s!$B$%d:$B$%d)' % (S_CA, R1, R2))
    put(6, "リストB の有効行数", '=SUMPRODUCT(%s!$B$%d:$B$%d)' % (S_CB, R1, R2))
    put(7, "一致（差異なし）", '=COUNTIF(%s,"一致")' % NA_ST)
    put(8, "変更（値の差異あり）", '=COUNTIF(%s,"変更")' % NA_ST)
    put(9, "Aのみ（B で削除された行）", '=COUNTIF(%s,"Aのみ")' % NA_ST)
    put(10, "Bのみ（B で追加された行）", '=COUNTIF(%s,"Bのみ")' % NB_ST)
    put(11, "差分の合計", "=C8+C9+C10", bold=True)

    section(smy, 13, "チェック")
    checks = [
        (14, "キー列 1", '=IF(cfg_key1="","▲ キー列1が未設定です",IF(ka1=0,"▲ リストAに「"&cfg_key1&"」列がありません",'
                        'IF(kb1=0,"▲ リストBに「"&cfg_key1&"」列がありません","OK")))'),
        (15, "キー列 2", '=IF(cfg_key2="","（未使用）",IF(ka2=0,"▲ リストAに「"&cfg_key2&"」列がありません",'
                        'IF(kb2=0,"▲ リストBに「"&cfg_key2&"」列がありません","OK")))'),
        (16, "キー列 3", '=IF(cfg_key3="","（未使用）",IF(ka3=0,"▲ リストAに「"&cfg_key3&"」列がありません",'
                        'IF(kb3=0,"▲ リストBに「"&cfg_key3&"」列がありません","OK")))'),
        (17, "リストA のキー重複",
         '=IF(SUMPRODUCT(({a}!$B${r1}:$B${r2}=1)*({a}!$I${r1}:$I${r2}>1))=0,"OK（重複なし）",'
         '"▲ "&SUMPRODUCT(({a}!$B${r1}:$B${r2}=1)*({a}!$I${r1}:$I${r2}>1))&" 行でキーが重複しています")'
         .format(a=S_CA, r1=R1, r2=R2)),
        (18, "リストB のキー重複",
         '=IF(SUMPRODUCT(({b}!$B${r1}:$B${r2}=1)*({b}!$I${r1}:$I${r2}>1))=0,"OK（重複なし）",'
         '"▲ "&SUMPRODUCT(({b}!$B${r1}:$B${r2}=1)*({b}!$I${r1}:$I${r2}>1))&" 行でキーが重複しています")'
         .format(b=S_CB, r1=R1, r2=R2)),
        (19, "リストA の行数上限",
         '=IF(COUNTA({s}!$A${x}:${L}$100000)>0,"▲ {n} 行を超えるデータがあります（はじめに シート参照）","OK")'
         .format(s=S_A, x=R2 + 1, L=LAST, n=NROW)),
        (20, "リストB の行数上限",
         '=IF(COUNTA({s}!$A${x}:${L}$100000)>0,"▲ {n} 行を超えるデータがあります（はじめに シート参照）","OK")'
         .format(s=S_B, x=R2 + 1, L=LAST, n=NROW)),
    ]
    for row, label, f in checks:
        put(row, label, f, fmt=None)
    smy.cell(21, 2, "リストB に無い列").font = F_BODY
    smy.cell(21, 2).border = BOX
    smy.cell(21, 3, AF("C21", '=IF(_xlfn.TEXTJOIN(", ",TRUE,IF(({ah}<>"")*ISNA(MATCH({ah},{bh},0)),{ah},""))="",'
                               '"OK（リストA の列はすべて リストB にあります）","▲ 比較できない列: "&'
                               '_xlfn.TEXTJOIN(", ",TRUE,IF(({ah}<>"")*ISNA(MATCH({ah},{bh},0)),{ah},"")))'
                               .format(ah=A_HEAD, bh=B_HEAD)))
    smy.cell(21, 3).font = F_BODY; smy.cell(21, 3).border = BOX
    smy.cell(22, 2, "リストA に無い列").font = F_BODY
    smy.cell(22, 2).border = BOX
    smy.cell(22, 3, AF("C22", '=IF(_xlfn.TEXTJOIN(", ",TRUE,IF(({bh}<>"")*ISNA(MATCH({bh},{ah},0)),{bh},""))="",'
                               '"OK（リストB の列はすべて リストA にあります）","▲ 無視した列: "&'
                               '_xlfn.TEXTJOIN(", ",TRUE,IF(({bh}<>"")*ISNA(MATCH({bh},{ah},0)),{bh},"")))'
                               .format(ah=A_HEAD, bh=B_HEAD)))
    smy.cell(22, 3).font = F_BODY; smy.cell(22, 3).border = BOX

    section(smy, 24, "列ごとの差異件数（「変更」行の内訳）")
    for j in range(1, NCOL + 1):
        row = 24 + j
        smy.cell(row, 2, '=IF(INDEX(%s,1,%d)="","",INDEX(%s,1,%d))' % (A_HEAD, j, A_HEAD, j)).font = F_BODY
        smy.cell(row, 3, '=IF($B%d="","",COUNTIF(%s!$M$%d:$M$%d,"*【"&$B%d&"】*"))'
                 % (row, S_CA, R1, R2, row)).font = F_BODY
        smy.cell(row, 3).number_format = "#,##0"
        smy.cell(row, 2).border = BOX; smy.cell(row, 3).border = BOX
    smy.column_dimensions["A"].width = 2
    smy.column_dimensions["B"].width = 30
    smy.column_dimensions["C"].width = 62

    # ============================================================ はじめに
    intro.column_dimensions["A"].width = 2
    intro.column_dimensions["B"].width = 112
    lines = [
        ("t", "一覧差分チェッカー"),
        ("n", "2 つの一覧（Before / After、旧 / 新、システムA / システムB など）を突き合わせて、"),
        ("n", "追加・削除・変更された行と、変更された列・値を自動で抽出します。マクロは使っていません。"),
        ("", ""),
        ("s", "■ 使い方（4 ステップ）"),
        ("b", "1. 「リストA」シートに比較元（Before）を貼り付ける"),
        ("", "   1 行目＝見出し、2 行目以降＝データ。サンプルは削除してください。"),
        ("b", "2. 「リストB」シートに比較先（After）を貼り付ける"),
        ("", "   見出しの名前が同じなら、列の並び順が違っても自動でそろえて比較します。"),
        ("b", "3. 「設定」シートでキー列を選ぶ"),
        ("", "   行を突き合わせる目印の列（社員ID、商品コードなど）。最大 3 列まで組み合わせられます。"),
        ("b", "4. 「差分結果」シートを見る／「状態」列でフィルターする"),
        ("", "   全体の件数と警告は「サマリー」シートで確認できます。"),
        ("", ""),
        ("s", "■ 判定の意味"),
        ("", "   一致    … キーが一致し、値にも差異なし"),
        ("", "   変更    … キーは一致するが、どこかの列の値が違う（どの列がどう変わったかは「差異内容」列）"),
        ("", "   Aのみ   … リストA にしかない＝リストB で削除された行"),
        ("", "   Bのみ   … リストB にしかない＝リストB で追加された行"),
        ("", ""),
        ("s", "■ このファイルの特徴"),
        ("", "   ・複合キー: キー列を最大 3 列まで組み合わせて突き合わせできます。"),
        ("", "   ・表記ゆれの吸収: 全角/半角・大文字小文字・前後の空白・記号を無視して照合できます（設定シート）。"),
        ("", "   ・列ごとの差異: 「どの列が」「何から何に」変わったかを 1 セルにまとめて表示します。"),
        ("", "   ・列順に依存しない: 見出しの名前で対応付けるため、2 つの一覧で列の並びが違っても比較できます。"),
        ("", "   ・重複キーに対応: 同じキーが複数あっても、出現順に 1 対 1 で対応付けます（3 件 対 2 件 なら 1 件が「Aのみ」）。"),
        ("", "   ・警告表示: キー重複・キーが空白・列の欠落・行数の上限超過を「サマリー」と「警告」列で知らせます。"),
        ("", "   ・マクロ不要: .xlsx（数式のみ）なのでセキュリティ警告が出ず、貼り付けるだけで自動再計算されます。"),
        ("", ""),
        ("s", "■ 設定の使い分け"),
        ("", "   キー列 1〜3        行を突き合わせる目印。重複するときは 2 列目・3 列目を足してください。"),
        ("", "   除外列 1〜3        「更新日時」など、差分として見たくない列を比較対象から外します。"),
        ("", "   全角・半角を区別しない   ＡＢ123 と AB123 を同じキーとして扱います。"),
        ("", "   前後・連続の空白を無視   \"A001 \" と \"A001\" を同じキーとして扱います。"),
        ("", "   大文字・小文字を区別しない  a001 と A001 を同じキーとして扱います。"),
        ("", "   記号・空白をすべて無視   ハイフンや括弧を消して照合します。強力なので必要なときだけ。"),
        ("", "   表記ゆれを無視して比較する  値の比較でも上記のゆれを無視します（「しない」なら 1 文字でも違えば「変更」）。"),
        ("", ""),
        ("s", "■ 制限と拡張"),
        ("", "   ・扱える大きさは 1 つの一覧につき %d 行 × %d 列（A〜%s列）です。" % (NROW, NCOL, LAST)),
        ("", "   ・行を増やすには、「計算A」「計算B」「差分結果」シートの最終行を選択して下にドラッグコピーしてください。"),
        ("", "     （計算A・計算B は非表示です。シート見出しを右クリック →「再表示」で表示できます。）"),
        ("", "   ・数万行を超える場合は、Excel の Power Query（データ → データの取得 → クエリのマージ）が高速です。"),
        ("", "   ・「差分結果」シートは数式なので、並べ替えは行わないでください。並べ替えたい場合は値として貼り付けてから。"),
        ("", "   ・キーの文字数が 255 文字を超えると、重複の判定が正しく行えません。"),
        ("", "   ・日付や通貨の書式はコピーされません。「差分結果」の列に元シートの書式を貼り付けてお使いください。"),
        ("", ""),
        ("s", "■ シート構成"),
        ("", "   はじめに    この説明"),
        ("", "   設定        キー列・除外列・表記ゆれの設定（黄色いセルを編集）"),
        ("", "   リストA     比較元のデータを貼り付ける"),
        ("", "   リストB     比較先のデータを貼り付ける"),
        ("", "   サマリー    件数の集計と警告"),
        ("", "   差分結果    1 行 1 件の差分一覧（フィルター付き）"),
        ("", "   計算A/計算B 内部計算用（非表示・編集不要）"),
        ("", ""),
        ("n", "サンプルデータでは、E001 の役職と給与が変わり、E005 の部署が変わり、E004 が削除され、E006 が追加されています。"),
        ("n", "リストB の E002「佐藤　花子」は全角スペースですが、設定で「全角・半角を区別しない」を「する」にすると一致扱いになります。"),
    ]
    for i, (kind, text) in enumerate(lines, 1):
        c = intro.cell(i, 2, text)
        if kind == "t":
            c.font = F_TITLE; intro.row_dimensions[i].height = 26
        elif kind == "s":
            c.font = F_SEC; c.fill = FILL_SEC
        elif kind == "b":
            c.font = F_BOLD
        elif kind == "n":
            c.font = F_NOTE
        else:
            c.font = F_BODY
    intro.sheet_view.showGridLines = False
    smy.sheet_view.showGridLines = False
    cfg.sheet_view.showGridLines = False

    for ws, color in ((intro, "1F3864"), (cfg, "FFC000"), (sa, "4472C4"), (sb, "4472C4"),
                      (smy, "548235"), (res, "548235"), (ca, "A6A6A6"), (cb, "A6A6A6")):
        ws.sheet_properties.tabColor = color

    wb.active = 0
    wb.save(path)
    print("saved:", path)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "list-diff-checker.xlsx")
