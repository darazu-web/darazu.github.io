// Power Apps の数式チェッカー（Power Fx オープンソース版で型チェックする）
//   python3 export_formulas.py && dotnet run -- formulas.json
// Power Apps 固有の関数（Notify, Navigate, Refresh, RemoveIf, Defaults など）は
// 型チェックできる形に置き換えてから検査する。実際の Studio での動作確認の代わりにはならない。
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.PowerFx;
using Microsoft.PowerFx.Types;

var path = args[0];
if (args.Length > 1 && args[1] == "render")
{
    var rj = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(File.ReadAllText(path))!;
    var cfg = new PowerFxConfig(Features.PowerFxV1) { MaximumExpressionLength = 200000 };
    var eng = new RecalcEngine(cfg);
    foreach (var k in new[] { "colProducts", "varProduct", "colItems", "colEqAll" })
        eng.UpdateVariable(k, eng.Eval(rj[k].GetString()!));
    var formula = rj["formula"].GetString()!;
    int n = rj["n"].GetInt32();
    for (int i = 0; i <= n; i++)
    {
        var view = i == 0 ? "summary" : "item";
        eng.UpdateVariable("varView", FormulaValue.New(view));
        eng.UpdateVariable("varItem", eng.Eval($"LookUp(colItems, RowNo = {Math.Max(i, 1)})"));
        var r = eng.Eval(formula);
        var outFile = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(path))!, $"render_{i}.html");
        File.WriteAllText(outFile, "<meta charset='utf-8'><body style='margin:0;width:900px'>" + ((StringValue)r).Value);
        Console.WriteLine(outFile);
    }
    return;
}
var items = JsonSerializer.Deserialize<List<Dictionary<string, string?>>>(File.ReadAllText(path))!;

RecordType R(params (string, FormulaType)[] f) { var r = RecordType.Empty(); foreach (var (n, t) in f) r = r.Add(n, t); return r; }
var S = FormulaType.String; var N = FormulaType.Number; var B = FormulaType.Boolean;

var prod = R(("ID", N), ("Title", S), ("ProductName", S), ("Description", S));
var item = R(("ID", N), ("Title", S), ("ProductID", N), ("ItemNo", N), ("Category", S), ("Method", S), ("Criteria", S),
             ("TesterNo", S), ("TesterName", S), ("Notes", S), ("Other", S));
var eq = R(("ID", N), ("Title", S), ("ItemID", N), ("ProductID", N), ("EquipType", S), ("Code", S), ("Note", S), ("SeqNo", N));
var colProd = R(("ID", N), ("Title", S), ("ProductName", S), ("Description", S), ("Label", S));
var colItem = item.Add("RowNo", N);
var editEq = R(("Key", S), ("EqID", N), ("EquipType", S), ("Code", S), ("EqName", S), ("Note", S), ("Seq", N));
var txt = R(("Text", S));
var dd = R(("Selected", R(("Value", S))));
var galEqRow = editEq.Add("txtEqName", txt).Add("txtEqCode", txt).Add("txtEqNote", txt).Add("ddEqType", dd);

SymbolTable Base()
{
    var s = new SymbolTable();
    s.EnableMutationFunctions();
    void T(string n, RecordType r) => s.AddVariable(n, r.ToTable(), mutable: true);
    void V(string n, FormulaType t) => s.AddVariable(n, t, mutable: true);
    T("InspProducts", prod); T("InspItems", item); T("InspEquipment", eq);
    T("colProducts", colProd); T("colTmp", item); T("colItems", colItem); T("colEqAll", eq);
    T("colAdmItems", item); T("colEditEq", editEq); T("colEqDeleted", R(("EqID", N)));
    V("varIsAdmin", B); V("varProduct", colProd); V("varItem", colItem); V("varView", S);
    V("varEdit", item); V("varAdmProduct", colProd); V("varConfirmDel", B); V("varConfirmDelP", B);
    foreach (var c in new[] { "txtSearch", "txtNo", "txtName", "txtCategory", "txtMethod", "txtCriteria", "txtTesterNo",
                              "txtTesterName", "txtNotes", "txtOther", "txtPCode", "txtPName", "txtPDesc" })
        s.AddVariable(c, txt);
    s.AddVariable("ddEqType", dd); s.AddVariable("txtEqCode", txt); s.AddVariable("txtEqName", txt); s.AddVariable("txtEqNote", txt);
    s.AddVariable("ddProduct", dd); s.AddVariable("ddAdmProduct", dd);
    s.AddVariable("galEq", R(("AllItems", galEqRow.ToTable())));
    s.AddVariable("ParentX", R(("Width", N), ("Height", N), ("TemplateWidth", N), ("TemplateHeight", N)));
    return s;
}

var config = new PowerFxConfig(Features.PowerFxV1) { MaximumExpressionLength = 200000 };
config.EnableSetFunction();
var engine = new RecalcEngine(config);

string Prep(string f, string control)
{
    f = f.Replace("DataSourceInfo(InspItems, DataSourceInfo.EditPermission)", "true");
    f = Regex.Replace(f, @"Refresh\(\w+\)", "true");
    f = Regex.Replace(f, @"Navigate\(\w+, ScreenTransition\.\w+\)", "true");
    f = Regex.Replace(f, @"Notify\((""[^""]*""), NotificationType\.\w+\)", "Len($1) > 0");
    f = f.Replace("User().FullName", "\"user\"");
    f = Regex.Replace(f, @"Defaults\((\w+)\)", "First(FirstN($1, 0))");
    f = Regex.Replace(f, @"RemoveIf\(", "Filter(");
    f = f.Replace("Select(Parent)", "true");
    f = Regex.Replace(f, @"\bSelf\.", control + ".");
    f = Regex.Replace(f, @"\bParent\.", "ParentX.");
    f = Regex.Replace(f, @"\b(DropShadow|FontWeight|Align|VerticalAlign|TextMode|DisplayMode|AlignInContainer|LayoutDirection|LayoutOverflow|LayoutAlignItems)\.\w+", "0");
    return f;
}

int errors = 0;
foreach (var it in items)
{
    var control = it["control"]!; var prop = it["prop"]!; var gal = it["gallery"];
    var s = Base();
    var thisType = gal switch { "galItems" => (RecordType?)colItem, "galAdmItems" => item, "galEq" => editEq, _ => null };
    if (thisType != null) s.AddVariable("ThisItemX", thisType);
    var f = Prep(it["formula"]!, control);
    if (thisType != null) f = Regex.Replace(f, @"\bThisItem\b", "ThisItemX");
    var behavior = prop.StartsWith("On");
    var res = engine.Check(f, new ParserOptions { AllowsSideEffects = behavior }, s);
    var problems = res.Errors.Where(e => e.Severity >= ErrorSeverity.Warning).Select(e => e.ToString()).ToList();
    if (res.IsSuccess)
    {
        var t = res.ReturnType;
        bool bad = prop switch
        {
            "Visible" => t is not BooleanType,
            "Text" or "HintText" or "HtmlText" => t is not StringType,
            "Items" => t is not TableType,
            _ => false
        };
        if (bad) problems.Add($"unexpected type {t.GetType().Name}");
    }
    if (problems.Count > 0)
    {
        errors++;
        Console.WriteLine($"[{it["screen"]}] {control}.{prop}:");
        foreach (var p in problems) Console.WriteLine("    " + p);
    }
}
Console.WriteLine($"checked {items.Count} formulas, {errors} with errors");
