<#
.SYNOPSIS
    服务查询与服务启停管理
.DESCRIPTION
    不带 -Action 时按名称/显示名/状态/启动类型筛选并列出服务，便于排查异常服务；
    带 -Action 时对指定服务执行启动、停止、重启、禁用、启用、改为自动。
    危险操作（停止/重启/禁用）默认先交互确认，图形界面可传 -Yes 跳过。
    优先使用 Get-Service / Start-Service 等原生 cmdlet，WMI 仅作可选增强，失败则静默降级。
.PARAMETER Filter
    名称或显示名包含该字符串时列出（不区分大小写）。
.PARAMETER State
    按状态筛选：All / Running / Stopped，默认 All。
.PARAMETER StartType
    按启动类型筛选：All / Automatic / Manual / Disabled，默认 All。
.PARAMETER Action
    要执行的操作：none / start / stop / restart / disable / enable / auto，默认 none（只查询）。
.PARAMETER Name
    要操作的服务名（-Action 非 none 时必填）。
.PARAMETER Top
    列表最多显示多少行，默认 30。
.PARAMETER Yes
    跳过危险操作的交互确认（图形界面会传这个）。
.EXAMPLE
    .\11-服务管理.ps1
.EXAMPLE
    .\11-服务管理.ps1 -Filter print -State Running
.EXAMPLE
    .\11-服务管理.ps1 -Action restart -Name Spooler -Yes
#>
[CmdletBinding()]
param(
    [string]$Filter,
    [ValidateSet('All','Running','Stopped')][string]$State = 'All',
    [ValidateSet('All','Automatic','Manual','Disabled')][string]$StartType = 'All',
    [ValidateSet('none','start','stop','restart','disable','enable','auto')][string]$Action = 'none',
    [string]$Name,
    [int]$Top = 30,
    [switch]$Yes
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# 关键服务黑名单：禁用/停止这些服务会直接影响系统，必须明确警告
$script:Critical = @{
    'RpcSs'      = '远程过程调用，系统核心，停止会导致大量程序崩溃'
    'RpcEptMapper' = 'RPC 端点映射，系统核心'
    'DcomLaunch' = 'DCOM 服务控制启动，系统核心'
    'Winmgmt'    = 'WMI 服务，本工具包很多功能依赖它，禁用后 Get-CimInstance 全部失效'
    'Dhcp'       = 'DHCP 客户端，禁用后拿不到自动 IP，会直接断网'
    'Dnscache'   = 'DNS 客户端，禁用后域名解析失败（只能上 IP 不能上网站）'
    'nsi'        = '网络存储接口，系统网络栈核心'
    'LanmanWorkstation' = '工作站服务，访问共享文件夹依赖它'
    'Themes'     = '主题服务，停止后界面会退化成经典样式'
    'AudioSrv'   = '音频服务，停止后没有声音'
    'AudioEndpointBuilder' = '音频端点，停止后没有声音'
    'BFE'        = '基础筛选引擎，防火墙依赖它'
    'MpsSvc'     = 'Windows 防火墙'
    'EventLog'   = '事件日志，停止后很多服务无法记录与启动'
    'Schedule'   = '任务计划程序'
    'CryptSvc'   = '加密服务，系统更新与证书依赖它'
    'TrustedInstaller' = 'Windows 模块安装程序，影响系统更新与组件修复'
    'WlanSvc'    = '无线网络，停止后 Wi-Fi 断开'
    'W32Time'    = '时间同步，时间错误会导致 HTTPS 证书校验失败'
}

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host ">> $Text" -ForegroundColor Cyan
}
function Write-Ok([string]$Text)   { Write-Host "   [OK]   $Text" -ForegroundColor Green }
function Write-Bad([string]$Text)  { Write-Host "   [FAIL] $Text" -ForegroundColor Red }
function Write-Warn([string]$Text) { Write-Host "   [!]    $Text" -ForegroundColor Yellow }
function Write-Info([string]$Text) { Write-Host "   [--]   $Text" -ForegroundColor DarkGray }
function Write-Title([string]$Text) {
    Write-Host ''
    Write-Host "== $Text " -ForegroundColor Cyan -NoNewline
    Write-Host ('=' * [Math]::Max(4, 58 - $Text.Length)) -ForegroundColor DarkCyan
}

