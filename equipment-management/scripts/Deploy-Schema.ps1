<#
.SYNOPSIS
    設備管理ソリューションのテーブル・列・リレーション・代替キーを作成します（フェーズ1-1〜1-7）。
.DESCRIPTION
    何度実行しても安全です（既にあるものは作らずスキップします）。
    開発環境で実行し、動作確認のうえソリューションをエクスポートして本番へ移送してください。
.EXAMPLE
    .\Deploy-Schema.ps1 -EnvironmentUrl 'https://contoso-dev.crm7.dynamics.com'
.EXAMPLE
    .\Deploy-Schema.ps1 -EnvironmentUrl 'https://contoso-dev.crm7.dynamics.com' -WhatIfOnly
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [string]$SchemaFile = (Join-Path $PSScriptRoot '..\schema\dataverse-schema.json'),
    [string]$TenantId = 'organizations',
    [string]$ClientId,
    [System.Security.SecureString]$ClientSecret,
    [switch]$SkipPublish,
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Dataverse.psm1') -Force

$schema = Get-Content -LiteralPath $SchemaFile -Raw -Encoding UTF8 | ConvertFrom-Json
$script:Lang = [int]$schema.languageCode

#region ---------- 属性メタデータの組み立て ----------

function New-AttributeMetadata {
    param([Parameter(Mandatory)]$Column, [switch]$IsPrimaryName)

    $displayName = $Column.displayName
    $required = 'None'
    if ($Column.PSObject.Properties.Name -contains 'required' -and $Column.required) { $required = $Column.required }

    $attr = @{
        SchemaName    = $Column.schemaName
        DisplayName   = New-DvLabel -Text $displayName -LanguageCode $script:Lang
        RequiredLevel = New-DvRequiredLevel -Level $required
    }
    if ($Column.PSObject.Properties.Name -contains 'description' -and $Column.description) {
        $attr['Description'] = New-DvLabel -Text $Column.description -LanguageCode $script:Lang
    }
    if ($Column.PSObject.Properties.Name -contains 'columnSecurity' -and $Column.columnSecurity) {
        $attr['IsSecured'] = $true
    }

    $type = 'string'
    if ($Column.PSObject.Properties.Name -contains 'type') { $type = $Column.type }
    if ($IsPrimaryName) { $type = 'string' }

    switch ($type) {
        'string' {
            $attr['@odata.type'] = 'Microsoft.Dynamics.CRM.StringAttributeMetadata'
            $maxLength = 100
            if ($Column.PSObject.Properties.Name -contains 'maxLength' -and $Column.maxLength) { $maxLength = [int]$Column.maxLength }
            $attr['MaxLength'] = $maxLength
            $format = 'Text'
            if ($Column.PSObject.Properties.Name -contains 'format' -and $Column.format) { $format = $Column.format }
            $attr['FormatName'] = @{ Value = $format }
            if ($IsPrimaryName) {
                $attr['IsPrimaryName'] = $true
                $attr['RequiredLevel'] = New-DvRequiredLevel -Level 'None'
            }
        }
        'memo' {
            $attr['@odata.type'] = 'Microsoft.Dynamics.CRM.MemoAttributeMetadata'
            $maxLength = 2000
            if ($Column.PSObject.Properties.Name -contains 'maxLength' -and $Column.maxLength) { $maxLength = [int]$Column.maxLength }
            $attr['MaxLength'] = $maxLength
            $attr['Format'] = 'TextArea'
        }
        'int' {
            $attr['@odata.type'] = 'Microsoft.Dynamics.CRM.IntegerAttributeMetadata'
            $min = 0; $max = 2147483647
            if ($Column.PSObject.Properties.Name -contains 'min') { $min = [int]$Column.min }
            if ($Column.PSObject.Properties.Name -contains 'max') { $max = [int]$Column.max }
            $attr['MinValue'] = $min
            $attr['MaxValue'] = $max
            $attr['Format']   = 'None'
        }
        'bool' {
            $attr['@odata.type'] = 'Microsoft.Dynamics.CRM.BooleanAttributeMetadata'
            $trueLabel = 'はい'; $falseLabel = 'いいえ'
            if ($Column.PSObject.Properties.Name -contains 'trueLabel' -and $Column.trueLabel) { $trueLabel = $Column.trueLabel }
            if ($Column.PSObject.Properties.Name -contains 'falseLabel' -and $Column.falseLabel) { $falseLabel = $Column.falseLabel }
            $defaultValue = $false
            if ($Column.PSObject.Properties.Name -contains 'default') { $defaultValue = [bool]$Column.default }
            $attr['DefaultValue'] = $defaultValue
            $attr['OptionSet'] = @{
                '@odata.type' = 'Microsoft.Dynamics.CRM.BooleanOptionSetMetadata'
                TrueOption    = @{ Value = 1; Label = (New-DvLabel -Text $trueLabel  -LanguageCode $script:Lang) }
                FalseOption   = @{ Value = 0; Label = (New-DvLabel -Text $falseLabel -LanguageCode $script:Lang) }
            }
        }
        'datetime' {
            $attr['@odata.type'] = 'Microsoft.Dynamics.CRM.DateTimeAttributeMetadata'
            $behavior = 'UserLocal'
            if ($Column.PSObject.Properties.Name -contains 'behavior' -and $Column.behavior) { $behavior = $Column.behavior }
            $attr['Format'] = 'DateAndTime'
            $attr['DateTimeBehavior'] = @{ Value = $behavior }
        }
        'date' {
            $attr['@odata.type'] = 'Microsoft.Dynamics.CRM.DateTimeAttributeMetadata'
            $attr['Format'] = 'DateOnly'
            $attr['DateTimeBehavior'] = @{ Value = 'DateOnly' }
        }
        'choice' {
            $attr['@odata.type'] = 'Microsoft.Dynamics.CRM.PicklistAttributeMetadata'
            $options = @()
            foreach ($o in $Column.options) {
                $options += @{ Value = [int]$o.value; Label = (New-DvLabel -Text $o.label -LanguageCode $script:Lang) }
            }
            $attr['OptionSet'] = @{
                '@odata.type'  = 'Microsoft.Dynamics.CRM.OptionSetMetadata'
                IsGlobal       = $false
                OptionSetType  = 'Picklist'
                Options        = $options
            }
            $default = -1
            if ($Column.PSObject.Properties.Name -contains 'default') { $default = [int]$Column.default }
            $attr['DefaultFormValue'] = $default
        }
        default { throw "未対応の列タイプです: $type ($($Column.schemaName))" }
    }
    return $attr
}

