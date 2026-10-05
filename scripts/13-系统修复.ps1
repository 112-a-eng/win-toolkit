<#
.SYNOPSIS
    系统修复工具箱（SFC / DISM / DNS / 网络重置 / 更新缓存 / 图标缓存）
.DESCRIPTION
    把 Windows 常见的“系统文件损坏、网络抽风、更新卡住、图标变白”等修复动作集中到一个脚本。
    不带任何修复开关运行（或加 -List）只打印“可用修复项”清单，不做任何改动。
    带开关时按固定顺序逐项执行，每项给出结果与耗时，最后输出「执行结果汇总」表。
    危险项（-ResetNetwork / -ClearUpdateCache / -RebuildIconCache）默认需要交互确认，
    图形工具台/自动化调用可传 -Yes 跳过确认。
    需要管理员的项在普通用户下会被明确跳过并提示提权方式，不会静默失败。
    每一步失败都不会中断整体流程，其余项目继续执行。
.PARAMETER Sfc
    运行 sfc /scannow，扫描并尝试修复受保护的系统文件（很慢，5-20 分钟，需要管理员）。
.PARAMETER Dism
    运行 DISM /Online /Cleanup-Image /RestoreHealth，修复系统映像（很慢，需要管理员，通常需要联网）。
.PARAMETER FlushDns
    运行 ipconfig /flushdns，刷新 DNS 解析缓存（很快，安全，普通用户即可）。
.PARAMETER ResetNetwork
    运行 netsh winsock reset 与 netsh int ip reset（危险：重置网络后需要重启电脑）。
.PARAMETER ClearUpdateCache
    停止 wuauserv/bits，删除 SoftwareDistribution\Download 中已下载的更新，再恢复原本在跑的服务（危险，需要管理员）。
.PARAMETER RebuildIconCache
    删除 IconCache.db 与 thumbcache_*.db 并重启资源管理器（危险：桌面会闪一下）。
.PARAMETER List
    只列出可用修复项与说明，不执行任何修复。
.PARAMETER Yes
    跳过所有交互确认（图形界面/自动化调用请传这个）。
.EXAMPLE
    .\13-系统修复.ps1 -List
.EXAMPLE
    .\13-系统修复.ps1 -FlushDns -Yes
.EXAMPLE
    .\13-系统修复.ps1 -Sfc -Dism -Yes
.EXAMPLE
    .\13-系统修复.ps1 -ResetNetwork -ClearUpdateCache
