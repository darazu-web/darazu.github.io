<#
.SYNOPSIS
    CSV から Dataverse へマスタデータを投入します（フェーズ2-1〜2-3）。
.DESCRIPTION
    CSV の見出し行には schema/dataverse-schema.json の「表示名」をそのまま使います。
    参照列（種別・場所・部署など）は、参照先の代替キーの値を書きます。
      例) 設備 CSV の「種別」列には設備種別の「種別コード」を書く
    選択肢列は選択肢のラベルをそのまま書きます（例: ステータス列に「空き」）。
    空欄の列は「変更しない」扱いです。上書きしたくない列は空にしておいてください。

    代替キーでの upsert なので、何度流しても重複しません。台帳を直したら流し直すだけです。
.EXAMPLE
    .\Import-MasterData.ps1 -EnvironmentUrl 'https://contoso-dev.crm7.dynamics.com' -All
.EXAMPLE
    .\Import-MasterData.ps1 -EnvironmentUrl 'https://contoso-dev.crm7.dynamics.com' -Table 設備 -CsvPath .\equipment.csv
.EXAMPLE
    # まず中身だけ確認する
    .\Import-MasterData.ps1 -EnvironmentUrl 'https://contoso-dev.crm7.dynamics.com' -All -WhatIfOnly
#>
[CmdletBinding(DefaultParameterSetName = 'All')]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [Parameter(ParameterSetName = 'All')][switch]$All,
    [Parameter(ParameterSetName = 'One', Mandatory)][string]$Table,
    [Parameter(ParameterSetName = 'One')][string]$CsvPath,
    [string]$DataDir    = (Join-Path $PSScriptRoot '..\data'),
    [string]$SchemaFile = (Join-Path $PSScriptRoot '..\schema\dataverse-schema.json'),
    [string]$Encoding   = 'UTF8',
    [string]$TenantId = 'organizations',
    [string]$ClientId,
    [System.Security.SecureString]$ClientSecret,
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Dataverse.psm1') -Force

$schema = Get-Content -LiteralPath $SchemaFile -Raw -Encoding UTF8 | ConvertFrom-Json

# 投入する順番（参照される側から先に入れる）
$ImportOrder = @('設備種別', '場所', '部署', '貸出先', '使用者', '設備')

function Get-TableDef {
    param([string]$DisplayName)
    $t = $schema.tables | Where-Object { $_.displayName -eq $DisplayName }
    if (-not $t) { throw "スキーマに『$DisplayName』というテーブルがありません。指定できるのは: $($ImportOrder -join ', ')" }
    return $t
}

function Get-LookupDefs {
    <# この表を参照元とするリレーション（＝この表に生える参照列）を集める #>
    param($TableDef)
    return @($schema.relationships | Where-Object { $_.referencing -eq $TableDef.schemaName })
}

function ConvertTo-DataverseValue {
    param($Column, [string]$Raw)

    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    $v = $Raw.Trim()

    switch ($Column.type) {
        'int'  { return [int]$v }
        'bool' {
            $trueWords = @('true', '1', 'yes', 'はい', '○', '有効', '可', '通知済み')
            if ($Column.PSObject.Properties.Name -contains 'trueLabel' -and $Column.trueLabel) { $trueWords += $Column.trueLabel }
            return ($trueWords -contains $v.ToLower()) -or ($trueWords -contains $v)
        }
        'date' {
            $d = [datetime]::Parse($v, [Globalization.CultureInfo]::GetCultureInfo('ja-JP'))
            return $d.ToString('yyyy-MM-dd')
        }
        'datetime' {
            $d = [datetime]::Parse($v, [Globalization.CultureInfo]::GetCultureInfo('ja-JP'))
            return $d.ToString('yyyy-MM-ddTHH:mm:ssK')
        }
        'choice' {
            $opt = $Column.options | Where-Object { $_.label -eq $v }
            if (-not $opt) {
                # 数値での指定も許す
                $asInt = 0
                if ([int]::TryParse($v, [ref]$asInt)) {
                    $opt = $Column.options | Where-Object { [int]$_.value -eq $asInt }
                }
            }
            if (-not $opt) {
                throw "『$($Column.displayName)』の値 '$v' は選択肢にありません。使えるのは: $(($Column.options | ForEach-Object { $_.label }) -join ' / ')"
            }
            return [int]$opt.value
        }
        default { return $v }
    }
}

