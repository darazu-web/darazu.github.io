<#
.SYNOPSIS
    Dataverse Web API を PowerShell から叩くための共通モジュール。
.DESCRIPTION
    追加モジュールのインストールを不要にするため、認証はデバイスコードフロー
    （ブラウザに表示されたコードを入力する方式）を Invoke-RestMethod だけで実装しています。
    アプリ登録（クライアントシークレット）を使う場合は Connect-Dataverse -ClientId/-ClientSecret を指定してください。

    Windows PowerShell 5.1 / PowerShell 7 の両方で動きます。
    日本語のラベルが文字化けしないよう、送信・受信とも UTF-8 を明示的に扱っています。
#>

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 は既定で TLS1.0 になることがある
if ([Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# Microsoft が公開しているパブリッククライアント ID（Dataverse のサンプルで使われるもの）
$script:DefaultPublicClientId = '51f81489-12ee-4a9e-aaae-a2591f45987d'
$script:Conn = $null

#region ---------- ログ出力 ----------

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    [作成] $Message" -ForegroundColor Green
}

function Write-Skip {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    [既存] $Message" -ForegroundColor DarkGray
}

function Write-Warn {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    [警告] $Message" -ForegroundColor Yellow
}

function Write-Info {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    [OK] $Message" -ForegroundColor Green
}

#endregion

#region ---------- 認証 ----------

function Connect-Dataverse {
    <#
    .SYNOPSIS
        Dataverse 環境に接続してアクセストークンを取得します。
    .EXAMPLE
        Connect-Dataverse -EnvironmentUrl 'https://contoso-dev.crm7.dynamics.com'
    .EXAMPLE
        Connect-Dataverse -EnvironmentUrl 'https://contoso-dev.crm7.dynamics.com' `
                          -TenantId '00000000-0000-0000-0000-000000000000' `
                          -ClientId  '11111111-1111-1111-1111-111111111111' `
                          -ClientSecret (Read-Host -AsSecureString)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvironmentUrl,
        [string]$TenantId = 'organizations',
        [string]$ClientId,
        [System.Security.SecureString]$ClientSecret,
        [string]$ApiVersion = 'v9.2'
    )

    $EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
    if ($EnvironmentUrl -notmatch '^https://') {
        throw "環境 URL は https:// で始まる必要があります: $EnvironmentUrl"
    }

    $effectiveClientId = $ClientId
    if ([string]::IsNullOrWhiteSpace($effectiveClientId)) { $effectiveClientId = $script:DefaultPublicClientId }

    $script:Conn = [pscustomobject]@{
        EnvironmentUrl = $EnvironmentUrl
        ApiUrl         = "$EnvironmentUrl/api/data/$ApiVersion"
        TenantId       = $TenantId
        ClientId       = $effectiveClientId
        ClientSecret   = $ClientSecret
        AccessToken    = $null
        RefreshToken   = $null
        ExpiresOn      = [datetime]::MinValue
        SolutionName   = $null
    }

    if ($ClientSecret) {
        Get-DataverseTokenByClientSecret | Out-Null
    } else {
        Get-DataverseTokenByDeviceCode | Out-Null
    }

    # 接続確認とユーザー情報の取得
    $who = Invoke-DataverseRequest -Method GET -Path 'WhoAmI'
    Write-Host ""
    Write-Host "接続しました: $EnvironmentUrl" -ForegroundColor Green
    Write-Host "  UserId         : $($who.UserId)"
    Write-Host "  BusinessUnitId : $($who.BusinessUnitId)"
    Write-Host ""
    return $script:Conn
}

function Get-DataverseTokenByDeviceCode {
    $c = $script:Conn
    $scope = "$($c.EnvironmentUrl)/.default offline_access"

    $device = Invoke-RestMethod -Method POST `
        -Uri "https://login.microsoftonline.com/$($c.TenantId)/oauth2/v2.0/devicecode" `
        -Body @{ client_id = $c.ClientId; scope = $scope } `
        -ContentType 'application/x-www-form-urlencoded'

    Write-Host ""
    Write-Host "----------------------------------------------------------" -ForegroundColor Yellow
    Write-Host " ブラウザで $($device.verification_uri) を開き、" -ForegroundColor Yellow
    Write-Host " 次のコードを入力してサインインしてください:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "     $($device.user_code)" -ForegroundColor White -BackgroundColor DarkBlue
    Write-Host ""
    Write-Host "----------------------------------------------------------" -ForegroundColor Yellow

    # Windows なら既定ブラウザを開いてあげる
    try { Start-Process $device.verification_uri | Out-Null } catch { }

    $interval = [int]$device.interval
    if ($interval -lt 1) { $interval = 5 }
    $deadline = (Get-Date).AddSeconds([int]$device.expires_in)

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            $tok = Invoke-RestMethod -Method POST `
                -Uri "https://login.microsoftonline.com/$($c.TenantId)/oauth2/v2.0/token" `
                -Body @{
                    grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                    client_id   = $c.ClientId
                    device_code = $device.device_code
                } -ContentType 'application/x-www-form-urlencoded'

            $c.AccessToken  = $tok.access_token
            $c.RefreshToken = $tok.refresh_token
            $c.ExpiresOn    = (Get-Date).AddSeconds([int]$tok.expires_in)
            return $c.AccessToken
        }
        catch {
            $err = Get-ErrorBody $_
            # まだ承認待ちならループを続ける
            if ($err -and ($err -match 'authorization_pending' -or $err -match 'slow_down')) {
                if ($err -match 'slow_down') { $interval += 5 }
                continue
            }
            throw "サインインに失敗しました: $err"
        }
    }
    throw "サインインがタイムアウトしました。もう一度実行してください。"
}