#endregion

#region ---------- 言語の確認 ----------

function Confirm-Language {
    $prov = Invoke-DataverseRequest -Method GET -Path 'RetrieveProvisionedLanguages'
    $ids = @()
    if ($prov -and $prov.PSObject.Properties.Name -contains 'RetrieveProvisionedLanguages') { $ids = $prov.RetrieveProvisionedLanguages }
    if ($ids -and ($ids -notcontains $script:Lang)) {
        $org = Get-DataverseRecords -Path 'organizations?$select=languagecode'
        $base = 1033
        if ($org -and $org.Count -gt 0) { $base = [int]$org[0].languagecode }
        Write-Warn "この環境では言語 $($script:Lang)（日本語）が有効化されていません。ラベルは基本言語 $base で作成します。"
        Write-Warn "日本語表示にするには 設定 > 言語 で日本語を有効化してから作り直してください。"
        $script:Lang = $base
    } else {
        Write-Host "    表示ラベルの言語: $($script:Lang)" -ForegroundColor DarkGray
    }
}

#endregion

#region ---------- 公開元とソリューション ----------

function Initialize-Publisher {
    param($Def)
    Write-Step "公開元を確認しています: $($Def.uniqueName)（接頭辞 $($Def.customizationPrefix)）"
    $existing = Get-DataverseRecords -Path "publishers?`$select=publisherid,customizationprefix&`$filter=uniquename eq '$($Def.uniqueName)'"
    if ($existing.Count -gt 0) {
        Write-Skip "公開元 $($Def.uniqueName)（接頭辞 $($existing[0].customizationprefix)）"
        if ($existing[0].customizationprefix -ne $Def.customizationPrefix) {
            throw "既存の公開元の接頭辞は '$($existing[0].customizationprefix)' です。接頭辞は後から変更できません。スキーマ定義側を合わせてください。"
        }
        return $existing[0].publisherid
    }
    if ($WhatIfOnly) { Write-Ok "（実行しません）公開元 $($Def.uniqueName)"; return [guid]::Empty }
    $r = Invoke-DataverseRequest -Method POST -Path 'publishers' -SolutionName '' -Body @{
        uniquename                    = $Def.uniqueName
        friendlyname                  = $Def.friendlyName
        customizationprefix           = $Def.customizationPrefix
        customizationoptionvalueprefix = [int]$Def.optionValuePrefix
        description                   = $Def.description
    }
    Write-Ok "公開元 $($Def.uniqueName)"
    return $r.Id
}

