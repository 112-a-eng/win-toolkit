<#
.SYNOPSIS
    局域网存活主机扫描（Runspace 并发 ping + ARP 表）
.DESCRIPTION
    自动推断本机所在网段，用 runspace 池并发调用 ping.exe 扫描整个网段，
    汇总在线主机（IP / 响应时间 / 可选主机名），并追加解析 arp -a 表补上 MAC。
    只做 ICMP 存活探测，不扫端口。全部为只读操作，不对目标做任何修改。
    优先使用 ping.exe / arp / ipconfig 等原生工具，WMI 仅作可选增强，失败则静默降级。
.PARAMETER Subnet
    要扫描的网段，例如 192.168.1.0/24、192.168.1.（等价 /24）、192.168.1.0/28。
    留空则自动取本机 IPv4 所在的 /24。
.PARAMETER TimeoutMs
    每个地址的 ping 超时（毫秒），默认 500。
.PARAMETER Throttle
    并发数，默认 64（网络较慢或受限环境可调小，例如 16）。
.PARAMETER ResolveNames
    对在线主机做反向 DNS 解析（PTR 查询）以获取主机名，默认不做。
.PARAMETER Export
    把结果导出为 CSV 文件（UTF-8，NoTypeInformation）。
.EXAMPLE
    .\10-局域网扫描.ps1
.EXAMPLE
    .\10-局域网扫描.ps1 -Subnet 192.168.1.0/24 -Throttle 32 -ResolveNames
.EXAMPLE
    .\10-局域网扫描.ps1 -Subnet 192.168.1. -Export D:\lan.csv
#>
[CmdletBinding()]
param(
    [string]$Subnet,
    [int]$TimeoutMs = 500,
    [int]$Throttle  = 64,
    [switch]$ResolveNames,
    [string]$Export
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

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

# IPv4 文本 -> 32 位整数
function Convert-IpToInt64([string]$Ip) {
    $p = @($Ip.Split('.'))
    if ($p.Count -ne 4) { return $null }
    $n = 0
    foreach ($x in $p) {
        $v = 0
        if (-not [int]::TryParse($x, [ref]$v)) { return $null }
        if ($v -lt 0 -or $v -gt 255) { return $null }
        $n = ($n * 256) + $v
    }
    return $n
}

# 32 位整数 -> IPv4 文本
function Convert-Int64ToIp([long]$N) {
    return ('{0}.{1}.{2}.{3}' -f [int](($N -shr 24) -band 255), [int](($N -shr 16) -band 255), [int](($N -shr 8) -band 255), [int]($N -band 255))
}

# 从 ipconfig 文本里取 IPv4 / 掩码（回退路径，不依赖任何 WMI/CIM）
function Get-IpConfigInfo {
    $plain = (ipconfig) -join "`n"
    $ips    = @([regex]::Matches($plain, '(?m)^\s*IPv4[^:]*:\s*([\d\.]+)')                  | ForEach-Object { $_.Groups[1].Value })
    $masks  = @([regex]::Matches($plain, '(?m)^\s*(?:Subnet Mask|子网掩码)[^:]*:\s*([\d\.]+)') | ForEach-Object { $_.Groups[1].Value })
    $gw     = @([regex]::Matches($plain, '(?m)^\s*(?:Default Gateway|默认网关)[^:]*:\s*([\d\.]+)') | ForEach-Object { $_.Groups[1].Value })
    $list   = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $ips.Count; $i++) {
        $m = ''
        if ($i -lt $masks.Count) { $m = $masks[$i] }
        $list.Add([pscustomobject]@{ Ip = $ips[$i]; Mask = $m }) | Out-Null
    }
    [pscustomobject]@{ Items = $list; Gateways = $gw }
}

