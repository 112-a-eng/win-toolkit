<#
.SYNOPSIS
    Windows 网络一键诊断
.DESCRIPTION
    依次检查：网卡状态 -> IP/网关 -> 网关连通 -> 公网连通 -> DNS 解析 -> 目标连通 -> HTTP。
    优先使用 PowerShell 网络命令，被限制（WMI/CIM 拒绝访问）时自动回退到
    ipconfig / ping.exe / nslookup / curl.exe。全部为只读操作。
.PARAMETER Target
    用于测试连通性的域名，默认 www.baidu.com
.PARAMETER DnsServer
    指定 DNS 服务器做解析对比，默认 223.5.5.5
.PARAMETER PublicIp
    用于探测公网连通性的 IP，默认 223.5.5.5
.EXAMPLE
    .\02-网络诊断.ps1
.EXAMPLE
    .\02-网络诊断.ps1 -Target github.com -DnsServer 8.8.8.8
#>
[CmdletBinding()]
param(
    [string]$Target    = 'www.baidu.com',
    [string]$DnsServer = '223.5.5.5',
    [string]$PublicIp  = '223.5.5.5'
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'
$script:Issues = New-Object System.Collections.Generic.List[string]

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host ">> $Text" -ForegroundColor Cyan
}
function Write-Ok([string]$Text)   { Write-Host "   [OK]   $Text" -ForegroundColor Green }
function Write-Bad([string]$Text)  {
    Write-Host "   [FAIL] $Text" -ForegroundColor Red
    $script:Issues.Add($Text) | Out-Null
}
function Write-Info([string]$Text) { Write-Host "   [--]   $Text" -ForegroundColor DarkGray }

# 用 ping.exe（几乎所有机器都能用，且不受 WMI 限制影响）
function Invoke-PingTest {
    param([string]$ComputerName, [int]$Count = 3)
    $text = (& ping.exe -n $Count -w 1500 $ComputerName 2>&1 | Out-String)
    $ok = ($text -match '(?i)TTL=')
    $times = @([regex]::Matches($text, '(?i)(?:time|时间)[=<]\s*(\d+)\s*ms') | ForEach-Object { [int]$_.Groups[1].Value })
    $avg = $null
    if ($times.Count -gt 0) { $avg = [Math]::Round(($times | Measure-Object -Average).Average, 0) }
    $replies = @([regex]::Matches($text, '(?i)(?:Reply from|来自)\s*[\d\.]+')).Count
    [pscustomobject]@{ Ok = $ok; AvgMs = $avg; Replies = $replies; Sent = $Count }
}

