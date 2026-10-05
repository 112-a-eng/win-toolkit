<#
.SYNOPSIS
    Windows 系统信息速查（一屏看清机器状况）
.DESCRIPTION
    显示操作系统、CPU、内存、磁盘、显卡、网卡、开机时长与最近补丁。
    优先使用 WMI/CIM；若当前环境禁止 WMI（受限账户、企业策略、沙箱），
    会自动回退到注册表 / 性能计数器 / 原生命令，并在开头给出提示。
.EXAMPLE
    .\01-系统信息.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# ---------------- 能力探测与工具函数 ----------------
$script:CimOk = $false
$script:OsInfo = $null
try {
    $script:OsInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    if ($script:OsInfo) { $script:CimOk = $true }
} catch {
    $script:CimOk = $false
}

function Get-CounterValue([string]$CounterPath) {
    try { return (Get-Counter -Counter $CounterPath -ErrorAction Stop).CounterSamples[0].CookedValue }
    catch { return $null }
}
function Write-Title([string]$Text) {
    $line = '=' * [Math]::Max(4, 58 - $Text.Length)
    Write-Host ''
    Write-Host "== $Text " -ForegroundColor Cyan -NoNewline
    Write-Host $line -ForegroundColor DarkCyan
}
function Write-Row([string]$Name, $Value) {
    Write-Host ('  {0,-12}: ' -f $Name) -ForegroundColor DarkGray -NoNewline
    Write-Host $Value
}

Write-Host ''
Write-Host ' Windows 系统信息速查' -ForegroundColor White -BackgroundColor DarkBlue
Write-Host (" 采集时间: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ForegroundColor DarkGray
if (-not $script:CimOk) {
    Write-Host ' 注意: 当前环境禁止 WMI/CIM 查询，已改用 注册表/性能计数器/原生命令 回退，信息略简。' -ForegroundColor Yellow
}

# ---------------- 操作系统 ----------------
Write-Title '操作系统'
Write-Row '计算机名' $env:COMPUTERNAME
Write-Row '当前用户' ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)

$installDate = $null
$buildNo = ''
$arch = ''
if ($script:CimOk) {
    $sysName = $script:OsInfo.Caption
    $buildNo = $script:OsInfo.BuildNumber
    $arch    = $script:OsInfo.OSArchitecture
    if ($script:OsInfo.InstallDate) { $installDate = $script:OsInfo.InstallDate }
} else {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $buildNo = $cv.CurrentBuild
    if ($cv.UBR) { $buildNo = "$($cv.CurrentBuild).$($cv.UBR)" }
    $sysName = $cv.ProductName
    # 注册表里 Win11 仍写作 Windows 10，按内核版本号纠正
    if ([int]$cv.CurrentBuild -ge 22000 -and $sysName -like 'Windows 10*') {
        $sysName = $sysName -replace '^Windows 10', 'Windows 11'
    }
    if ($cv.DisplayVersion) { $sysName = "$sysName $($cv.DisplayVersion)" }
    if ($cv.InstallDate) {
        try { $installDate = [datetime]::FromFileTime([int64]$cv.InstallDate * 10000000 + 116444736000000000) } catch { }
    }
    if ([Environment]::Is64BitOperatingSystem) { $arch = '64 位' } else { $arch = '32 位' }
}
Write-Row '系统版本' ("{0} (Build {1})" -f $sysName, $buildNo)
Write-Row '架构' $arch
Write-Row '安装时间' $(if ($installDate) { $installDate.ToString('yyyy-MM-dd') } else { '未知' })

if ($script:CimOk -and $script:OsInfo.LastBootUpTime) {
    $boot = $script:OsInfo.LastBootUpTime
    $up = (Get-Date) - $boot
    Write-Row '开机时长' ("{0} 天 {1} 小时 {2} 分（{3}）" -f $up.Days, $up.Hours, $up.Minutes, $boot.ToString('yyyy-MM-dd HH:mm'))
} else {
    $upSec = Get-CounterValue '\System\System Up Time'
    if ($upSec) {
        $up = [TimeSpan]::FromSeconds($upSec)
        Write-Row '开机时长' ("{0} 天 {1} 小时 {2} 分（本次开机 {3}）" -f $up.Days, $up.Hours, $up.Minutes,
            (Get-Date).AddSeconds(-$upSec).ToString('yyyy-MM-dd HH:mm'))
    }
}

