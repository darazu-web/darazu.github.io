#!/usr/bin/env python3
"""Power Apps の貼り付け用 YAML（powerapps/*.pa.yaml）と App.OnStart を生成する。

    python3 m365/tools/build_powerapps.py

HTML エスケープなど繰り返しの多い Power Fx をここでまとめて組み立てる。
生成物を直接編集した場合は、このスクリプトにも反映すること。
"""
import os
import re

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'powerapps')

# ------------------------------------------------------------------ Power Fx helpers

def E(x):
    """HTML エスケープ"""
    return f'Substitute(Substitute(Substitute({x}, "&", "&amp;"), "<", "&lt;"), ">", "&gt;")'


def EBR(x):
    """HTML エスケープ＋改行を <br> に"""
    return f'Substitute(Substitute({E(x)}, Char(13), ""), Char(10), "<br>")'


def has_text(x):
    return f'Len(Trim({x})) > 0'


# 色
BLUE = 'RGBA(31, 111, 235, 1)'
BLUE_WEAK = 'RGBA(227, 237, 253, 1)'
DARK = 'RGBA(28, 36, 48, 1)'
MUTED = 'RGBA(93, 107, 122, 1)'
BG = 'RGBA(244, 246, 248, 1)'
WHITE = 'RGBA(255, 255, 255, 1)'
BORDER = 'RGBA(213, 219, 226, 1)'
ADMIN = 'RGBA(43, 52, 64, 1)'
RED = 'RGBA(198, 40, 40, 1)'

# HTML 用スタイル
S_WRAP = "font-family:Meiryo,sans-serif;font-size:16px;line-height:1.6;color:#1c2430;padding:8px 16px"
S_H2 = 'font-size:24px;font-weight:bold;margin:0'
S_SUB = 'color:#5d6b7a;font-size:14px;margin:2px 0 8px'
S_BADGE = 'display:inline-block;background:#eef1f4;color:#5d6b7a;border-radius:10px;padding:1px 10px;font-size:13px;margin-left:8px;vertical-align:middle'
S_H3 = 'font-size:17px;font-weight:bold;margin:20px 0 8px;padding-bottom:4px;border-bottom:2px solid #1f6feb'
S_H4 = 'font-size:15px;font-weight:bold;margin:12px 0 4px'
S_NOTICE = 'background:#fff4d6;color:#6b4e00;border:1px solid #e0a800;border-left:6px solid #e0a800;border-radius:6px;padding:10px 14px;font-weight:bold'
S_OL = 'margin:0;padding-left:28px'
S_LI = 'background:#eef1f4;border-radius:6px;padding:8px 10px;margin-bottom:6px;font-size:17px'
S_TABLE = 'border-collapse:collapse;width:100%;font-size:15px;margin-bottom:8px'
S_TH = 'border:1px solid #d5dbe2;background:#eef1f4;padding:5px 8px;text-align:left;white-space:nowrap'
S_TD = 'border:1px solid #d5dbe2;padding:5px 8px;vertical-align:top'
S_EMPTY = 'color:#5d6b7a;font-style:italic'

EQ_TYPES = 'Table({T: "周辺設備", C: "品番"}, {T: "ハーネス", C: "品番"}, {T: "ソフトウェア", C: "バージョン"})'
NONE_HTML = f'"<div style=\'{S_EMPTY}\'>なし</div>"'


def th(label_expr):
    return f'"<th style=\'{S_TH}\'>" & {label_expr} & "</th>"'


def td(expr):
    return f'"<td style=\'{S_TD}\'>" & {expr} & "</td>"'


# ------------------------------------------------------------------ 共通の読み込み処理

LOAD_PRODUCTS = (
    'ClearCollect(colProducts, ForAll(Sort(InspProducts, Title, SortOrder.Ascending) As p, '
    '{ID: p.ID, Title: p.Title, ProductName: p.ProductName, Description: p.Description, '
    'Label: p.Title & "  " & p.ProductName}))'
)


def load_browse(product_expr):
    return f'''Set(varProduct, {product_expr});
ClearCollect(colTmp, Sort(Filter(InspItems, ProductID = varProduct.ID), ItemNo, SortOrder.Ascending));
ClearCollect(colItems, ForAll(Sequence(CountRows(colTmp)) As n, Patch(Index(colTmp, n.Value), {{RowNo: n.Value}})));
ClearCollect(colEqAll, Filter(InspEquipment, ProductID = varProduct.ID));
Set(varItem, First(colItems));
Set(varView, "item")'''


LOAD_ADM_ITEMS = 'ClearCollect(colAdmItems, Sort(Filter(InspItems, ProductID = varAdmProduct.ID), ItemNo, SortOrder.Ascending))'