function Import-Table {
    param([string]$DisplayName, [string]$File)

    $t = Get-TableDef -DisplayName $DisplayName
    if (-not $File) { $File = Join-Path $DataDir "$($t.entitySetName).csv" }

    if (-not (Test-Path -LiteralPath $File)) {
        Write-Warn "$DisplayName : CSV が見つからないためスキップします（$File）"
        return
    }
    if (-not $t.alternateKeys -or $t.alternateKeys.Count -eq 0) {
        throw "$DisplayName には代替キーがないため、この方法では投入できません。"
    }

    $keyColumn = $t.alternateKeys[0].columns[0]
    $keyDef    = $t.columns | Where-Object { $_.schemaName -eq $keyColumn }
    $keyHeader = $keyDef.displayName

    $rows = Import-Csv -LiteralPath $File -Encoding $Encoding
    if ($rows.Count -eq 0) { Write-Warn "$DisplayName : 行がありません（$File）"; return }

    $headers   = $rows[0].PSObject.Properties.Name
    $lookups   = Get-LookupDefs -TableDef $t

    # CSV の見出しがスキーマのどれにも当たらない場合は打ち間違いの可能性が高いので知らせる
    $known = @($t.primaryName.displayName) + @($t.columns | ForEach-Object { $_.displayName }) + @($lookups | ForEach-Object { $_.lookup.displayName })
    $unknown = @($headers | Where-Object { $known -notcontains $_ })
    if ($unknown.Count -gt 0) { Write-Warn "$DisplayName : 使われない見出しがあります → $($unknown -join ', ')" }
    if ($headers -notcontains $keyHeader) { throw "$DisplayName : CSV に代替キー列『$keyHeader』がありません。" }

    Write-Step "$DisplayName を投入しています（$($rows.Count) 行 / $([IO.Path]::GetFileName($File))）"

    $okCount = 0; $errCount = 0; $lineNo = 1
    foreach ($row in $rows) {
        $lineNo++
        $keyValue = ("$($row.$keyHeader)").Trim()
        if ([string]::IsNullOrWhiteSpace($keyValue)) { Write-Warn "  $lineNo 行目: $keyHeader が空のためスキップ"; continue }

        try {
            $body = @{}

            # 主キー列（名称）
            if ($headers -contains $t.primaryName.displayName) {
                $pv = ("$($row.($t.primaryName.displayName))").Trim()
                if ($pv) { $body[$t.primaryName.schemaName] = $pv }
            }

            # 通常の列
            foreach ($col in $t.columns) {
                if ($headers -notcontains $col.displayName) { continue }
                $val = ConvertTo-DataverseValue -Column $col -Raw ("$($row.($col.displayName))")
                if ($null -ne $val) { $body[$col.schemaName] = $val }
            }

            # 参照列（参照先の代替キーで結ぶ）
            foreach ($rel in $lookups) {
                $header = $rel.lookup.displayName
                if ($headers -notcontains $header) { continue }
                $refValue = ("$($row.$header)").Trim()
                if ([string]::IsNullOrWhiteSpace($refValue)) { continue }

                $refTable = $schema.tables | Where-Object { $_.schemaName -eq $rel.referenced }
                if (-not $refTable -or -not $refTable.alternateKeys -or $refTable.alternateKeys.Count -eq 0) {
                    throw "参照先 $($rel.referenced) に代替キーがないため『$header』を解決できません。"
                }
                $refKey = $refTable.alternateKeys[0].columns[0]
                $escaped = $refValue.Replace("'", "''")
                $body["$($rel.lookup.schemaName)@odata.bind"] = "/$($refTable.entitySetName)($refKey='$escaped')"
            }

            if ($body.Count -eq 0) { Write-Warn "  $lineNo 行目: 書き込む値がないためスキップ"; continue }

            if ($WhatIfOnly) {
                Write-Host "    [確認] $keyValue → $($body.Keys -join ', ')" -ForegroundColor DarkGray
            } else {
                $escapedKey = $keyValue.Replace("'", "''")
                Invoke-DataverseRequest -Method PATCH -Upsert -SolutionName '' `
                    -Path "$($t.entitySetName)($keyColumn='$escapedKey')" -Body $body | Out-Null
            }
            $okCount++
        }
        catch {
            $errCount++
            Write-Warn "  $lineNo 行目 ($keyValue): $($_.Exception.Message)"
        }
    }

    if ($WhatIfOnly) {
        Write-Host "    確認 $okCount 行 / エラー $errCount 行" -ForegroundColor DarkGray
    } else {
        Write-Ok "$DisplayName : $okCount 行を投入しました（エラー $errCount 行）"
    }
}

Write-Host ''
Write-Host '========================================' -ForegroundColor White
Write-Host ' 設備管理ソリューション 初期データ投入' -ForegroundColor White
Write-Host '========================================' -ForegroundColor White
if ($WhatIfOnly) { Write-Warn '確認モードです。実際の書き込みは行いません。' }

Connect-Dataverse -EnvironmentUrl $EnvironmentUrl -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret | Out-Null

if ($PSCmdlet.ParameterSetName -eq 'One') {
    Import-Table -DisplayName $Table -File $CsvPath
} else {
    foreach ($name in $ImportOrder) { Import-Table -DisplayName $name }
}

Write-Host ''
Write-Host '完了しました。' -ForegroundColor Green
Write-Host '次にやること:' -ForegroundColor White
Write-Host '  - 全設備のステータスが「空き」になっているか確認する（フェーズ2-5）'
Write-Host '  - 短縮番号に重複がないか確認する（.\New-ShortNumber.ps1 -Verify）'
Write-Host ''
