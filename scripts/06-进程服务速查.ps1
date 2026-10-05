<#
.SYNOPSIS
    进程 / 服务 / 启动项 / 监听端口 速查
.DESCRIPTION
    显示占内存和 CPU 最高的进程、应该自启但未运行的服务、自动启动项与监听端口，
    便于快速定位“电脑卡 / 变慢”的原因。
    优先使用 WMI/CIM，被限制时自动回退到 netstat 与注册表 Run 键。
.PARAMETER Top
    每类显示前 N 条，默认 12。
.EXAMPLE
    .\06-进程服务速查.ps1
.EXAMPLE
    .\06-进程服务速查.ps1 -Top 20
#>
[CmdletBinding()]
param(
    [int]$Top = 12
)

$ErrorActionPreference = 'SilentlyContinue'

function Write-Title([string]$Text) {
    Write-Host ''
    Write-Host "== $Text " -ForegroundColor Cyan -NoNewline
    Write-Host ('=' * [Math]::Max(4, 58 - $Text.Length)) -ForegroundColor DarkCyan
}
function Get-CounterValue([string]$CounterPath) {
    try { return (Get-Counter -Counter $CounterPath -ErrorAction Stop).CounterSamples[0].CookedValue }
    catch { return $null }
}

Write-Host ''
Write-Host ' 进程 / 服务 / 启动项 速查' -ForegroundColor White -BackgroundColor DarkBlue
Write-Host (" 时间: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ForegroundColor DarkGray

# ---------- 概览 ----------
$os = $null
try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { $os = $null }
$procCount = (Get-Process).Count
if ($os) {
    $usedPct = [Math]::Round((1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100, 1)
    Write-Host (" 内存已用 {0}%   进程总数 {1}" -f $usedPct, $procCount) -ForegroundColor Yellow
} else {
    $availMB = Get-CounterValue '\Memory\Available MBytes'
    $committed = Get-CounterValue '\Memory\Committed Bytes'
    if ($availMB) {
        Write-Host (" 可用物理内存 {0} GB   已提交 {1} GB   进程总数 {2}（WMI 受限，无法算使用率）" -f `
            [Math]::Round($availMB / 1024, 2), [Math]::Round($committed / 1GB, 2), $procCount) -ForegroundColor Yellow
    } else {
        Write-Host (" 进程总数 {0}（WMI 受限，内存统计不可用）" -f $procCount) -ForegroundColor Yellow
    }
}

# ---------- 内存 Top ----------
Write-Title ("内存占用 Top {0}" -f $Top)
Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First $Top | ForEach-Object {
    $mb = [Math]::Round($_.WorkingSet64 / 1MB, 1)
    $bar = '#' * [Math]::Min([int]($mb / 50), 40)
    Write-Host ('  {0,-28} {1,8} MB  {2}' -f $_.ProcessName, $mb, $bar) -ForegroundColor Gray
}

# ---------- CPU Top ----------
Write-Title ("累计 CPU 时间 Top {0}（秒）" -f $Top)
Get-Process | Where-Object { $_.CPU -gt 0 } | Sort-Object CPU -Descending | Select-Object -First $Top | ForEach-Object {
    Write-Host ('  {0,-28} {1,10:N1} s   PID {2}' -f $_.ProcessName, $_.CPU, $_.Id) -ForegroundColor Gray
}

# ---------- 异常服务 ----------
Write-Title '应该自启但当前未运行的服务'
$bad = @(Get-Service | Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' })
if ($bad.Count -gt 0) {
    $bad | Select-Object -First 15 | ForEach-Object { Write-Host ('  [!] {0,-34} {1}' -f $_.Name, $_.DisplayName) -ForegroundColor Yellow }
    if ($bad.Count -gt 15) { Write-Host ("  … 共 {0} 个" -f $bad.Count) -ForegroundColor DarkGray }
    Write-Host '  启动命令示例: Start-Service -Name 服务名' -ForegroundColor DarkGray
} else {
    Write-Host '  没有异常，全部自动服务都在运行。' -ForegroundColor Green
}

# ---------- 延迟启动服务 ----------
Write-Title '自动(延迟启动) 但未运行的服务（通常正常）'
$delayed = @()
try {
    $delayed = @(Get-CimInstance Win32_Service -ErrorAction Stop |
        Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' -and $_.DelayedAutoStart })
} catch { $delayed = @() }
if ($delayed.Count -gt 0) {
    $delayed | Select-Object -First 10 | ForEach-Object { Write-Host ('  {0,-34} {1}' -f $_.Name, $_.DisplayName) -ForegroundColor DarkGray }
} else {
    Write-Host '  无（或需要 WMI 权限才能判断）。' -ForegroundColor DarkGray
}

# ---------- 启动项 ----------
Write-Title '自动启动项'
$startupRows = @()
try {
    $startupRows = @(Get-CimInstance Win32_StartupCommand -ErrorAction Stop |
        Select-Object @{n='名称';e={$_.Name}}, @{n='位置';e={$_.Location}}, @{n='命令';e={$_.Command}})
} catch { $startupRows = @() }
if ($startupRows.Count -eq 0) {
    # 注册表 Run 键回退
    $runKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($k in $runKeys) {
        if (-not (Test-Path $k)) { continue }
        $props = Get-ItemProperty $k
        $props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object {
            $startupRows += [pscustomobject]@{ 名称 = $_.Name; 位置 = ($k -replace '^.*\\', ''); 命令 = $_.Value }
        }
    }
}
if ($startupRows.Count -gt 0) {
    Write-Host ("  共 {0} 项：" -f $startupRows.Count) -ForegroundColor DarkGray
    $startupRows | ForEach-Object {
        $cmd = [string]$_.命令
        if ($cmd.Length -gt 90) { $cmd = $cmd.Substring(0, 90) + '…' }
        Write-Host ('   - [{0}] {1}' -f $_.位置, $_.名称)
        Write-Host ('       ' + $cmd) -ForegroundColor DarkGray
    }
} else {
    Write-Host '  未读取到启动项。' -ForegroundColor DarkGray
}
$startupFolder = [Environment]::GetFolderPath('Startup')
if (Test-Path $startupFolder) {
    $shortcuts = @(Get-ChildItem $startupFolder -Force | Where-Object { $_.Name -ne 'desktop.ini' })
    Write-Host ("  启动文件夹: {0} 个快捷方式" -f $shortcuts.Count) -ForegroundColor DarkGray
    $shortcuts | ForEach-Object { Write-Host ('    - ' + $_.Name) -ForegroundColor DarkGray }
}

# ---------- 监听端口 ----------
Write-Title '监听端口统计'
$listenRows = @()
try {
    $listenRows = @(Get-NetTCPConnection -State Listen -ErrorAction Stop |
        Select-Object @{n='Pid';e={$_.OwningProcess}}, @{n='Port';e={$_.LocalPort}})
} catch { $listenRows = @() }
if ($listenRows.Count -eq 0) {
    foreach ($line in (netstat -ano | Select-String 'LISTENING')) {
        $parts = @(($line.Line -split '\s+') | Where-Object { $_ })
        if ($parts.Count -ge 5) {
            $portTxt = ($parts[1] -split ':')[-1]
            $listenRows += [pscustomobject]@{ Pid = [int]$parts[-1]; Port = $portTxt }
        }
    }
}
if ($listenRows.Count -gt 0) {
    $listenRows | Group-Object Pid | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object {
        $p = Get-Process -Id ([int]$_.Name) -ErrorAction SilentlyContinue
        $name = if ($p) { $p.ProcessName } else { '?' }
        Write-Host ('  {0,-28} {1} 个端口   PID {2}' -f $name, $_.Count, $_.Name) -ForegroundColor Gray
    }
    Write-Host ("  合计监听端口: {0}" -f $listenRows.Count) -ForegroundColor DarkGray
} else {
    Write-Host '  未能读取监听端口（需要 WMI 权限，或 netstat 被限制）。' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host ' 定位卡顿建议：看上面的内存/CPU Top -> 查该进程用途 -> 必要时 Stop-Process -Id PID -Force' -ForegroundColor Green
Write-Host ''