function Get-DataverseTokenByClientSecret {
    $c = $script:Conn
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($c.ClientSecret))

    $tok = Invoke-RestMethod -Method POST `
        -Uri "https://login.microsoftonline.com/$($c.TenantId)/oauth2/v2.0/token" `
        -Body @{
            grant_type    = 'client_credentials'
            client_id     = $c.ClientId
            client_secret = $plain
            scope         = "$($c.EnvironmentUrl)/.default"
        } -ContentType 'application/x-www-form-urlencoded'

    $c.AccessToken = $tok.access_token
    $c.ExpiresOn   = (Get-Date).AddSeconds([int]$tok.expires_in)
    return $c.AccessToken
}

function Update-DataverseToken {
    # 有効期限が 5 分を切っていたら黙って取り直す（スキーマ配置は 1 時間を超えることがある）
    $c = $script:Conn
    if ((Get-Date).AddMinutes(5) -lt $c.ExpiresOn) { return }

    if ($c.ClientSecret) {
        Get-DataverseTokenByClientSecret | Out-Null
        return
    }
    if ($c.RefreshToken) {
        try {
            $tok = Invoke-RestMethod -Method POST `
                -Uri "https://login.microsoftonline.com/$($c.TenantId)/oauth2/v2.0/token" `
                -Body @{
                    grant_type    = 'refresh_token'
                    client_id     = $c.ClientId
                    refresh_token = $c.RefreshToken
                    scope         = "$($c.EnvironmentUrl)/.default offline_access"
                } -ContentType 'application/x-www-form-urlencoded'
            $c.AccessToken  = $tok.access_token
            if ($tok.PSObject.Properties.Name -contains 'refresh_token') { $c.RefreshToken = $tok.refresh_token }
            $c.ExpiresOn    = (Get-Date).AddSeconds([int]$tok.expires_in)
            return
        } catch {
            Write-Warn "トークンの更新に失敗しました。サインインし直します。"
        }
    }
    Get-DataverseTokenByDeviceCode | Out-Null
}

#endregion

#region ---------- Web API 呼び出し ----------