function Initialize-Solution {
    param($Def, [string]$PublisherId)
    Write-Step "ソリューションを確認しています: $($Def.uniqueName)"
    $existing = Get-DataverseRecords -Path "solutions?`$select=solutionid,version&`$filter=uniquename eq '$($Def.uniqueName)'"
    if ($existing.Count -gt 0) {
        Write-Skip "ソリューション $($Def.uniqueName)（v$($existing[0].version)）"
        return $existing[0].solutionid
    }
    if ($WhatIfOnly) { Write-Ok "（実行しません）ソリューション $($Def.uniqueName)"; return [guid]::Empty }
    $r = Invoke-DataverseRequest -Method POST -Path 'solutions' -SolutionName '' -Body @{
        uniquename              = $Def.uniqueName
        friendlyname            = $Def.friendlyName
        version                 = $Def.version
        description             = $Def.description
        'publisherid@odata.bind' = "/publishers($PublisherId)"
    }
    Write-Ok "ソリューション $($Def.uniqueName)"
    return $r.Id
}

#endregion

#region ---------- テーブル・列・リレーション・キー ----------

function Initialize-Table {
    param($Table)
    $logical = $Table.schemaName.ToLower()
    if (Test-DvTableExists -LogicalName $logical) {
        Write-Skip "テーブル $($Table.displayName) ($logical)"
        return
    }
    if ($WhatIfOnly) { Write-Ok "（実行しません）テーブル $($Table.displayName)"; return }

    $primary = New-AttributeMetadata -Column $Table.primaryName -IsPrimaryName
    $body = @{
        '@odata.type'          = 'Microsoft.Dynamics.CRM.EntityMetadata'
        SchemaName             = $Table.schemaName
        EntitySetName          = $Table.entitySetName
        DisplayName            = New-DvLabel -Text $Table.displayName -LanguageCode $script:Lang
        DisplayCollectionName  = New-DvLabel -Text $Table.displayCollectionName -LanguageCode $script:Lang
        Description            = New-DvLabel -Text $Table.description -LanguageCode $script:Lang
        OwnershipType          = $Table.ownershipType
        IsActivity             = $false
        HasActivities          = $false
        HasNotes               = $false
        Attributes             = @($primary)
    }
    Invoke-DataverseRequest -Method POST -Path 'EntityDefinitions' -Body $body | Out-Null
    Write-Ok "テーブル $($Table.displayName) ($logical)"
}

function Initialize-Columns {
    param($Table)
    $logical = $Table.schemaName.ToLower()
    foreach ($col in $Table.columns) {
        $colLogical = $col.schemaName.ToLower()
        if ((-not $WhatIfOnly) -and (Test-DvColumnExists -TableLogicalName $logical -ColumnLogicalName $colLogical)) {
            Write-Skip "  列 $($Table.displayName).$($col.displayName)"
            continue
        }
        if ($WhatIfOnly) { Write-Ok "（実行しません）列 $($Table.displayName).$($col.displayName)"; continue }
        $attr = New-AttributeMetadata -Column $col
        Invoke-DataverseRequest -Method POST -Path "EntityDefinitions(LogicalName='$logical')/Attributes" -Body $attr | Out-Null
        Write-Ok "  列 $($Table.displayName).$($col.displayName)"
    }
}

function Initialize-Relationship {
    param($Rel)
    if ((-not $WhatIfOnly) -and (Test-DvRelationshipExists -SchemaName $Rel.schemaName)) {
        Write-Skip "リレーション $($Rel.schemaName)"
        return
    }
    if ($WhatIfOnly) { Write-Ok "（実行しません）リレーション $($Rel.schemaName)"; return }

    $required = 'None'
    if ($Rel.lookup.PSObject.Properties.Name -contains 'required' -and $Rel.lookup.required) { $required = $Rel.lookup.required }

    $body = @{
        '@odata.type'      = 'Microsoft.Dynamics.CRM.OneToManyRelationshipMetadata'
        SchemaName         = $Rel.schemaName
        ReferencedEntity   = $Rel.referenced.ToLower()
        ReferencingEntity  = $Rel.referencing.ToLower()
        CascadeConfiguration = @{
            Assign   = 'NoCascade'
            Delete   = $Rel.cascade
            Merge    = 'NoCascade'
            Reparent = 'NoCascade'
            Share    = 'NoCascade'
            Unshare  = 'NoCascade'
        }
        Lookup = @{
            '@odata.type'  = 'Microsoft.Dynamics.CRM.LookupAttributeMetadata'
            SchemaName     = $Rel.lookup.schemaName
            DisplayName    = New-DvLabel -Text $Rel.lookup.displayName -LanguageCode $script:Lang
            RequiredLevel  = New-DvRequiredLevel -Level $required
        }
        AssociatedMenuConfiguration = @{
            Behavior = 'UseLabel'
            Group    = $Rel.menu.group
            Label    = New-DvLabel -Text $Rel.menu.label -LanguageCode $script:Lang
            Order    = [int]$Rel.menu.order
        }
    }
    Invoke-DataverseRequest -Method POST -Path 'RelationshipDefinitions' -Body $body | Out-Null
    Write-Ok "リレーション $($Rel.schemaName) → $($Rel.lookup.displayName)"
}

