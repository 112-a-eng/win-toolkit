<#
.SYNOPSIS
    批量重命名文件（默认预览，安全）
.DESCRIPTION
    支持加前缀、加后缀、正则替换、插入序号。默认只预览不修改，
    确认无误后加 -Apply 才真正执行。自动跳过会重名冲突的项。
.PARAMETER Path
    目标目录，默认当前目录。
.PARAMETER Filter
    文件通配符，默认 *（例如 *.jpg）。
.PARAMETER Prefix
    在文件名前添加的字符串。
.PARAMETER Suffix
    在文件名（扩展名前）后添加的字符串。
.PARAMETER Replace
    要替换的正则表达式（例如 '^IMG_' 或 '\s+'）。
.PARAMETER With
    替换成的内容（配合 -Replace 使用）。
.PARAMETER Number
    添加序号，如 3 表示从 3 开始编号。
.PARAMETER Pad
    序号位数，默认 3（即 001）。
.PARAMETER Recurse
    递归子目录。
.PARAMETER Apply
    真正执行重命名；不加则只预览。
.EXAMPLE
    .\08-批量重命名.ps1 -Path D:\photos -Filter *.jpg -Prefix 2024_
.EXAMPLE
    .\08-批量重命名.ps1 -Path . -Filter *.txt -Replace '\s+' -With '_' -Apply
.EXAMPLE
    .\08-批量重命名.ps1 -Filter *.png -Prefix pic_ -Number 1 -Pad 4 -Apply
#>
[CmdletBinding()]
param(
    [string]$Path = '.',
    [string]$Filter = '*',
    [string]$Prefix,
    [string]$Suffix,
    [string]$Replace,
    [string]$With = '',
    [int]$Number = -1,
    [int]$Pad = 3,
    [switch]$Recurse,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path)) { Write-Host (" 目录不存在: {0}" -f $Path) -ForegroundColor Red; exit 1 }
$Path = (Resolve-Path -LiteralPath $Path).Path

if (-not $Prefix -and -not $Suffix -and -not $Replace -and $Number -lt 0) {
    Write-Host ' 至少指定一个改名规则：-Prefix / -Suffix / -Replace / -Number' -ForegroundColor Yellow
    Write-Host ' 例：.\08-批量重命名.ps1 -Filter *.jpg -Prefix 旅行_' -ForegroundColor DarkGray
    exit 1
}

$files = Get-ChildItem -LiteralPath $Path -Filter $Filter -File -Force:$false -Recurse:$Recurse |
    Sort-Object FullName
if (@($files).Count -eq 0) { Write-Host ' 没有匹配的文件。' -ForegroundColor Yellow; exit 0 }

Write-Host ''
Write-Host ' 批量重命名' -ForegroundColor White -BackgroundColor DarkBlue
Write-Host (" 目录: {0}    匹配: {1}    共 {2} 个文件" -f $Path, $Filter, @($files).Count)
Write-Host (" 模式: {0}" -f $(if ($Apply) { '实际执行' } else { '预览（不修改文件）' })) `
    -ForegroundColor $(if ($Apply) { 'Yellow' } else { 'Green' })

$index = if ($Number -ge 0) { $Number } else { 0 }
$plan = @()
foreach ($f in $files) {
    $base = $f.BaseName
    $ext  = $f.Extension

    if ($Replace) { $base = $base -replace $Replace, $With }
    if ($Prefix)  { $base = $Prefix + $base }
    if ($Suffix)  { $base = $base + $Suffix }
    if ($Number -ge 0) {
        $base = $base + '_' + $index.ToString().PadLeft($Pad, '0')
        $index++
    }

    $newName = $base + $ext
    $plan += [pscustomobject]@{
        Dir     = $f.DirectoryName
        Old     = $f.Name
        New     = $newName
        Full    = $f.FullName
        Changed = ($newName -ne $f.Name)
    }
}

$changed = $plan | Where-Object Changed
if (@($changed).Count -eq 0) { Write-Host ' 所有文件名都符合目标规则，无需修改。' -ForegroundColor Green; exit 0 }

Write-Host ''
$plan | Select-Object @{n='原名';e={$_.Old}}, @{n='新名';e={$_.New}},
    @{n='变化';e={ if ($_.Changed) { '改名' } else { '不变' } }} |
    Format-Table -AutoSize | Out-String -Width 200 | Write-Host

$skipped = 0
$done = 0
foreach ($item in $changed) {
    $target = Join-Path $item.Dir $item.New
    if (Test-Path -LiteralPath $target) {
        Write-Host (" 跳过（目标已存在）: {0}" -f $item.New) -ForegroundColor Yellow
        $skipped++
        continue
    }
    if ($Apply) {
        try {
            Rename-Item -LiteralPath $item.Full -NewName $item.New -ErrorAction Stop
            Write-Host (" 已改名: {0}  ->  {1}" -f $item.Old, $item.New) -ForegroundColor Green
            $done++
        } catch {
            Write-Host (" 失败: {0} ({1})" -f $item.Old, $_.Exception.Message) -ForegroundColor Red
            $skipped++
        }
    } else {
        Write-Host (" 将改名: {0}  ->  {1}" -f $item.Old, $item.New) -ForegroundColor Gray
    }
}

Write-Host ''
if ($Apply) {
    Write-Host (" 完成: 成功 {0} 个，跳过 {1} 个。" -f $done, $skipped) -ForegroundColor Green
} else {
    Write-Host ' 以上为预览结果。确认无误后重新执行并加上 -Apply 才会真正改名。' -ForegroundColor Yellow
    Write-Host ' 撤销提示：PowerShell 可用 Get-ChildItem | Rename-Item 反向改回，建议先小范围试。' -ForegroundColor DarkGray
}
Write-Host ''
