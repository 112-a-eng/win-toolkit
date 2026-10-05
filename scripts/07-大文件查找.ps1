<#
.SYNOPSIS
    查找磁盘上的大文件 / 老文件，并可导出 CSV
.DESCRIPTION
    递归扫描指定目录，列出超过阈值大小的文件，按大小排序。
    可同时按“多少天未修改”筛选，用于清理长期不用的大文件。
.PARAMETER Path
    要扫描的目录，可多个，默认整个系统盘。
.PARAMETER MinMB
    只显示大于该大小（MB）的文件，默认 100。
.PARAMETER Top
    显示前 N 条，默认 30；设为 0 表示全部。
.PARAMETER OlderThanDays
    只显示超过 N 天未修改的文件，0 表示不限。
.PARAMETER Extension
    只统计指定扩展名，例如 -Extension .iso,.vhdx,.zip
.PARAMETER Export
    导出完整结果为 CSV，例如 D:\bigfiles.csv
.PARAMETER Quiet
    不输出进度提示。
.EXAMPLE
    .\07-大文件查找.ps1 -Path D:\ -MinMB 500
.EXAMPLE
    .\07-大文件查找.ps1 -Path C:\Users -MinMB 200 -OlderThanDays 90 -Export D:\old-big.csv
#>
[CmdletBinding()]
param(
    [string[]]$Path = @(),
    [int]$MinMB = 100,
    [int]$Top = 30,
    [int]$OlderThanDays = 0,
    [string[]]$Extension = @(),
    [string]$Export,
    [switch]$Quiet
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

if ($Path.Count -eq 0) { $Path = @("$env:SystemDrive\") }
$Path = $Path | Where-Object { Test-Path -LiteralPath $_ }
if ($Path.Count -eq 0) { Write-Host ' 指定的目录都不存在。' -ForegroundColor Red; exit 1 }

# 规范化扩展名（允许写 iso 或 .iso）
if ($Extension.Count -gt 0) {
    $Extension = $Extension | ForEach-Object { if ($_ -like '.*') { $_.ToLower() } else { '.' + $_.ToLower() } }
}

$minBytes = [int64]$MinMB * 1MB
$cutTime  = if ($OlderThanDays -gt 0) { (Get-Date).AddDays(-$OlderThanDays) } else { $null }

Write-Host ''
Write-Host ' 大文件查找' -ForegroundColor White -BackgroundColor DarkBlue
Write-Host (" 目录: {0}" -f ($Path -join ' ; '))
Write-Host (" 条件: 大于 {0} MB{1}{2}" -f $MinMB,
    $(if ($cutTime) { "，且 {0} 天未修改" -f $OlderThanDays } else { '' }),
    $(if ($Extension.Count -gt 0) { "，扩展名 " + ($Extension -join ',') } else { '' })) -ForegroundColor DarkGray
if (-not $Quiet) { Write-Host ' 扫描中，请稍候…' -ForegroundColor Cyan }

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$all = foreach ($p in $Path) {
    Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -ge $minBytes }
}
if ($cutTime)      { $all = $all | Where-Object { $_.LastWriteTime -lt $cutTime } }
if ($Extension.Count -gt 0) { $all = $all | Where-Object { $Extension -contains $_.Extension.ToLower() } }
$all = @($all | Sort-Object Length -Descending)
$sw.Stop()

$totalSize = ($all | Measure-Object Length -Sum).Sum
Write-Host ''
Write-Host (" 扫描完成: {0} 个文件，合计 {1} GB，耗时 {2:N1} 秒" -f `
    $all.Count, [Math]::Round($totalSize / 1GB, 2), $sw.Elapsed.TotalSeconds) -ForegroundColor Yellow

$show = if ($Top -gt 0) { $all | Select-Object -First $Top } else { $all }
Write-Host ''
$show | Select-Object @{n='大小MB';e={[Math]::Round($_.Length / 1MB, 1)}},
    @{n='修改时间';e={$_.LastWriteTime.ToString('yyyy-MM-dd')}},
    @{n='路径';e={$_.FullName}} |
    Format-Table -AutoSize | Out-String -Width 240 | Write-Host

if ($Top -gt 0 -and $all.Count -gt $Top) {
    Write-Host (" （仅显示前 {0} 条，共 {1} 条；用 -Top 0 显示全部）" -f $Top, $all.Count) -ForegroundColor DarkGray
}

if ($Export) {
    $all | Select-Object FullName, Length,
        @{n='SizeMB';e={[Math]::Round($_.Length / 1MB, 1)}},
        LastWriteTime, Extension |
        Export-Csv -LiteralPath $Export -NoTypeInformation -Encoding UTF8
    Write-Host (" 已导出 {0} 条到: {1}" -f $all.Count, $Export) -ForegroundColor Green
}

Write-Host ''
Write-Host ' 安全提醒：删除前请确认文件用途，系统盘上的大文件多为休眠/虚拟内存/更新缓存。' -ForegroundColor DarkGray
Write-Host ''