function Initialize-AlternateKey {
    param($Table, $Key)
    $logical = $Table.schemaName.ToLower()
    if ((-not $WhatIfOnly) -and (Test-DvKeyExists -TableLogicalName $logical -KeySchemaName $Key.schemaName)) {
        Write-Skip "代替キー $($Key.schemaName)"
        return
    }
    if ($WhatIfOnly) { Write-Ok "（実行しません）代替キー $($Key.schemaName)"; return }

    $body = @{
        '@odata.type' = 'Microsoft.Dynamics.CRM.EntityKeyMetadata'
        SchemaName    = $Key.schemaName
        DisplayName   = New-DvLabel -Text $Key.displayName -LanguageCode $script:Lang
        KeyAttributes = @($Key.columns | ForEach-Object { $_.ToLower() })
    }
    Invoke-DataverseRequest -Method POST -Path "EntityDefinitions(LogicalName='$logical')/Keys" -Body $body | Out-Null
    Write-Ok "代替キー $($Key.schemaName)"
}

function Wait-AlternateKeys {
    param($Tables)
    Write-Step '代替キーのインデックス作成を待っています（最大10分）'
    $deadline = (Get-Date).AddMinutes(10)
    while ((Get-Date) -lt $deadline) {
        $pending = @()
        foreach ($t in $Tables) {
            if (-not $t.alternateKeys) { continue }
            foreach ($k in $t.alternateKeys) {
                $r = Invoke-DataverseRequest -Method GET -AllowNotFound `
                    -Path "EntityDefinitions(LogicalName='$($t.schemaName.ToLower())')/Keys?`$select=SchemaName,EntityKeyIndexStatus&`$filter=SchemaName eq '$($k.schemaName)'"
                if ($r -and $r.value.Count -gt 0 -and $r.value[0].EntityKeyIndexStatus -ne 'Active') {
                    $pending += "$($k.schemaName)=$($r.value[0].EntityKeyIndexStatus)"
                }
            }
        }
        if ($pending.Count -eq 0) { Write-Ok '代替キーはすべて有効になりました'; return }
        Write-Host "    待機中: $($pending -join ', ')" -ForegroundColor DarkGray
        Start-Sleep -Seconds 15
    }
    Write-Warn '代替キーの一部がまだ有効になっていません。メーカーポータルの「キー」で状態を確認してください。'
}

#endregion

#region ---------- 実行 ----------

Write-Host ''
Write-Host '========================================' -ForegroundColor White
Write-Host ' 設備管理ソリューション スキーマ配置' -ForegroundColor White
Write-Host '========================================' -ForegroundColor White
if ($WhatIfOnly) { Write-Warn '確認モードです。実際の作成は行いません。' }

Connect-Dataverse -EnvironmentUrl $EnvironmentUrl -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret | Out-Null
Confirm-Language

$publisherId = Initialize-Publisher -Def $schema.publisher
$null = Initialize-Solution -Def $schema.solution -PublisherId $publisherId
Set-DataverseSolutionContext -SolutionUniqueName $schema.solution.uniqueName

Write-Step "テーブルを作成しています（$($schema.tables.Count) 件）"
foreach ($t in $schema.tables) { Initialize-Table -Table $t }

Write-Step '列を作成しています'
foreach ($t in $schema.tables) { Initialize-Columns -Table $t }

Write-Step "リレーション（参照列）を作成しています（$($schema.relationships.Count) 件）"
foreach ($r in $schema.relationships) { Initialize-Relationship -Rel $r }

Write-Step '代替キーを作成しています'
foreach ($t in $schema.tables) {
    if (-not $t.alternateKeys) { continue }
    foreach ($k in $t.alternateKeys) { Initialize-AlternateKey -Table $t -Key $k }
}

if (-not $WhatIfOnly) {
    Wait-AlternateKeys -Tables $schema.tables
    if (-not $SkipPublish) { Publish-DvCustomizations }
}

Write-Host ''
Write-Host '完了しました。' -ForegroundColor Green
Write-Host '次にやること:' -ForegroundColor White
Write-Host '  1. .\Deploy-Security.ps1 でセキュリティロールと列レベルセキュリティを作成する（フェーズ1-8, 1-9）'
Write-Host '  2. docs/phase1-data.md の「ビジネスルール」をメーカーポータルで作成する（フェーズ1-10）'
Write-Host '  3. .\Import-MasterData.ps1 で初期データを投入する（フェーズ2）'
Write-Host ''

#endregion
