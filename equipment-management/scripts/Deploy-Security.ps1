<#
.SYNOPSIS
    セキュリティロール3種（フェーズ1-8）と列レベルセキュリティ（フェーズ1-9）を作成します。
.DESCRIPTION
    ロールの権限は schema/security.json を正とし、毎回その内容で「上書き」します。
    メーカーポータルで手で足した権限はこのスクリプトを流すと消えます。
    権限を変えたいときは JSON を直してから流し直してください。

    -UserGroupObjectId / -AdminGroupObjectId に Entra セキュリティグループのオブジェクト ID を渡すと、
    Entra グループチームを作成してロールを割り当てます（フェーズ0-2 で作ったグループ）。
.EXAMPLE
    .\Deploy-Security.ps1 -EnvironmentUrl 'https://contoso-dev.crm7.dynamics.com'
.EXAMPLE
    .\Deploy-Security.ps1 -EnvironmentUrl 'https://contoso-dev.crm7.dynamics.com' `
        -UserGroupObjectId  'aaaaaaaa-....' -AdminGroupObjectId 'bbbbbbbb-....'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [string]$SecurityFile = (Join-Path $PSScriptRoot '..\schema\security.json'),
    [string]$SchemaFile   = (Join-Path $PSScriptRoot '..\schema\dataverse-schema.json'),
    [string]$TenantId = 'organizations',
    [string]$ClientId,
    [System.Security.SecureString]$ClientSecret,
    [string]$UserGroupObjectId,
    [string]$AdminGroupObjectId,
    [switch]$SkipPublish
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Dataverse.psm1') -Force

$sec    = Get-Content -LiteralPath $SecurityFile -Raw -Encoding UTF8 | ConvertFrom-Json
$schema = Get-Content -LiteralPath $SchemaFile   -Raw -Encoding UTF8 | ConvertFrom-Json

Write-Host ''
Write-Host '========================================' -ForegroundColor White
Write-Host ' 設備管理ソリューション セキュリティ配置' -ForegroundColor White
Write-Host '========================================' -ForegroundColor White

Connect-Dataverse -EnvironmentUrl $EnvironmentUrl -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret | Out-Null
Set-DataverseSolutionContext -SolutionUniqueName $schema.solution.uniqueName

#region ---------- 事業部（ルート BU）----------

Write-Step 'ルート事業部を取得しています'
$rootBus = Get-DataverseRecords -Path 'businessunits?$select=businessunitid,name&$filter=parentbusinessunitid eq null'
if ($rootBus.Count -eq 0) { throw 'ルート事業部が見つかりませんでした。' }
$rootBuId = $rootBus[0].businessunitid
Write-Host "    ルート事業部: $($rootBus[0].name) ($rootBuId)" -ForegroundColor DarkGray

#endregion

#region ---------- 特権 ID の取得 ----------

function Get-PrivilegeMap {
    <# prvCreateeqm_equipment のような特権名 → privilegeid の対応表を作る #>
    param([string[]]$Names)

    $map = @{}
    $chunkSize = 15
    for ($i = 0; $i -lt $Names.Count; $i += $chunkSize) {
        $chunk = $Names[$i..([Math]::Min($i + $chunkSize - 1, $Names.Count - 1))]
        $filter = ($chunk | ForEach-Object { "name eq '$_'" }) -join ' or '
        $rows = Get-DataverseRecords -Path ("privileges?`$select=privilegeid,name&`$filter=" + [uri]::EscapeDataString($filter))
        foreach ($r in $rows) { $map[$r.name] = $r.privilegeid }
    }
    return $map
}

Write-Step '特権 ID を取得しています'
$wantedNames = New-Object System.Collections.Generic.HashSet[string]
foreach ($role in $sec.roles) {
    foreach ($tp in $role.tablePrivileges) {
        foreach ($action in $tp.privileges.PSObject.Properties.Name) {
            [void]$wantedNames.Add("prv$action$($tp.table)")
        }
    }
}
$privMap = Get-PrivilegeMap -Names ([string[]]$wantedNames)
Write-Host "    $($privMap.Count) / $($wantedNames.Count) 件の特権が見つかりました" -ForegroundColor DarkGray

$missing = @($wantedNames | Where-Object { -not $privMap.ContainsKey($_) })
if ($missing.Count -gt 0) {
    Write-Warn "次の特権が見つかりませんでした。Deploy-Schema.ps1 を先に実行し、公開が終わっているか確認してください:"
    $missing | ForEach-Object { Write-Warn "  $_" }
    throw '特権が揃っていないため中断しました。'
}

#endregion

#region ---------- セキュリティロール ----------

function Initialize-Role {
    param($RoleDef)

    $escapedName = $RoleDef.name.Replace("'", "''")
    $existing = Get-DataverseRecords -Path ("roles?`$select=roleid,name&`$filter=" + [uri]::EscapeDataString("name eq '$escapedName' and _businessunitid_value eq $rootBuId"))

    if ($existing.Count -gt 0) {
        $roleId = $existing[0].roleid
        Write-Skip "ロール $($RoleDef.name)"
    } else {
        $r = Invoke-DataverseRequest -Method POST -Path 'roles' -Body @{
            name                       = $RoleDef.name
            description                = $RoleDef.description
            'businessunitid@odata.bind' = "/businessunits($rootBuId)"
        }
        $roleId = $r.Id
        Write-Ok "ロール $($RoleDef.name)"
    }

    # 権限は JSON の内容で総入れ替えする
    $privileges = @()
    foreach ($tp in $RoleDef.tablePrivileges) {
        foreach ($action in $tp.privileges.PSObject.Properties.Name) {
            $depth = $tp.privileges.$action
            $privName = "prv$action$($tp.table)"
            # RolePrivilege 複合型のプロパティのみを渡す
            $privileges += @{
                Depth          = $depth
                PrivilegeId    = $privMap[$privName]
                BusinessUnitId = $rootBuId
                PrivilegeName  = $privName
            }
        }
    }
    Invoke-DataverseRequest -Method POST -Path "roles($roleId)/Microsoft.Dynamics.CRM.ReplacePrivilegesRole" `
        -Body @{ Privileges = $privileges } | Out-Null
    Write-Host "    権限 $($privileges.Count) 件を設定しました" -ForegroundColor DarkGray

    return $roleId
}