# 从 ipconfig 文本里提取 IP / 网关 / DNS（回退路径）
function Get-IpConfigInfo {
    $plain = (ipconfig) -join "`n"
    $all   = (ipconfig /all) -join "`n"
    [pscustomobject]@{
        Ips      = @([regex]::Matches($plain, '(?m)^\s*IPv4[^:]*:\s*([\d\.]+)')      | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        Gateways = @([regex]::Matches($all,   '(?m)^\s*(?:Default Gateway|默认网关)[^:]*:\s*([\d\.]+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        Dns      = @([regex]::Matches($all,   '(?m)^\s*(?:DNS Servers|DNS 服务器)[^:]*:\s*([\d\.]+)')  | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    }
}

Write-Host ''
Write-Host ' Windows 网络一键诊断' -ForegroundColor White -BackgroundColor DarkBlue
Write-Host (" 目标: {0}    对比 DNS: {1}" -f $Target, $DnsServer) -ForegroundColor DarkGray

# ---------- 1. 网卡 ----------
Write-Step '1/7 网卡与链路状态'
$adapters = @()
try { $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceType -ne 24 }) } catch { $adapters = @() }
if ($adapters.Count -gt 0) {
    foreach ($a in $adapters) { Write-Ok ("{0}（{1}，{2}）" -f $a.Name, $a.InterfaceDescription, $a.LinkSpeed) }
} else {
    $nsOut = (& netsh interface show interface 2>&1 | Out-String)
    $connected = @(($nsOut -split "`r?`n") | Where-Object { $_ -match 'Connected|已连接' })
    if ($connected.Count -gt 0) {
        Write-Ok '检测到已连接的接口（netsh）：'
        $connected | ForEach-Object { Write-Info $_.Trim() }
    } else {
        Write-Info '未能读取网卡清单（当前环境限制网络类 CIM 查询）'
    }
}

# ---------- 2. IP 与网关 ----------
Write-Step '2/7 IP 地址与默认网关'
$netOk = $false
$gw = $null
$ips = @()
try { $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -ne '127.0.0.1' }) } catch { $ips = @() }
if ($ips.Count -gt 0) {
    foreach ($ip in $ips) { Write-Ok ("{0}: {1}/{2}" -f $ip.InterfaceAlias, $ip.IPAddress, $ip.PrefixLength) }
    $netOk = $true
    $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).NextHop
} else {
    $cfg = Get-IpConfigInfo
    if ($cfg.Ips.Count -gt 0) {
        foreach ($ip in $cfg.Ips) { Write-Ok ("IPv4: {0}" -f $ip) }
        $netOk = $true
    }
    if ($cfg.Gateways.Count -gt 0) { $gw = $cfg.Gateways[0] }
    if ($cfg.Dns.Count -gt 0) { Write-Info ("DNS: {0}" -f ($cfg.Dns -join ', ')) }
}
$apipa = @($ips | Where-Object { $_.IPAddress -like '169.254.*' })
if ($apipa.Count -gt 0) { Write-Bad '出现 169.254.x.x 地址，说明 DHCP 没拿到地址（检查路由器/DHCP 服务）' }
if (-not $netOk) { Write-Bad '没有获取到 IPv4 地址（DHCP 失败或未连接）' }
if ($gw) { Write-Ok "默认网关: $gw" } else { Write-Bad '没有默认网关（无法访问外网）' }

# ---------- 3. 网关连通 ----------
Write-Step '3/7 网关连通性'
if ($gw) {
    $r = Invoke-PingTest -ComputerName $gw -Count 3
    if ($r.Ok) { Write-Ok ("能 ping 通网关 {0}（平均 {1} ms，局域网链路正常）" -f $gw, $r.AvgMs) }
    else { Write-Bad "ping 不通网关 $gw（问题在本地链路 / 网线 / 路由器 / 防火墙）" }
}

# ---------- 4. 公网连通 ----------
Write-Step '4/7 公网连通性'
$rPub = Invoke-PingTest -ComputerName $PublicIp -Count 3
if ($rPub.Ok) {
    Write-Ok ("能 ping 通公网 IP {0}（平均 {1} ms，外网出口正常）" -f $PublicIp, $rPub.AvgMs)
} else {
    $rAlt = Invoke-PingTest -ComputerName '114.114.114.114' -Count 3
    if ($rAlt.Ok) { Write-Ok '能 ping 通 114.114.114.114，外网出口正常（对端禁 ping 属正常现象）' }
    else { Write-Bad "ping 不通公网 IP $PublicIp / 114.114.114.114（断网、路由问题，或全部禁 ping）" }
}

# ---------- 5. DNS ----------
Write-Step '5/7 DNS 解析'
$dnsServers = @()
try { $dnsServers = @((Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.ServerAddresses }).ServerAddresses | Select-Object -Unique) } catch { }
if ($dnsServers.Count -eq 0) { $dnsServers = (Get-IpConfigInfo).Dns }
if ($dnsServers.Count -gt 0) { Write-Info ("当前 DNS: {0}" -f ($dnsServers -join ', ')) } else { Write-Bad '未配置 DNS 服务器' }

