<#
.SYNOPSIS
    管理者アプリ（モデル駆動）のソリューション zip を組み立てます。Dataverse には接続しません。
.DESCRIPTION
    schema/dataverse-schema.json と solution/app-definition.json から、
    フォーム・ビュー・サイトマップ・アプリを含む「アンマネージド」ソリューションを生成します。

    出力は2つです。どちらか一方だけを取り込んでください。

      EquipmentManagementApp_<版>.zip            フォーム＋ビュー＋サイトマップ＋アプリ（通常はこちら）
      EquipmentManagementApp_<版>_formsviews.zip フォーム＋ビューのみ（上が取り込めなかったときの保険）

    このソリューションは既存のテーブルに重ねる形です。
    先に scripts\Deploy-Schema.ps1 でテーブルを作成しておいてください。

    GUID は名前から決まる値（UUID version 5）なので、作り直しても同じ ID になります。
    再インポートは追加ではなく更新になります。
.EXAMPLE
    .\Build-Solution.ps1
.EXAMPLE
    .\Build-Solution.ps1 -Version '1.0.1.0' -OutputDir 'C:\temp'
#>
[CmdletBinding()]
param(
    [string]$SchemaFile = (Join-Path $PSScriptRoot '..\schema\dataverse-schema.json'),
    [string]$AppFile    = (Join-Path $PSScriptRoot 'app-definition.json'),
    [string]$OutputDir  = (Join-Path $PSScriptRoot 'dist'),
    [string]$Version
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\scripts\Dataverse.psm1') -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem

$schema = Get-Content -LiteralPath $SchemaFile -Raw -Encoding UTF8 | ConvertFrom-Json
$app    = Get-Content -LiteralPath $AppFile    -Raw -Encoding UTF8 | ConvertFrom-Json
if ($Version) { $app.solution.version = $Version }

$Lang = [int]$app.languageCode

#region ---------- 小道具 ----------

function Esc {
    param([AllowEmptyString()][string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&apos;')
}

function New-DetGuid {
    <# 名前から決まる GUID（RFC 4122 version 5）。作り直しても同じ値になる #>
    param([Parameter(Mandatory)][string]$Name)

    # このソリューション専用の名前空間
    $ns = [guid]'7f3c1d42-6a51-4f8e-9b27-0d5a8c41e6b3'
    $nsBytes = $ns.ToByteArray()
    [Array]::Reverse($nsBytes, 0, 4); [Array]::Reverse($nsBytes, 4, 2); [Array]::Reverse($nsBytes, 6, 2)

    $nameBytes = [Text.Encoding]::UTF8.GetBytes($Name)
    $buffer = New-Object byte[] ($nsBytes.Length + $nameBytes.Length)
    [Array]::Copy($nsBytes, 0, $buffer, 0, $nsBytes.Length)
    [Array]::Copy($nameBytes, 0, $buffer, $nsBytes.Length, $nameBytes.Length)

    $sha1 = [Security.Cryptography.SHA1]::Create()
    try { $hash = $sha1.ComputeHash($buffer) } finally { $sha1.Dispose() }

    $g = New-Object byte[] 16
    [Array]::Copy($hash, 0, $g, 0, 16)
    $g[6] = [byte](($g[6] -band 0x0F) -bor 0x50)   # version 5
    $g[8] = [byte](($g[8] -band 0x3F) -bor 0x80)   # variant RFC 4122
    [Array]::Reverse($g, 0, 4); [Array]::Reverse($g, 4, 2); [Array]::Reverse($g, 6, 2)
    return (New-Object guid (,$g))
}

function Get-TableDef {
    param([string]$Logical)
    return ($schema.tables | Where-Object { $_.schemaName.ToLower() -eq $Logical.ToLower() })
}

# 論理名 → 列情報の索引をあらかじめ作る
$script:ColumnIndex = @{}
foreach ($t in $schema.tables) {
    $tl = $t.schemaName.ToLower()
    $map = @{}
    $map[$t.primaryName.schemaName.ToLower()] = @{ Type = 'string'; DisplayName = $t.primaryName.displayName; IsPrimaryName = $true }
    foreach ($c in $t.columns) {
        $type = 'string'
        if ($c.PSObject.Properties.Name -contains 'type') { $type = $c.type }
        $map[$c.schemaName.ToLower()] = @{ Type = $type; DisplayName = $c.displayName; IsPrimaryName = $false }
    }
    $map["${tl}id"] = @{ Type = 'uniqueidentifier'; DisplayName = $t.displayName; IsPrimaryName = $false }
    $script:ColumnIndex[$tl] = $map
}
foreach ($r in $schema.relationships) {
    $tl = $r.referencing.ToLower()
    $script:ColumnIndex[$tl][$r.lookup.schemaName.ToLower()] =
        @{ Type = 'lookup'; DisplayName = $r.lookup.displayName; IsPrimaryName = $false }
}

# ビューの絞り込みで使う標準列
$SystemAttributes = @{
    'statecode'  = @{ Type = 'choice'; DisplayName = '状態' }
    'statuscode' = @{ Type = 'choice'; DisplayName = 'ステータスの理由' }
    'createdon'  = @{ Type = 'datetime'; DisplayName = '作成日' }
    'modifiedon' = @{ Type = 'datetime'; DisplayName = '更新日' }
    'ownerid'    = @{ Type = 'lookup'; DisplayName = '所有者' }
}

function Get-ColumnInfo {
    param([string]$Table, [string]$Column)
    $tl = $Table.ToLower(); $cl = $Column.ToLower()
    if ($script:ColumnIndex.ContainsKey($tl) -and $script:ColumnIndex[$tl].ContainsKey($cl)) {
        return $script:ColumnIndex[$tl][$cl]
    }
    if ($SystemAttributes.ContainsKey($cl)) { return $SystemAttributes[$cl] }
    throw "列が見つかりません: $Table.$Column"
}

$ClassId = @{
    'string'           = '{4273EDBD-AC1D-40d3-9FB2-095C621B552D}'
    'memo'             = '{E0DECE4B-6FC8-4a8f-A065-082708572369}'
    'int'              = '{C3EFE0C3-0EC6-42be-8349-CBD9079DFD8E}'
    'bool'             = '{67FAC785-CD58-4f9f-ABB3-4B7DDC6ED5ED}'
    'date'             = '{5B773807-9FB2-42db-97C3-7A91EFF8ADFF}'
    'datetime'         = '{5B773807-9FB2-42db-97C3-7A91EFF8ADFF}'
    'choice'           = '{3EF39988-22BB-4f0b-BBBE-64B5A3748AEE}'
    'lookup'           = '{270BD3DB-D9AF-4782-9025-509E298DEC0A}'
    'uniqueidentifier' = '{4273EDBD-AC1D-40d3-9FB2-095C621B552D}'
}
$SubGridClassId = '{E7A81278-8635-4d9e-8D4D-59480B391C5B}'

function New-LocalizedNames {
    param([string]$Text, [int]$Indent = 0)
    $pad = ' ' * $Indent
    return "$pad<LocalizedNames>`n$pad  <LocalizedName description=`"$(Esc $Text)`" languagecode=`"$Lang`" />`n$pad</LocalizedNames>"
}

function New-Descriptions {
    param([string]$Text, [int]$Indent = 0)
    $pad = ' ' * $Indent
    return "$pad<Descriptions>`n$pad  <Description description=`"$(Esc $Text)`" languagecode=`"$Lang`" />`n$pad</Descriptions>"
}

#endregion

#region ---------- ビュー（SavedQuery） ----------

function New-FetchXml {
    param($View)

    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('          <fetch version="1.0" output-format="xml-platform" mapping="logical" returntotalrecordcount="true" no-lock="false" distinct="false">')
    [void]$sb.AppendLine("            <entity name=`"$($View.table)`">")

    foreach ($c in $View.columns) {
        Get-ColumnInfo -Table $View.table -Column $c.name | Out-Null   # 存在確認
        [void]$sb.AppendLine("              <attribute name=`"$($c.name)`" />")
    }
    # 主キーは常に取得する（グリッドの行識別に必要）
    $pk = "$($View.table)id"
    if (-not ($View.columns | Where-Object { $_.name -eq $pk })) {
        [void]$sb.AppendLine("              <attribute name=`"$pk`" />")
    }

    foreach ($o in $View.order) {
        Get-ColumnInfo -Table $View.table -Column $o.attribute | Out-Null
        $desc = 'false'; if ($o.descending) { $desc = 'true' }
        [void]$sb.AppendLine("              <order attribute=`"$($o.attribute)`" descending=`"$desc`" />")
    }

    function Write-Filter {
        param($Filter, [int]$Indent)
        $pad = ' ' * $Indent
        $type = 'and'
        if ($Filter.PSObject.Properties.Name -contains 'type' -and $Filter.type) { $type = $Filter.type }
        [void]$sb.AppendLine("$pad<filter type=`"$type`">")
        if ($Filter.PSObject.Properties.Name -contains 'conditions') {
            foreach ($c in $Filter.conditions) {
                Get-ColumnInfo -Table $View.table -Column $c.attribute | Out-Null
                if ($c.PSObject.Properties.Name -contains 'value' -and $null -ne $c.value) {
                    [void]$sb.AppendLine("$pad  <condition attribute=`"$($c.attribute)`" operator=`"$($c.operator)`" value=`"$(Esc ([string]$c.value))`" />")
                } else {
                    [void]$sb.AppendLine("$pad  <condition attribute=`"$($c.attribute)`" operator=`"$($c.operator)`" />")
                }
            }
        }
        if ($Filter.PSObject.Properties.Name -contains 'filters') {
            foreach ($f in $Filter.filters) { Write-Filter -Filter $f -Indent ($Indent + 2) }
        }
        [void]$sb.AppendLine("$pad</filter>")
    }

    if ($View.filter -and ($View.filter.PSObject.Properties.Name -contains 'conditions')) {
        Write-Filter -Filter $View.filter -Indent 14
    }

    [void]$sb.AppendLine('            </entity>')
    [void]$sb.Append('          </fetch>')
    return $sb.ToString()
}

