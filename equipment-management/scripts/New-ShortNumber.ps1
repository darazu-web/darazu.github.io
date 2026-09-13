<#
.SYNOPSIS
    設備 CSV の短縮番号を場所ごとの番号帯で採番し、重複を検査します（フェーズ2-4）。
.DESCRIPTION
    Dataverse には接続しません。取り込み前の CSV を相手に、手元で完結します。
    場所ごとに番号帯を分けておくと、現場が番号から場所を推測できます（1階=0100番台、2階=0200番台）。
    番号帯は data\eqm_locations.csv の「番号帯開始」「番号帯終了」で決まります。

    -Verify を付けると採番せず、検査だけします。
.EXAMPLE
    # 空欄を採番して eqm_equipments_numbered.csv に書き出す
    .\New-ShortNumber.ps1
.EXAMPLE
    # 既存の番号の重複・番号帯外だけを検査する
    .\New-ShortNumber.ps1 -Verify
.EXAMPLE
    # すでに Dataverse にある番号を避けて採番する
    .\New-ShortNumber.ps1 -ExistingNumbersCsv .\live-numbers.csv
#>
[CmdletBinding()]
param(
    [string]$EquipmentCsv = (Join-Path $PSScriptRoot '..\data\eqm_equipments.csv'),
    [string]$LocationCsv  = (Join-Path $PSScriptRoot '..\data\eqm_locations.csv'),
    [string]$OutputPath,
    [string]$ExistingNumbersCsv,
    [string]$Encoding = 'UTF8',
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Dataverse.psm1') -Force

$HeaderShortNumber = '短縮番号'
$HeaderLocation    = '場所'
$HeaderCode        = '設備コード'
$HeaderName        = '設備名'
$HeaderQr          = 'QRコード値'
$HeaderLocCode     = '場所コード'
$HeaderLocName     = '場所名'
$HeaderBandFrom    = '番号帯開始'
$HeaderBandTo      = '番号帯終了'

Write-Host ''
Write-Host '========================================' -ForegroundColor White
Write-Host ' 短縮番号の採番と重複チェック' -ForegroundColor White
Write-Host '========================================' -ForegroundColor White

#region ---------- 読み込み ----------

if (-not (Test-Path -LiteralPath $EquipmentCsv)) { throw "設備 CSV が見つかりません: $EquipmentCsv" }
if (-not (Test-Path -LiteralPath $LocationCsv))  { throw "場所 CSV が見つかりません: $LocationCsv" }

$equipment = @(Import-Csv -LiteralPath $EquipmentCsv -Encoding $Encoding)
$locations = @(Import-Csv -LiteralPath $LocationCsv  -Encoding $Encoding)
if ($equipment.Count -eq 0) { throw '設備 CSV に行がありません。' }

$headers = $equipment[0].PSObject.Properties.Name
foreach ($h in @($HeaderShortNumber, $HeaderLocation, $HeaderCode)) {
    if ($headers -notcontains $h) { throw "設備 CSV に『$h』列がありません。" }
}

# 場所コード → 番号帯
$bands = @{}
foreach ($loc in $locations) {
    $code = ("$($loc.$HeaderLocCode)").Trim()
    if (-not $code) { continue }
    $from = ("$($loc.$HeaderBandFrom)").Trim()
    $to   = ("$($loc.$HeaderBandTo)").Trim()
    if (-not $from -or -not $to) {
        Write-Warn "場所 $code には番号帯が設定されていません。この場所の設備は採番できません。"
        continue
    }
    $bands[$code] = [pscustomobject]@{
        Code   = $code
        Name   = ("$($loc.$HeaderLocName)").Trim()
        From   = [int]$from
        To     = [int]$to
        Digits = $from.Length
    }
}
Write-Host "    場所 $($bands.Count) 件の番号帯を読み込みました" -ForegroundColor DarkGray

# 既に使われている番号（他環境や本番から書き出したもの）
$reserved = New-Object System.Collections.Generic.HashSet[string]
if ($ExistingNumbersCsv) {
    if (-not (Test-Path -LiteralPath $ExistingNumbersCsv)) { throw "既存番号 CSV が見つかりません: $ExistingNumbersCsv" }
    foreach ($r in @(Import-Csv -LiteralPath $ExistingNumbersCsv -Encoding $Encoding)) {
        $n = ("$($r.$HeaderShortNumber)").Trim()
        if ($n) { [void]$reserved.Add($n) }
    }
    Write-Host "    既存番号 $($reserved.Count) 件を予約済みとして扱います" -ForegroundColor DarkGray
}

#endregion

#region ---------- 検査 ----------

$problems = New-Object System.Collections.ArrayList
$seen = @{}
$rowNo = 1

foreach ($row in $equipment) {
    $rowNo++
    $num  = ("$($row.$HeaderShortNumber)").Trim()
    $loc  = ("$($row.$HeaderLocation)").Trim()
    $code = ("$($row.$HeaderCode)").Trim()
    if (-not $num) { continue }

    if ($num -notmatch '^\d+$') {
        [void]$problems.Add("$rowNo 行目 ($code): 短縮番号 '$num' に数字以外が含まれています")
        continue
    }
    if ($seen.ContainsKey($num)) {
        [void]$problems.Add("$rowNo 行目 ($code): 短縮番号 $num が $($seen[$num]) 行目と重複しています")
    } else {
        $seen[$num] = $rowNo
    }
    if ($reserved.Contains($num)) {
        [void]$problems.Add("$rowNo 行目 ($code): 短縮番号 $num は既に使われています（既存番号 CSV と衝突）")
    }
    if ($bands.ContainsKey($loc)) {
        $b = $bands[$loc]
        $v = [int]$num
        if ($v -lt $b.From -or $v -gt $b.To) {
            $bandText = "$(([string]$b.From).PadLeft($b.Digits,'0'))〜$(([string]$b.To).PadLeft($b.Digits,'0'))"
            [void]$problems.Add("$rowNo 行目 ($code): 短縮番号 $num が場所 $loc（$($b.Name)）の番号帯 $bandText の外です")
        }
        if ($num.Length -ne $b.Digits) {
            [void]$problems.Add("$rowNo 行目 ($code): 短縮番号 $num の桁数が $($b.Digits) 桁になっていません（先頭のゼロが落ちている可能性があります）")
        }
    } elseif ($loc) {
        [void]$problems.Add("$rowNo 行目 ($code): 場所 '$loc' が場所マスタにありません")
    }
}

Write-Step '既存の短縮番号を検査しています'
if ($problems.Count -eq 0) {
    Write-Info "問題は見つかりませんでした（$($seen.Count) 件の番号を確認）"
} else {
    foreach ($p in $problems) { Write-Warn $p }
    Write-Host "    $($problems.Count) 件の問題が見つかりました" -ForegroundColor Yellow
}

#endregion

#region ---------- 採番 ----------

if ($Verify) {
    Write-Host ''
    if ($problems.Count -gt 0) { Write-Host '検査のみ実行しました。上の問題を直してください。' -ForegroundColor Yellow; exit 1 }
    Write-Host '検査のみ実行しました。問題はありません。' -ForegroundColor Green
    exit 0
}

# 重複があるまま採番すると傷口が広がるので止める
if ($problems.Count -gt 0) {
    throw "既存の短縮番号に問題があるため採番を中止しました。上の内容を直してから実行し直してください。"
}

Write-Step '空欄の短縮番号を採番しています'

# 場所ごとに「次に空いている番号」を探すためのカーソル
$cursor = @{}
foreach ($k in $bands.Keys) { $cursor[$k] = $bands[$k].From }

$assigned = 0
$rowNo = 1
foreach ($row in $equipment) {
    $rowNo++
    $num = ("$($row.$HeaderShortNumber)").Trim()
    if ($num) { continue }

    $loc = ("$($row.$HeaderLocation)").Trim()
    $code = ("$($row.$HeaderCode)").Trim()
    if (-not $bands.ContainsKey($loc)) {
        Write-Warn "$rowNo 行目 ($code): 場所 '$loc' の番号帯が分からないため採番できません"
        continue
    }

    $b = $bands[$loc]
    $v = $cursor[$loc]
    while ($v -le $b.To) {
        $candidate = ([string]$v).PadLeft($b.Digits, '0')
        if (-not $seen.ContainsKey($candidate) -and -not $reserved.Contains($candidate)) { break }
        $v++
    }
    if ($v -gt $b.To) {
        $bandText = "$(([string]$b.From).PadLeft($b.Digits,'0'))〜$(([string]$b.To).PadLeft($b.Digits,'0'))"
        throw "場所 $loc（$($b.Name)）の番号帯 $bandText が満杯です。場所マスタの番号帯を広げてください。"
    }

    $candidate = ([string]$v).PadLeft($b.Digits, '0')
    $row.$HeaderShortNumber = $candidate
    # QR コード値が空なら短縮番号と同じ値を入れておく（フェーズ3-11 でそのまま使える）
    if ($headers -contains $HeaderQr -and -not ("$($row.$HeaderQr)").Trim()) { $row.$HeaderQr = $candidate }
    $seen[$candidate] = $rowNo
    $cursor[$loc] = $v + 1
    $assigned++

    $label = $code
    if ($headers -contains $HeaderName) { $label = "$code $($row.$HeaderName)" }
    Write-Info "  $candidate ← $label"
}

if ($assigned -eq 0) { Write-Host '    採番が必要な行はありませんでした' -ForegroundColor DarkGray }

#endregion

#region ---------- 書き出しと集計 ----------

if (-not $OutputPath) {
    $dir  = Split-Path -Parent $EquipmentCsv
    $base = [IO.Path]::GetFileNameWithoutExtension($EquipmentCsv)
    $OutputPath = Join-Path $dir "$base`_numbered.csv"
}

# Excel で開いたときに文字化けしないよう BOM 付き UTF-8 で書く
$outEncoding = 'UTF8'
if ($PSVersionTable.PSVersion.Major -ge 6) { $outEncoding = 'utf8BOM' }
$equipment | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding $outEncoding

Write-Host ''
Write-Step '場所ごとの使用状況'
foreach ($k in ($bands.Keys | Sort-Object)) {
    $b = $bands[$k]
    $used = @($equipment | Where-Object { ("$($_.$HeaderLocation)").Trim() -eq $k -and ("$($_.$HeaderShortNumber)").Trim() }).Count
    $capacity = $b.To - $b.From + 1
    $from = ([string]$b.From).PadLeft($b.Digits, '0')
    $to   = ([string]$b.To).PadLeft($b.Digits, '0')
    Write-Host ("    {0,-6} {1,-12} {2,4} / {3,4} 使用（番号帯 {4}〜{5}）" -f $k, $b.Name, $used, $capacity, $from, $to)
}

Write-Host ''
Write-Info "$assigned 件を採番しました → $OutputPath"
Write-Host ''
Write-Host '次にやること:' -ForegroundColor White
Write-Host '  1. 出力された CSV を確認し、問題なければ data\eqm_equipments.csv を置き換える'
Write-Host '  2. .\Import-MasterData.ps1 -Table 設備 で投入する'
Write-Host '  3. print\label-sheet.html でラベルを印刷する（フェーズ6-2 / 7-1）'
Write-Host ''

#endregion