LOAD_EDIT_EQ = '''ClearCollect(colEditEq, ForAll(Sort(Filter(InspEquipment, ItemID = varEdit.ID), SeqNo, SortOrder.Ascending) As e, {Key: Text(GUID()), EqID: e.ID, EquipType: e.EquipType, Code: e.Code, EqName: e.Title, Note: e.Note, Seq: e.SeqNo}));
Clear(colEqDeleted)'''

ON_START = f'''Set(varIsAdmin, DataSourceInfo(InspItems, DataSourceInfo.EditPermission));
{LOAD_PRODUCTS};
ClearCollect(colEditEq, {{Key: "", EqID: 0, EquipType: "", Code: "", EqName: "", Note: "", Seq: 0}});
Clear(colEditEq);
ClearCollect(colEqDeleted, {{EqID: 0}});
Clear(colEqDeleted);
Set(varEdit, LookUp(InspItems, ID = -1));
Set(varConfirmDel, false);
Set(varConfirmDelP, false);
Set(varAdmProduct, First(colProducts));
{LOAD_ADM_ITEMS};
{load_browse('First(colProducts)')}'''

# ------------------------------------------------------------------ 閲覧画面の HTML

ITEM_HTML = f'''If(IsBlank(varItem),
    "<div style='{S_WRAP}'><p style='{S_EMPTY}'>" & If(IsBlank(varProduct), "製品が登録されていません。", "左の一覧から検査項目を選択してください。") & "</p></div>",
    With({{eq: Filter(colEqAll, ItemID = varItem.ID)}},
        "<div style='{S_WRAP}'>" &
        "<div style='{S_H2}'>" & Text(varItem.ItemNo) & ". " & {E('varItem.Title')} &
        If({has_text('varItem.Category')}, "<span style='{S_BADGE}'>" & {E('varItem.Category')} & "</span>", "") & "</div>" &
        "<div style='{S_SUB}'>" & {E('varProduct.Label')} & "</div>" &
        If({has_text('varItem.Notes')},
            "<div style='{S_H3}'>特記事項 <span style='color:#1f6feb;font-size:13px;font-weight:normal'>必ず確認</span></div>" &
            "<div style='{S_NOTICE}'>⚠ " & {EBR('varItem.Notes')} & "</div>", "") &
        "<div style='{S_H3}'>検査方法</div>" &
        If({has_text('varItem.Method')},
            "<ol style='{S_OL}'>" &
            Concat(Filter(Split(Substitute(varItem.Method, Char(13), ""), Char(10)), Len(Trim(Value)) > 0),
                "<li style='{S_LI}'>" & {E('Trim(Value)')} & "</li>") &
            "</ol>",
            {NONE_HTML}) &
        If({has_text('varItem.Criteria')},
            "<div style='{S_H3}'>判定基準</div><div>" & {EBR('varItem.Criteria')} & "</div>", "") &
        "<div style='{S_H3}'>使用設備</div>" &
        If({has_text('varItem.TesterNo & varItem.TesterName')},
            "<table style='{S_TABLE}'><tr>" & {th('"テスター品番"')} & {td(f'"<b>" & {E("varItem.TesterNo")} & "</b>"')} & "</tr>" &
            "<tr>" & {th('"テスター名"')} & {td(f'"<b>" & {E("varItem.TesterName")} & "</b>"')} & "</tr></table>", "") &
        Concat({EQ_TYPES} As ty,
            With({{rows: Sort(Filter(eq, EquipType = ty.T), SeqNo, SortOrder.Ascending)}},
                If(CountRows(rows) = 0, "",
                    "<div style='{S_H4}'>" & ty.T & "</div><table style='{S_TABLE}'><tr>" &
                    {th('ty.C')} & {th('"名称"')} & {th('"備考"')} & "</tr>" &
                    Concat(rows, "<tr>" & {td(E('Code'))} & {td(E('Title'))} & {td(E('Note'))} & "</tr>") &
                    "</table>"))) &
        If(!({has_text('varItem.TesterNo & varItem.TesterName')}) && CountRows(eq) = 0, {NONE_HTML}, "") &
        If({has_text('varItem.Other')},
            "<div style='{S_H3}'>その他</div><div>" & {EBR('varItem.Other')} & "</div>", "") &
        "</div>"
    )
)'''