Write-Step "セキュリティロールを作成しています（$($sec.roles.Count) 件）"
$roleIds = @{}
foreach ($role in $sec.roles) { $roleIds[$role.name] = Initialize-Role -RoleDef $role }

#endregion

#region ---------- Entra グループチーム ----------

function Initialize-GroupTeam {
    param([string]$TeamName, [string]$GroupObjectId, [string]$RoleId)

    if ([string]::IsNullOrWhiteSpace($GroupObjectId)) { return }

    $escaped = $TeamName.Replace("'", "''")
    $existing = Get-DataverseRecords -Path ("teams?`$select=teamid,name&`$filter=" + [uri]::EscapeDataString("name eq '$escaped'"))
    if ($existing.Count -gt 0) {
        $teamId = $existing[0].teamid
        Write-Skip "チーム $TeamName"
    } else {
        $r = Invoke-DataverseRequest -Method POST -Path 'teams' -SolutionName '' -Body @{
            name                        = $TeamName
            description                 = "Entra セキュリティグループ連携チーム（設備管理）"
            teamtype                    = 2          # 2 = Microsoft Entra ID セキュリティグループ
            membershiptype              = 0          # 0 = メンバーとゲスト
            azureactivedirectoryobjectid = $GroupObjectId
            'businessunitid@odata.bind'  = "/businessunits($rootBuId)"
        }
        $teamId = $r.Id
        Write-Ok "チーム $TeamName（Entra グループ $GroupObjectId）"
    }

    # ロールを割り当て（既に割り当て済みなら 412 が返るので握りつぶす）
    try {
        Invoke-DataverseRequest -Method POST -Path "teams($teamId)/teamroles_association/`$ref" -SolutionName '' `
            -Body @{ '@odata.id' = "$((Get-DataverseConnection).ApiUrl)/roles($RoleId)" } | Out-Null
        Write-Ok "  チーム $TeamName にロールを割り当てました"
    } catch {
        Write-Skip "  チーム $TeamName のロール割り当て（既に割り当て済みとみなします）"
    }
    return $teamId
}

if ($UserGroupObjectId -or $AdminGroupObjectId) {
    Write-Step 'Entra グループチームを作成しています'
    Initialize-GroupTeam -TeamName '設備-使用者チーム' -GroupObjectId $UserGroupObjectId  -RoleId $roleIds['設備-使用者'] | Out-Null
    Initialize-GroupTeam -TeamName '設備-管理者チーム' -GroupObjectId $AdminGroupObjectId -RoleId $roleIds['設備-管理者'] | Out-Null
} else {
    Write-Warn 'Entra グループのオブジェクト ID が指定されていないため、チーム作成はスキップしました。'
    Write-Warn 'ロールは作成済みです。ユーザーへの割り当ては管理センターから行ってください。'
}

#endregion

#region ---------- 列レベルセキュリティ ----------

Write-Step '列レベルセキュリティ プロファイルを作成しています'
foreach ($profileDef in $sec.columnSecurityProfiles) {
    $escaped = $profileDef.name.Replace("'", "''")
    $existing = Get-DataverseRecords -Path ("fieldsecurityprofiles?`$select=fieldsecurityprofileid,name&`$filter=" + [uri]::EscapeDataString("name eq '$escaped'"))

    if ($existing.Count -gt 0) {
        $profileId = $existing[0].fieldsecurityprofileid
        Write-Skip "プロファイル $($profileDef.name)"
    } else {
        $r = Invoke-DataverseRequest -Method POST -Path 'fieldsecurityprofiles' -Body @{
            name        = $profileDef.name
            description = $profileDef.description
        }
        $profileId = $r.Id
        Write-Ok "プロファイル $($profileDef.name)"
    }

    foreach ($perm in $profileDef.permissions) {
        $f = "attributelogicalname eq '$($perm.column)' and entityname eq '$($perm.table)' and _fieldsecurityprofileid_value eq $profileId"
        $existingPerm = Get-DataverseRecords -Path ("fieldpermissions?`$select=fieldpermissionid&`$filter=" + [uri]::EscapeDataString($f))

        # 4 = 許可 / 0 = 不許可
        $body = @{
            canread   = $(if ($perm.canRead)   { 4 } else { 0 })
            cancreate = $(if ($perm.canCreate) { 4 } else { 0 })
            canupdate = $(if ($perm.canUpdate) { 4 } else { 0 })
        }
        if ($existingPerm.Count -gt 0) {
            Invoke-DataverseRequest -Method PATCH -Path "fieldpermissions($($existingPerm[0].fieldpermissionid))" -Body $body | Out-Null
            Write-Skip "  列アクセス $($perm.table).$($perm.column)（更新）"
        } else {
            $body['attributelogicalname'] = $perm.column
            $body['entityname']           = $perm.table
            $body['fieldsecurityprofileid@odata.bind'] = "/fieldsecurityprofiles($profileId)"
            Invoke-DataverseRequest -Method POST -Path 'fieldpermissions' -Body $body | Out-Null
            Write-Ok "  列アクセス $($perm.table).$($perm.column)"
        }
    }

    Write-Warn "プロファイル『$($profileDef.name)』に読み取りを許可するユーザー／チームは、メーカーポータルで追加してください（自動では追加しません）。"
}

#endregion

if (-not $SkipPublish) { Publish-DvCustomizations }

Write-Host ''
Write-Host '完了しました。' -ForegroundColor Green
Write-Host '確認すること:' -ForegroundColor White
Write-Host '  - Power Platform 管理センター > 環境 > ユーザー で、ロールが割り当たっているか'
Write-Host '  - フロー所有用のサービスアカウントに「設備-システム」ロールが付いているか（フェーズ0-5）'
Write-Host '  - 列レベルセキュリティのプロファイルに管理者を追加したか（フェーズ1-9）'
Write-Host ''