# 判断当前是否管理员（cmdlet 不可用时直接当没有权限处理）
function Test-Admin {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

# 友好的失败提示：不把堆栈糊到屏幕上
function Show-ServiceFailure([string]$What, [System.Exception]$Ex) {
    $msg = ''
    if ($Ex) { $msg = [string]$Ex.Message }
    if ($Ex -and $Ex.InnerException) { $msg = $msg + ' / ' + [string]$Ex.InnerException.Message }
    Write-Bad ("{0} 失败：{1}" -f $What, $msg)
    if ($msg -match '(?i)denied|拒绝访问|0x5|权限') {
        Write-Warn "该操作需要以管理员身份运行（右键 PowerShell -> 以管理员身份运行，再执行本脚本）。"
    } elseif ($msg -match '(?i)cannot|无法|not find|不存在|依赖|dependent') {
        Write-Warn '服务被禁用、不存在，或依赖的服务没起来；可用 sc.exe qc <服务名> 查看依赖。'
    } else {
        Write-Warn "可尝试：sc.exe queryex <服务名> 查看状态，事件查看器 -> Windows 日志 -> 系统 查看原因。"
    }
}

function Get-StartTypeText($Service) {
    $t = [string]$Service.StartType
    if ([string]::IsNullOrWhiteSpace($t)) { return '?' }
    switch ($t) {
        'Automatic' { return '自动' }
        'Manual'    { return '手动' }
        'Disabled'  { return '禁用' }
        default     { return $t }
    }
}
function Get-StatusText($Service) {
    $s = [string]$Service.Status
    switch ($s) {
        'Running'      { return '正在运行' }
        'Stopped'      { return '已停止' }
        'StartPending' { return '正在启动' }
        'StopPending'  { return '正在停止' }
        'Paused'       { return '已暂停' }
        default        { return $s }
    }
}
function Get-StatusColor($Service) {
    switch ([string]$Service.Status) {
        'Running' { return 'Green' }
        'Stopped' { return 'DarkGray' }
        default   { return 'Yellow' }
    }
}

Write-Host ''
Write-Host ' 服务查询与启停管理' -ForegroundColor White -BackgroundColor DarkBlue
Write-Host (" 时间: {0}    操作: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Action) -ForegroundColor DarkGray

$isAdmin = Test-Admin

# ============================================================
# 模式一：只查询
# ============================================================
if ($Action -eq 'none') {

    Write-Step '1/4 读取服务清单'
    $all = @(Get-Service -ErrorAction SilentlyContinue)
    if ($all.Count -eq 0) {
        Write-Bad '读取不到任何服务（服务控制管理器可能被限制）。'
        Write-Host ''
        exit 1
    }
    Write-Ok ("本机共 {0} 个服务。" -f $all.Count)
    if (-not $isAdmin) { Write-Info '当前不是管理员：只读查询不受影响，启停/禁用操作需要管理员。' }

    # 启动类型过滤：部分环境下 StartType 读不到，则静默降级为“不过滤”
    $matched = $all
    if (-not [string]::IsNullOrWhiteSpace($Filter)) {
        $matched = @($matched | Where-Object { $_.Name -like ('*' + $Filter + '*') -or $_.DisplayName -like ('*' + $Filter + '*') })
    }
    if ($State -ne 'All') {
        $matched = @($matched | Where-Object { [string]$_.Status -eq $State })
    }
    $startTypeSkipped = 0
    if ($StartType -ne 'All') {
        $probe = @($matched | Where-Object { $null -ne $_.StartType -and [string]$_.StartType -ne '' })
        if ($probe.Count -eq 0 -and $matched.Count -gt 0) {
            Write-Warn '当前环境读不到服务的启动类型，已忽略 -StartType 筛选（其余结果仍然有效）。'
            $startTypeSkipped = 1
        } else {
            $matched = @($probe | Where-Object { [string]$_.StartType -eq $StartType })
        }
    }

    # ---------- 列表 ----------
    Write-Step '2/4 符合条件的服务'
    Write-Info ("筛选条件 -> 名称/显示名: {0}    状态: {1}    启动类型: {2}" -f `
        $(if ([string]::IsNullOrWhiteSpace($Filter)) { '(不限)' } else { $Filter }), $State, $StartType)
    if ($startTypeSkipped -eq 1) { Write-Info '（本次未按启动类型筛选）' }

    if ($matched.Count -eq 0) {
        Write-Warn '没有符合条件的服务。'
        Write-Info '试试放宽条件：-Filter 去掉，或 -State All -StartType All。'
    } else {
        $showCount = $Top
        if ($showCount -lt 1) { $showCount = 1 }
        $shown = @($matched | Sort-Object Name | Select-Object -First $showCount)
        Write-Host ('  {0,-34} {1,-26} {2,-10} {3}' -f '服务名', '显示名', '状态', '启动类型') -ForegroundColor DarkCyan
        Write-Host ('  ' + ('-' * 88)) -ForegroundColor DarkGray
        foreach ($s in $shown) {
            $dn = [string]$s.DisplayName
            if ($dn.Length -gt 24) { $dn = $dn.Substring(0, 24) + '…' }
            Write-Host ('  {0,-34} {1,-26} {2,-10} {3}' -f $s.Name, $dn, (Get-StatusText $s), (Get-StartTypeText $s)) -ForegroundColor (Get-StatusColor $s)
        }
        if ($matched.Count -gt $shown.Count) {
            Write-Warn ("还有 {0} 条未显示（共 {1} 条，已显示 {2} 条）。可用 -Top {1} 全部显示，或用 -Filter 缩小范围。" -f ($matched.Count - $shown.Count), $matched.Count, $shown.Count)
        } else {
            Write-Ok ("已全部显示，共 {0} 条。" -f $shown.Count)
        }
    }

    # ---------- 统计 ----------
    Write-Step '3/4 状态统计（按当前筛选条件）'
    $pool = $all
    if (-not [string]::IsNullOrWhiteSpace($Filter)) {
        $pool = @($pool | Where-Object { $_.Name -like ('*' + $Filter + '*') -or $_.DisplayName -like ('*' + $Filter + '*') })
    }
    $running = @($pool | Where-Object { [string]$_.Status -eq 'Running' }).Count
    $stopped = @($pool | Where-Object { [string]$_.Status -eq 'Stopped' }).Count
    $other   = $pool.Count - $running - $stopped
    $autoStopped = @($pool | Where-Object { [string]$_.StartType -eq 'Automatic' -and [string]$_.Status -ne 'Running' })
    Write-Host ("  正在运行 {0} 个    已停止 {1} 个    其它状态 {2} 个" -f $running, $stopped, $other) -ForegroundColor Gray
    if ($autoStopped.Count -gt 0) {
        Write-Warn ("其中 {0} 个是「自动」启动却没在运行（可能异常）：" -f $autoStopped.Count)
        $autoStopped | Select-Object -First 10 | ForEach-Object { Write-Host ('    [!] {0,-32} {1}' -f $_.Name, $_.DisplayName) -ForegroundColor Yellow }
        if ($autoStopped.Count -gt 10) { Write-Info ("… 共 {0} 个" -f $autoStopped.Count) }
    } else {
        Write-Ok '没有发现「自动启动但未运行」的异常服务。'
    }

    # ---------- 常见坑 ----------
    Write-Step '4/4 常见坑提示'
    if ($isAdmin) {
        Write-Info '当前是管理员权限，可以执行 -Action start/stop/restart/disable/enable/auto。'
    } else {
        Write-Warn '当前不是管理员：-Action 里的启停/禁用会失败，请用管理员身份重开 PowerShell。'
    }
    Write-Host '   禁用服务前先确认它的用途，以下服务禁用后系统会明显异常：' -ForegroundColor Yellow
    foreach ($k in @('Winmgmt','RpcSs','Dhcp','Dnscache','MpsSvc','AudioSrv','Themes','LanmanWorkstation')) {
        $desc = ''
        if ($script:Critical.ContainsKey($k)) { $desc = $script:Critical[$k] }
        Write-Host ('    - {0,-20} {1}' -f $k, $desc) -ForegroundColor DarkGray
    }
    Write-Host '   停止 vs 禁用：Stop-Service 只是本次停掉（重启后还会按启动类型起来）；' -ForegroundColor Gray
    Write-Host '   Set-Service -StartupType Disabled 是永久禁用，重启也不会起来，改回来要用 -Action enable。' -ForegroundColor Gray
    Write-Host '   相关原生命令：sc.exe query <服务名> / sc.exe qc <服务名> / services.msc' -ForegroundColor DarkGray

    Write-Title '结论'
    if ($matched.Count -eq 0) {
        Write-Host ("  筛选出 0 个服务（全机共 {0} 个）；换个 -Filter 或放宽 -State/-StartType 再看。" -f $all.Count) -ForegroundColor Yellow
    } else {
        Write-Host ("  筛选出 {0} 个服务（已显示 {1} 个）：运行 {2} 个、停止 {3} 个。" -f $matched.Count, [Math]::Min($Top, $matched.Count), $running, $stopped) -ForegroundColor Green
        if ($autoStopped.Count -gt 0) { Write-Host ("  注意 {0} 个自动服务未运行，可用 -Action start -Name <服务名> 尝试启动。" -f $autoStopped.Count) -ForegroundColor Yellow }
    }
    Write-Host ''
    exit 0
}

# ============================================================
# 模式二：执行操作
# ============================================================

$actionText = @{
    'start'   = '启动'
    'stop'    = '停止'
    'restart' = '重启'
    'disable' = '禁用（永久，重启也不会自启）'
    'enable'  = '设为手动启动'
    'auto'    = '设为自动启动'
}
$dangerous = @('stop','restart','disable')

Write-Step ("1/6 检查操作参数（{0}）" -f $actionText[$Action])
if ([string]::IsNullOrWhiteSpace($Name)) {
    Write-Bad ("-Action {0} 必须同时指定 -Name <服务名>。" -f $Action)
    Write-Info '服务名不是显示名，示例: Spooler（打印后台）、W32Time（时间同步）、wuauserv（Windows 更新）。'
    Write-Warn '不确定服务名？先不加 -Action 用 -Filter 查：.\11-服务管理.ps1 -Filter print'
    Write-Host ''
    exit 1
}
Write-Ok ("目标服务: {0}    操作: {1}" -f $Name, $actionText[$Action])
if (-not $isAdmin) {
    Write-Warn '当前不是管理员：下面这一步大概率会失败，建议先以管理员身份重开 PowerShell。'
}

# ---------- 定位服务，匹配多个则列出候选不擅自操作 ----------
Write-Step '2/6 定位目标服务'
$target = $null
$candidates = @()
$exact = @(Get-Service -Name $Name -ErrorAction SilentlyContinue)
if ($exact.Count -eq 1) {
    $target = $exact[0]
} elseif ($exact.Count -gt 1) {
    $candidates = $exact
} else {
    # 名字对不上，按名称/显示名模糊找候选（只提示，不擅自操作）
    $candidates = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ('*' + $Name + '*') -or $_.DisplayName -like ('*' + $Name + '*') })
    if ($candidates.Count -eq 1) {
        $target = $candidates[0]
        Write-Info ("未找到精确匹配，按唯一模糊匹配继续：{0}" -f $target.Name)
    }
}

if (-not $target -and $candidates.Count -eq 0) {
    Write-Bad ("找不到服务 '{0}'（名称和显示名都没匹配上）。" -f $Name)
    Write-Info '查服务名的方法：.\11-服务管理.ps1 -Filter 关键词   或   sc.exe query type= service state= all'
    Write-Host ''
    exit 1
}
if (-not $target -and $candidates.Count -gt 1) {
    Write-Warn ("'{0}' 匹配到 {1} 个服务，为避免误操作，请用精确的服务名（-Name）重试：" -f $Name, $candidates.Count)
    $candidates | Select-Object -First 20 | ForEach-Object {
        Write-Host ('    {0,-32} {1,-10} {2}' -f $_.Name, (Get-StatusText $_), $_.DisplayName) -ForegroundColor Gray
    }
    if ($candidates.Count -gt 20) { Write-Info ("… 共 {0} 个候选" -f $candidates.Count) }
    Write-Host ''
    exit 1
}

$name = $target.Name
Write-Ok ("已定位服务: {0}（{1}）" -f $name, $target.DisplayName)

# ---------- 当前状态 ----------
Write-Step '3/6 操作前的当前状态'
$svc = Get-Service -Name $name -ErrorAction SilentlyContinue
if (-not $svc) { $svc = $target }
Write-Host ("   服务名    : {0}" -f $svc.Name) -ForegroundColor Gray
Write-Host ("   显示名    : {0}" -f $svc.DisplayName) -ForegroundColor Gray
Write-Host ("   当前状态  : {0}" -f (Get-StatusText $svc)) -ForegroundColor (Get-StatusColor $svc)
Write-Host ("   启动类型  : {0}" -f (Get-StartTypeText $svc)) -ForegroundColor Gray

# 关键服务风险提示
$riskHit = @()
if ($script:Critical.ContainsKey($name)) { $riskHit += $name }
foreach ($k in $script:Critical.Keys) { if ($name -like ('*' + $k + '*') -and $riskHit -notcontains $k) { $riskHit += $k } }
if ($riskHit.Count -gt 0) {
    Write-Host ''
    foreach ($k in $riskHit) { Write-Warn ("关键服务警告：{0} —— {1}" -f $k, $script:Critical[$k]) }
    Write-Warn '除非你非常确定，否则不要停止/禁用上面这些服务。'
}

# 幂等提示
if ($Action -eq 'start' -and [string]$svc.Status -eq 'Running') { Write-Info '该服务已经在运行，启动操作通常会直接成功且无变化。' }
if ($Action -eq 'stop' -and [string]$svc.Status -eq 'Stopped')   { Write-Info '该服务已经停止，停止操作通常不会报错。' }

# ---------- 确认 ----------
Write-Step '4/6 操作确认'
if ($dangerous -contains $Action) {
    Write-Host '   这是会影响系统的操作，可能造成：' -ForegroundColor Yellow
    switch ($Action) {
        'stop'    { Write-Host '    - 依赖该服务的功能立即不可用（打印、声音、网络共享等）' -ForegroundColor Yellow }
        'restart' { Write-Host '    - 该服务短暂中断，正在使用它的程序可能报错' -ForegroundColor Yellow }
        'disable' { Write-Host '    - 永久禁用，重启后也不会自动启动，直到手动改回（-Action enable/auto）' -ForegroundColor Yellow }
    }
    if ($Yes) {
        Write-Warn '已指定 -Yes，跳过交互确认，直接执行。'
    } else {
        Write-Host ("   确认要对 [{0}] 执行 [{1}] 吗？(Y/N) " -f $name, $actionText[$Action]) -ForegroundColor Cyan -NoNewline
        $answer = ''
        try { $answer = [string](Read-Host) } catch { $answer = '' }
        if ($answer -notmatch '^(?i)y') {
            Write-Info '已取消，没有做任何修改。'
            Write-Host ''
            exit 0
        }
    }
} else {
    Write-Info '该操作风险较低，直接执行。'
}

# ---------- 执行 ----------
Write-Step ("5/6 执行操作：{0}" -f $actionText[$Action])
$ok = $false
$err = $null
try {
    switch ($Action) {
        'start' {
            Start-Service -Name $name -ErrorAction Stop
            $ok = $true
        }
        'stop' {
            Stop-Service -Name $name -Force -ErrorAction Stop
            $ok = $true
        }
        'restart' {
            Restart-Service -Name $name -Force -ErrorAction Stop
            $ok = $true
        }
        'disable' {
            Set-Service -Name $name -StartupType Disabled -ErrorAction Stop
            $ok = $true
        }
        'enable' {
            Set-Service -Name $name -StartupType Manual -ErrorAction Stop
            $ok = $true
        }
        'auto' {
            Set-Service -Name $name -StartupType Automatic -ErrorAction Stop
            $ok = $true
        }
    }
} catch {
    $err = $_.Exception
    $ok = $false
}

if (-not $ok) {
    Show-ServiceFailure ("对服务 [{0}] 执行 [{1}]" -f $name, $actionText[$Action]) $err
    Write-Host ''
    Write-Info '排查顺序：1) 是否管理员 2) 服务名是否准确 3) 依赖服务是否已启动 4) 服务是否被组策略/安全软件锁定。'
    Write-Title '结论'
    Write-Host ("  服务 [{0}] 的 [{1}] 操作未成功，未对系统做出修改。" -f $name, $actionText[$Action]) -ForegroundColor Red
    if (-not $isAdmin) { Write-Host '  最可能的原因：需要以管理员身份运行。' -ForegroundColor Yellow }
    Write-Host ''
    exit 1
}

# ---------- 复核 ----------
Write-Step '6/6 操作后状态复核'
Start-Sleep -Milliseconds 600
$after = Get-Service -Name $name -ErrorAction SilentlyContinue
if ($after) {
    Write-Ok ("{0}    状态: {1}    启动类型: {2}" -f $after.Name, (Get-StatusText $after), (Get-StartTypeText $after))
} else {
    Write-Info '操作已提交，但复核时读不到该服务状态。'
}

Write-Title '结论'
Write-Host ("  服务 [{0}] 的 [{1}] 操作已完成。" -f $name, $actionText[$Action]) -ForegroundColor Green
if ($Action -eq 'start')   { Write-Host '  验证建议：Get-Service -Name 服务名 | Format-List Name,Status,StartType' -ForegroundColor Gray }
if ($Action -eq 'stop')    { Write-Host '  重启后该服务仍会按启动类型自动起来；要永久关闭请用 -Action disable（需谨慎）。' -ForegroundColor Gray }
if ($Action -eq 'disable') { Write-Host '  改回来：.\11-服务管理.ps1 -Action enable -Name 服务名（手动）或 -Action auto（自动）。' -ForegroundColor Gray }
Write-Host ''
exit 0