SUMMARY_HTML = f'''If(IsBlank(varProduct),
    "<div style='{S_WRAP}'><p style='{S_EMPTY}'>製品が登録されていません。</p></div>",
    With({{testers: Distinct(Filter(colItems, {has_text('TesterNo & TesterName')}), TesterNo & "｜" & TesterName)}},
        "<div style='{S_WRAP}'>" &
        "<div style='{S_H2}'>使用設備まとめ</div>" &
        "<div style='{S_SUB}'>" & {E('varProduct.Label')} & "　・検査準備時の確認用</div>" &
        If({has_text('varProduct.Description')}, "<div>" & {EBR('varProduct.Description')} & "</div>", "") &
        If(CountRows(testers) > 0,
            "<div style='{S_H3}'>テスター（" & CountRows(testers) & "）</div><table style='{S_TABLE}'><tr>" &
            {th('"テスター品番"')} & {th('"テスター名"')} & {th('"使用する検査項目No."')} & "</tr>" &
            Concat(testers As d,
                "<tr>" & {td(E('First(Split(d.Value, "｜")).Value'))} & {td(E('Last(Split(d.Value, "｜")).Value'))} &
                {td('Concat(Filter(colItems, TesterNo & "｜" & TesterName = d.Value), Text(ItemNo), ", ")')} & "</tr>") &
            "</table>", "") &
        Concat({EQ_TYPES} As ty,
            With({{ds: Distinct(Filter(colEqAll, EquipType = ty.T), Code & "｜" & Title)}},
                If(CountRows(ds) = 0, "",
                    "<div style='{S_H3}'>" & ty.T & "（" & CountRows(ds) & "）</div><table style='{S_TABLE}'><tr>" &
                    {th('ty.C')} & {th('"名称"')} & {th('"使用する検査項目No."')} & "</tr>" &
                    Concat(ds As d,
                        "<tr>" & {td(E('First(Split(d.Value, "｜")).Value'))} & {td(E('Last(Split(d.Value, "｜")).Value'))} &
                        {td('Concat(Filter(colEqAll, EquipType = ty.T && Code & "｜" & Title = d.Value) As r, Text(LookUp(colItems, ID = r.ItemID).ItemNo), ", ")')} &
                        "</tr>") &
                    "</table>"))) &
        If(CountRows(testers) = 0 && CountRows(colEqAll) = 0, "<p style='{S_EMPTY}'>登録された設備はありません。</p>", "") &
        "</div>"
    )
)'''

# ------------------------------------------------------------------ コントロール定義ヘルパー


def select_parent(controls):
    """ギャラリー内のラベルをタップしても行が選択されるようにする"""
    for c in controls:
        next(iter(c.values()))['Properties']['OnSelect'] = 'Select(Parent)'
    return controls


def ctl(name, control, props, children=None, variant=None):
    body = {'Control': control}
    if variant:
        body['Variant'] = variant
    body['Properties'] = props
    if children is not None:
        body['Children'] = children
    return {name: body}


def label(name, text, x, y, w, h, **extra):
    p = {'Text': text, 'X': x, 'Y': y, 'Width': w, 'Height': h}
    p.update(extra)
    return ctl(name, 'Label@2.5.1', p)


def button(name, text, on_select, x, y, w, h, primary=False, **extra):
    p = {
        'Text': text, 'OnSelect': on_select, 'X': x, 'Y': y, 'Width': w, 'Height': h, 'Size': '13',
        'Fill': BLUE if primary else WHITE,
        'Color': WHITE if primary else DARK,
        'HoverFill': 'RGBA(25, 95, 205, 1)' if primary else 'RGBA(238, 241, 244, 1)',
        'HoverColor': WHITE if primary else DARK,
        'BorderColor': BLUE if primary else BORDER,
        'BorderThickness': '1',
    }
    p.update(extra)
    return ctl(name, 'Classic/Button@2.2.0', p)


def text_input(name, default, x='0', y='0', w='200', h='40', multiline=False, **extra):
    p = {'Default': default, 'X': x, 'Y': y, 'Width': w, 'Height': h, 'Size': '13'}
    if multiline:
        p['Mode'] = 'TextMode.MultiLine'
    p.update(extra)
    return ctl(name, 'Classic/TextInput@2.3.2', p)


def auto(props):
    """AutoLayout コンテナー内の子に付ける共通プロパティ"""
    d = {'AlignInContainer': 'AlignInContainer.Stretch', 'FillPortions': '0'}
    d.update(props)
    return d


def field_label(name, text):
    return ctl(name, 'Label@2.5.1', auto({'Text': f'="{text}"', 'Height': '24', 'Size': '11',
                                         'FontWeight': 'FontWeight.Semibold', 'Color': MUTED}))


def field_input(name, default, h='40', multiline=False, hint=None):
    p = auto({'Default': default, 'Height': h, 'Size': '13'})
    if multiline:
        p['Mode'] = 'TextMode.MultiLine'
    if hint:
        p['HintText'] = f'="{hint}"'
    return ctl(name, 'Classic/TextInput@2.3.2', p)


# ------------------------------------------------------------------ 閲覧画面

SEARCH_ITEMS = '''With({q: Trim(txtSearch.Text)},
    If(IsBlank(q), colItems,
        Filter(colItems As it,
            q in it.Title || q in it.Category || q in Text(it.ItemNo) || q in it.Method ||
            q in it.Criteria || q in it.Notes || q in it.Other || q in it.TesterNo || q in it.TesterName ||
            CountRows(Filter(colEqAll, ItemID = it.ID && (q in Code || q in Title || q in Note))) > 0
        )
    )
)'''

