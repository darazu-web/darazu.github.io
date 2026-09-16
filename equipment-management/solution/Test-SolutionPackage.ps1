<#
.SYNOPSIS
    生成したソリューション zip を取り込む前に検査します。Dataverse には接続しません。
.DESCRIPTION
    取り込みに失敗すると Power Platform のエラーは分かりにくいので、
    手元で見つけられる種類の間違いは先に潰します。

    検査する内容:
      1. zip の構成（必要な3ファイルが直下にあるか）
      2. XML が壊れていないか
      3. RootComponents と実体の対応（宣言だけあって中身がない／その逆）
      4. ビューが参照する列・テーブルがスキーマに実在するか
      5. フォームの各コントロールが実在する列を指しているか
      6. サブグリッドの ViewId が実在し、対象テーブルが一致しているか
      7. サイトマップのサブエリアが実在するテーブルを指しているか
      8. アプリが参照するサイトマップ・フォーム・ビューの対応
      9. GUID の重複
.EXAMPLE
    .\Test-SolutionPackage.ps1
.EXAMPLE
    .\Test-SolutionPackage.ps1 -ZipPath .\dist\EquipmentManagementApp_1_0_0_0.zip
#>
[CmdletBinding()]
param(
    [string]$ZipPath,
    [string]$SchemaFile = (Join-Path $PSScriptRoot '..\schema\dataverse-schema.json'),
    [string]$OutputDir  = (Join-Path $PSScriptRoot 'dist')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\scripts\Dataverse.psm1') -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem

$schema = Get-Content -LiteralPath $SchemaFile -Raw -Encoding UTF8 | ConvertFrom-Json

$script:Problems = New-Object System.Collections.ArrayList
function Add-Problem { param([string]$Area, [string]$Message) [void]$script:Problems.Add([pscustomobject]@{ Area = $Area; Message = $Message }) }

# ---------- スキーマ側の索引 ----------
$validAttrs = @{}   # テーブル論理名 -> 列論理名の集合
foreach ($t in $schema.tables) {
    $tl = $t.schemaName.ToLower()
    $set = New-Object System.Collections.Generic.HashSet[string]
    [void]$set.Add($t.primaryName.schemaName.ToLower())
    foreach ($c in $t.columns) { [void]$set.Add($c.schemaName.ToLower()) }
    [void]$set.Add("${tl}id")
    foreach ($sys in 'statecode','statuscode','createdon','modifiedon','ownerid','createdby','modifiedby') { [void]$set.Add($sys) }
    $validAttrs[$tl] = $set
}
foreach ($r in $schema.relationships) { [void]$validAttrs[$r.referencing.ToLower()].Add($r.lookup.schemaName.ToLower()) }
$validRelationships = New-Object System.Collections.Generic.HashSet[string]
foreach ($r in $schema.relationships) { [void]$validRelationships.Add($r.schemaName) }

function Test-Package {
    param([string]$Zip)

    Write-Host ''
    Write-Step "検査しています: $([IO.Path]::GetFileName($Zip))"
    $label = [IO.Path]::GetFileNameWithoutExtension($Zip)

    # ---------- 1. zip の構成 ----------
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $names = @($archive.Entries | ForEach-Object { $_.FullName })
        foreach ($required in '[Content_Types].xml', 'solution.xml', 'customizations.xml') {
            if ($names -notcontains $required) { Add-Problem "$label/構成" "$required が zip の直下にありません" }
        }
        $extra = @($names | Where-Object { @('[Content_Types].xml','solution.xml','customizations.xml') -notcontains $_ })
        if ($extra.Count -gt 0) { Add-Problem "$label/構成" "余計なファイルが入っています: $($extra -join ', ')" }
        if ($names | Where-Object { $_ -like '*/*' }) { Add-Problem "$label/構成" 'フォルダーを含んでいます。zip の直下にファイルを置いてください' }
    }
    finally { $archive.Dispose() }

    $stage = Join-Path ([IO.Path]::GetTempPath()) ("eqmtest_" + [guid]::NewGuid().ToString('N'))
    [IO.Compression.ZipFile]::ExtractToDirectory($Zip, $stage)

    try {
        # ---------- 2. XML が壊れていないか ----------
        $sol = $null; $cust = $null
        foreach ($f in 'solution.xml', 'customizations.xml', '[Content_Types].xml') {
            $p = Join-Path $stage $f
            if (-not (Test-Path -LiteralPath $p)) { continue }
            try {
                $doc = New-Object Xml.XmlDocument
                $doc.Load($p)
                if ($f -eq 'solution.xml') { $sol = $doc }
                if ($f -eq 'customizations.xml') { $cust = $doc }
            } catch { Add-Problem "$label/XML" "$f を解析できません: $($_.Exception.Message)" }
        }
        if (-not $sol -or -not $cust) { return }

        # ---------- 3. RootComponents と実体の対応 ----------
        $declared = @{}
        foreach ($rc in $sol.SelectNodes('//RootComponent')) {
            $key = "$($rc.type)|$($rc.id.ToUpper())"
            if ($declared.ContainsKey($key)) { Add-Problem "$label/宣言" "RootComponent が重複しています: $key" }
            $declared[$key] = $true
        }

        $actual = @{}
        foreach ($n in $cust.SelectNodes('//systemform/formid'))      { $actual["60|$($n.InnerText.ToUpper())"] = 'フォーム' }
        foreach ($n in $cust.SelectNodes('//savedquery/savedqueryid')) { $actual["26|$($n.InnerText.ToUpper())"] = 'ビュー' }
        foreach ($n in $cust.SelectNodes('//SiteMap/SiteMapId'))       { $actual["62|$($n.InnerText.ToUpper())"] = 'サイトマップ' }
        foreach ($n in $cust.SelectNodes('//AppModule/AppModuleId'))   { $actual["80|$($n.InnerText.ToUpper())"] = 'アプリ' }

        foreach ($k in $declared.Keys) {
            if (-not $actual.ContainsKey($k)) { Add-Problem "$label/宣言" "RootComponent $k に対応する定義が customizations.xml にありません" }
        }
        foreach ($k in $actual.Keys) {
            if (-not $declared.ContainsKey($k)) { Add-Problem "$label/宣言" "$($actual[$k]) $k が RootComponents に載っていません（取り込んでも入りません）" }
        }

        # ---------- 9. GUID の重複 ----------
        $seenGuid = @{}
        foreach ($k in $actual.Keys) {
            $g = $k.Split('|')[1]
            if ($seenGuid.ContainsKey($g)) { Add-Problem "$label/GUID" "GUID が重複しています: $g（$($seenGuid[$g]) と $($actual[$k])）" }
            $seenGuid[$g] = $actual[$k]
        }

        # ---------- 4. ビューの参照先 ----------
        $viewsById = @{}
        foreach ($e in $cust.SelectNodes('//Entities/Entity')) {
            $entityLogical = $e.SelectSingleNode('Name').InnerText
            if (-not $validAttrs.ContainsKey($entityLogical)) {
                Add-Problem "$label/テーブル" "テーブル $entityLogical がスキーマにありません"
                continue
            }

            foreach ($sq in $e.SelectNodes('SavedQueries/savedqueries/savedquery')) {
                $vname = $sq.SelectSingleNode('LocalizedNames/LocalizedName').description
                $vid   = $sq.SelectSingleNode('savedqueryid').InnerText.ToUpper()
                $rtc   = $sq.SelectSingleNode('returnedtypecode').InnerText
                $viewsById[$vid] = @{ Entity = $rtc; Name = $vname }

                if ($rtc -ne $entityLogical) { Add-Problem "$label/ビュー" "『$vname』の returnedtypecode ($rtc) が入れ子のテーブル ($entityLogical) と違います" }

                $fetchEntity = $sq.SelectSingleNode('fetchxml/fetch/entity')
                if (-not $fetchEntity) { Add-Problem "$label/ビュー" "『$vname』に fetchxml がありません"; continue }
                if ($fetchEntity.name -ne $rtc) { Add-Problem "$label/ビュー" "『$vname』の fetch の対象 ($($fetchEntity.name)) が returnedtypecode ($rtc) と違います" }

                foreach ($a in $sq.SelectNodes('fetchxml/fetch/entity/attribute')) {
                    if (-not $validAttrs[$rtc].Contains($a.name)) { Add-Problem "$label/ビュー" "『$vname』が存在しない列を取得しています: $($a.name)" }
                }
                foreach ($o in $sq.SelectNodes('fetchxml/fetch/entity/order')) {
                    if (-not $validAttrs[$rtc].Contains($o.attribute)) { Add-Problem "$label/ビュー" "『$vname』が存在しない列で並べ替えています: $($o.attribute)" }
                }
                foreach ($c in $sq.SelectNodes('.//condition')) {
                    if (-not $validAttrs[$rtc].Contains($c.attribute)) { Add-Problem "$label/ビュー" "『$vname』が存在しない列で絞り込んでいます: $($c.attribute)" }
                }
                # レイアウトの列は fetch で取得していないと表示されない
                $fetched = @($sq.SelectNodes('fetchxml/fetch/entity/attribute') | ForEach-Object { $_.name })
                foreach ($cell in $sq.SelectNodes('layoutxml/grid/row/cell')) {
                    if ($fetched -notcontains $cell.name) { Add-Problem "$label/ビュー" "『$vname』の表示列 $($cell.name) が fetchxml で取得されていません" }
                }
                $gridRow = $sq.SelectSingleNode('layoutxml/grid/row')
                if ($gridRow -and $gridRow.id -ne "${rtc}id") { Add-Problem "$label/ビュー" "『$vname』のレイアウトの id ($($gridRow.id)) が主キー (${rtc}id) と違います" }
            }
        }

        # ---------- 5 & 6. フォーム ----------
        foreach ($e in $cust.SelectNodes('//Entities/Entity')) {
            $entityLogical = $e.SelectSingleNode('Name').InnerText
            if (-not $validAttrs.ContainsKey($entityLogical)) { continue }

            foreach ($sf in $e.SelectNodes('FormXml/forms/systemform')) {
                $fname = $sf.SelectSingleNode('LocalizedNames/LocalizedName').description
                $tabs = @($sf.SelectNodes('form/tabs/tab'))
                if ($tabs.Count -eq 0) { Add-Problem "$label/フォーム" "『$fname』にタブがありません" }

                foreach ($ctrl in $sf.SelectNodes('.//control')) {
                    if ($ctrl.datafieldname) {
                        if (-not $validAttrs[$entityLogical].Contains($ctrl.datafieldname)) {
                            Add-Problem "$label/フォーム" "『$fname』が存在しない列を表示しています: $($ctrl.datafieldname)"
                        }
                    }
                    if ($ctrl.indicationOfSubgrid -eq 'true') {
                        $target = $ctrl.SelectSingleNode('parameters/TargetEntityType').InnerText
                        $rel    = $ctrl.SelectSingleNode('parameters/RelationshipName').InnerText
                        $vid    = $ctrl.SelectSingleNode('parameters/ViewId').InnerText.ToUpper()

                        if (-not $validAttrs.ContainsKey($target)) { Add-Problem "$label/フォーム" "『$fname』のサブグリッドの対象テーブル $target がスキーマにありません" }
                        if (-not $validRelationships.Contains($rel)) { Add-Problem "$label/フォーム" "『$fname』のサブグリッドのリレーション $rel がスキーマにありません" }
                        if (-not $viewsById.ContainsKey($vid)) {
                            Add-Problem "$label/フォーム" "『$fname』のサブグリッドが参照するビュー $vid がこのソリューションにありません"
                        } elseif ($viewsById[$vid].Entity -ne $target) {
                            Add-Problem "$label/フォーム" "『$fname』のサブグリッドのビュー『$($viewsById[$vid].Name)』は $($viewsById[$vid].Entity) 用で、対象 $target と違います"
                        }
                    }
                }

                # 空の cell id が残っていないか
                foreach ($cell in $sf.SelectNodes('.//cell')) {
                    if (-not $cell.id -or $cell.id -notmatch '^\{[0-9A-Fa-f-]{36}\}$') {
                        Add-Problem "$label/フォーム" "『$fname』に GUID が不正なセルがあります: '$($cell.id)'"
                    }
                }
            }
        }

        # ---------- 7 & 8. サイトマップとアプリ ----------
        $siteMapNames = @()
        foreach ($sm in $cust.SelectNodes('//SiteMaps/SiteMap')) {
            $smName = $sm.SelectSingleNode('SiteMapUniqueName').InnerText
            $siteMapNames += $smName
            $subs = @($sm.SelectNodes('SiteMapXml/SiteMap/Area/Group/SubArea'))
            if ($subs.Count -eq 0) { Add-Problem "$label/サイトマップ" "『$smName』にサブエリアがありません" }
            foreach ($sub in $subs) {
                if ($sub.Entity -and -not $validAttrs.ContainsKey($sub.Entity)) {
                    Add-Problem "$label/サイトマップ" "サブエリア $($sub.Id) が存在しないテーブル $($sub.Entity) を指しています"
                }
            }
            $ids = @($subs | ForEach-Object { $_.Id })
            $dupIds = @($ids | Group-Object | Where-Object { $_.Count -gt 1 })
            foreach ($d in $dupIds) { Add-Problem "$label/サイトマップ" "サブエリアの Id が重複しています: $($d.Name)" }
        }

        foreach ($am in $cust.SelectNodes('//AppModules/AppModule')) {
            $amName = $am.SelectSingleNode('AppModuleUniqueName').InnerText
            $smRef  = $am.SelectSingleNode('SiteMapUniqueName')
            if (-not $smRef) {
                Add-Problem "$label/アプリ" "『$amName』にサイトマップの指定がありません"
            } elseif ($siteMapNames -notcontains $smRef.InnerText) {
                Add-Problem "$label/アプリ" "『$amName』が参照するサイトマップ $($smRef.InnerText) がこのソリューションにありません"
            }
            foreach ($comp in $am.SelectNodes('AppModuleComponents/AppModuleComponent')) {
                if ($comp.type -eq '1') {
                    if (-not $validAttrs.ContainsKey($comp.schemaName)) { Add-Problem "$label/アプリ" "『$amName』が存在しないテーブル $($comp.schemaName) を含めています" }
                } else {
                    $key = "$($comp.type)|$($comp.id.ToUpper())"
                    if (-not $actual.ContainsKey($key)) { Add-Problem "$label/アプリ" "『$amName』が、このソリューションにない部品を含めています: $key" }
                }
            }
        }

        # ---------- 集計 ----------
        $nForms = @($cust.SelectNodes('//systemform')).Count
        $nViews = @($cust.SelectNodes('//savedquery')).Count
        $nSm    = @($cust.SelectNodes('//SiteMaps/SiteMap')).Count
        $nApp   = @($cust.SelectNodes('//AppModules/AppModule')).Count
        Write-Host "    フォーム $nForms / ビュー $nViews / サイトマップ $nSm / アプリ $nApp" -ForegroundColor DarkGray
    }
    finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host '========================================' -ForegroundColor White
Write-Host ' ソリューション zip の検査' -ForegroundColor White
Write-Host '========================================' -ForegroundColor White

$targets = @()
if ($ZipPath) { $targets = @($ZipPath) }
else {
    if (-not (Test-Path -LiteralPath $OutputDir)) { throw "出力フォルダーがありません: $OutputDir （先に Build-Solution.ps1 を実行してください）" }
    $targets = @(Get-ChildItem -LiteralPath $OutputDir -Filter '*.zip' | ForEach-Object { $_.FullName })
}
if ($targets.Count -eq 0) { throw '検査する zip がありません。先に Build-Solution.ps1 を実行してください。' }

foreach ($t in $targets) { Test-Package -Zip $t }

Write-Host ''
if ($script:Problems.Count -eq 0) {
    Write-Info "問題は見つかりませんでした（$($targets.Count) 個の zip を検査）"
    Write-Host ''
    Write-Warn '取り込み自体は実環境でしか確認できません。まず開発環境に取り込んでください。'
    Write-Host ''
    exit 0
}

Write-Host "$($script:Problems.Count) 件の問題が見つかりました:" -ForegroundColor Yellow
foreach ($g in ($script:Problems | Group-Object Area)) {
    Write-Host ''
    Write-Host "  [$($g.Name)]" -ForegroundColor Yellow
    foreach ($p in $g.Group) { Write-Host "    - $($p.Message)" }
}
Write-Host ''
exit 1
