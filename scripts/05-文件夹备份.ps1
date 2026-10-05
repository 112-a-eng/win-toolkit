<#
.SYNOPSIS
    基于 robocopy 的文件夹备份 / 镜像同步
.DESCRIPTION
    默认「增量复制」：只复制新增和改动的文件，绝不删除目标端内容。
    加 -Mirror 变成「镜像同步」：目标会与源完全一致，多余文件会被删除（需二次确认）。
.PARAMETER Source
    源目录，例如 D:\work
.PARAMETER Destination
    目标目录，例如 E:\backup\work 或 \\NAS\backup\work
.PARAMETER Mirror
    镜像模式（/MIR），目标端多余文件将被删除。
.PARAMETER ExcludeDir
    要排除的目录名（可多个），例如 -ExcludeDir node_modules,.git
.PARAMETER LogPath
    日志文件路径，默认在目标目录旁的 backup-<时间>.log。
.PARAMETER Threads
    并发线程数，默认 8。
.PARAMETER DryRun
    只预览会做什么，不真正复制（/L）。
.EXAMPLE
    .\05-文件夹备份.ps1 -Source D:\work -Destination E:\backup\work
.EXAMPLE
    .\05-文件夹备份.ps1 -Source D:\work -Destination E:\backup\work -Mirror -ExcludeDir node_modules,.git
.EXAMPLE
    .\05-文件夹备份.ps1 -Source D:\work -Destination E:\backup\work -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination,
    [switch]$Mirror,
    [string[]]$ExcludeDir = @(),
    [string]$LogPath,
    [int]$Threads = 8,
    [switch]$DryRun,
    [switch]$Yes          # 跳过交互确认（图形界面/自动化调用）
)

$ErrorActionPreference = 'Continue'

if (-not (Test-Path -LiteralPath $Source)) {
    Write-Host (" 源目录不存在: {0}" -f $Source) -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $Destination)) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Write-Host (" 已创建目标目录: {0}" -f $Destination) -ForegroundColor DarkGray
}
if (-not (Get-Command robocopy.exe -ErrorAction SilentlyContinue)) {
    Write-Host ' 找不到 robocopy.exe（Windows 自带，请检查 PATH）' -ForegroundColor Red
    exit 1
}

$Source      = (Resolve-Path -LiteralPath $Source).Path
$Destination = (Resolve-Path -LiteralPath $Destination).Path

if (-not $LogPath) {
    $LogPath = Join-Path $Destination ("backup-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

$argList = @(
    $Source
    $Destination
    '/E'                 # 含子目录（含空目录）
    '/COPY:DAT'          # 数据+属性+时间戳
    '/DCOPY:T'           # 目录时间戳
    '/R:2'               # 失败重试 2 次
    '/W:2'               # 重试间隔 2 秒
    '/Z'                 # 断点续传模式（网络更稳）
    '/NP'                # 不显示百分比
    '/NDL'               # 不列目录
)
if ($ExcludeDir.Count -gt 0) { $argList += @('/XD') + $ExcludeDir }
$argList += @('/XF', 'Thumbs.db', 'desktop.ini', '*.tmp', '~$*')
$argList += @('/MT:' + $Threads, '/TEE', ('/LOG+:' + $LogPath))
if ($Mirror) { $argList += '/MIR' }
if ($DryRun)  { $argList += '/L' }

Write-Host ''
Write-Host ' robocopy 备份' -ForegroundColor White -BackgroundColor DarkBlue
Write-Host (" 源      : {0}" -f $Source)
Write-Host (" 目标    : {0}" -f $Destination)
Write-Host (" 模式    : {0}" -f $(if ($Mirror) { '镜像同步（目标多余文件会被删除）' } else { '增量复制（不删除目标文件）' })) `
    -ForegroundColor $(if ($Mirror) { 'Yellow' } else { 'Green' })
if ($ExcludeDir.Count -gt 0) { Write-Host (" 排除目录: {0}" -f ($ExcludeDir -join ', ')) }
Write-Host (" 日志    : {0}" -f $LogPath)
if ($DryRun) { Write-Host ' 预览模式: 只列出将发生的操作，不复制' -ForegroundColor Yellow }

if ($Mirror -and -not $DryRun -and -not $Yes) {
    Write-Host ''
    $answer = Read-Host ' 镜像模式会删除目标端多余文件，确认继续? 输入 y'
    if ($answer -ne 'y') { Write-Host ' 已取消。' -ForegroundColor DarkGray; exit 0 }
}

Write-Host ''
Write-Host ' 开始执行…' -ForegroundColor Cyan
$sw = [System.Diagnostics.Stopwatch]::StartNew()
& robocopy.exe @argList | Out-Null
$code = $LASTEXITCODE
$sw.Stop()

# robocopy 返回码: 0=无变化 1=已复制 2=有多余项 3=1+2 4..7=警告 8+=失败
$summary = switch ($code) {
    0 { '无需复制，目标已是最新' }
    1 { '成功复制了文件' }
    2 { '目标端存在多余文件/目录（未删除）' }
    3 { '复制完成，且目标端有多余文件' }
    default {
        if ($code -lt 8) { "完成，但有警告（代码 $code）" } else { "失败（代码 $code）" }
    }
}
if ($DryRun -and $code -lt 8) { $summary = '预览完成（未真正复制任何文件）' }
$color = if ($code -ge 8) { 'Red' } elseif ($code -ge 4) { 'Yellow' } else { 'Green' }
Write-Host ''
Write-Host (" 结果: {0}  (robocopy 代码 {1}, 耗时 {2:N1} 秒)" -f $summary, $code, $sw.Elapsed.TotalSeconds) -ForegroundColor $color
Write-Host (" 日志: {0}" -f $LogPath) -ForegroundColor DarkGray

if ($code -ge 8) { exit $code }

# 打印日志中的汇总段
Get-Content -LiteralPath $LogPath -Tail 12 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ('   ' + $_) -ForegroundColor DarkGray }
Write-Host ''