# 从 arp -a 输出解析 IP -> MAC 映射（在线与否之外的另一份参考）
function Get-ArpTable {
    $map = @{}
    $script:ArpTotal   = @{}
    $script:ArpDynamic = New-Object System.Collections.Generic.List[string]
    $text = (& arp.exe -a 2>&1 | Out-String)
    foreach ($line in ($text -split "`r?`n")) {
        $m = [regex]::Match($line, '^\s*(\d{1,3}(?:\.\d{1,3}){3})\s+([0-9a-fA-F]{2}(?:[-:][0-9a-fA-F]{2}){5})\s+(\S+)')
        if ($m.Success) {
            $key = $m.Groups[1].Value
            $mac = ($m.Groups[2].Value -replace ':', '-').ToUpper()
            $kind = $m.Groups[3].Value
            if (-not $script:ArpTotal.ContainsKey($key)) { $script:ArpTotal[$key] = $mac }
            if ($kind -match '(?i)dynamic|动态') { $script:ArpDynamic.Add($key) | Out-Null }
            if ($map.ContainsKey($key)) { continue }
            # 只要单播地址：排除广播 / 组播 / 保留段（组播 MAC 以 01-00-5E 开头）
            $o = @($key -split '\.')
            if ($o.Count -ne 4) { continue }
            if ($o[0] -eq '255' -or $o[3] -eq '255') { continue }
            try { $firstOctet = [int]$o[0] } catch { continue }
            if ($firstOctet -ge 224 -or $firstOctet -eq 0) { continue }
            $map[$key] = $mac
        }
    }
    return $map
}

# ---------------- 头部 ----------------
Write-Host ''
Write-Host ' 局域网存活主机扫描' -ForegroundColor White -BackgroundColor DarkBlue
Write-Host (" 时间: {0}    单地址超时: {1} ms    并发: {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $TimeoutMs, $Throttle) -ForegroundColor DarkGray

if ($TimeoutMs -lt 50)   { Write-Warn '超时小于 50ms 容易漏报，已按 50ms 处理。'; $TimeoutMs = 50 }
if ($Throttle  -lt 1)    { Write-Warn '并发数不能小于 1，已按 1 处理。'; $Throttle = 1 }
if ($Throttle  -gt 512)  { Write-Warn '并发数过大反而更慢，已按 512 处理。'; $Throttle = 512 }

# ---------- 1. 确定网段 ----------
Write-Step '1/5 确定扫描网段'
$baseIp   = $null
$prefix   = 24
$maskText = '(未知，按 /24 处理)'
$srcText  = ''
$isAuto   = [string]::IsNullOrWhiteSpace($Subnet)

if (-not $isAuto) {
    $text = $Subnet.Trim()
    $m = [regex]::Match($text, '^(\d{1,3}(?:\.\d{1,3}){2,3})\.?(?:/(\d{1,2}))?$')
    if (-not $m.Success) {
        Write-Bad ("无法识别 -Subnet '{0}'，示例: 192.168.1.0/24 或 192.168.1." -f $Subnet)
        Write-Host ''
        exit 1
    }
    $head = $m.Groups[1].Value
    $oct  = @($head.Split('.'))
    if ($oct.Count -eq 3) {
        $baseIp = ('{0}.0' -f $head)
        $prefix = 24
    } else {
        $baseIp = $head
        $prefix = 24
    }
    if ($m.Groups[2].Success) { $prefix = [int]$m.Groups[2].Value }
    if ($prefix -lt 24 -or $prefix -gt 32) {
        Write-Bad ("只支持 /24~/32 的网段（当前 /{0}）：/16 之类的大网段会扫很久，且容易被当成扫描器。" -f $prefix)
        Write-Host ''
        exit 1
    }
    $srcText = '手动指定'
} else {
    $cim = @()
    try { $cim = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' }) } catch { $cim = @() }
    if ($cim.Count -gt 0) {
        # 优先物理网卡：跳过 VPN / WSL 等虚拟接口（CIM 查询失败时此项自动跳过）
        $virtual = @()
        try {
            $virtual = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Virtual -eq $true -or $_.InterfaceType -eq 24 } | Select-Object -ExpandProperty ifIndex)
        } catch { $virtual = @() }
        $picked = $null
        foreach ($a in $cim) { if ($virtual -notcontains $a.ifIndex -and $a.IPAddress -notlike '169.254.*') { $picked = $a; break } }
        if (-not $picked) { foreach ($a in $cim) { if ($a.IPAddress -notlike '169.254.*') { $picked = $a; break } } }
        if (-not $picked) { $picked = $cim[0] }
        $baseIp   = $picked.IPAddress
        $prefix   = [int]$picked.PrefixLength
        $srcText  = ('Get-NetIPAddress -> {0}' -f $picked.InterfaceAlias)
        $maskText = ('/{0}' -f $prefix)
    } else {
        $cfg = Get-IpConfigInfo
        if ($cfg.Items.Count -eq 0) {
            Write-Bad '没有找到可用的 IPv4 地址（未联网 / 只有 APIPA 地址 / 命令被限制）。请用 -Subnet 手动指定网段。'
            Write-Host ''
            exit 1
        }
        $baseIp  = $cfg.Items[0].Ip
        $srcText = 'ipconfig（Get-NetIPAddress 不可用，已回退）'
        if ($cfg.Items[0].Mask -match '^\d{1,3}(\.\d{1,3}){3}$') {
            $maskText = $cfg.Items[0].Mask
            $mn = Convert-IpToInt64 -Ip $cfg.Items[0].Mask
            if ($mn -ne $null) {
                $bits = 0
                for ($i = 31; $i -ge 0; $i--) { if ((($mn -shr $i) -band 1) -eq 1) { $bits++ } else { break } }
                if ($bits -ge 8 -and $bits -le 32) { $prefix = $bits }
            }
        }
    }
    if ($prefix -lt 24 -or $prefix -gt 32) {
        Write-Warn ("本机掩码是 /{0}，网段比 /24 大很多；为避免长时间扫描，自动按 /24 处理。" -f $prefix)
        $prefix = 24
    }
}