#>
[CmdletBinding()]
param(
    [switch]$Sfc,              # sfc /scannow
    [switch]$Dism,             # DISM /Online /Cleanup-Image /RestoreHealth
    [switch]$FlushDns,         # ipconfig /flushdns
    [switch]$ResetNetwork,     # netsh winsock reset + netsh int ip reset
    [switch]$ClearUpdateCache, # 停 wuauserv/bits -> 删 SoftwareDistribution\Download -> 恢复服务
    [switch]$RebuildIconCache, # 删 IconCache.db / thumbcache_*.db 并重启 explorer
    [switch]$List,             # 只列出可用修复项与说明
    [switch]$Yes               # 跳过交互确认（图形界面/自动化调用）
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ---------------- 通用工具函数 ----------------
function Write-Title([string]$Text) {
    Write-Host ''
    Write-Host "== $Text " -ForegroundColor Cyan -NoNewline
    Write-Host ('=' * [Math]::Max(4, 58 - $Text.Length)) -ForegroundColor DarkCyan
}
# 从命令输出里挑出关键结论行（最多 Max 行）
function Get-MatchedLines([string]$Text, [string]$Pattern, [int]$Max = 5) {
    $result = @()
    foreach ($line in @($Text -split '[\r\n]+')) {
        $t = $line.Trim()
        if ($t -ne '' -and $t -match $Pattern) { $result += $t }
        if ($result.Count -ge $Max) { break }
    }
    return ,$result
}
# 取最后 Max 行非空输出（命令没给可识别结论时兜底展示）
function Get-TailLines([string]$Text, [int]$Max = 3) {
    $result = @()
    foreach ($line in @($Text -split '[\r\n]+')) {
        $t = $line.Trim()
        if ($t -ne '') { $result += $t }
    }
    if ($result.Count -le $Max) { return ,$result }
    return ,@($result[($result.Count - $Max)..($result.Count - 1)])
}
function Write-Detail($Lines) {
    foreach ($l in @($Lines)) { Write-Host ('    ' + $l) -ForegroundColor DarkGray }
}

# ---------------- 修复项定义（顺序 = 执行顺序） ----------------
$items = @(
    [pscustomobject]@{
        Key = 'Sfc'; Switch = '-Sfc'
        Name = '系统文件完整性扫描修复'
        Action = 'sfc /scannow，扫描并尝试修复受保护的系统文件'
        Time = '5-20 分钟'; Admin = $true; Danger = $false
        Risk = '安全：只扫描并尝试用系统副本修复损坏文件'
    }
    [pscustomobject]@{
        Key = 'Dism'; Switch = '-Dism'
        Name = '系统映像健康修复'
        Action = 'DISM /Online /Cleanup-Image /RestoreHealth，修复组件存储'
        Time = '5-20 分钟'; Admin = $true; Danger = $false
        Risk = '安全：需要联网从 Windows 更新源取修复文件，可能较慢'
    }
    [pscustomobject]@{
        Key = 'FlushDns'; Switch = '-FlushDns'
        Name = '刷新 DNS 解析缓存'
        Action = 'ipconfig /flushdns，清掉过期/错误的域名解析缓存'
        Time = '2 秒'; Admin = $false; Danger = $false
        Risk = '安全：只清缓存，不影响网络配置，可随时执行'
    }
    [pscustomobject]@{
        Key = 'ResetNetwork'; Switch = '-ResetNetwork'
        Name = '重置网络协议栈'
        Action = 'netsh winsock reset + netsh int ip reset，重置 Winsock 与 TCP/IP'
        Time = '10-30 秒'; Admin = $true; Danger = $true
        Risk = '危险：重置网络后需要重启电脑才完全生效，期间网络可能短暂断开；手工设置的静态 IP/端口代理等可能需要重新配置'
    }
    [pscustomobject]@{
        Key = 'ClearUpdateCache'; Switch = '-ClearUpdateCache'
        Name = '清理 Windows 更新下载缓存'
        Action = '停 wuauserv/bits -> 删 SoftwareDistribution\Download -> 恢复服务'
        Time = '20 秒 - 2 分钟'; Admin = $true; Danger = $true
        Risk = '危险：会删除已下载但未安装的更新，之后需要重新下载；服务会临时停止'
    }
    [pscustomobject]@{
        Key = 'RebuildIconCache'; Switch = '-RebuildIconCache'
        Name = '重建图标/缩略图缓存'
        Action = '删 IconCache.db 与 thumbcache_*.db，然后重启资源管理器'
        Time = '5-15 秒'; Admin = $false; Danger = $true
        Risk = '危险：会强制重启资源管理器，桌面与任务栏会闪一下（短暂消失后恢复）'
    }
)

$selected = @{
    'Sfc'              = [bool]$Sfc
    'Dism'             = [bool]$Dism
    'FlushDns'         = [bool]$FlushDns
    'ResetNetwork'     = [bool]$ResetNetwork
    'ClearUpdateCache' = [bool]$ClearUpdateCache
    'RebuildIconCache' = [bool]$RebuildIconCache
}
$anySelected = @($selected.Values | Where-Object { $_ }).Count -gt 0

# ---------------- 清单 ----------------
function Show-ItemList {
    Write-Title '可用修复项'
    $rows = foreach ($i in $items) {
        [pscustomobject]@{
            开关     = $i.Switch
            作用     = $i.Name
            预计耗时 = $i.Time
            需管理员 = $(if ($i.Admin) { '是' } else { '否' })
            危险     = $(if ($i.Danger) { '是' } else { '否' })
        }
    }
    $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

    Write-Title '各项说明'
    foreach ($i in $items) {
        Write-Host ("   {0,-18} {1}" -f $i.Switch, $i.Name) -ForegroundColor White
        Write-Host ("     作用    : {0}" -f $i.Action) -ForegroundColor DarkGray
        Write-Host ("     预计耗时: {0}    需要管理员: {1}    危险: {2}" -f `
            $i.Time, $(if ($i.Admin) { '是' } else { '否' }), $(if ($i.Danger) { '是' } else { '否' })) -ForegroundColor DarkGray
        Write-Host ("     风险    : {0}" -f $i.Risk) -ForegroundColor $(if ($i.Danger) { 'Yellow' } else { 'DarkGray' })
    }

    Write-Title '怎么用'
    Write-Host '   .\13-系统修复.ps1 -FlushDns -Yes                    只刷新 DNS 缓存（快、安全）' -ForegroundColor DarkGray
    Write-Host '   .\13-系统修复.ps1 -Sfc -Dism -Yes                   先修系统文件，再修系统映像（慢）' -ForegroundColor DarkGray
    Write-Host '   .\13-系统修复.ps1 -ResetNetwork -ClearUpdateCache   危险项会逐项交互确认' -ForegroundColor DarkGray
    Write-Host '   提示: 需要管理员的项请在图形工具台右上角点「以管理员身份重启」后再运行。' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host ' Windows 系统修复工具箱' -ForegroundColor White -BackgroundColor DarkBlue
Write-Host (" 管理员: {0}    确认模式: {1}    时间: {2}" -f `
    $(if ($isAdmin) { '是' } else { '否' }), `
    $(if ($Yes) { '自动确认（-Yes）' } else { '交互确认' }), `
    (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ForegroundColor DarkGray

# 不带任何修复开关（或带 -List）只打印清单，绝不执行
if ($List -or -not $anySelected) {
    if ($List -and $anySelected) {
        Write-Host ' 已指定 -List，只列出清单，忽略其他修复开关。' -ForegroundColor Yellow
    }
    Show-ItemList
    Write-Host ''
    return
}

# ---------------- 交互确认 ----------------
function Confirm-Danger([string]$Switch, [string]$Consequence) {
    Write-Host ''
    Write-Host (" 危险操作确认: {0}" -f $Switch) -ForegroundColor Yellow
    Write-Host (" 后果: {0}" -f $Consequence) -ForegroundColor Yellow
    if ($Yes) {
        Write-Host ' 已指定 -Yes，跳过交互确认。' -ForegroundColor DarkGray
        return $true
    }
    $answer = 'n'
    try { $answer = Read-Host ' 确认执行该项? 输入 y 继续，其它任意输入取消' } catch { $answer = 'n' }
    if ($answer -eq 'y') { return $true }
    Write-Host ' 已取消该项。' -ForegroundColor DarkGray
    return $false
}

# ---------------- 各修复项实现 ----------------
function Invoke-Sfc {
    Write-Host '    提示: sfc /scannow 可能需要 5-20 分钟，请耐心等待，不要关闭窗口…' -ForegroundColor Yellow
    $out = (& sfc.exe /scannow 2>&1 | Out-String)
    $key = Get-MatchedLines $out '未找到完整性冲突|已成功修复|已修复|无法修复|Windows 资源保护|did not find any integrity|successfully repaired|unable to fix|found corrupt|verification' 5
    if (@($key).Count -gt 0) { Write-Detail $key }
    else {
        Write-Host '    （未匹配到结论行，原始输出末尾如下）' -ForegroundColor DarkGray
        Write-Detail (Get-TailLines $out 3)
    }
    $text = (@($key) -join ' ')
    if ($text -match '未找到完整性冲突|did not find any integrity') { return '成功：未找到完整性冲突' }
    if ($text -match '已成功修复|successfully repaired') { return '成功：已修复损坏的系统文件（详见 CBS.log）' }
    if ($text -match '无法修复|unable to fix|found corrupt') { return '警告：存在无法修复的文件，建议再执行 -Dism 后重试，并查看 CBS.log' }
    return '完成：请根据上方输出判断结果'
}

function Invoke-Dism {
    Write-Host '    提示: DISM 修复可能需要 5-20 分钟（视网络与更新源），请耐心等待…' -ForegroundColor Yellow
    $out = (& dism.exe /Online /Cleanup-Image /RestoreHealth 2>&1 | Out-String)
    $key = Get-MatchedLines $out '还原操作已成功完成|操作成功完成|completed successfully|已完成|错误|Error|0x|%' 4
    if (@($key).Count -gt 0) { Write-Detail $key }
    Write-Host '    输出末尾:' -ForegroundColor DarkGray
    Write-Detail (Get-TailLines $out 3)
    $text = ($out -join ' ')
    if ($text -match '需要提升|requires elevation|Elevated permissions are required|请求的操作需要提升|错误: 740') { return '失败：需要管理员权限' }
    if ($text -match '还原操作已成功完成|操作成功完成|restore operation completed successfully|completed successfully') { return '成功：系统映像已修复' }
    if ($text -match '错误|Error|0x[0-9a-fA-F]{4,}') { return '失败：DISM 返回错误，请查看上方输出' }
    return '完成：请根据上方输出判断结果'
}

function Invoke-FlushDns {
    $out = (& ipconfig.exe /flushdns 2>&1 | Out-String)
    Write-Detail (Get-TailLines $out 3)
    if ($out -match '已成功刷新|Successfully flushed') { return '成功：DNS 解析缓存已刷新' }
    if ($out -match '需要提升|requires elevation|Access is denied|拒绝访问') { return '失败：需要管理员权限' }
    return '完成：请根据上方输出判断结果'
}

function Invoke-ResetNetwork {
    Write-Host '    [1/2] netsh winsock reset' -ForegroundColor DarkGray
    $o1 = (& netsh.exe winsock reset 2>&1 | Out-String)
    Write-Detail (Get-TailLines $o1 2)
    Write-Host '    [2/2] netsh int ip reset' -ForegroundColor DarkGray
    $o2 = (& netsh.exe int ip reset 2>&1 | Out-String)
    Write-Detail (Get-TailLines $o2 2)

    $all = ($o1 + ' ' + $o2)
    if ($all -match '需要提升|requires elevation|Access is denied|拒绝访问|请求的操作需要提升') { return '失败：需要管理员权限' }
    if ($all -match '成功重置|Successfully reset|重置成功|Resetting') { return '成功：Winsock 与 TCP/IP 已重置，请重启电脑使其完全生效' }
    return '完成：请根据上方输出判断结果（网络重置后建议重启电脑）'
}

function Invoke-ClearUpdateCache {
    Write-Host '    提示: 已下载但未安装的更新会被删除，之后需要重新下载。' -ForegroundColor Yellow
    $svcNames = @('wuauserv', 'bits')

    # 先记下原本在跑哪些服务
    $wasRunning = @()
    foreach ($svc in $svcNames) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s -and $s.Status -eq 'Running') { $wasRunning += $svc }
    }
    if ($wasRunning.Count -gt 0) {
        Write-Host ("    原本在运行的服务: {0}，先停止…" -f ($wasRunning -join ', ')) -ForegroundColor DarkGray
    } else {
        Write-Host '    wuauserv / bits 原本未运行。' -ForegroundColor DarkGray
    }

    # 停服务（单步失败不中断）
    foreach ($svc in $svcNames) {
        if (-not (Get-Service -Name $svc -ErrorAction SilentlyContinue)) {
            Write-Host ("    服务不存在，跳过: {0}" -f $svc) -ForegroundColor Yellow
            continue
        }
        try {
            Stop-Service -Name $svc -Force -ErrorAction Stop
            Write-Host ("    已停止服务: {0}" -f $svc) -ForegroundColor DarkGray
        } catch {
            Write-Host ("    停止服务 {0} 失败（继续执行）: {1}" -f $svc, $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    # 删下载缓存
    $download = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
    $deleted = 0
    $failed  = 0
    if (Test-Path -LiteralPath $download) {
        foreach ($item in @(Get-ChildItem -LiteralPath $download -Force -ErrorAction SilentlyContinue)) {
            $full = $item.FullName
            Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $full) { $failed++ } else { $deleted++ }
        }
        Write-Host ("    已删除 {0} 项，{1} 项被占用/删除失败。" -f $deleted, $failed) -ForegroundColor DarkGray
    } else {
        Write-Host ("    目录不存在，跳过: {0}" -f $download) -ForegroundColor Yellow
    }

    # 只把原本在跑的服务启回来
    foreach ($svc in $wasRunning) {
        try {
            Start-Service -Name $svc -ErrorAction Stop
            Write-Host ("    已恢复服务: {0}" -f $svc) -ForegroundColor Green
        } catch {
            Write-Host ("    恢复服务 {0} 失败: {1}" -f $svc, $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    if ($failed -gt 0) { return ('警告：已清理 {0} 项，{1} 项未能删除（可能被占用），服务已恢复' -f $deleted, $failed) }
    return ('成功：已清理更新下载缓存 {0} 项，服务已恢复' -f $deleted)
}

function Invoke-RebuildIconCache {
    Write-Host '    提示: 重启资源管理器时桌面与任务栏会闪一下（短暂消失后自动恢复）。' -ForegroundColor Yellow

    $targets = New-Object System.Collections.Generic.List[string]
    $iconDb = Join-Path $env:LOCALAPPDATA 'IconCache.db'
    if (Test-Path -LiteralPath $iconDb) { $targets.Add($iconDb) }
    $thumbDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
    if (Test-Path -LiteralPath $thumbDir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $thumbDir -Filter 'thumbcache_*.db' -Force -ErrorAction SilentlyContinue)) {
            $targets.Add($f.FullName)
        }
    }
    Write-Host ("    找到 {0} 个图标/缩略图缓存文件。" -f $targets.Count) -ForegroundColor DarkGray

    $deleted = 0
    $locked  = 0
    foreach ($f in $targets) {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $f) { $locked++ } else { $deleted++ }
    }
    Write-Host ("    已删除 {0} 个，{1} 个被占用（更新系统后 Windows 会自动重建缓存）。" -f $deleted, $locked) -ForegroundColor DarkGray

    Write-Host '    正在重启资源管理器（桌面会闪一下）…' -ForegroundColor DarkGray
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
    Start-Process explorer -ErrorAction SilentlyContinue
    Write-Host '    资源管理器已重新启动。' -ForegroundColor DarkGray

    if ($targets.Count -eq 0) { return '警告：未找到图标/缩略图缓存文件，资源管理器已重启' }
    if ($locked -gt 0) { return ('完成：已删除 {0} 个缓存文件（{1} 个被占用未删除），资源管理器已重启' -f $deleted, $locked) }
    return ('成功：已删除 {0} 个图标/缩略图缓存并重启资源管理器' -f $deleted)
}

# ---------------- 执行与汇总 ----------------
$script:Results = New-Object System.Collections.Generic.List[object]
$script:ExecutedKeys = New-Object System.Collections.Generic.List[string]

function Invoke-Step([string]$Title, [scriptblock]$Body) {
    Write-Host ''
    Write-Host (" >> 执行：{0}" -f $Title) -ForegroundColor Cyan
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $status = '完成'
    try {
        $status = [string](& $Body)
        if (-not $status) { $status = '完成（无输出）' }
    } catch {
        $status = ('失败：{0}' -f $_.Exception.Message)
    }
    $sw.Stop()
    $color = 'Green'
    if ($status -like '失败*') { $color = 'Red' }
    elseif ($status -like '警告*' -or $status -like '跳过*') { $color = 'Yellow' }
    Write-Host ("    结果: {0}" -f $status) -ForegroundColor $color
    Write-Host ("    耗时: {0:N1} 秒" -f $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray
    $script:Results.Add([pscustomobject]@{
        项目 = $Title
        结果 = $status
        耗时 = ('{0:N1} 秒' -f $sw.Elapsed.TotalSeconds)
    })
    return $status
}

Write-Title '开始执行'

foreach ($item in $items) {
    if (-not $selected[$item.Key]) { continue }
    $title = ('{0}（{1}）' -f $item.Name, $item.Switch)

    # 需要管理员却不是管理员：明确提示，不静默失败
    if ($item.Admin -and -not $isAdmin) {
        Write-Host ''
        Write-Host (" >> 跳过：{0}" -f $title) -ForegroundColor Yellow
        Write-Host '    需要管理员权限，当前不是管理员，未执行。' -ForegroundColor Red
        Write-Host '    请点图形工具台右上角的「以管理员身份重启」，再重新运行本项。' -ForegroundColor Yellow
        $script:Results.Add([pscustomobject]@{
            项目 = $title
            结果 = '跳过：需要管理员权限'
            耗时 = '-'
        })
        continue
    }

    # 危险项必须先确认
    if ($item.Danger) {
        if (-not (Confirm-Danger $item.Switch $item.Risk)) {
            $script:Results.Add([pscustomobject]@{
                项目 = $title
                结果 = '取消：用户未确认'
                耗时 = '-'
            })
            continue
        }
    }

    $body = $null
    switch ($item.Key) {
        'Sfc'              { $body = { Invoke-Sfc } }
        'Dism'             { $body = { Invoke-Dism } }
        'FlushDns'         { $body = { Invoke-FlushDns } }
        'ResetNetwork'     { $body = { Invoke-ResetNetwork } }
        'ClearUpdateCache' { $body = { Invoke-ClearUpdateCache } }
        'RebuildIconCache' { $body = { Invoke-RebuildIconCache } }
    }
    if ($body) {
        Invoke-Step $title $body | Out-Null
        [void]$script:ExecutedKeys.Add($item.Key)
    }
}

# ---------------- 汇总 ----------------
Write-Title '执行结果汇总'
$script:Results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

$okCount   = @($script:Results | Where-Object { $_.结果 -like '成功*' -or $_.结果 -like '完成*' }).Count
$warnCount = @($script:Results | Where-Object { $_.结果 -like '警告*' }).Count
$failCount = @($script:Results | Where-Object { $_.结果 -like '失败*' }).Count
$skipCount = @($script:Results | Where-Object { $_.结果 -like '跳过*' -or $_.结果 -like '取消*' }).Count

$sumColor = 'Green'
if ($failCount -gt 0) { $sumColor = 'Red' }
elseif ($warnCount -gt 0 -or $skipCount -gt 0) { $sumColor = 'Yellow' }
Write-Host (" 完成 {0} 项 / 警告 {1} 项 / 失败 {2} 项 / 跳过或取消 {3} 项。" -f `
    $okCount, $warnCount, $failCount, $skipCount) -ForegroundColor $sumColor

Write-Title '结论与建议'
$adminSkipCount = @($script:Results | Where-Object { $_.结果 -like '跳过：需要管理员权限' }).Count
$cancelCount    = @($script:Results | Where-Object { $_.结果 -like '取消*' }).Count
if ($adminSkipCount -gt 0) {
    Write-Host (" 有 {0} 项因权限不足被跳过：请点图形工具台右上角的「以管理员身份重启」，然后重新运行。" -f $adminSkipCount) -ForegroundColor Yellow
}
if ($cancelCount -gt 0) {
    Write-Host (" 有 {0} 项被取消，未做任何改动。" -f $cancelCount) -ForegroundColor DarkGray
}
if ($failCount -gt 0) {
    Write-Host ' 存在失败项：请查看上方各项输出；提权类失败请以管理员身份重新运行。' -ForegroundColor Red
}
if ($script:ExecutedKeys -contains 'ResetNetwork') {
    Write-Host ' 网络已重置：请重启电脑后网络才会完全恢复正常。' -ForegroundColor Yellow
}
if ($script:ExecutedKeys -contains 'ClearUpdateCache') {
    Write-Host ' 更新缓存已清理：下次检查更新会重新下载，属正常现象。' -ForegroundColor DarkGray
}
if ($script:ExecutedKeys -contains 'RebuildIconCache') {
    Write-Host ' 图标缓存已重建：若个别图标仍异常，注销或重启一次即可。' -ForegroundColor DarkGray
}
if ($script:ExecutedKeys -contains 'Sfc' -or $script:ExecutedKeys -contains 'Dism') {
    Write-Host ' 系统文件/映像修复日志: %windir%\Logs\CBS\CBS.log 与 %windir%\Logs\DISM\dism.log' -ForegroundColor DarkGray
}
if ($okCount -eq $script:Results.Count) {
    Write-Host ' 全部选中项目均已成功执行完毕。' -ForegroundColor Green
}
Write-Host ''
