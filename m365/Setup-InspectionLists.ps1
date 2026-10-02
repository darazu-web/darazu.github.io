<#
.SYNOPSIS
    検査情報アプリ用の SharePoint リストを作成し、サンプルデータを登録する。

.DESCRIPTION
    次の 3 つのリストを作成する（既にあるリスト・列はそのまま残す）。
      InspProducts   … 製品
      InspItems      … 検査項目
      InspEquipment  … 検査項目ごとの使用設備（周辺設備／ハーネス／ソフトウェア）
    Power Apps の数式はこのリスト名・列名を前提にしているため、名前は変更しないこと。

.PARAMETER SiteUrl
    リストを作成する SharePoint サイトの URL。
    例: https://contoso.sharepoint.com/sites/Inspection

.PARAMETER ClientId
    PnP PowerShell 用に登録した Entra ID アプリのクライアント ID（README 参照）。

.PARAMETER DataJson
    取り込むデータ（JSON）。既定は同じフォルダーの sample-data.json。

.PARAMETER SkipData
    リストだけ作成し、データは登録しない。

.PARAMETER MembersReadOnly
    3 つのリストの権限継承を切り、サイトの「メンバー」を閲覧のみにする。
    編集できるのはサイトの「所有者」だけになる。
    既存のチームサイトなど、作業者がメンバーに入っているサイトで使う。

.EXAMPLE
    ./Setup-InspectionLists.ps1 -SiteUrl https://contoso.sharepoint.com/sites/Inspection -ClientId 00000000-0000-0000-0000-000000000000
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SiteUrl,
    [Parameter(Mandatory)] [string] $ClientId,
    [string] $DataJson = (Join-Path $PSScriptRoot 'sample-data.json'),
    [switch] $SkipData,
    [switch] $MembersReadOnly
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
    throw 'PnP.PowerShell が見つかりません。PowerShell 7 で「Install-Module PnP.PowerShell -Scope CurrentUser」を実行してください。'
}

Write-Host "接続中: $SiteUrl" -ForegroundColor Cyan
Connect-PnPOnline -Url $SiteUrl -Interactive -ClientId $ClientId

# ---------------------------------------------------------------- 定義
# Type: Text / Note（複数行テキスト・書式なし）/ Number
$schema = [ordered]@{
    InspProducts  = @{
        Description = '検査情報アプリ：製品'
        TitleIndexedUnique = $true
        Fields      = @(
            @{ Name = 'ProductName'; Type = 'Text' }
            @{ Name = 'Description'; Type = 'Note' }
        )
    }
    InspItems     = @{
        Description = '検査情報アプリ：検査項目'
        Fields      = @(
            @{ Name = 'ProductID';  Type = 'Number'; Indexed = $true }
            @{ Name = 'ItemNo';     Type = 'Number' }
            @{ Name = 'Category';   Type = 'Text' }
            @{ Name = 'Method';     Type = 'Note' }
            @{ Name = 'Criteria';   Type = 'Note' }
            @{ Name = 'TesterNo';   Type = 'Text' }
            @{ Name = 'TesterName'; Type = 'Text' }
            @{ Name = 'Notes';      Type = 'Note' }
            @{ Name = 'Other';      Type = 'Note' }
        )
    }
    InspEquipment = @{
        Description = '検査情報アプリ：使用設備'
        Fields      = @(
            @{ Name = 'ItemID';    Type = 'Number'; Indexed = $true }
            @{ Name = 'ProductID'; Type = 'Number'; Indexed = $true }
            @{ Name = 'EquipType'; Type = 'Text' }
            @{ Name = 'Code';      Type = 'Text' }
            @{ Name = 'Note';      Type = 'Text' }
            @{ Name = 'SeqNo';     Type = 'Number' }
        )
    }
}