# ---------------- CPU ----------------
Write-Title '处理器'
if ($script:CimOk) {
    foreach ($cpu in Get-CimInstance Win32_Processor) {
        Write-Row '型号' $cpu.Name.Trim()
        Write-Row '核心/线程' ("{0} 核 / {1} 线程 @ {2} MHz" -f $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors, $cpu.MaxClockSpeed)
        if ($null -ne $cpu.LoadPercentage) { Write-Row '当前负载' ("{0}%" -f $cpu.LoadPercentage) }
    }
} else {
    Write-Row '型号' $env:PROCESSOR_IDENTIFIER
    Write-Row '逻辑处理器' ("{0} 个（环境变量读取）" -f $env:NUMBER_OF_PROCESSORS)
    $load = Get-CounterValue '\Processor(_Total)\% Processor Time'
    if ($load) { Write-Row '当前负载' ("{0}%" -f [Math]::Round($load, 1)) }
}

# ---------------- 内存 ----------------
Write-Title '内存'
if ($script:CimOk) {
    $totalGB = [Math]::Round($script:OsInfo.TotalVisibleMemorySize / 1MB, 2)
    $freeGB  = [Math]::Round($script:OsInfo.FreePhysicalMemory / 1MB, 2)
    $usedPct = if ($totalGB -gt 0) { [Math]::Round((1 - $freeGB / $totalGB) * 100, 1) } else { 0 }
    Write-Row '总量' ("{0} GB" -f $totalGB)
    Write-Row '可用' ("{0} GB（已用 {1}%）" -f $freeGB, $usedPct)
    $barLen = 30
    $fill = [int]($usedPct / 100 * $barLen)
    $bar = ('#' * [Math]::Min($fill, $barLen)).PadRight($barLen, '.')
    Write-Host ('  {0,-12}  [{1}]' -f '使用率', $bar) -ForegroundColor Yellow
    foreach ($m in Get-CimInstance Win32_PhysicalMemory) {
        Write-Row '内存条' ("{0} GB {1} MHz {2}" -f [Math]::Round($m.Capacity / 1GB, 0), $m.Speed, $m.Manufacturer)
    }
} else {
    $availMB     = Get-CounterValue '\Memory\Available MBytes'
    $committedGB = Get-CounterValue '\Memory\Committed Bytes'
    if ($availMB)     { Write-Row '可用物理内存' ("{0} GB" -f [Math]::Round($availMB / 1024, 2)) }
    if ($committedGB) { Write-Row '已提交内存' ("{0} GB（含页面文件）" -f [Math]::Round($committedGB / 1GB, 2)) }
    Write-Row '说明' '物理总量与内存条信息需要 WMI 权限；也可用 systeminfo / 任务管理器 查看。'
}

# ---------------- 磁盘 ----------------
Write-Title '磁盘'
$printedDisk = $false
if ($script:CimOk) {
    foreach ($d in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3') {
        $size = [Math]::Round($d.Size / 1GB, 1)
        $free = [Math]::Round($d.FreeSpace / 1GB, 1)
        $pct  = if ($d.Size -gt 0) { [Math]::Round((1 - $d.FreeSpace / $d.Size) * 100, 1) } else { 0 }
        $warn = if ($pct -ge 90) { '  <== 空间紧张' } else { '' }
        Write-Row $d.DeviceID ("{0} GB 总 / {1} GB 可用（已用 {2}%）{3}" -f $size, $free, $pct, $warn)
        $printedDisk = $true
    }
    Get-PhysicalDisk | ForEach-Object {
        Write-Row '物理磁盘' ("{0} | {1} | {2} | {3} GB | {4}" -f $_.FriendlyName, $_.MediaType, $_.HealthStatus,
            [Math]::Round($_.Size / 1GB, 0), $_.BusType)
    }
}
if (-not $printedDisk) {
    foreach ($drv in [System.IO.DriveInfo]::GetDrives()) {
        try {
            if (-not $drv.IsReady) { continue }
            $size = [Math]::Round($drv.TotalSize / 1GB, 1)
            $free = [Math]::Round($drv.AvailableFreeSpace / 1GB, 1)
            $pct  = if ($drv.TotalSize -gt 0) { [Math]::Round((1 - $drv.AvailableFreeSpace / $drv.TotalSize) * 100, 1) } else { 0 }
            $warn = if ($pct -ge 90) { '  <== 空间紧张' } else { '' }
            $printedDisk = $true
            Write-Row $drv.Name ("{0} GB 总 / {1} GB 可用（已用 {2}%）{3}" -f $size, $free, $pct, $warn)
        } catch { }
    }
}
if (-not $printedDisk) { Write-Row '磁盘' '无法读取（需要 WMI 或更高权限）' }