PREV = 'LookUp(colItems, RowNo = varItem.RowNo - 1)'
NEXT = 'LookUp(colItems, RowNo = varItem.RowNo + 1)'


def browse_screen():
    item_template = [
        label('lblItemNo', '=Text(ThisItem.ItemNo)', '8', '0', '48', 'Parent.TemplateHeight',
              FontWeight='FontWeight.Bold', Color=BLUE, Size='15', Align='Align.Center'),
        label('lblItemName', '=ThisItem.Title', '56', '6', 'Parent.TemplateWidth - 64', '30',
              Size='14', Color=DARK, FontWeight='If(ThisItem.ID = varItem.ID && varView = "item", FontWeight.Bold, FontWeight.Normal)'),
        label('lblItemCat', '=ThisItem.Category', '56', '34', 'Parent.TemplateWidth - 64', '24', Size='10', Color=MUTED),
    ]
    children = [
        ctl('recBrowseHeader', 'Rectangle@2.3.0', {'X': '0', 'Y': '0', 'Width': 'Parent.Width', 'Height': '64', 'Fill': BLUE}),
        label('lblBrowseTitle', '="検査情報"', '16', '0', '130', '64', Color=WHITE, Size='18', FontWeight='FontWeight.Bold'),
        ctl('ddProduct', 'Classic/DropDown@2.3.1', {
            'Items': 'ForAll(colProducts, ThisRecord.Label)',
            'Default': 'varProduct.Label',
            'OnChange': load_browse('LookUp(colProducts, Label = Self.Selected.Value)'),
            'X': '150', 'Y': '12', 'Width': 'Min(460, Parent.Width - 520)', 'Height': '40', 'Size': '13',
        }),
        button('btnSummary', '=If(varView = "summary", "検査項目に戻る", "設備まとめ")',
               'Set(varView, If(varView = "summary", "item", "summary"))',
               'Parent.Width - 336', '12', '160', '40'),
        button('btnGoAdmin', '="管理"',
               'Set(varAdmProduct, LookUp(colProducts, ID = varProduct.ID));\n' + LOAD_ADM_ITEMS + ';\nSet(varEdit, LookUp(InspItems, ID = -1));\nNavigate(scrAdmin, ScreenTransition.None)',
               'Parent.Width - 168', '12', '152', '40', Visible='varIsAdmin'),
        text_input('txtSearch', '=""', '12', '76', '320', '40', HintText='="検索（項目名・品番・設備名など）"', DelayOutput='true'),
        ctl('galItems', 'Gallery@2.15.0', {
            'Items': SEARCH_ITEMS,
            'X': '12', 'Y': '124', 'Width': '320', 'Height': 'Parent.Height - 136',
            'TemplateSize': '64', 'TemplatePadding': '2',
            'TemplateFill': f'If(ThisItem.ID = varItem.ID && varView = "item", {BLUE_WEAK}, {WHITE})',
            'Fill': WHITE, 'BorderColor': BORDER, 'BorderThickness': '1',
            'OnSelect': 'Set(varItem, ThisItem);\nSet(varView, "item")',
        }, children=select_parent(item_template), variant='Vertical'),
        ctl('recDetailBg', 'Rectangle@2.3.0', {'X': '344', 'Y': '76', 'Width': 'Parent.Width - 356', 'Height': 'Parent.Height - 88', 'Fill': WHITE,
                                                'BorderColor': BORDER, 'BorderThickness': '1'}),
        ctl('htmlDetail', 'HtmlViewer@2.1.0', {
            'HtmlText': f'If(varView = "summary",\n{SUMMARY_HTML},\n{ITEM_HTML})',
            'X': '348', 'Y': '80', 'Width': 'Parent.Width - 364',
            'Height': 'Parent.Height - If(varView = "item", 152, 96)',
        }),
        button('btnPrev', f'="← " & Text({PREV}.ItemNo) & " " & {PREV}.Title', f'Set(varItem, {PREV})',
               '356', 'Parent.Height - 64', '(Parent.Width - 380) / 2 - 6', '44',
               Visible=f'varView = "item" && !IsBlank({PREV})'),
        button('btnNext', f'=Text({NEXT}.ItemNo) & " " & {NEXT}.Title & " →"', f'Set(varItem, {NEXT})',
               '356 + (Parent.Width - 380) / 2 + 6', 'Parent.Height - 64', '(Parent.Width - 380) / 2 - 6', '44',
               primary=True, Visible=f'varView = "item" && !IsBlank({NEXT})'),
    ]
    return [ctl('conBrowse', 'GroupContainer@1.3.0', {
        'X': '0', 'Y': '0', 'Width': 'Parent.Width', 'Height': 'Parent.Height', 'Fill': BG, 'DropShadow': 'DropShadow.None',
    }, children=children, variant='ManualLayout')]