# ---------------------------------------------------------------- リスト作成
foreach ($listName in $schema.Keys) {
    $def = $schema[$listName]
    $list = Get-PnPList -Identity $listName -ErrorAction SilentlyContinue
    if (-not $list) {
        Write-Host "リスト作成: $listName" -ForegroundColor Green
        $list = New-PnPList -Title $listName -Template GenericList -Url "Lists/$listName" -EnableVersioning
        Set-PnPList -Identity $listName -Description $def.Description | Out-Null
    } else {
        Write-Host "リストは既に存在: $listName"
    }

    if ($def.TitleIndexedUnique) {
        Set-PnPField -List $listName -Identity 'Title' -Values @{ Indexed = $true; EnforceUniqueValues = $true } | Out-Null
    }

    foreach ($f in $def.Fields) {
        $existing = Get-PnPField -List $listName -Identity $f.Name -ErrorAction SilentlyContinue
        if ($existing) { continue }
        Write-Host "  列追加: $($f.Name) ($($f.Type))"
        Add-PnPField -List $listName -DisplayName $f.Name -InternalName $f.Name -Type $f.Type -AddToDefaultView | Out-Null
        if ($f.Type -eq 'Note') {
            Set-PnPField -List $listName -Identity $f.Name -Values @{ RichText = $false; NumberOfLines = 6 } | Out-Null
        }
        if ($f.Indexed) {
            Set-PnPField -List $listName -Identity $f.Name -Values @{ Indexed = $true } | Out-Null
        }
    }
}

# ---------------------------------------------------------------- 権限
if ($MembersReadOnly) {
    $members = Get-PnPGroup -AssociatedMemberGroup
    $roles   = Get-PnPRoleDefinition
    # 権限レベル名はサイトの言語で変わるため、種類で取得する
    $reader  = ($roles | Where-Object { $_.RoleTypeKind -eq 'Reader' } | Select-Object -First 1).Name
    $editRoles = $roles | Where-Object { $_.RoleTypeKind -in @('Editor', 'Contributor', 'WebDesigner') }

    foreach ($listName in $schema.Keys) {
        Write-Host "権限設定: $listName（メンバー → 閲覧のみ）" -ForegroundColor Yellow
        Set-PnPList -Identity $listName -BreakRoleInheritance -CopyRoleAssignments | Out-Null
        foreach ($r in $editRoles) {
            try { Set-PnPListPermission -Identity $listName -Group $members -RemoveRole $r.Name } catch { }
        }
        Set-PnPListPermission -Identity $listName -Group $members -AddRole $reader
    }
}

# ---------------------------------------------------------------- データ登録
if ($SkipData) {
    Write-Host '完了（データ登録はスキップ）' -ForegroundColor Cyan
    return
}
if (-not (Test-Path $DataJson)) {
    Write-Warning "データファイルが見つかりません: $DataJson（リストのみ作成しました）"
    return
}

$data = Get-Content -Path $DataJson -Raw -Encoding UTF8 | ConvertFrom-Json
$typeLabels = [ordered]@{ peripherals = '周辺設備'; harnesses = 'ハーネス'; software = 'ソフトウェア' }

function Get-NumberOrNull([string] $s) {
    $n = 0.0
    if ([double]::TryParse($s, [ref] $n)) { return $n }
    return $null
}

foreach ($p in $data.products) {
    $dup = Get-PnPListItem -List InspProducts -Query "<View><Query><Where><Eq><FieldRef Name='Title'/><Value Type='Text'>$([Security.SecurityElement]::Escape($p.code))</Value></Eq></Where></Query></View>"
    if ($dup) {
        Write-Host "製品は登録済みのためスキップ: $($p.code)"
        continue
    }
    Write-Host "製品登録: $($p.code) $($p.name)" -ForegroundColor Green
    $prod = Add-PnPListItem -List InspProducts -Values @{
        Title       = $p.code
        ProductName = $p.name
        Description = $p.description
    }

    $seq = 0
    foreach ($it in $p.items) {
        $seq++
        $no = Get-NumberOrNull $it.no
        if ($null -eq $no) { $no = $seq }
        $eq = $it.equipment
        $item = Add-PnPListItem -List InspItems -Values @{
            Title      = $it.name
            ProductID  = $prod.Id
            ItemNo     = $no
            Category   = $it.category
            Method     = $it.method
            Criteria   = $it.criteria
            TesterNo   = $eq.testerNo
            TesterName = $eq.testerName
            Notes      = $it.notes
            Other      = $it.other
        }
        Write-Host "  検査項目: $no $($it.name)"

        $order = 0
        foreach ($key in $typeLabels.Keys) {
            foreach ($row in @($eq.$key)) {
                if (-not $row) { continue }
                $order++
                Add-PnPListItem -List InspEquipment -Values @{
                    Title     = $row.name
                    Code      = $row.code
                    Note      = $row.note
                    EquipType = $typeLabels[$key]
                    ItemID    = $item.Id
                    ProductID = $prod.Id
                    SeqNo     = $order
                } | Out-Null
            }
        }
    }
}

Write-Host '完了しました。' -ForegroundColor Cyan