# ---------------- 显卡 ----------------
Write-Title '显卡与显示'
$gpus = @()
if ($script:CimOk) {
    foreach ($v in Get-CimInstance Win32_VideoController) {
        $line = "{0}" -f $v.Name
        if ($v.DriverVersion) { $line += " | 驱动 $($v.DriverVersion)" }
        if ($v.CurrentHorizontalResolution) { $line += " | $($v.CurrentHorizontalResolution)x$($v.CurrentVerticalResolution)" }
        $gpus += $line
    }
}
if (-not $gpus) {
    # 注册表回退：显示适配器类 GUID
    $classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    Get-ChildItem $classKey | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath
        if ($props.DriverDesc) {
            $gpus += ("{0}{1}" -f $props.DriverDesc, $(if ($props.DriverVersion) { " | 驱动 $($props.DriverVersion)" } else { '' }))
        }
    }
}
if ($gpus) { $gpus | ForEach-Object { Write-Row '显卡' $_ } } else { Write-Row '显卡' '未读取到' }

# ---------------- 网络 ----------------
Write-Title '网络'
$shownNet = $false
if ($script:CimOk) {
    foreach ($ip in Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne '127.0.0.1' }) {
        Write-Row $ip.InterfaceAlias ("{0}/{1}" -f $ip.IPAddress, $ip.PrefixLength)
        $shownNet = $true
    }
    $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric).NextHop | Select-Object -First 1
    if ($gw) { Write-Row '默认网关' $gw; $shownNet = $true }
}
if (-not $shownNet) {
    $ipOut = (ipconfig) -join "`n"
    foreach ($m in [regex]::Matches($ipOut, '(?m)^\s*IPv4[^:]*:\s*([\d\.]+)')) {
        Write-Row 'IPv4' $m.Groups[1].Value
        $shownNet = $true
    }
    $allOut = (ipconfig /all) -join "`n"
    $gw2 = [regex]::Match($allOut, '(?m)^\s*(?:Default Gateway|默认网关)[^:]*:\s*([\d\.]+)')
    if ($gw2.Success) { Write-Row '默认网关' $gw2.Groups[1].Value }
    $dns = [regex]::Matches($allOut, '(?m)^\s*(?:DNS Servers|DNS 服务器)[^:]*:\s*([\d\.]+)') |
        ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
    if ($dns) { Write-Row 'DNS' ($dns -join ', ') }
}
if (-not $shownNet) { Write-Row '网络' '未读取到 IPv4 信息（网卡可能未连接）' }

# ---------------- 补丁 ----------------
Write-Title '最近安装的更新'
$hotfix = @()
try { $hotfix = @(Get-HotFix -ErrorAction Stop | Sort-Object InstalledOn -Descending | Select-Object -First 8) } catch { }
if ($hotfix.Count -gt 0) {
    foreach ($h in $hotfix) {
        $when = if ($h.InstalledOn) { $h.InstalledOn.ToString('yyyy-MM-dd') } else { '未知' }
        Write-Row $when $h.HotFixID
    }
} else {
    Write-Row '提示' '未读取到补丁信息（需要管理员权限）；也可用 Get-HotFix 或“设置 - 更新历史”查看。'
}

Write-Host ''
Write-Host ' 完成。更详细：msinfo32 / dxdiag；补丁查询：Get-HotFix' -ForegroundColor Green
Write-Host ''