$b24 = $null
if ($prefix -lt 32) { $b24 = 1; for ($i = 1; $i -lt (32 - $prefix); $i++) { $b24 = ($b24 * 2) + 1 } }
$startInt = ($(Convert-IpToInt64 -Ip $baseIp) -band (0xFFFFFFFF - $b24))
$endInt   = $startInt + (1 -shl (32 - $prefix)) - 1

$scanTargets = @()
$skippedSelf = @()
$selfInts = @()
try { $selfInts = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Select-Object -ExpandProperty IPAddress) } catch { }
foreach ($ip in (Get-IpConfigInfo).Items) { if ($selfInts -notcontains $ip.Ip) { $selfInts += $ip.Ip } }

for ($i = $startInt + 1; $i -lt $endInt; $i++) {
    $ip = Convert-Int64ToIp -N $i
    if ($selfInts -contains $ip) { $skippedSelf += $ip; continue }
    # 排除网络 / 广播地址（/31 /32 除外）
    if ($prefix -le 30 -and ($i -eq $startInt -or $i -eq $endInt)) { continue }
    $scanTargets += $ip
}

Write-Ok ("扫描网段: {0}/{1}    共 {2} 个待探测地址" -f (Convert-Int64ToIp -N $startInt), $prefix, $scanTargets.Count)
Write-Info ("网段来源: {0}" -f $srcText)
if ($maskText -ne '') { Write-Info ("子网掩码: {0}" -f $maskText) }
if ($prefix -lt 24) { Write-Info '（IPv4 私有地址网段如 10.x 可能实际是 /16，/24 之外的主机不会被扫到）' }
if ($skippedSelf.Count -gt 0) { Write-Info ("已跳过本机地址: {0}" -f ($skippedSelf -join ', ')) }