function Get-ErrorBody {
    <# 例外から Dataverse / Entra が返したエラー本文を取り出す（PS5.1 と PS7 で取り方が違う） #>
    param($ErrorRecord)
    try {
        if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
            return $ErrorRecord.ErrorDetails.Message
        }
        $resp = $ErrorRecord.Exception.Response
        if ($resp -and $resp.GetResponseStream) {
            $stream = $resp.GetResponseStream()
            $stream.Position = 0
            $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::UTF8)
            return $reader.ReadToEnd()
        }
    } catch { }
    return $ErrorRecord.Exception.Message
}

function Get-ResponseHeader {
    <# PS5.1 は Dictionary<string,string>、PS7 は Dictionary<string,string[]> でヘッダーを返す #>
    param($Response, [string]$Name)
    try {
        if (-not $Response.Headers) { return $null }
        if (-not $Response.Headers.ContainsKey($Name)) { return $null }
        $v = $Response.Headers[$Name]
        if ($v -is [array]) { return [string]($v[0]) }
        return [string]$v
    } catch { return $null }
}

function Invoke-DataverseRequest {
    <#
    .SYNOPSIS
        Dataverse Web API を呼び出します。
    .PARAMETER Path
        API ルート以降のパス。例: "EntityDefinitions(LogicalName='eqm_equipment')"
    .PARAMETER Body
        ハッシュテーブルまたは PSCustomObject。UTF-8 の JSON に変換して送信します。
    .PARAMETER SolutionName
        指定するとそのソリューションにコンポーネントが追加されます（MSCRM.SolutionUniqueName）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET','POST','PATCH','PUT','DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        $Body,
        [string]$SolutionName,
        [hashtable]$ExtraHeaders,
        [switch]$AllowNotFound,
        [switch]$Upsert
    )

    if (-not $script:Conn) { throw 'Connect-Dataverse を先に実行してください。' }
    Update-DataverseToken

    if ($Path -match '^https?://') { $uri = $Path } else { $uri = "$($script:Conn.ApiUrl)/$($Path.TrimStart('/'))" }

    $headers = @{
        'Authorization'    = "Bearer $($script:Conn.AccessToken)"
        'Accept'           = 'application/json'
        'OData-MaxVersion' = '4.0'
        'OData-Version'    = '4.0'
    }
    if (-not $SolutionName -and $script:Conn.SolutionName) { $SolutionName = $script:Conn.SolutionName }
    if ($SolutionName) { $headers['MSCRM.SolutionUniqueName'] = $SolutionName }
    # PATCH は既定で upsert になるため、更新のみにしたい場合は If-Match を付ける
    if ($Method -eq 'PATCH' -and -not $Upsert) { $headers['If-Match'] = '*' }
    if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $headers[$k] = $ExtraHeaders[$k] } }

    $params = @{
        Uri             = $uri
        Method          = $Method
        Headers         = $headers
        UseBasicParsing = $true
    }
    if ($null -ne $Body) {
        if ($Body -is [string]) { $json = $Body } else { $json = $Body | ConvertTo-Json -Depth 30 -Compress }
        # PS5.1 は -Body に文字列を渡すと UTF-8 で送ってくれない。バイト配列にして渡す。
        $params['Body']        = [Text.Encoding]::UTF8.GetBytes($json)
        $params['ContentType'] = 'application/json; charset=utf-8'
    }

    try {
        $resp = Invoke-WebRequest @params
    }
    catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($AllowNotFound -and $status -eq 404) { return $null }
        $detail = Get-ErrorBody $_
        throw "Dataverse 呼び出しに失敗しました ($Method $Path / HTTP $status)`n$detail"
    }

    if (-not $resp.Content -or $resp.RawContentLength -eq 0) {
        # 作成系は本文なしで OData-EntityId ヘッダーに URL が返る
        $entityId = Get-ResponseHeader $resp 'OData-EntityId'
        if ($entityId -and $entityId -match '\(([0-9a-fA-F-]{36})\)') {
            return [pscustomobject]@{ Id = $Matches[1]; EntityId = $entityId }
        }
        return $null
    }

    # 受信も UTF-8 を明示してデコードする
    $text = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
}