$local = @()
try { $local = @(Resolve-DnsName $Target -ErrorAction Stop | Where-Object { $_.IPAddress }) } catch { }
if ($local.Count -gt 0) {
    Write-Ok ("本机 DNS 解析 {0} -> {1}" -f $Target, (($local.IPAddress | Select-Object -First 3) -join ', '))
} else {
    Write-Bad "本机 DNS 无法解析 $Target"
}
$remote = @()
try { $remote = @(Resolve-DnsName $Target -Server $DnsServer -ErrorAction Stop | Where-Object { $_.IPAddress }) } catch { }
if ($remote.Count -gt 0) {
    Write-Ok ("用 {0} 解析 {1} -> {2}" -f $DnsServer, $Target, (($remote.IPAddress | Select-Object -First 3) -join ', '))
    if ($local.Count -eq 0) { Write-Info ("建议：本机 DNS 有问题，可临时改用 {0}" -f $DnsServer) }
} else {
    Write-Info ("无法通过 {0} 解析（可能被防火墙拦截 UDP 53，可忽略）" -f $DnsServer)
}

# ---------- 6. 目标连通 ----------
Write-Step '6/7 目标主机连通性'
$rTarget = Invoke-PingTest -ComputerName $Target -Count 4
if ($rTarget.Ok) {
    $loss = [Math]::Round((1 - $rTarget.Replies / $rTarget.Sent) * 100, 0)
    Write-Ok ("ping {0} 平均 {1} ms，丢包 {2}%" -f $Target, $rTarget.AvgMs, $loss)
} else {
    Write-Bad "ping 不通 $Target（可能禁 ping，请看下一步 HTTP 结果）"
}

# ---------- 7. HTTP ----------
Write-Step '7/7 HTTP 访问测试'
$httpOk = $false
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = Invoke-WebRequest -Uri ("https://{0}" -f $Target) -Method Head -TimeoutSec 12 -UseBasicParsing -ErrorAction Stop
    $sw.Stop()
    Write-Ok ("HTTP {0}，耗时 {1} ms" -f $resp.StatusCode, $sw.ElapsedMilliseconds)
    $httpOk = $true
} catch {
    $firstError = $_.Exception.Message
    $code = (& curl.exe -s -o NUL --max-time 12 -w '%{http_code}' ("https://{0}" -f $Target) 2>&1 | Out-String).Trim()
    if ($code -match '^\d{3}$' -and $code -ne '000') {
        Write-Ok ("HTTP {0}（curl.exe 检测）" -f $code)
        $httpOk = $true
    } else {
        Write-Bad ("HTTP 访问失败: {0}" -f $firstError)
    }
}

# ---------- 结论 ----------
Write-Host ''
Write-Host '================ 结论与建议 ================' -ForegroundColor Yellow
if ($script:Issues.Count -eq 0 -and $httpOk) {
    Write-Host ' 网络看起来完全正常。' -ForegroundColor Green
} elseif ($script:Issues.Count -eq 0) {
    Write-Host ' 基础连通性正常，但 HTTP 测试未通过（可能是代理/防火墙/HTTPS 拦截）。' -ForegroundColor Yellow
} else {
    Write-Host (" 发现 {0} 个问题：" -f $script:Issues.Count) -ForegroundColor Yellow
    $script:Issues | ForEach-Object { Write-Host "   - $_" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host ' 常见修复（管理员运行）：' -ForegroundColor Cyan
    Write-Host '   ipconfig /flushdns                     # 清 DNS 缓存'
    Write-Host '   ipconfig /release && ipconfig /renew   # 重新获取 IP'
    Write-Host '   netsh winsock reset                    # 重置 Winsock（需重启）'
    Write-Host '   netsh int ip reset                     # 重置 TCP/IP（需重启）'
    Write-Host '   netsh wlan show profiles               # 查已保存的 Wi-Fi'
    Write-Host '   netsh interface ip set dns "以太网" static 223.5.5.5   # 换 DNS'
    Write-Host '   Test-NetConnection 主机 -Port 端口      # 单独测某个端口'
}
Write-Host ''