# ------------------------------------------------------------------ 管理画面

RELOAD_ADM_PRODUCT = f'''{LOAD_PRODUCTS};
Set(varAdmProduct, LookUp(colProducts, ID = pid));
{LOAD_ADM_ITEMS}'''

SAVE_PRODUCT = f'''If(IsBlank(Trim(txtPCode.Text)),
    Notify("製品品番を入力してください", NotificationType.Error),
    With({{pid: varAdmProduct.ID}},
        Patch(InspProducts, LookUp(InspProducts, ID = pid), {{Title: Trim(txtPCode.Text), ProductName: txtPName.Text, Description: txtPDesc.Text}});
        {RELOAD_ADM_PRODUCT};
        Notify("製品情報を保存しました", NotificationType.Success)
    )
)'''

ADD_PRODUCT = f'''With({{pid: Patch(InspProducts, Defaults(InspProducts), {{Title: "NEW-" & Text(Now(), "yyyymmddhhmmss"), ProductName: "新しい製品"}}).ID}},
    {RELOAD_ADM_PRODUCT}
);
Set(varEdit, LookUp(InspItems, ID = -1));
Set(varConfirmDelP, false);
Notify("製品を追加しました。品番と製品名を入力して保存してください", NotificationType.Information)'''

DELETE_PRODUCT = f'''If(!varConfirmDelP,
    Set(varConfirmDelP, true),
    With({{pid: varAdmProduct.ID}},
        RemoveIf(InspEquipment, ProductID = pid);
        RemoveIf(InspItems, ProductID = pid);
        RemoveIf(InspProducts, ID = pid)
    );
    {LOAD_PRODUCTS};
    Set(varAdmProduct, First(colProducts));
    {LOAD_ADM_ITEMS};
    Set(varEdit, LookUp(InspItems, ID = -1));
    Set(varConfirmDelP, false);
    Notify("製品を削除しました", NotificationType.Success)
)'''

SELECT_ADM_PRODUCT = f'''Set(varAdmProduct, LookUp(colProducts, Label = Self.Selected.Value));
{LOAD_ADM_ITEMS};
Set(varEdit, LookUp(InspItems, ID = -1));
Set(varConfirmDelP, false)'''

ADD_ITEM = f'''Set(varEdit, Patch(InspItems, Defaults(InspItems), {{Title: "新しい検査項目", ProductID: varAdmProduct.ID, ItemNo: Max(colAdmItems, ItemNo) + 1}}));
{LOAD_ADM_ITEMS};
{LOAD_EDIT_EQ};
Set(varConfirmDel, false)'''

SELECT_ITEM = f'''Set(varEdit, ThisItem);
{LOAD_EDIT_EQ};
Set(varConfirmDel, false)'''

SAVE_ITEM = f'''If(IsBlank(Trim(txtName.Text)),
    Notify("検査項目名を入力してください", NotificationType.Error),
    Set(varEdit, Patch(InspItems, LookUp(InspItems, ID = varEdit.ID), {{
        Title: Trim(txtName.Text),
        ItemNo: Value(txtNo.Text),
        Category: txtCategory.Text,
        Method: txtMethod.Text,
        Criteria: txtCriteria.Text,
        TesterNo: txtTesterNo.Text,
        TesterName: txtTesterName.Text,
        Notes: txtNotes.Text,
        Other: txtOther.Text
    }}));
    ForAll(colEqDeleted As d, RemoveIf(InspEquipment, ID = d.EqID));
    ForAll(galEq.AllItems As g,
        Patch(InspEquipment,
            If(g.EqID = 0, Defaults(InspEquipment), LookUp(InspEquipment, ID = g.EqID)),
            {{
                Title: g.txtEqName.Text,
                Code: g.txtEqCode.Text,
                Note: g.txtEqNote.Text,
                EquipType: g.ddEqType.Selected.Value,
                SeqNo: g.Seq,
                ItemID: varEdit.ID,
                ProductID: varAdmProduct.ID
            }}
        )
    );
    {LOAD_EDIT_EQ};
    {LOAD_ADM_ITEMS};
    Notify("保存しました", NotificationType.Success)
)'''

DELETE_ITEM = f'''If(!varConfirmDel,
    Set(varConfirmDel, true),
    With({{iid: varEdit.ID}},
        RemoveIf(InspEquipment, ItemID = iid);
        RemoveIf(InspItems, ID = iid)
    );
    Set(varEdit, LookUp(InspItems, ID = -1));
    Clear(colEditEq);
    Set(varConfirmDel, false);
    {LOAD_ADM_ITEMS};
    Notify("検査項目を削除しました", NotificationType.Success)
)'''

