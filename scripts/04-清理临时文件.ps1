<#
.SYNOPSIS
    安全清理 Windows 临时文件与缓存
.DESCRIPTION
    统计并删除常见临时目录中的文件，默认只清理“用户临时目录 + 系统临时目录”。
    可选清理回收站、Windows 更新缓存、缩略图/图标缓存、崩溃转储。
    强烈建议先加 -DryRun 预览会删什么。
.PARAMETER DryRun
    只统计与列出，不删除任何文件。
.PARAMETER IncludeRecycleBin
    同时清空回收站（不可恢复）。
.PARAMETER IncludeUpdateCache
    清理 Windows 更新下载缓存（会临时停止 wuauserv/bits 服务，需要管理员）。
.PARAMETER IncludeCrashDumps
    清理崩溃转储与缩略图缓存。
.PARAMETER DaysOld
    只清理 N 天以前的文件，0 表示不限（默认 0）。
.EXAMPLE
    .\04-清理临时文件.ps1 -DryRun
.EXAMPLE
    .\04-清理临时文件.ps1 -IncludeRecycleBin -IncludeCrashDumps -DaysOld 7
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$IncludeRecycleBin,
    [switch]$IncludeUpdateCache,
    [switch]$IncludeCrashDumps,
    [int]$DaysOld = 0,
    [switch]$Yes          # 跳过交互确认（图形界面/自动化调用）
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$targets = New-Object System.Collections.Generic.List[object]
function Add-Target([string]$Name, [string]$Path) {
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        $targets.Add([pscustomobject]@{ Name = $Name; Path = $Path })
    }
}

Add-Target '用户临时目录'      $env:TEMP
Add-Target '系统临时目录'      "$env:SystemRoot\Temp"
Add-Target 'IE/Edge 网页缓存'  "$env:LOCALAPPDATA\Microsoft\Windows\INetCache"
Add-Target 'Windows 错误报告'  "$env:LOCALAPPDATA\Microsoft\Windows\WER"
if ($IncludeCrashDumps) {
    Add-Target '崩溃转储'      "$env:LOCALAPPDATA\CrashDumps"
    Add-Target '缩略图缓存'    "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
    Add-Target '系统转储'      "$env:SystemRoot\Minidump"
}
if ($IncludeUpdateCache) {
    Add-Target '更新下载缓存'  "$env:SystemRoot\SoftwareDistribution\Download"
}

function Get-FolderSize([string]$Path, [int]$Days) {
    $cut = if ($Days -gt 0) { (Get-Date).AddDays(-$Days) } else { $null }
    $items = Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue
    if ($cut) { $items = $items | Where-Object { $_.LastWriteTime -lt $cut } }
    [pscustomobject]@{
        Size  = ($items | Measure-Object Length -Sum).Sum
        Count = @($items).Count
    }
}

Write-Host ''
Write-Host ' Windows 临时文件清理' -ForegroundColor White -BackgroundColor DarkBlue
Write-Host (" 模式: {0}   管理员: {1}   仅清理 {2}" -f `
    $(if ($DryRun) { '预览（不会删除）' } else { '实际删除' }), `
    $(if ($isAdmin) { '是' } else { '否' }), `
    $(if ($DaysOld -gt 0) { "$DaysOld 天前的文件" } else { '全部文件' })) -ForegroundColor DarkGray

# 统计
$totalSize = 0
$totalCount = 0
$report = @()
foreach ($t in $targets) {
    $s = Get-FolderSize $t.Path $DaysOld
    $totalSize += $s.Size
    $totalCount += $s.Count
    $report += [pscustomobject]@{
        项目 = $t.Name
        大小MB = [Math]::Round($s.Size / 1MB, 1)
        文件数 = $s.Count
        路径 = $t.Path
    }
}
if ($IncludeRecycleBin) {
    $report += [pscustomobject]@{ 项目 = '回收站'; 大小MB = $null; 文件数 = $null; 路径 = '（清空后不可恢复）' }
}

Write-Host ''
$report | Format-Table -AutoSize | Out-String | Write-Host
Write-Host (" 合计可清理: {0} MB / {1} 个文件" -f [Math]::Round($totalSize / 1MB, 1), $totalCount) -ForegroundColor Yellow

if ($DryRun) {
    Write-Host ''
    Write-Host ' 这是预览模式，未删除任何文件。确认无误后执行：' -ForegroundColor Green
    Write-Host '   .\04-清理临时文件.ps1 -IncludeRecycleBin -IncludeCrashDumps' -ForegroundColor DarkGray
    Write-Host ''
    return
}

$answer = 'y'
if (-not $Yes) { $answer = Read-Host ' 确认删除以上内容? 输入 y 继续' }
if ($answer -ne 'y') { Write-Host ' 已取消。' -ForegroundColor DarkGray; return }

# 需要先停服务的情况
$servicesStopped = @()
if ($IncludeUpdateCache) {
    foreach ($svc in 'wuauserv', 'bits', 'dosvc') {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s -and $s.Status -eq 'Running') {
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
            $servicesStopped += $svc
        }
    }
    if ($servicesStopped.Count -gt 0) { Write-Host (" 已临时停止服务: {0}" -f ($servicesStopped -join ', ')) -ForegroundColor DarkGray }
}

$cut = if ($DaysOld -gt 0) { (Get-Date).AddDays(-$DaysOld) } else { $null }
$freed = 0
foreach ($t in $targets) {
    $items = Get-ChildItem -LiteralPath $t.Path -Force -ErrorAction SilentlyContinue
    if ($cut) { $items = $items | Where-Object { $_.LastWriteTime -lt $cut } }
    foreach ($item in @($items)) {
        $size = 0
        if ($item.PSIsContainer) {
            $size = (Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object Length -Sum).Sum
        } else {
            $size = $item.Length
        }
        Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $item.FullName)) {
            $freed += [int64]$size
        }
    }
}

if ($IncludeRecycleBin) {
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    Write-Host ' 回收站已清空。' -ForegroundColor Green
}

foreach ($svc in $servicesStopped) {
    Start-Service -Name $svc -ErrorAction SilentlyContinue
}
if ($servicesStopped.Count -gt 0) { Write-Host (" 已恢复服务: {0}" -f ($servicesStopped -join ', ')) -ForegroundColor DarkGray }

Write-Host ''
Write-Host (" 清理完成，释放约 {0} MB 空间。" -f [Math]::Round($freed / 1MB, 1)) -ForegroundColor Green
Write-Host ''
