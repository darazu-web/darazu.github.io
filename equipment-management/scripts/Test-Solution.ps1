<#
.SYNOPSIS
    スキーマ定義・Power Fx・CSV の食い違いを検査します。Dataverse には接続しません。
.DESCRIPTION
    列の表示名を1つ変えると、数式・CSV の見出し・セキュリティ定義の3か所がずれます。
    このスクリプトはその「ずれ」を見つけます。スキーマを触ったら必ず流してください。

    検査する内容:
      1. スキーマ定義そのものの整合性（重複・参照先の欠落・代替キーの指定ミス）
      2. Power Fx が参照している選択肢・列・テーブルが実在するか
      3. CSV の見出しがスキーマの表示名と一致しているか
      4. セキュリティ定義が実在するテーブル・列を指しているか
      5. 表示名が Power Fx でそのまま書けるか（空白・記号・数字始まりがないか）
      6. 管理者アプリの定義（solution/app-definition.json）が実在する列・テーブルを指しているか
.EXAMPLE
    .\Test-Solution.ps1
#>
[CmdletBinding()]
param(
    [string]$Root = (Join-Path $PSScriptRoot '..')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Dataverse.psm1') -Force

$schema = Get-Content -LiteralPath (Join-Path $Root 'schema\dataverse-schema.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$sec    = Get-Content -LiteralPath (Join-Path $Root 'schema\security.json')         -Raw -Encoding UTF8 | ConvertFrom-Json

$script:Problems = New-Object System.Collections.ArrayList
function Add-Problem { param([string]$Area, [string]$Message) [void]$script:Problems.Add([pscustomobject]@{ Area = $Area; Message = $Message }) }

Write-Host ''
Write-Host '========================================' -ForegroundColor White
Write-Host ' 設備管理ソリューション 整合性チェック' -ForegroundColor White
Write-Host '========================================' -ForegroundColor White

#region ---------- 1. スキーマ定義の整合性 ----------

Write-Step 'スキーマ定義を検査しています'

$tableBySchema  = @{}
$tableByDisplay = @{}
foreach ($t in $schema.tables) {
    if ($tableBySchema.ContainsKey($t.schemaName))   { Add-Problem 'スキーマ' "テーブル $($t.schemaName) が重複しています" }
    if ($tableByDisplay.ContainsKey($t.displayName)) { Add-Problem 'スキーマ' "テーブル表示名『$($t.displayName)』が重複しています" }
    $tableBySchema[$t.schemaName]   = $t
    $tableByDisplay[$t.displayName] = $t

    # 列の重複
    $seenCol = @{}
    $seenDisp = @{}
    foreach ($c in $t.columns) {
        if ($seenCol.ContainsKey($c.schemaName))    { Add-Problem 'スキーマ' "$($t.displayName): 列 $($c.schemaName) が重複しています" }
        if ($seenDisp.ContainsKey($c.displayName))  { Add-Problem 'スキーマ' "$($t.displayName): 列表示名『$($c.displayName)』が重複しています" }
        $seenCol[$c.schemaName] = $true
        $seenDisp[$c.displayName] = $true

        if ($c.schemaName -cne $c.schemaName.ToLower()) { Add-Problem 'スキーマ' "$($t.displayName).$($c.schemaName): 列のスキーマ名は小文字で書いてください" }
        if (-not $c.schemaName.StartsWith("$($schema.prefix)_")) { Add-Problem 'スキーマ' "$($t.displayName).$($c.schemaName): 接頭辞 $($schema.prefix)_ がありません" }
        if ($c.type -eq 'choice') {
            if (-not $c.options -or $c.options.Count -eq 0) { Add-Problem 'スキーマ' "$($t.displayName).$($c.displayName): 選択肢が空です" }
            $vals = @($c.options | ForEach-Object { $_.value })
            if (($vals | Select-Object -Unique).Count -ne $vals.Count) { Add-Problem 'スキーマ' "$($t.displayName).$($c.displayName): 選択肢の値が重複しています" }
        }
    }

    # 代替キーが実在する列を指しているか
    if ($t.alternateKeys) {
        foreach ($k in $t.alternateKeys) {
            foreach ($kc in $k.columns) {
                if (-not $seenCol.ContainsKey($kc)) { Add-Problem 'スキーマ' "$($t.displayName): 代替キー $($k.schemaName) が存在しない列 $kc を指しています" }
            }
        }
    }
}

$relSeen = @{}
foreach ($r in $schema.relationships) {
    if ($relSeen.ContainsKey($r.schemaName)) { Add-Problem 'スキーマ' "リレーション $($r.schemaName) が重複しています" }
    $relSeen[$r.schemaName] = $true
    if (-not $tableBySchema.ContainsKey($r.referenced))  { Add-Problem 'スキーマ' "$($r.schemaName): 参照先テーブル $($r.referenced) がありません" }
    if (-not $tableBySchema.ContainsKey($r.referencing)) { Add-Problem 'スキーマ' "$($r.schemaName): 参照元テーブル $($r.referencing) がありません" }
    if (@('Restrict','Cascade','RemoveLink','NoCascade') -notcontains $r.cascade) {
        Add-Problem 'スキーマ' "$($r.schemaName): cascade の値 '$($r.cascade)' は使えません"
    }
    # 参照先に代替キーがないと CSV 取り込みで結べない
    $refT = $tableBySchema[$r.referenced]
    if ($refT -and (-not $refT.alternateKeys -or $refT.alternateKeys.Count -eq 0)) {
        Write-Host "    （参考）$($r.schemaName): 参照先 $($refT.displayName) に代替キーがないため、CSV からは結べません" -ForegroundColor DarkGray
    }
}

#endregion

#region ---------- 2. 表示名が Power Fx でそのまま書けるか ----------

Write-Step '表示名が Power Fx の識別子として使えるか検査しています'

function Test-PowerFxIdentifier {
    param([string]$Name)
    # 数字・記号・空白で始まらず、英数字と日本語だけで構成されていること
    return $Name -match '^[^\d\W][\w]*$'
}

$allNames = New-Object System.Collections.ArrayList
foreach ($t in $schema.tables) {
    [void]$allNames.Add([pscustomobject]@{ Where = "テーブル"; Name = $t.displayName })
    [void]$allNames.Add([pscustomobject]@{ Where = "$($t.displayName) の主列"; Name = $t.primaryName.displayName })
    foreach ($c in $t.columns) { [void]$allNames.Add([pscustomobject]@{ Where = "$($t.displayName).$($c.schemaName)"; Name = $c.displayName }) }
}
foreach ($r in $schema.relationships) { [void]$allNames.Add([pscustomobject]@{ Where = "$($r.schemaName) の参照列"; Name = $r.lookup.displayName }) }

foreach ($n in $allNames) {
    if (-not (Test-PowerFxIdentifier -Name $n.Name)) {
        Add-Problem '表示名' "$($n.Where): 表示名『$($n.Name)』は Power Fx で引用符が必要です（空白・括弧・数字始まりを避けてください）"
    }
}

#endregion

#region ---------- 3. Power Fx の参照先 ----------

Write-Step 'Power Fx の参照先を検査しています'

# 表示名 → 使える列名の集合
$columnsOf = @{}
foreach ($t in $schema.tables) {
    $set = New-Object System.Collections.Generic.HashSet[string]
    [void]$set.Add($t.primaryName.displayName)
    foreach ($c in $t.columns) { [void]$set.Add($c.displayName) }
    $columnsOf[$t.displayName] = $set
}
foreach ($r in $schema.relationships) {
    $refingDisplay = $tableBySchema[$r.referencing].displayName
    [void]$columnsOf[$refingDisplay].Add($r.lookup.displayName)
}

$allColumnNames = New-Object System.Collections.Generic.HashSet[string]
foreach ($k in $columnsOf.Keys) { foreach ($v in $columnsOf[$k]) { [void]$allColumnNames.Add($v) } }

# 選択肢: 「列表示名 (テーブル表示名)」 → ラベル集合
$choiceLabels = @{}
foreach ($t in $schema.tables) {
    foreach ($c in $t.columns) {
        if ($c.type -ne 'choice') { continue }
        $key = "$($c.displayName) ($($t.displayName))"
        $set = New-Object System.Collections.Generic.HashSet[string]
        foreach ($o in $c.options) { [void]$set.Add($o.label) }
        $choiceLabels[$key] = $set
    }
}

# Power Fx 側で使われる組み込みメンバー（列ではないもの）
$builtinMembers = @('Text','Value','Selected','AllItems','Connected','ActiveScreen','SelectedDate','Email')

$fxFiles = @(Get-ChildItem -LiteralPath (Join-Path $Root 'powerfx') -Filter '*.fx' -ErrorAction SilentlyContinue)
if ($fxFiles.Count -eq 0) { Write-Warn 'powerfx フォルダーに .fx がありません' }

foreach ($f in $fxFiles) {
    $lines = Get-Content -LiteralPath $f.FullName -Encoding UTF8
    # コメント行は検査しない
    $body = ($lines | Where-Object { -not $_.TrimStart().StartsWith('//') }) -join "`n"

    # 3-1. 選択肢参照  '列 (テーブル)'.ラベル
    foreach ($m in [regex]::Matches($body, "'([^'()]+ \([^'()]+\))'\.([^\s,);&]+)")) {
        $key = $m.Groups[1].Value
        $label = $m.Groups[2].Value
        if (-not $choiceLabels.ContainsKey($key)) {
            Add-Problem 'PowerFx' "$($f.Name): 選択肢列 '$key' がスキーマにありません"
        } elseif (-not $choiceLabels[$key].Contains($label)) {
            Add-Problem 'PowerFx' "$($f.Name): '$key'.$label というラベルはありません（使えるのは $(($choiceLabels[$key]) -join ' / ')）"
        }
    }

    # 3-2. 引用符付き識別子（テーブル名のはず）
    foreach ($m in [regex]::Matches($body, "'([^'()\s.]+)'")) {
        $name = $m.Groups[1].Value
        if ($tableByDisplay.ContainsKey($name)) { continue }
        if ($allColumnNames.Contains($name))    { continue }
        Add-Problem 'PowerFx' "$($f.Name): '$name' はテーブル名にも列名にも一致しません"
    }

    # 3-3. ドットに続く列参照（選択肢参照を取り除いてから調べる）
    $stripped = [regex]::Replace($body, "'[^'()]+ \([^'()]+\)'\.[^\s,);&]+", ' ')
    foreach ($m in [regex]::Matches($stripped, '\.([\p{IsHiragana}\p{IsKatakana}\p{IsCJKUnifiedIdeographs}ー][\p{IsHiragana}\p{IsKatakana}\p{IsCJKUnifiedIdeographs}ーA-Za-z0-9]*)')) {
        $name = $m.Groups[1].Value
        if ($builtinMembers -contains $name) { continue }
        if (-not $allColumnNames.Contains($name)) {
            Add-Problem 'PowerFx' "$($f.Name): 列『$name』がスキーマにありません（打ち間違いの可能性）"
        }
    }
}

#endregion

#region ---------- 4. CSV の見出し ----------

Write-Step 'CSV の見出しを検査しています'

foreach ($t in $schema.tables) {
    $csv = Join-Path $Root "data\$($t.entitySetName).csv"
    if (-not (Test-Path -LiteralPath $csv)) { continue }

    $rows = @(Import-Csv -LiteralPath $csv -Encoding UTF8)
    if ($rows.Count -eq 0) { Add-Problem 'CSV' "$($t.entitySetName).csv に行がありません"; continue }

    $headers = $rows[0].PSObject.Properties.Name
    foreach ($h in $headers) {
        if (-not $columnsOf[$t.displayName].Contains($h)) {
            Add-Problem 'CSV' "$($t.entitySetName).csv: 見出し『$h』は $($t.displayName) の列にありません"
        }
    }
    if ($t.alternateKeys -and $t.alternateKeys.Count -gt 0) {
        $keyCol = $t.alternateKeys[0].columns[0]
        $keyDisp = ($t.columns | Where-Object { $_.schemaName -eq $keyCol }).displayName
        if ($headers -notcontains $keyDisp) {
            Add-Problem 'CSV' "$($t.entitySetName).csv: 代替キー列『$keyDisp』の見出しがありません"
        }
    }
}

#endregion

#region ---------- 5. セキュリティ定義 ----------

Write-Step 'セキュリティ定義を検査しています'

$validDepths = @('Basic','Local','Deep','Global')
$validActions = @('Create','Read','Write','Delete','Append','AppendTo','Assign','Share')

foreach ($role in $sec.roles) {
    foreach ($tp in $role.tablePrivileges) {
        if (-not $tableBySchema.ContainsKey($tp.table)) {
            Add-Problem 'セキュリティ' "ロール『$($role.name)』: テーブル $($tp.table) がスキーマにありません"
            continue
        }
        foreach ($action in $tp.privileges.PSObject.Properties.Name) {
            if ($validActions -notcontains $action) { Add-Problem 'セキュリティ' "ロール『$($role.name)』: 権限 $action は使えません" }
            $depth = $tp.privileges.$action
            if ($validDepths -notcontains $depth) { Add-Problem 'セキュリティ' "ロール『$($role.name)』: $($tp.table).$action の範囲 '$depth' は使えません" }
        }
    }
}

foreach ($p in $sec.columnSecurityProfiles) {
    foreach ($perm in $p.permissions) {
        $t = $tableBySchema[$perm.table]
        if (-not $t) { Add-Problem 'セキュリティ' "プロファイル『$($p.name)』: テーブル $($perm.table) がありません"; continue }
        $col = $t.columns | Where-Object { $_.schemaName -eq $perm.column }
        if (-not $col) {
            Add-Problem 'セキュリティ' "プロファイル『$($p.name)』: 列 $($perm.column) が $($perm.table) にありません"
        } elseif (-not ($col.PSObject.Properties.Name -contains 'columnSecurity' -and $col.columnSecurity)) {
            Add-Problem 'セキュリティ' "プロファイル『$($p.name)』: $($perm.column) は columnSecurity=true になっていません（スキーマ側で保護対象にしてください）"
        }
    }
}

#endregion

#region ---------- 6. 管理者アプリの定義 ----------

$appFile = Join-Path $Root 'solution\app-definition.json'
if (Test-Path -LiteralPath $appFile) {
    Write-Step '管理者アプリの定義を検査しています'
    $appDef = Get-Content -LiteralPath $appFile -Raw -Encoding UTF8 | ConvertFrom-Json

    # テーブル論理名 -> 使える列（論理名）
    $logicalCols = @{}
    foreach ($t in $schema.tables) {
        $tl = $t.schemaName.ToLower()
        $set = New-Object System.Collections.Generic.HashSet[string]
        [void]$set.Add($t.primaryName.schemaName.ToLower())
        foreach ($c in $t.columns) { [void]$set.Add($c.schemaName.ToLower()) }
        [void]$set.Add("${tl}id")
        foreach ($sys in 'statecode','statuscode','createdon','modifiedon','ownerid','createdby','modifiedby') { [void]$set.Add($sys) }
        $logicalCols[$tl] = $set
    }
    foreach ($r in $schema.relationships) { [void]$logicalCols[$r.referencing.ToLower()].Add($r.lookup.schemaName.ToLower()) }
    $relNames = @($schema.relationships | ForEach-Object { $_.schemaName })

    function Test-AppTable {
        param([string]$Table, [string]$Where)
        if (-not $logicalCols.ContainsKey($Table)) { Add-Problem 'アプリ定義' "$Where : テーブル $Table がスキーマにありません"; return $false }
        return $true
    }
    function Test-AppColumn {
        param([string]$Table, [string]$Column, [string]$Where)
        if (-not $logicalCols.ContainsKey($Table)) { return }
        if (-not $logicalCols[$Table].Contains($Column.ToLower())) { Add-Problem 'アプリ定義' "$Where : 列 $Column が $Table にありません" }
    }

    # ビュー
    $viewKeys = New-Object System.Collections.Generic.HashSet[string]
    foreach ($v in $appDef.views) {
        $where = "ビュー『$($v.name)』"
        [void]$viewKeys.Add("$($v.table)|$($v.name)")
        if (-not (Test-AppTable -Table $v.table -Where $where)) { continue }
        foreach ($c in $v.columns) { Test-AppColumn -Table $v.table -Column $c.name -Where $where }
        foreach ($o in $v.order)   { Test-AppColumn -Table $v.table -Column $o.attribute -Where "$where の並べ替え" }
        function Test-AppFilter {
            param($Filter, [string]$Table, [string]$Where)
            if (-not $Filter) { return }
            if ($Filter.PSObject.Properties.Name -contains 'conditions') {
                foreach ($c in $Filter.conditions) { Test-AppColumn -Table $Table -Column $c.attribute -Where "$Where の絞り込み" }
            }
            if ($Filter.PSObject.Properties.Name -contains 'filters') {
                foreach ($f in $Filter.filters) { Test-AppFilter -Filter $f -Table $Table -Where $Where }
            }
        }
        Test-AppFilter -Filter $v.filter -Table $v.table -Where $where
    }
    $dupViews = @($appDef.views | Group-Object { "$($_.table)|$($_.name)" } | Where-Object { $_.Count -gt 1 })
    foreach ($d in $dupViews) { Add-Problem 'アプリ定義' "ビュー名が同じテーブル内で重複しています: $($d.Name)" }

    # フォーム
    foreach ($f in $appDef.forms) {
        $where = "フォーム『$($f.label)』"
        if (-not (Test-AppTable -Table $f.table -Where $where)) { continue }
        foreach ($tab in $f.tabs) {
            foreach ($sec in $tab.sections) {
                if ($sec.PSObject.Properties.Name -contains 'subgrid' -and $sec.subgrid) {
                    $sg = $sec.subgrid
                    Test-AppTable -Table $sg.table -Where "$where のサブグリッド" | Out-Null
                    if ($relNames -notcontains $sg.relationship) { Add-Problem 'アプリ定義' "$where : リレーション $($sg.relationship) がスキーマにありません" }
                    if (-not $viewKeys.Contains("$($sg.table)|$($sg.view)")) { Add-Problem 'アプリ定義' "$where : サブグリッドが参照するビュー『$($sg.view)』($($sg.table)) が定義されていません" }
                } else {
                    foreach ($col in $sec.columns) { Test-AppColumn -Table $f.table -Column $col -Where "$where / $($sec.label)" }
                }
            }
        }
    }
    $formTables = @($appDef.forms | ForEach-Object { $_.table })
    foreach ($t in $schema.tables) {
        if ($formTables -notcontains $t.schemaName.ToLower()) {
            Write-Host "    （参考）$($t.displayName) のフォームがアプリ定義にありません。既定のフォームが使われます" -ForegroundColor DarkGray
        }
    }

    # サイトマップ
    $subIds = @()
    foreach ($area in $appDef.sitemap.areas) {
        foreach ($group in $area.groups) {
            foreach ($sub in $group.subAreas) {
                $subIds += $sub.id
                Test-AppTable -Table $sub.table -Where "サイトマップのサブエリア $($sub.id)" | Out-Null
            }
        }
    }
    foreach ($d in @($subIds | Group-Object | Where-Object { $_.Count -gt 1 })) {
        Add-Problem 'アプリ定義' "サイトマップのサブエリア Id が重複しています: $($d.Name)"
    }
}

#endregion

#region ---------- 結果 ----------

Write-Host ''
if ($script:Problems.Count -eq 0) {
    Write-Info "問題は見つかりませんでした（テーブル $($schema.tables.Count) / リレーション $($schema.relationships.Count) / 数式 $($fxFiles.Count) ファイル / アプリ定義 フォーム $(@($appDef.forms).Count)・ビュー $(@($appDef.views).Count)）"
    Write-Host ''
    exit 0
}

Write-Host "$($script:Problems.Count) 件の問題が見つかりました:" -ForegroundColor Yellow
foreach ($g in ($script:Problems | Group-Object Area)) {
    Write-Host ""
    Write-Host "  [$($g.Name)]" -ForegroundColor Yellow
    foreach ($p in $g.Group) { Write-Host "    - $($p.Message)" }
}
Write-Host ''
exit 1

#endregion