BACK_TO_BROWSE = f'''Refresh(InspProducts);
Refresh(InspItems);
Refresh(InspEquipment);
{LOAD_PRODUCTS};
{load_browse('If(IsBlank(LookUp(colProducts, ID = varAdmProduct.ID)), First(colProducts), LookUp(colProducts, ID = varAdmProduct.ID))')};
Navigate(scrBrowse, ScreenTransition.None)'''


def admin_screen():
    adm_item_template = [
        label('lblAdmItemNo', '=Text(ThisItem.ItemNo)', '4', '0', '44', 'Parent.TemplateHeight',
              FontWeight='FontWeight.Bold', Color=BLUE, Size='13', Align='Align.Center'),
        label('lblAdmItemName', '=ThisItem.Title', '48', '0', 'Parent.TemplateWidth - 52', 'Parent.TemplateHeight',
              Size='13', Color=DARK),
    ]

    eq_row = [
        ctl('ddEqType', 'Classic/DropDown@2.3.1', {
            'Items': '["周辺設備", "ハーネス", "ソフトウェア"]',
            'Default': 'ThisItem.EquipType',
            'OnChange': 'Patch(colEditEq, ThisItem, {EquipType: Self.Selected.Value})',
            'X': '0', 'Y': '4', 'Width': '150', 'Height': '40', 'Size': '12',
        }),
        text_input('txtEqCode', '=ThisItem.Code', '158', '4', '190', '40',
                   HintText='="品番／バージョン"', OnChange='Patch(colEditEq, ThisItem, {Code: Self.Text})'),
        text_input('txtEqName', '=ThisItem.EqName', '356', '4', 'Parent.TemplateWidth - 356 - 8 - 240 - 8 - 48', '40',
                   HintText='="名称"', OnChange='Patch(colEditEq, ThisItem, {EqName: Self.Text})'),
        text_input('txtEqNote', '=ThisItem.Note', 'Parent.TemplateWidth - 48 - 8 - 240', '4', '240', '40',
                   HintText='="備考"', OnChange='Patch(colEditEq, ThisItem, {Note: Self.Text})'),
        button('btnEqDel', '="✕"', 'If(ThisItem.EqID > 0, Collect(colEqDeleted, {EqID: ThisItem.EqID}));\nRemove(colEditEq, ThisItem)',
               'Parent.TemplateWidth - 44', '4', '44', '40', Color=RED),
    ]

    editor_children = [
        ctl('lblEditHead', 'Label@2.5.1', auto({'Text': '="検査項目の編集"', 'Height': '40', 'Size': '18',
                                                'FontWeight': 'FontWeight.Bold', 'Color': DARK})),
        field_label('lblNo', 'No.（数字・並び順）'), field_input('txtNo', '=Text(varEdit.ItemNo)'),
        field_label('lblName', '検査項目名'), field_input('txtName', '=varEdit.Title'),
        field_label('lblCategory', '分類'), field_input('txtCategory', '=varEdit.Category', hint='例：外観／電気特性／機能'),
        field_label('lblMethod', '検査方法（手順：1行が1ステップ）'), field_input('txtMethod', '=varEdit.Method', h='150', multiline=True),
        field_label('lblCriteria', '判定基準'), field_input('txtCriteria', '=varEdit.Criteria', h='80', multiline=True),
        field_label('lblTesterNo', 'テスター品番'), field_input('txtTesterNo', '=varEdit.TesterNo'),
        field_label('lblTesterName', 'テスター名'), field_input('txtTesterName', '=varEdit.TesterName'),
        field_label('lblEq', '使用設備（種類／品番・バージョン／名称／備考）'),
        ctl('galEq', 'Gallery@2.15.0', auto({
            'Items': 'colEditEq',
            'Height': 'Max(1, CountRows(colEditEq)) * 48',
            'TemplateSize': '48', 'TemplatePadding': '0',
        }), children=eq_row, variant='Vertical'),
        ctl('btnAddEq', 'Classic/Button@2.2.0', {
            'Text': '="＋ 設備を追加"',
            'OnSelect': 'Collect(colEditEq, {Key: Text(GUID()), EqID: 0, EquipType: "周辺設備", Code: "", EqName: "", Note: "", Seq: Max(colEditEq, Seq) + 1})',
            'AlignInContainer': 'AlignInContainer.Start', 'FillPortions': '0', 'Width': '200', 'Height': '40', 'Size': '12',
            'Fill': WHITE, 'Color': DARK, 'BorderColor': BORDER, 'BorderThickness': '1', 'HoverFill': 'RGBA(238, 241, 244, 1)', 'HoverColor': DARK,
        }),
        field_label('lblNotes', '特記事項（閲覧画面で警告枠として先頭に表示）'), field_input('txtNotes', '=varEdit.Notes', h='80', multiline=True),
        field_label('lblOther', 'その他'), field_input('txtOther', '=varEdit.Other', h='80', multiline=True),
        ctl('conItemButtons', 'GroupContainer@1.3.0', auto({
            'Height': '56', 'LayoutDirection': 'LayoutDirection.Horizontal', 'LayoutGap': '12',
            'LayoutAlignItems': 'LayoutAlignItems.Center', 'PaddingTop': '8', 'DropShadow': 'DropShadow.None',
        }), children=[
            ctl('btnSaveItem', 'Classic/Button@2.2.0', {
                'Text': '="保存"', 'OnSelect': SAVE_ITEM, 'Width': '160', 'Height': '44', 'FillPortions': '0', 'Size': '14',
                'Fill': BLUE, 'Color': WHITE, 'HoverFill': 'RGBA(25, 95, 205, 1)', 'HoverColor': WHITE, 'BorderColor': BLUE,
            }),
            ctl('btnDelItem', 'Classic/Button@2.2.0', {
                'Text': '=If(varConfirmDel, "本当に削除する", "この項目を削除")', 'OnSelect': DELETE_ITEM,
                'Width': '180', 'Height': '44', 'FillPortions': '0', 'Size': '13',
                'Fill': f'If(varConfirmDel, {RED}, {WHITE})', 'Color': f'If(varConfirmDel, {WHITE}, {RED})',
                'HoverFill': f'If(varConfirmDel, {RED}, RGBA(253, 231, 231, 1))', 'HoverColor': f'If(varConfirmDel, {WHITE}, {RED})',
                'BorderColor': RED, 'BorderThickness': '1',
            }),
        ], variant='AutoLayout'),
    ]

    children = [
        ctl('recAdmHeader', 'Rectangle@2.3.0', {'X': '0', 'Y': '0', 'Width': 'Parent.Width', 'Height': '64', 'Fill': ADMIN}),
        label('lblAdmTitle', '="検査情報 管理"', '16', '0', '200', '64', Color=WHITE, Size='18', FontWeight='FontWeight.Bold'),
        label('lblAdmUser', '=User().FullName & " で編集中"', '220', '0', '400', '64', Color='RGBA(200, 209, 219, 1)', Size='11'),
        button('btnBack', '="閲覧画面へ戻る"', BACK_TO_BROWSE, 'Parent.Width - 196', '12', '180', '40'),

        # --- 左列：製品
        ctl('ddAdmProduct', 'Classic/DropDown@2.3.1', {
            'Items': 'ForAll(colProducts, ThisRecord.Label)', 'Default': 'varAdmProduct.Label',
            'OnChange': SELECT_ADM_PRODUCT,
            'X': '12', 'Y': '76', 'Width': '260', 'Height': '40', 'Size': '13',
        }),
        button('btnAddProduct', '="＋ 製品"', ADD_PRODUCT, '280', '76', '92', '40'),
        label('lblPCode', '="製品品番"', '12', '122', '360', '22', Size='11', Color=MUTED, FontWeight='FontWeight.Semibold'),
        text_input('txtPCode', '=varAdmProduct.Title', '12', '144', '360', '38', DisplayMode='If(IsBlank(varAdmProduct), DisplayMode.Disabled, DisplayMode.Edit)'),
        label('lblPName', '="製品名"', '12', '186', '360', '22', Size='11', Color=MUTED, FontWeight='FontWeight.Semibold'),
        text_input('txtPName', '=varAdmProduct.ProductName', '12', '208', '360', '38', DisplayMode='If(IsBlank(varAdmProduct), DisplayMode.Disabled, DisplayMode.Edit)'),
        label('lblPDesc', '="説明・備考"', '12', '250', '360', '22', Size='11', Color=MUTED, FontWeight='FontWeight.Semibold'),
        text_input('txtPDesc', '=varAdmProduct.Description', '12', '272', '360', '60', multiline=True, DisplayMode='If(IsBlank(varAdmProduct), DisplayMode.Disabled, DisplayMode.Edit)'),
        button('btnSaveProduct', '="製品情報を保存"', SAVE_PRODUCT, '12', '340', '176', '38', primary=True,
               DisplayMode='If(IsBlank(varAdmProduct), DisplayMode.Disabled, DisplayMode.Edit)'),
        button('btnDelProduct', '=If(varConfirmDelP, "本当に削除する", "製品を削除")', DELETE_PRODUCT, '196', '340', '176', '38',
               Color=f'If(varConfirmDelP, {WHITE}, {RED})', Fill=f'If(varConfirmDelP, {RED}, {WHITE})', BorderColor=RED,
               HoverFill=f'If(varConfirmDelP, {RED}, RGBA(253, 231, 231, 1))', HoverColor=f'If(varConfirmDelP, {WHITE}, {RED})',
               DisplayMode='If(IsBlank(varAdmProduct), DisplayMode.Disabled, DisplayMode.Edit)'),

        # --- 左列：検査項目一覧
        label('lblAdmItems', '="検査項目（" & CountRows(colAdmItems) & "）"', '12', '392', '220', '40', Size='13', FontWeight='FontWeight.Bold', Color=DARK),
        button('btnAddItem', '="＋ 検査項目"', ADD_ITEM, '240', '392', '132', '40',
               DisplayMode='If(IsBlank(varAdmProduct), DisplayMode.Disabled, DisplayMode.Edit)'),
        ctl('galAdmItems', 'Gallery@2.15.0', {
            'Items': 'colAdmItems',
            'X': '12', 'Y': '438', 'Width': '360', 'Height': 'Parent.Height - 450',
            'TemplateSize': '44', 'TemplatePadding': '2',
            'TemplateFill': f'If(ThisItem.ID = varEdit.ID, {BLUE_WEAK}, {WHITE})',
            'Fill': WHITE, 'BorderColor': BORDER, 'BorderThickness': '1',
            'OnSelect': SELECT_ITEM,
        }, children=select_parent(adm_item_template), variant='Vertical'),

        # --- 右：検査項目の編集
        label('lblNoEdit', '="左の一覧から検査項目を選択するか、「＋ 検査項目」で追加してください。"',
              '388', '76', 'Parent.Width - 400', '60', Color=MUTED, Size='13', Visible='IsBlank(varEdit)'),
        ctl('conEditor', 'GroupContainer@1.3.0', {
            'X': '388', 'Y': '76', 'Width': 'Parent.Width - 400', 'Height': 'Parent.Height - 88',
            'Fill': WHITE, 'BorderColor': BORDER, 'BorderThickness': '1',
            'LayoutDirection': 'LayoutDirection.Vertical', 'LayoutGap': '2',
            'LayoutOverflowY': 'LayoutOverflow.Scroll',
            'PaddingTop': '12', 'PaddingBottom': '24', 'PaddingLeft': '20', 'PaddingRight': '20',
            'Visible': '!IsBlank(varEdit)', 'DropShadow': 'DropShadow.None',
        }, children=editor_children, variant='AutoLayout'),
    ]
    return [ctl('conAdmin', 'GroupContainer@1.3.0', {
        'X': '0', 'Y': '0', 'Width': 'Parent.Width', 'Height': 'Parent.Height', 'Fill': BG, 'DropShadow': 'DropShadow.None',
    }, children=children, variant='ManualLayout')]