if ($scanTargets.Count -eq 0) {
    Write-Warn '该网段没有可探测的其它地址（/31 或 /32）。'
} else {
    # ---------- 2. 并发 ping ----------
    Write-Step ("2/5 并发 ping（共 {0} 个地址，并发 {1}，单地址超时 {2} ms）" -f $scanTargets.Count, $Throttle, $TimeoutMs)
    Write-Info '正在探测，请稍候…'

    # 放在 runspace 里执行的探测函数：只用 ping.exe，不依赖 WMI/CIM
    $pingScript = @'
param($Addresses, $WaitMs)
function Test-Alive {
    param([string]$Target, [int]$Wait)
    $out = ''
    try { $out = (& ping.exe -n 1 -w $Wait $Target 2>&1 | Out-String) } catch { $out = '' }
    $ms = $null
    if ($out -match '(?i)TTL=') {
        $m = [regex]::Match($out, '(?i)(?:time|时间)\s*[=<]\s*(\d+)\s*ms')
        if ($m.Success) { $ms = [int]$m.Groups[1].Value } else { $ms = 0 }
    }
    [pscustomobject]@{ Ip = $Target; Ok = [bool]($out -match '(?i)TTL='); Ms = $ms }
}
foreach ($a in $Addresses) { Test-Alive -Target $a -Wait $WaitMs }
'@

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $alive = @()
    $pool = $null
    $ps = $null
    try {
        $pool = [runspacefactory]::CreateRunspacePool(1, $Throttle)
        $pool.ApartmentState = 'MTA'
        $pool.Open()
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($pingScript).AddArgument($scanTargets).AddArgument($TimeoutMs)
        $handle = $ps.BeginInvoke()
        # 安全兜底：按“最坏情况”估一个上限，正常会远早于此结束
        $budgetMs = [int](($scanTargets.Count / [double]$Throttle) * ($TimeoutMs + 1500))
        $budgetMs = [Math]::Max(60000, [Math]::Min(1800000, $budgetMs))
        $lastLog = 0
        while ($true) {
            if ($handle.AsyncWaitHandle.WaitOne(2000)) { break }
            $sec = [int]$sw.Elapsed.TotalSeconds
            if ($sec - $lastLog -ge 5) {
                $lastLog = $sec
                Write-Info ("已等待 {0} 秒（上限 {1} 秒），仍在探测…" -f $sec, [Math]::Round($budgetMs / 1000, 0))
            }
            if ($sw.Elapsed.TotalMilliseconds -ge $budgetMs) { throw ('ping 阶段等待超过 {0} 秒' -f [Math]::Round($budgetMs / 1000, 0)) }
        }
        $raw = @($ps.EndInvoke($handle))
        $alive = @($raw | Where-Object { $_ -ne $null -and $_.Ok })
    } catch {
        Write-Warn ("runspace 并发探测不可用，改用串行探测：{0}" -f $_.Exception.Message)
        $alive = @()
        foreach ($ip in $scanTargets) {
            $out = (& ping.exe -n 1 -w $TimeoutMs $ip 2>&1 | Out-String)
            if ($out -match '(?i)TTL=') {
                $m = [regex]::Match($out, '(?i)(?:time|时间)\s*[=<]\s*(\d+)\s*ms')
                $ms = 0
                if ($m.Success) { $ms = [int]$m.Groups[1].Value }
                $alive += [pscustomobject]@{ Ip = $ip; Ok = $true; Ms = $ms }
            }
        }
    } finally {
        if ($ps)   { $ps.Dispose() }
        if ($pool) { $pool.Close(); $pool.Dispose() }
    }
    $sw.Stop()
    $elapsed = [Math]::Round($sw.Elapsed.TotalSeconds, 1)

    $alive = @($alive | Sort-Object { Convert-IpToInt64 -Ip $_.Ip })

    # ---------- 3. 反向解析主机名 ----------
    Write-Step ("3/5 汇总在线主机（{0} 台）" -f $alive.Count)
    if ($ResolveNames -and $alive.Count -gt 0) { Write-Info '正在反向解析主机名…' }
    $hostMap = @{}
    if ($ResolveNames) {
        foreach ($h in $alive) {
            $name = ''
            try { $name = ([System.Net.Dns]::GetHostEntry($h.Ip)).HostName } catch { $name = '' }
            $hostMap[$h.Ip] = $name
        }
    }

    # ---------- 4. ARP 表 ----------
    $arpMap = Get-ArpTable

    Write-Title ("在线主机（{0} 台）" -f $alive.Count)
    if ($alive.Count -eq 0) {
        Write-Warn '没有探测到在线主机。'
        Write-Info '可能原因：本机防火墙拦 ICMP、对方禁 ping、网段不对、或真的没人。'
    } else {
        Write-Host ('  {0,-16} {1,-10} {2,-20} {3}' -f 'IP 地址', '响应(ms)', 'MAC 地址', '主机名') -ForegroundColor DarkCyan
        Write-Host ('  ' + ('-' * 70)) -ForegroundColor DarkGray
        foreach ($h in $alive) {
            $mac = ''
            if ($arpMap.ContainsKey($h.Ip)) { $mac = $arpMap[$h.Ip] }
            if ($mac -eq '') { $mac = '(不在 arp 表)' }
            $name = ''
            if ($hostMap.ContainsKey($h.Ip)) { $name = $hostMap[$h.Ip] }
            $msTxt = [string]$h.Ms
            if ($h.Ms -eq 0) { $msTxt = '<1' }
            Write-Host ('  {0,-16} {1,-10} {2,-20} {3}' -f $h.Ip, $msTxt, $mac, $name) -ForegroundColor Gray
        }
    }

    Write-Title 'ARP 邻居表补充（arp -a）'
    if ($arpMap.Count -eq 0) {
        Write-Info '未读取到 arp 表（可能被限制，或本机还没和任何主机通信过）。'
    } else {
        $aliveIps = @($alive | ForEach-Object { $_.Ip })
        # 只保留可能的单播主机（组播 / 广播已在解析阶段排除）
        $extra = @($arpMap.Keys | Where-Object { $aliveIps -notcontains $_ })
        $extra = @($extra | Sort-Object { [double](Convert-IpToInt64 -Ip $_) })
        $arpRawCount = 0
        if ($script:ArpTotal -ne $null) { $arpRawCount = $script:ArpTotal.Count }
        $dyn = 0
        if ($script:ArpDynamic -ne $null) { $dyn = $script:ArpDynamic.Count }
        Write-Host ("  原始 arp 条目 {0} 条（其中动态 {1} 条）-> 排除组播/广播后单播 {2} 条，与在线主机对应 {3} 条" -f `
            $arpRawCount, $dyn, $arpMap.Count, ($arpMap.Count - $extra.Count)) -ForegroundColor DarkGray
        if ($extra.Count -gt 0) {
            Write-Host '  以下地址在 arp 表里但本次 ping 没回应（可能禁 ping，或已离线）：' -ForegroundColor DarkGray
            foreach ($ip in $extra) { Write-Host ('    {0,-16} {1}' -f $ip, $arpMap[$ip]) -ForegroundColor DarkGray }
        }
    }

    # ---------- 5. 导出 ----------
    Write-Step '4/5 导出 CSV'
    if (-not [string]::IsNullOrWhiteSpace($Export)) {
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($h in $alive) {
            $mac = ''
            if ($arpMap.ContainsKey($h.Ip)) { $mac = $arpMap[$h.Ip] }
            $name = ''
            if ($hostMap.ContainsKey($h.Ip)) { $name = $hostMap[$h.Ip] }
            $rows.Add([pscustomobject]@{
                IP         = $h.Ip
                ResponseMs = $h.Ms
                Mac        = $mac
                HostName   = $name
                Online     = $true
            }) | Out-Null
        }
        foreach ($ip in $extra) {
            $rows.Add([pscustomobject]@{
                IP         = $ip
                ResponseMs = ''
                Mac        = $arpMap[$ip]
                HostName   = ''
                Online     = $false
            }) | Out-Null
        }
        try {
            $rows | Export-Csv -Path $Export -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
            $full = $Export
            try { $full = (Resolve-Path -Path $Export -ErrorAction Stop).Path } catch { }
            Write-Ok ("已导出 {0} 行 -> {1}" -f $rows.Count, $full)
        } catch {
            Write-Bad ("导出失败: {0}" -f $_.Exception.Message)
        }
    } else {
        Write-Info '未指定 -Export，跳过导出。'
    }

    # ---------- 结论 ----------
    $totalSec = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
    Write-Title '结论'
    Write-Host ("  扫描 {0} 个地址，在线 {1} 个，耗时 {2} 秒。" -f $scanTargets.Count, $alive.Count, $totalSec) -ForegroundColor Green
    Write-Info ("网段 {0}/{1}    并发 {2}    单地址超时 {3} ms" -f (Convert-Int64ToIp -N $startInt), $prefix, $Throttle, $TimeoutMs)
    if ($alive.Count -eq 0) { Write-Warn '一个都没扫到：先确认网段是否正确，再确认是否被防火墙拦住 ICMP。' }
}

Write-Title '下一步：想确认某台主机开了什么端口（本脚本不扫端口）'
Write-Host '   Test-NetConnection 192.168.1.10 -Port 445          # 图形化常用：单端口探测' -ForegroundColor Gray
Write-Host '   Test-NetConnection 192.168.1.10 -Port 3389 -InformationLevel Quiet' -ForegroundColor Gray
Write-Host '   Test-NetConnection 192.168.1.10 -CommonTCPPort SMB # 常用端口快捷名' -ForegroundColor Gray
Write-Host '   netstat -ano | findstr :445                        # 本机端口占用（本工具包 03）' -ForegroundColor Gray
Write-Host '   提示：只对自己有权限的设备做端口探测，未授权扫描可能被当成入侵行为。' -ForegroundColor Yellow
Write-Host ''
