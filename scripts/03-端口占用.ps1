<#
.SYNOPSIS
    查询端口被哪个进程占用（可按需结束该进程）
.DESCRIPTION
    列出占用指定端口的连接、协议、状态与对应进程（名称/路径/所属用户），
    加 -Kill 可在确认后结束进程。不加端口时显示全部监听端口的概览。
.PARAMETER Port
    要查询的端口号，例如 8080。省略时列出所有监听端口。
.PARAMETER Kill
    结束占用该端口的进程（会二次确认）。
.PARAMETER All
    显示所有连接（默认只看监听 + 已建立）。
.EXAMPLE
    .\03-端口占用.ps1 -Port 8080
.EXAMPLE
    .\03-端口占用.ps1 -Port 3000 -Kill
.EXAMPLE
    .\03-端口占用.ps1            # 列出全部监听端口
#>
[CmdletBinding()]
param(
    [int]$Port,
    [switch]$Kill,
    [switch]$All,
    [switch]$Yes          # 跳过交互确认（图形界面/自动化调用）
)

$ErrorActionPreference = 'SilentlyContinue'

function Get-ProcDetail([int]$ProcessId) {
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $p) { return $null }

    # 取进程所属用户：CimInstance 没有 GetOwner() 方法，必须用 Invoke-CimMethod；
    # 再退回 Get-WmiObject，任何失败都只显示“未知”，绝不中断主流程
    $user = '未知'
    try {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
        if ($proc) {
            $owner = Invoke-CimMethod -InputObject $proc -MethodName GetOwner -ErrorAction Stop
            if ($owner -and $owner.User) { $user = "{0}\{1}" -f $owner.Domain, $owner.User }
        }
    } catch {
        try {
            $wm = Get-WmiObject Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
            if ($wm) {
                $owner = $wm.GetOwner()
                if ($owner -and $owner.User) { $user = "{0}\{1}" -f $owner.Domain, $owner.User }
            }
        } catch { }
    }

    [pscustomobject]@{
        Name = $p.ProcessName
        Id   = $p.Id
        Path = $p.Path
        User = $user
        Mem  = [Math]::Round($p.WorkingSet64 / 1MB, 1)
    }
}

if (-not $PSBoundParameters.ContainsKey('Port')) {
    Write-Host ''
    Write-Host ' 当前监听端口概览（Top 40，按端口排序）' -ForegroundColor White -BackgroundColor DarkBlue
    $listen = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue
    if (-not $listen) { $listen = netstat -ano | Select-String 'LISTENING' | ForEach-Object { $null } }
    $listen | Sort-Object LocalPort -Unique | Select-Object -First 40 | ForEach-Object {
        $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
        $name = if ($proc) { $proc.ProcessName } else { '?' }
        Write-Host ('  {0,-22} {1,-8} PID {2,-7} {3}' -f $_.LocalAddress, $_.LocalPort, $_.OwningProcess, $name)
    }
    Write-Host ''
    Write-Host ' 提示：查具体端口用  .\03-端口占用.ps1 -Port 8080' -ForegroundColor DarkGray
    Write-Host ''
    return
}

Write-Host ''
Write-Host (" 查询端口 {0} 的占用情况" -f $Port) -ForegroundColor White -BackgroundColor DarkBlue

$conns = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
if (-not $All) {
    $conns = $conns | Where-Object { $_.State -in @('Listen', 'Established') }
}

if (-not $conns) {
    # 回退到 netstat 解析（老系统或权限受限时）
    Write-Host '  未通过 CIM 查询到，尝试 netstat 解析…' -ForegroundColor DarkGray
    $lines = netstat -ano | Select-String (":{0}\s" -f $Port)
    if ($lines) {
        Write-Host ''
        $lines | ForEach-Object { Write-Host ('   ' + $_.Line.Trim()) }
        $pids = $lines | ForEach-Object { ($_ -split '\s+')[-1] } | Sort-Object -Unique
        foreach ($processId in $pids) {
            $d = Get-ProcDetail ([int]$processId)
            if ($d) { Write-Host ("   -> PID {0} = {1} ({2}) 用户 {3}" -f $d.Id, $d.Name, $d.Path, $d.User) -ForegroundColor Yellow }
        }
    } else {
        Write-Host ("  端口 {0} 当前没有被占用。" -f $Port) -ForegroundColor Green
    }
    Write-Host ''
    return
}

$conns | Format-Table -AutoSize @{n='本地地址';e={"{0}:{1}" -f $_.LocalAddress, $_.LocalPort}},
    @{n='远端';e={"{0}:{1}" -f $_.RemoteAddress, $_.RemotePort}}, @{n='状态';e={$_.State}},
    @{n='PID';e={$_.OwningProcess}} | Out-String | Write-Host

$owners = $conns | Select-Object -ExpandProperty OwningProcess -Unique
$details = @()
foreach ($processId in $owners) {
    $d = Get-ProcDetail ([int]$processId)
    if ($d) { $details += $d }
}
if ($details) {
    Write-Host ' 占用进程详情：' -ForegroundColor Cyan
    foreach ($d in $details) {
        Write-Host ("   PID {0,-7} {1}" -f $d.Id, $d.Name) -ForegroundColor Yellow
        Write-Host ("            路径: {0}" -f $d.Path) -ForegroundColor DarkGray
        Write-Host ("            用户: {0}   内存: {1} MB" -f $d.User, $d.Mem) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host (" 结束进程命令: taskkill /PID {0} /F" -f ($details.Id -join ' /PID ')) -ForegroundColor DarkGray

    if ($Kill) {
        Write-Host ''
        $answer = 'y'
        if (-not $Yes) { $answer = Read-Host (" 确认结束以上 {0} 个进程? 输入 y 继续" -f $details.Count) }
        if ($answer -eq 'y') {
            foreach ($d in $details) {
                try {
                    Stop-Process -Id $d.Id -Force -ErrorAction Stop
                    Write-Host ("   已结束 {0} (PID {1})" -f $d.Name, $d.Id) -ForegroundColor Green
                } catch {
                    Write-Host ("   无法结束 {0}: {1}" -f $d.Name, $_.Exception.Message) -ForegroundColor Red
                }
            }
        } else {
            Write-Host ' 已取消。' -ForegroundColor DarkGray
        }
    }
}
Write-Host ''