function New-LayoutXml {
    param($View)
    $t = Get-TableDef -Logical $View.table
    $sb = New-Object Text.StringBuilder
    # object は取り込み時に解決されるため固定値でよい（returnedtypecode が正）
    [void]$sb.AppendLine("          <grid name=`"resultset`" object=`"1`" jump=`"$($t.primaryName.schemaName.ToLower())`" select=`"1`" icon=`"1`" preview=`"1`">")
    [void]$sb.AppendLine("            <row name=`"result`" id=`"$($View.table)id`">")
    foreach ($c in $View.columns) {
        $width = 100
        if ($c.PSObject.Properties.Name -contains 'width' -and $c.width) { $width = [int]$c.width }
        [void]$sb.AppendLine("              <cell name=`"$($c.name)`" width=`"$width`" />")
    }
    [void]$sb.AppendLine('            </row>')
    [void]$sb.Append('          </grid>')
    return $sb.ToString()
}

function New-SavedQueryXml {
    param($View, [guid]$Id)
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('        <savedquery>')
    [void]$sb.AppendLine('          <IsCustomizable>1</IsCustomizable>')
    [void]$sb.AppendLine('          <CanBeDeleted>1</CanBeDeleted>')
    [void]$sb.AppendLine('          <isquickfindquery>0</isquickfindquery>')
    [void]$sb.AppendLine('          <isprivate>0</isprivate>')
    [void]$sb.AppendLine('          <isdefault>0</isdefault>')
    [void]$sb.AppendLine("          <returnedtypecode>$($View.table)</returnedtypecode>")
    [void]$sb.AppendLine("          <savedqueryid>{$($Id.ToString().ToUpper())}</savedqueryid>")
    [void]$sb.AppendLine('          <layoutxml>')
    [void]$sb.AppendLine((New-LayoutXml -View $View))
    [void]$sb.AppendLine('          </layoutxml>')
    [void]$sb.AppendLine('          <querytype>0</querytype>')
    [void]$sb.AppendLine('          <fetchxml>')
    [void]$sb.AppendLine((New-FetchXml -View $View))
    [void]$sb.AppendLine('          </fetchxml>')
    [void]$sb.AppendLine('          <IntroducedVersion>1.0.0.0</IntroducedVersion>')
    [void]$sb.AppendLine((New-LocalizedNames -Text $View.name -Indent 10))
    [void]$sb.AppendLine((New-Descriptions -Text $View.description -Indent 10))
    [void]$sb.Append('        </savedquery>')
    return $sb.ToString()
}

#endregion

#region ---------- フォーム（SystemForm） ----------

function New-FormXml {
    param($Form, [guid]$Id, [hashtable]$ViewIds)

    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('        <systemform>')
    [void]$sb.AppendLine("          <formid>{$($Id.ToString().ToUpper())}</formid>")
    [void]$sb.AppendLine('          <IntroducedVersion>1.0.0.0</IntroducedVersion>')
    [void]$sb.AppendLine('          <FormPresentation>1</FormPresentation>')
    [void]$sb.AppendLine('          <FormActivationState>1</FormActivationState>')
    [void]$sb.AppendLine('          <form>')
    [void]$sb.AppendLine('            <tabs>')

    $tabIndex = 0
    foreach ($tab in $Form.tabs) {
        $tabIndex++
        $tabId = New-DetGuid "$($Form.table)|tab|$($tab.name)"
        $expanded = 'false'; if ($tabIndex -eq 1) { $expanded = 'true' }
        [void]$sb.AppendLine("              <tab name=`"$($tab.name)`" id=`"{$($tabId.ToString().ToUpper())}`" IsUserDefined=`"0`" locklevel=`"0`" showlabel=`"true`" expanded=`"$expanded`">")
        [void]$sb.AppendLine("                <labels><label description=`"$(Esc $tab.label)`" languagecode=`"$Lang`" /></labels>")
        [void]$sb.AppendLine('                <columns>')
        [void]$sb.AppendLine('                  <column width="100%">')
        [void]$sb.AppendLine('                    <sections>')

        foreach ($sec in $tab.sections) {
            $secId = New-DetGuid "$($Form.table)|section|$($tab.name)|$($sec.name)"
            [void]$sb.AppendLine("                      <section name=`"$($sec.name)`" id=`"{$($secId.ToString().ToUpper())}`" IsUserDefined=`"0`" locklevel=`"0`" showlabel=`"true`" showbar=`"false`" columns=`"11`" labelwidth=`"140`" celllabelalignment=`"Left`" celllabelposition=`"Left`">")
            [void]$sb.AppendLine("                        <labels><label description=`"$(Esc $sec.label)`" languagecode=`"$Lang`" /></labels>")
            [void]$sb.AppendLine('                        <rows>')

            if ($sec.PSObject.Properties.Name -contains 'subgrid' -and $sec.subgrid) {
                $sg = $sec.subgrid
                $cellId = New-DetGuid "$($Form.table)|cell|$($sec.name)|subgrid"
                $viewKey = "$($sg.table)|$($sg.view)"
                if (-not $ViewIds.ContainsKey($viewKey)) { throw "サブグリッドが参照するビューがありません: $viewKey" }
                $rows = 8
                if ($sg.PSObject.Properties.Name -contains 'rows' -and $sg.rows) { $rows = [int]$sg.rows }
                [void]$sb.AppendLine('                          <row>')
                [void]$sb.AppendLine("                            <cell id=`"{$($cellId.ToString().ToUpper())}`" showlabel=`"false`" rowspan=`"$rows`" colspan=`"2`" auto=`"false`" locklevel=`"0`">")
                [void]$sb.AppendLine("                              <labels><label description=`"$(Esc $sec.label)`" languagecode=`"$Lang`" /></labels>")
                [void]$sb.AppendLine("                              <control id=`"grid_$($sg.table)`" classid=`"$SubGridClassId`" indicationOfSubgrid=`"true`" uniqueid=`"{$($cellId.ToString().ToUpper())}`">")
                [void]$sb.AppendLine('                                <parameters>')
                [void]$sb.AppendLine("                                  <TargetEntityType>$($sg.table)</TargetEntityType>")
                [void]$sb.AppendLine("                                  <RelationshipName>$($sg.relationship)</RelationshipName>")
                [void]$sb.AppendLine("                                  <ViewId>{$($ViewIds[$viewKey].ToString().ToUpper())}</ViewId>")
                [void]$sb.AppendLine('                                  <IsUserView>false</IsUserView>')
                [void]$sb.AppendLine('                                  <AutoExpand>Fixed</AutoExpand>')
                [void]$sb.AppendLine('                                  <EnableQuickFind>false</EnableQuickFind>')
                [void]$sb.AppendLine('                                  <EnableViewPicker>true</EnableViewPicker>')
                [void]$sb.AppendLine('                                  <EnableJumpBar>false</EnableJumpBar>')
                [void]$sb.AppendLine('                                  <ChartGridMode>Grid</ChartGridMode>')
                [void]$sb.AppendLine('                                  <VisualizationId />')
                [void]$sb.AppendLine('                                  <RelationshipEditable>false</RelationshipEditable>')
                [void]$sb.AppendLine('                                </parameters>')
                [void]$sb.AppendLine('                              </control>')
                [void]$sb.AppendLine('                            </cell>')
                [void]$sb.AppendLine('                          </row>')
            }
            else {
                $readOnly = $false
                if ($sec.PSObject.Properties.Name -contains 'readOnly' -and $sec.readOnly) { $readOnly = $true }
                foreach ($col in $sec.columns) {
                    $logical = $col.ToLower()
                    $info = Get-ColumnInfo -Table $Form.table -Column $logical
                    $cellId = New-DetGuid "$($Form.table)|cell|$($sec.name)|$logical"
                    $disabled = 'false'; if ($readOnly) { $disabled = 'true' }
                    [void]$sb.AppendLine('                          <row>')
                    [void]$sb.AppendLine("                            <cell id=`"{$($cellId.ToString().ToUpper())}`" showlabel=`"true`" locklevel=`"0`">")
                    [void]$sb.AppendLine("                              <labels><label description=`"$(Esc $info.DisplayName)`" languagecode=`"$Lang`" /></labels>")
                    [void]$sb.AppendLine("                              <control id=`"$logical`" classid=`"$($ClassId[$info.Type])`" datafieldname=`"$logical`" disabled=`"$disabled`" />")
                    [void]$sb.AppendLine('                            </cell>')
                    [void]$sb.AppendLine('                          </row>')
                }
            }

            [void]$sb.AppendLine('                        </rows>')
            [void]$sb.AppendLine('                      </section>')
        }

        [void]$sb.AppendLine('                    </sections>')
        [void]$sb.AppendLine('                  </column>')
        [void]$sb.AppendLine('                </columns>')
        [void]$sb.AppendLine('              </tab>')
    }

    [void]$sb.AppendLine('            </tabs>')
    [void]$sb.AppendLine('          </form>')
    [void]$sb.AppendLine('          <IsCustomizable>1</IsCustomizable>')
    [void]$sb.AppendLine('          <CanBeDeleted>1</CanBeDeleted>')
    [void]$sb.AppendLine((New-LocalizedNames -Text $Form.label -Indent 10))
    [void]$sb.Append('        </systemform>')
    return $sb.ToString()
}

#endregion

#region ---------- サイトマップ ----------

function New-SiteMapXml {
    param([guid]$Id)
    $sm = $app.sitemap
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('    <SiteMap>')
    [void]$sb.AppendLine("      <SiteMapUniqueName>$($sm.uniqueName)</SiteMapUniqueName>")
    [void]$sb.AppendLine("      <SiteMapId>{$($Id.ToString().ToUpper())}</SiteMapId>")
    [void]$sb.AppendLine('      <IsAppAware>1</IsAppAware>')
    [void]$sb.AppendLine('      <IntroducedVersion>1.0.0.0</IntroducedVersion>')
    [void]$sb.AppendLine('      <SiteMapXml>')
    [void]$sb.AppendLine("        <SiteMap IntroducedVersion=`"7.0.0.0`" SiteMapName=`"$($sm.uniqueName)`">")
    foreach ($area in $sm.areas) {
        [void]$sb.AppendLine("          <Area Id=`"$($area.id)`" ShowGroups=`"true`" Title=`"$(Esc $area.title)`">")
        [void]$sb.AppendLine("            <Titles><Title LCID=`"$Lang`" Title=`"$(Esc $area.title)`" /></Titles>")
        foreach ($group in $area.groups) {
            [void]$sb.AppendLine("            <Group Id=`"$($group.id)`" Title=`"$(Esc $group.title)`">")
            [void]$sb.AppendLine("              <Titles><Title LCID=`"$Lang`" Title=`"$(Esc $group.title)`" /></Titles>")
            foreach ($sub in $group.subAreas) {
                Get-TableDef -Logical $sub.table | Out-Null
                [void]$sb.AppendLine("              <SubArea Id=`"$($sub.id)`" Entity=`"$($sub.table)`" Client=`"All`" AvailableOffline=`"true`" PassParams=`"false`" Sku=`"All`">")
                [void]$sb.AppendLine("                <Titles><Title LCID=`"$Lang`" Title=`"$(Esc $sub.title)`" /></Titles>")
                [void]$sb.AppendLine('              </SubArea>')
            }
            [void]$sb.AppendLine('            </Group>')
        }
        [void]$sb.AppendLine('          </Area>')
    }
    [void]$sb.AppendLine('        </SiteMap>')
    [void]$sb.AppendLine('      </SiteMapXml>')
    [void]$sb.Append('    </SiteMap>')
    return $sb.ToString()
}

#endregion

#region ---------- アプリ（AppModule） ----------

function New-AppModuleXml {
    param([guid]$Id, [guid[]]$FormIds, [guid[]]$ViewIds, [string[]]$Tables)
    $a = $app.app
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('    <AppModule>')
    [void]$sb.AppendLine("      <AppModuleUniqueName>$($a.uniqueName)</AppModuleUniqueName>")
    [void]$sb.AppendLine("      <AppModuleId>{$($Id.ToString().ToUpper())}</AppModuleId>")
    [void]$sb.AppendLine("      <Url>$($a.uniqueName)</Url>")
    [void]$sb.AppendLine('      <ClientType>4</ClientType>')
    [void]$sb.AppendLine('      <FormFactor>1</FormFactor>')
    [void]$sb.AppendLine('      <IsDefault>0</IsDefault>')
    [void]$sb.AppendLine('      <IsFeatured>0</IsFeatured>')
    [void]$sb.AppendLine('      <NavigationType>0</NavigationType>')
    [void]$sb.AppendLine('      <IntroducedVersion>1.0.0.0</IntroducedVersion>')
    [void]$sb.AppendLine((New-LocalizedNames -Text $a.name -Indent 6))
    [void]$sb.AppendLine((New-Descriptions -Text $a.description -Indent 6))
    [void]$sb.AppendLine("      <SiteMapUniqueName>$($app.sitemap.uniqueName)</SiteMapUniqueName>")
    [void]$sb.AppendLine('      <AppModuleRoleMaps />')
    [void]$sb.AppendLine('      <AppModuleComponents>')
    # 並べ替えてから書く。ハッシュテーブルの列挙順は実行ごとに変わるので、
    # ソートしないと「同じ定義から作ったのに中身が違う zip」ができてしまう。
    foreach ($t in ($Tables  | Sort-Object)) { [void]$sb.AppendLine("        <AppModuleComponent type=`"1`" schemaName=`"$t`" />") }
    foreach ($f in ($FormIds | Sort-Object)) { [void]$sb.AppendLine("        <AppModuleComponent type=`"60`" id=`"{$($f.ToString().ToUpper())}`" />") }
    foreach ($v in ($ViewIds | Sort-Object)) { [void]$sb.AppendLine("        <AppModuleComponent type=`"26`" id=`"{$($v.ToString().ToUpper())}`" />") }
    [void]$sb.AppendLine('      </AppModuleComponents>')
    [void]$sb.Append('    </AppModule>')
    return $sb.ToString()
}

#endregion

#region ---------- 組み立て ----------

Write-Host ''
Write-Host '========================================' -ForegroundColor White
Write-Host ' 管理者アプリ ソリューション zip の作成' -ForegroundColor White
Write-Host '========================================' -ForegroundColor White

# --- ID を先に確定させる ---
$viewIds = @{}
foreach ($v in $app.views) { $viewIds["$($v.table)|$($v.name)"] = New-DetGuid "view|$($v.table)|$($v.name)" }
$formIds = @{}
foreach ($f in $app.forms) { $formIds[$f.table] = New-DetGuid "form|$($f.table)" }
$siteMapId  = New-DetGuid "sitemap|$($app.sitemap.uniqueName)"
$appModuleId = New-DetGuid "appmodule|$($app.app.uniqueName)"

Write-Step "定義を読み込みました（フォーム $($app.forms.Count) / ビュー $($app.views.Count)）"

# --- テーブルごとの Entity ノード ---
$tablesInApp = @()
foreach ($t in $schema.tables) { $tablesInApp += $t.schemaName.ToLower() }

function New-EntitiesXml {
    param([switch]$Quiet)
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('  <Entities>')
    foreach ($t in $schema.tables) {
        $tl = $t.schemaName.ToLower()
        $myForms = @($app.forms | Where-Object { $_.table -eq $tl })
        $myViews = @($app.views | Where-Object { $_.table -eq $tl })
        if ($myForms.Count -eq 0 -and $myViews.Count -eq 0) { continue }

        [void]$sb.AppendLine('    <Entity>')
        [void]$sb.AppendLine("      <Name LocalizedName=`"$(Esc $t.displayName)`" OriginalName=`"$(Esc $t.displayName)`">$tl</Name>")
        [void]$sb.AppendLine('      <EntityInfo>')
        [void]$sb.AppendLine("        <entity Name=`"$($t.schemaName)`">")
        [void]$sb.AppendLine("          <LocalizedNames><LocalizedName description=`"$(Esc $t.displayName)`" languagecode=`"$Lang`" /></LocalizedNames>")
        [void]$sb.AppendLine("          <LocalizedCollectionNames><LocalizedCollectionName description=`"$(Esc $t.displayCollectionName)`" languagecode=`"$Lang`" /></LocalizedCollectionNames>")
        [void]$sb.AppendLine('          <attributes />')
        [void]$sb.AppendLine('        </entity>')
        [void]$sb.AppendLine('      </EntityInfo>')

        if ($myForms.Count -gt 0) {
            [void]$sb.AppendLine('      <FormXml>')
            [void]$sb.AppendLine('        <forms type="main">')
            foreach ($f in $myForms) {
                [void]$sb.AppendLine((New-FormXml -Form $f -Id $formIds[$f.table] -ViewIds $viewIds))
                if (-not $Quiet) { Write-Ok "  フォーム $($t.displayName)" }
            }
            [void]$sb.AppendLine('        </forms>')
            [void]$sb.AppendLine('      </FormXml>')
        }
        if ($myViews.Count -gt 0) {
            [void]$sb.AppendLine('      <SavedQueries>')
            [void]$sb.AppendLine('        <savedqueries>')
            foreach ($v in $myViews) {
                [void]$sb.AppendLine((New-SavedQueryXml -View $v -Id $viewIds["$($v.table)|$($v.name)"]))
                if (-not $Quiet) { Write-Ok "  ビュー   $($t.displayName) / $($v.name)" }
            }
            [void]$sb.AppendLine('        </savedqueries>')
            [void]$sb.AppendLine('      </SavedQueries>')
        }
        [void]$sb.AppendLine('    </Entity>')
    }
    [void]$sb.Append('  </Entities>')
    return $sb.ToString()
}

Write-Step 'フォームとビューを組み立てています'
$entitiesXml = New-EntitiesXml

function New-CustomizationsXml {
    param([switch]$IncludeApp)
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="utf-8"?>')
    [void]$sb.AppendLine("<ImportExportXml version=`"9.2.0.0`" SolutionPackageVersion=`"9.2`" languagecode=`"$Lang`" generatedBy=`"EquipmentManagement`" xmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`">")
    [void]$sb.AppendLine($entitiesXml)
    [void]$sb.AppendLine('  <Roles />')
    [void]$sb.AppendLine('  <Workflows />')
    [void]$sb.AppendLine('  <FieldSecurityProfiles />')
    [void]$sb.AppendLine('  <Templates />')
    [void]$sb.AppendLine('  <EntityMaps />')
    [void]$sb.AppendLine('  <EntityRelationships />')
    [void]$sb.AppendLine('  <OrganizationSettings />')
    [void]$sb.AppendLine('  <optionsets />')
    [void]$sb.AppendLine('  <CustomControls />')
    [void]$sb.AppendLine('  <SolutionPluginAssemblies />')
    [void]$sb.AppendLine('  <EntityDataProviders />')
    if ($IncludeApp) {
        [void]$sb.AppendLine('  <SiteMaps>')
        [void]$sb.AppendLine((New-SiteMapXml -Id $siteMapId))
        [void]$sb.AppendLine('  </SiteMaps>')
        [void]$sb.AppendLine('  <AppModules>')
        [void]$sb.AppendLine((New-AppModuleXml -Id $appModuleId `
            -FormIds ([guid[]]@($formIds.Values)) -ViewIds ([guid[]]@($viewIds.Values)) -Tables $tablesInApp))
        [void]$sb.AppendLine('  </AppModules>')
    }
    [void]$sb.AppendLine("  <Languages>`n    <Language>$Lang</Language>`n  </Languages>")
    [void]$sb.Append('</ImportExportXml>')
    return $sb.ToString()
}

function New-SolutionXml {
    param([switch]$IncludeApp)
    # 公開元と接頭辞は schema/dataverse-schema.json が正（2か所に持つとずれる）
    $p = $schema.publisher
    $s = $app.solution
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="utf-8"?>')
    [void]$sb.AppendLine("<ImportExportXml version=`"9.2.0.0`" SolutionPackageVersion=`"9.2`" languagecode=`"$Lang`" generatedBy=`"EquipmentManagement`" xmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`">")
    [void]$sb.AppendLine('  <SolutionManifest>')
    [void]$sb.AppendLine("    <UniqueName>$($s.uniqueName)</UniqueName>")
    [void]$sb.AppendLine((New-LocalizedNames -Text $s.friendlyName -Indent 4))
    [void]$sb.AppendLine((New-Descriptions -Text $s.description -Indent 4))
    [void]$sb.AppendLine("    <Version>$($s.version)</Version>")
    [void]$sb.AppendLine('    <Managed>0</Managed>')
    [void]$sb.AppendLine('    <Publisher>')
    [void]$sb.AppendLine("      <UniqueName>$($p.uniqueName)</UniqueName>")
    [void]$sb.AppendLine((New-LocalizedNames -Text $p.friendlyName -Indent 6))
    [void]$sb.AppendLine((New-Descriptions -Text $p.description -Indent 6))
    [void]$sb.AppendLine('      <EMailAddress xsi:nil="true"></EMailAddress>')
    [void]$sb.AppendLine('      <SupportingWebsiteUrl xsi:nil="true"></SupportingWebsiteUrl>')
    [void]$sb.AppendLine("      <CustomizationPrefix>$($p.customizationPrefix)</CustomizationPrefix>")
    [void]$sb.AppendLine("      <CustomizationOptionValuePrefix>$($p.optionValuePrefix)</CustomizationOptionValuePrefix>")
    [void]$sb.AppendLine('      <Addresses>')
    foreach ($n in 1, 2) {
        [void]$sb.AppendLine('        <Address>')
        [void]$sb.AppendLine("          <AddressNumber>$n</AddressNumber>")
        [void]$sb.AppendLine("          <AddressTypeCode>$n</AddressTypeCode>")
        foreach ($f in 'City','County','Country','Fax','FreightTermsCode','ImportSequenceNumber','Latitude','Line1','Line2','Line3','Longitude','Name','PostalCode','PostOfficeBox','PrimaryContactName','ShippingMethodCode','StateOrProvince','Telephone1','Telephone2','Telephone3','TimeZoneRuleVersionNumber','UPSZone','UTCOffset','UTCConversionTimeZoneCode') {
            [void]$sb.AppendLine("          <$f xsi:nil=`"true`"></$f>")
        }
        [void]$sb.AppendLine('        </Address>')
    }
    [void]$sb.AppendLine('      </Addresses>')
    [void]$sb.AppendLine('    </Publisher>')
    [void]$sb.AppendLine('    <RootComponents>')
    foreach ($id in ($formIds.Values | Sort-Object)) { [void]$sb.AppendLine("      <RootComponent type=`"60`" id=`"{$($id.ToString().ToUpper())}`" behavior=`"0`" />") }
    foreach ($id in ($viewIds.Values | Sort-Object)) { [void]$sb.AppendLine("      <RootComponent type=`"26`" id=`"{$($id.ToString().ToUpper())}`" behavior=`"0`" />") }
    if ($IncludeApp) {
        [void]$sb.AppendLine("      <RootComponent type=`"62`" id=`"{$($siteMapId.ToString().ToUpper())}`" behavior=`"0`" />")
        [void]$sb.AppendLine("      <RootComponent type=`"80`" id=`"{$($appModuleId.ToString().ToUpper())}`" behavior=`"0`" />")
    }
    [void]$sb.AppendLine('    </RootComponents>')
    [void]$sb.AppendLine('    <MissingDependencies />')
    [void]$sb.AppendLine('  </SolutionManifest>')
    [void]$sb.Append('</ImportExportXml>')
    return $sb.ToString()
}

$ContentTypesXml = @'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="xml" ContentType="text/xml" />
</Types>
'@

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $enc = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Text, $enc)
}

function Build-Package {
    param([string]$ZipPath, [switch]$IncludeApp)

    $stage = Join-Path ([IO.Path]::GetTempPath()) ("eqmsol_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        Write-Utf8NoBom -Path (Join-Path $stage '[Content_Types].xml') -Text $ContentTypesXml
        Write-Utf8NoBom -Path (Join-Path $stage 'solution.xml')        -Text (New-SolutionXml -IncludeApp:$IncludeApp)
        Write-Utf8NoBom -Path (Join-Path $stage 'customizations.xml')  -Text (New-CustomizationsXml -IncludeApp:$IncludeApp)

        # 生成した XML が壊れていないか、zip にする前に確かめる
        foreach ($f in 'solution.xml', 'customizations.xml', '[Content_Types].xml') {
            $doc = New-Object Xml.XmlDocument
            $doc.Load((Join-Path $stage $f))
        }

        if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
        [IO.Compression.ZipFile]::CreateFromDirectory($stage, $ZipPath, [IO.Compression.CompressionLevel]::Optimal, $false)
    }
    finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$verTag = $app.solution.version.Replace('.', '_')
$fullZip  = Join-Path $OutputDir "$($app.solution.uniqueName)_$verTag.zip"
$plainZip = Join-Path $OutputDir "$($app.solution.uniqueName)_${verTag}_formsviews.zip"

Write-Step 'zip を書き出しています'
Build-Package -ZipPath $fullZip  -IncludeApp
Build-Package -ZipPath $plainZip

Write-Host ''
Write-Info "$([IO.Path]::GetFileName($fullZip))  （フォーム＋ビュー＋サイトマップ＋アプリ / $([math]::Round((Get-Item $fullZip).Length / 1KB, 1)) KB）"
Write-Info "$([IO.Path]::GetFileName($plainZip))  （フォーム＋ビューのみ / $([math]::Round((Get-Item $plainZip).Length / 1KB, 1)) KB）"
Write-Host ''
Write-Host '取り込みかた:' -ForegroundColor White
Write-Host '  1. 先に scripts\Deploy-Schema.ps1 でテーブルを作っておく（これが前提です）'
Write-Host '  2. make.powerapps.com > ソリューション > 「ソリューションのインポート」'
Write-Host "  3. $([IO.Path]::GetFileName($fullZip)) を選ぶ（どちらか一方だけを取り込みます）"
Write-Host '  4. 取り込み後、アプリ「設備管理（管理者）」を「設備-管理者」チームに共有する'
Write-Host ''
Write-Host '  アプリの取り込みでエラーになったときは、_formsviews のほうを取り込み、'
Write-Host '  アプリだけメーカーポータルで新規作成してください（フォームとビューは入った状態になります）。'
Write-Host ''

#endregion