# ------------------------------------------------------------------ YAML 出力

PLAIN_OK = re.compile(r'^[A-Za-z0-9_.()+\-*/ ,!=<>&|]*$')


def fmt_value(v, indent):
    v = v if v.startswith('=') else '=' + v
    if '\n' not in v and PLAIN_OK.match(v) and ': ' not in v and ' #' not in v and not v.endswith(':'):
        return ' ' + v
    pad = ' ' * (indent + 2)
    return ' |-\n' + '\n'.join(pad + line if line else '' for line in v.split('\n'))


def emit_controls(controls, indent, out):
    pad = ' ' * indent
    for c in controls:
        (name, body), = c.items()
        out.append(f'{pad}- {name}:')
        inner = indent + 4
        ipad = ' ' * inner
        out.append(f'{ipad}Control: {body["Control"]}')
        if body.get('Variant'):
            out.append(f'{ipad}Variant: {body["Variant"]}')
        out.append(f'{ipad}Properties:')
        for k in sorted(body['Properties']):
            out.append(f'{ipad}  {k}:' + fmt_value(body['Properties'][k], inner + 2))
        if body.get('Children') is not None:
            out.append(f'{ipad}Children:')
            emit_controls(body['Children'], inner + 2, out)


HEADER = '''# 検査情報アプリ（Power Apps）{title}
# 貼り付け方：Power Apps Studio のツリービューで画面「{screen}」を右クリック →「貼り付け」
#             （またはこのファイルの内容をコピーし、画面を選択して Ctrl+V）
# このファイルは m365/tools/build_powerapps.py から生成しています。
'''


def write_screen(fname, title, screen, controls):
    out = []
    emit_controls(controls, 0, out)
    with open(os.path.join(OUT, fname), 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(out) + '\n')


def main():
    os.makedirs(OUT, exist_ok=True)
    write_screen('scrBrowse.pa.yaml', '閲覧画面', 'scrBrowse', browse_screen())
    write_screen('scrAdmin.pa.yaml', '管理画面', 'scrAdmin', admin_screen())
    with open(os.path.join(OUT, 'App.OnStart.txt'), 'w', encoding='utf-8', newline='\n') as f:
        f.write(ON_START + '\n')
    print('generated:', ', '.join(sorted(os.listdir(OUT))))


if __name__ == '__main__':
    main()