function Get-DataverseRecords {
    <# ページングを辿って全件取得する #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $all = @()
    $next = $Path
    while ($next) {
        $page = Invoke-DataverseRequest -Method GET -Path $next
        if ($null -eq $page) { break }
        if ($page.PSObject.Properties.Name -contains 'value') { $all += $page.value } else { $all += $page }
        $next = $null
        if ($page.PSObject.Properties.Name -contains '@odata.nextLink') { $next = $page.'@odata.nextLink' }
    }
    return $all
}

function Set-DataverseSolutionContext {
    param([Parameter(Mandatory)][string]$SolutionUniqueName)
    $script:Conn.SolutionName = $SolutionUniqueName
}

function Get-DataverseConnection { return $script:Conn }

#endregion

#region ---------- メタデータのヘルパー ----------

function New-DvLabel {
    <# Dataverse のローカライズラベルを組み立てる #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [int]$LanguageCode = 1041)
    return @{
        '@odata.type'     = 'Microsoft.Dynamics.CRM.Label'
        'LocalizedLabels' = @(@{
            '@odata.type'  = 'Microsoft.Dynamics.CRM.LocalizedLabel'
            'Label'        = $Text
            'LanguageCode' = $LanguageCode
        })
    }
}

function New-DvRequiredLevel {
    param([string]$Level = 'None')
    return @{ Value = $Level; CanBeChanged = $true; ManagedPropertyLogicalName = 'canmodifyrequirementlevelsettings' }
}

function Test-DvTableExists {
    param([Parameter(Mandatory)][string]$LogicalName)
    $r = Invoke-DataverseRequest -Method GET -AllowNotFound `
        -Path "EntityDefinitions(LogicalName='$LogicalName')?`$select=LogicalName"
    return $null -ne $r
}

function Test-DvColumnExists {
    param([Parameter(Mandatory)][string]$TableLogicalName, [Parameter(Mandatory)][string]$ColumnLogicalName)
    $r = Invoke-DataverseRequest -Method GET -AllowNotFound `
        -Path "EntityDefinitions(LogicalName='$TableLogicalName')/Attributes(LogicalName='$ColumnLogicalName')?`$select=LogicalName"
    return $null -ne $r
}

function Test-DvRelationshipExists {
    param([Parameter(Mandatory)][string]$SchemaName)
    $r = Invoke-DataverseRequest -Method GET -AllowNotFound `
        -Path "RelationshipDefinitions?`$select=SchemaName&`$filter=SchemaName eq '$SchemaName'"
    return ($null -ne $r) -and ($r.value.Count -gt 0)
}

function Test-DvKeyExists {
    param([Parameter(Mandatory)][string]$TableLogicalName, [Parameter(Mandatory)][string]$KeySchemaName)
    $r = Invoke-DataverseRequest -Method GET -AllowNotFound `
        -Path "EntityDefinitions(LogicalName='$TableLogicalName')/Keys?`$select=SchemaName&`$filter=SchemaName eq '$KeySchemaName'"
    return ($null -ne $r) -and ($r.value.Count -gt 0)
}

function Publish-DvCustomizations {
    Write-Step 'カスタマイズを公開しています（数分かかることがあります）'
    Invoke-DataverseRequest -Method POST -Path 'PublishAllXml' -Body @{} | Out-Null
    Write-Ok 'カスタマイズを公開しました'
}

#endregion

Export-ModuleMember -Function `
    Write-Step, Write-Ok, Write-Skip, Write-Warn, Write-Info, `
    Connect-Dataverse, Invoke-DataverseRequest, Get-DataverseRecords, `
    Set-DataverseSolutionContext, Get-DataverseConnection, Get-ErrorBody, Get-ResponseHeader, `
    New-DvLabel, New-DvRequiredLevel, `
    Test-DvTableExists, Test-DvColumnExists, Test-DvRelationshipExists, Test-DvKeyExists, `
    Publish-DvCustomizations
