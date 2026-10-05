<#
.SYNOPSIS
    查看与修改 Windows 环境变量（用户级 / 系统级），PATH 可安全追加与去重
.DESCRIPTION
    显示指定范围的环境变量，PATH 会按 ';' 拆开逐条列出并统计条数与总长度，
    过长（>2047）时提示风险。写入操作分 set / append / prepend / remove 四种，
    append 与 prepend 会先按 ';' 拆分并做大小写不敏感去重，避免重复项。
    修改 PATH 与删除变量都会先确认（图形界面可传 -Yes 跳过）。
    修改系统级变量需要管理员权限，否则会明确提示不会静默失败。
.PARAMETER Scope
    User（当前用户）/ Machine（本机系统）/ All（两者，默认）。
.PARAMETER Action
    show（默认）/ set / append / prepend / remove。
.PARAMETER Name
    变量名，写操作时必填。
.PARAMETER Value
    变量值，set / append / prepend 时必填；remove 不需要。
.PARAMETER Yes
    跳过交互确认（图形界面/自动化调用）。
.EXAMPLE
    .\12-环境变量.ps1
.EXAMPLE
    .\12-环境变量.ps1 -Scope User -Action show -Name Path
.EXAMPLE
    .\12-环境变量.ps1 -Scope User -Action append -Name Path -Value 'D:\tools\bin' -Yes
.EXAMPLE
    .\12-环境变量.ps1 -Scope User -Action set -Name DSH_TEST_VAR -Value hello
#>
[CmdletBinding()]
param(
    [ValidateSet('User', 'Machine', 'All')]
    [string]$Scope = 'All',
    [ValidateSet('show', 'set', 'remove', 'append', 'prepend')]
    [string]$Action = 'show',
    [string]$Name,
    [string]$Value,
    [switch]$Yes
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Write-Title([string]$Text) {
    $line = '=' * [Math]::Max(4, 58 - $Text.Length)
    Write-Host ''
    Write-Host "== $Text " -ForegroundColor Cyan -NoNewline
    Write-Host $line -ForegroundColor DarkCyan
}

# 显示用截断，避免个别变量把整屏刷掉
function Format-Value([object]$Text, [int]$Max = 120) {
    $s = "$Text"
    if ($s.Length -gt $Max) { return ($s.Substring(0, $Max) + ' …(共 ' + $s.Length + ' 字符)') }
    return $s
}

# 把 IDictionary 转成 Name/Value 对象数组
# 注意: 必须用 Write-Output -NoEnumerate 包住，否则哈希表会被外层 @() 当成单个对象
function ConvertTo-EnvItems([object]$Raw) {
    $list = New-Object System.Collections.Generic.List[object]
    if ($Raw -ne $null) {
        foreach ($k in $Raw.Keys) {
            $list.Add([pscustomobject]@{ Name = "$k"; Value = "$($Raw[$k])" })
        }
    }
    Write-Output -NoEnumerate ([object[]]$list.ToArray())
}

# 读某个范围的环境变量（Machine 读的是系统级注册表值，可能比当前会话更新）
function Get-EnvItems([string]$TargetScope) {
    if ($TargetScope -eq 'Machine') {
        $raw = [Environment]::GetEnvironmentVariables('Machine')
    } else {
        $raw = [Environment]::GetEnvironmentVariables('User')
    }
    return (ConvertTo-EnvItems $raw)
}

# 判断变量在该范围是否存在（存在但为空 与 不存在 要分开）
function Test-EnvExists([string]$VarName, [string]$TargetScope) {
    $v = [Environment]::GetEnvironmentVariable($VarName, $TargetScope)
    if ($null -eq $v) { return $false }
    return $true
}

function Split-EnvList([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return , @() }
    return , @($Text -split ';')
}

# 按 ';' 拆分并去重（大小写不敏感，保留首次出现的写法与顺序），空项丢弃
function Merge-PathValue([string]$OldValue, [string]$NewValue, [bool]$AtFront) {
    $items = New-Object System.Collections.Generic.List[string]
    $seen  = @{}
    $segments = @()
    if ($AtFront) {
        $segments += (Split-EnvList $NewValue)
        $segments += (Split-EnvList $OldValue)
    } else {
        $segments += (Split-EnvList $OldValue)
        $segments += (Split-EnvList $NewValue)
    }
    foreach ($seg in $segments) {
        if ($seg.Length -eq 0) { continue }
        $key = $seg.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $items.Add($seg)
        }
    }
    return ($items -join ';')
}

# ---------- 头部 ----------
Write-Host ''
Write-Host ' Windows 环境变量管理' -ForegroundColor White -BackgroundColor DarkBlue
Write-Host (" 范围: {0}   动作: {1}   管理员: {2}" -f `
    $Scope, $Action, $(if ($isAdmin) { '是' } else { '否' })) -ForegroundColor DarkGray
if ($Scope -ne 'User' -and -not $isAdmin) {
    Write-Host ' 注意: 非管理员运行，只能查看系统级变量；写入系统级会失败。' -ForegroundColor Yellow
}

# ================= show =================
if ($Action -eq 'show') {
    $targets = @()
    if ($Scope -eq 'User')         { $targets = @('User') }
    elseif ($Scope -eq 'Machine')  { $targets = @('Machine') }
    else                           { $targets = @('User', 'Machine') }

    $shownName = @{}
    foreach ($sc in $targets) {
        $label = if ($sc -eq 'User') { '当前用户 (User)' } else { '本机系统 (Machine)' }
        Write-Title $label

        $items = @(Get-EnvItems $sc | Sort-Object Name)
        if ($items.Count -eq 0) {
            Write-Host '   没有读到任何环境变量（可能被策略限制）。' -ForegroundColor Yellow
            continue
        }
        Write-Host ("   共 {0} 个变量" -f $items.Count) -ForegroundColor Yellow
        foreach ($it in $items) {
            $dup = ''
            if ($shownName.ContainsKey($it.Name.ToLowerInvariant())) { $dup = '  (与另一范围重名)' }
            $shownName[$it.Name.ToLowerInvariant()] = $true
            Write-Host ("   {0} = {1}{2}" -f $it.Name, (Format-Value $it.Value), $dup) -ForegroundColor DarkGray
        }

        # PATH 单独拆开细看
        $pathes = @($items | Where-Object { $_.Name -ieq 'PATH' })
        foreach ($pv in $pathes) {
            $v = "$($pv.Value)"
            $parts = @($v -split ';')
            $nonEmpty = @($parts | Where-Object { $_.Trim().Length -gt 0 })
            Write-Title ("PATH 明细 [{0}]" -f $sc)
            Write-Host ("   共 {0} 条（非空 {1} 条），字符串长度 {2} 字符" -f $parts.Count, $nonEmpty.Count, $v.Length) -ForegroundColor Yellow
            if ($v.Length -gt 300) {
                Write-Host ("   完整值: {0}" -f (Format-Value $v 300)) -ForegroundColor DarkGray
            }
            for ($i = 0; $i -lt $parts.Count; $i++) {
                $seg = $parts[$i]
                if ($seg.Trim().Length -eq 0) {
                    Write-Host ("   [{0,3}] (空项)" -f ($i + 1)) -ForegroundColor Red
                } else {
                    Write-Host ("   [{0,3}] {1}" -f ($i + 1), $seg) -ForegroundColor DarkGray
                }
            }
            if ($v.Length -gt 2047) {
                Write-Host '   警告: PATH 已超过 2047 字符，部分老程序读取时会被截断，建议精简。' -ForegroundColor Red
            } elseif ($v.Length -gt 1500) {
                Write-Host '   提醒: PATH 接近 2047 字符上限，建议留意清理无效路径。' -ForegroundColor Yellow
            } else {
                Write-Host '   长度正常（未接近 2047 字符上限）。' -ForegroundColor Green
            }
        }
    }

    Write-Host ''
    Write-Host ' 结论: 以上为当前环境变量快照；修改 PATH 前建议先导出备份。' -ForegroundColor Green
    Write-Host ''
    exit 0
}

# ================= 写操作的公共校验 =================
if ([string]::IsNullOrWhiteSpace($Name)) {
    Write-Host ''
    Write-Host (" 动作 {0} 必须指定变量名，例如：-Name Path" -f $Action) -ForegroundColor Red
    Write-Host ' 只有 show 可以不写 -Name。' -ForegroundColor DarkGray
    Write-Host ''
    exit 1
}
$Name = $Name.Trim()

if ($Scope -eq 'All') {
    Write-Host ''
    Write-Host ' 写操作必须明确范围，请用 -Scope User 或 -Scope Machine（不能是 All）。' -ForegroundColor Red
    Write-Host ''
    exit 1
}

if (($Action -eq 'set' -or $Action -eq 'append' -or $Action -eq 'prepend') -and [string]::IsNullOrEmpty($Value)) {
    Write-Host ''
    Write-Host (" 动作 {0} 必须提供 -Value，且不能为空字符串。" -f $Action) -ForegroundColor Red
    Write-Host ' 提示: 想清空某个变量请用 -Action remove。' -ForegroundColor DarkGray
    Write-Host ''
    exit 1
}

$isPath  = ($Name -ieq 'PATH')
$target  = if ($Scope -eq 'User') { 'User' } else { 'Machine' }
$scopeCn = if ($target -eq 'User') { '当前用户' } else { '本机系统' }

# 系统级写入必须管理员
if ($target -eq 'Machine' -and -not $isAdmin) {
    Write-Host ''
    Write-Host ' 无法修改系统级(Machine)变量：需要管理员权限运行。' -ForegroundColor Red
    Write-Host ' 建议: 右键「以管理员身份运行 Windows PowerShell」，再执行同一条命令；' -ForegroundColor DarkGray
    Write-Host '       或改用 -Scope User 只修改当前用户变量。' -ForegroundColor DarkGray
    Write-Host ''
    exit 1
}

# 删除也要先把旧值取出来，才能确认与展示
if ($Action -eq 'remove') {
    if (-not (Test-EnvExists $Name $target)) {
        Write-Host ''
        Write-Host (" {0} 范围里没有 {1}，无需删除。" -f $scopeCn, $Name) -ForegroundColor Yellow
        Write-Host ''
        exit 0
    }
}

$oldExists = Test-EnvExists $Name $target
$oldValue  = [Environment]::GetEnvironmentVariable($Name, $target)

# ---------- 危险操作确认 ----------
if (-not $Yes) {
    $needConfirm = $false
    if ($Action -eq 'remove') { $needConfirm = $true }
    if ($isPath -and ($Action -eq 'append' -or $Action -eq 'prepend' -or $Action -eq 'set')) { $needConfirm = $true }

    if ($needConfirm) {
        Write-Host ''
        if ($isPath) {
            Write-Host (" 即将修改 {0} 的 PATH（{1}）" -f $scopeCn, $Action) -ForegroundColor Yellow
            Write-Host ' 强烈建议先备份，出错时可整体还原：' -ForegroundColor DarkGray
            if ($target -eq 'User') {
                Write-Host ('   reg export "HKCU\Environment" "%USERPROFILE%\Desktop\env-user-backup.reg"') -ForegroundColor Yellow
            } else {
                Write-Host ('   reg export "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" "C:\env-machine-backup.reg"') -ForegroundColor Yellow
            }
        } else {
            Write-Host (" 即将删除 {0} 的变量 {1}" -f $scopeCn, $Name) -ForegroundColor Yellow
            Write-Host ("   当前值: {0}" -f (Format-Value $oldValue)) -ForegroundColor DarkGray
        }
        $answer = Read-Host ' 确认执行? 输入 y 继续'
        if ($answer -ne 'y') {
            Write-Host ' 已取消，未做任何修改。' -ForegroundColor DarkGray
            Write-Host ''
            exit 0
        }
    }
}

# ---------- 计算新值 ----------
$newValue  = $null
$deleteVar = $false

switch ($Action) {
    'set' {
        $newValue = $Value
    }
    'append' {
        $newValue = Merge-PathValue $oldValue $Value $false
    }
    'prepend' {
        $newValue = Merge-PathValue $oldValue $Value $true
    }
    'remove' {
        $deleteVar = $true
    }
}

# ---------- 写入 ----------
try {
    if ($deleteVar) {
        [Environment]::SetEnvironmentVariable($Name, $null, $target)
        # 再读一次确认真的删掉了
        $still = [Environment]::GetEnvironmentVariable($Name, $target)
        if ($null -ne $still) {
            Write-Host ''
            Write-Host (" 删除失败: {0} 仍然存在，当前值 {1}" -f $Name, (Format-Value $still)) -ForegroundColor Red
            Write-Host ' 可能原因: 权限不足、值被组策略/登录脚本重新写入。' -ForegroundColor DarkGray
            Write-Host ''
            exit 1
        }
        Write-Host ''
        Write-Host (" 已删除 {0} 的变量 {1}。" -f $scopeCn, $Name) -ForegroundColor Green
        Write-Host (" 原值: {0}" -f (Format-Value $oldValue)) -ForegroundColor DarkGray
    } else {
        if ($isPath -and $oldExists -and $oldValue) {
            $oldCount = @($oldValue -split ';').Count
            $newCount = @($newValue -split ';').Count
            if ($newCount -lt $oldCount -or $newCount -lt @($Value -split ';').Count) {
                Write-Host ("   去重: {0} 条 → {1} 条" -f $oldCount, $newCount) -ForegroundColor DarkGray
            }
        }
        [Environment]::SetEnvironmentVariable($Name, $newValue, $target)
        # 广播环境变更消息，让新开的进程尽快拿到新值（失败不影响结果）
        if (-not ('Win32.EnvBroadcast' -as [type])) {
            Add-Type -Namespace Win32 -Name EnvBroadcast -ErrorAction SilentlyContinue -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        }
        if ('Win32.EnvBroadcast' -as [type]) {
            $res = [UIntPtr]::Zero
            try {
                [void][Win32.EnvBroadcast]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 3000, [ref]$res)
            } catch { }
        }

        $check = [Environment]::GetEnvironmentVariable($Name, $target)
        Write-Host ''
        if ("$check" -eq "$newValue") {
            Write-Host (" 已写入 {0} 的变量 {1}（{2}）。" -f $scopeCn, $Name, $Action) -ForegroundColor Green
        } else {
            Write-Host (" 已执行 {0}，但回读值与预期不一致，请用 -Action show 复核。" -f $Action) -ForegroundColor Yellow
        }
        Write-Host ("   原值: {0}" -f $(if ($oldExists) { Format-Value $oldValue } else { '(不存在)' })) -ForegroundColor DarkGray
        Write-Host ("   新值: {0}" -f (Format-Value $newValue)) -ForegroundColor DarkGray
    }
} catch {
    Write-Host ''
    Write-Host (" 操作失败: {0}" -f $_.Exception.Message) -ForegroundColor Red
    if ($target -eq 'Machine') {
        Write-Host ' 系统级变量需要管理员权限，请以管理员身份重新运行本脚本。' -ForegroundColor Yellow
    } else {
        Write-Host ' 可能原因: 权限不足或变量被策略锁定。' -ForegroundColor DarkGray
    }
    Write-Host ''
    exit 1
}

Write-Host ''
Write-Host ' 提示: 环境变量对已打开的窗口无效，新开的窗口 / 重新登录后生效。' -ForegroundColor DarkGray
if ($isPath) {
    Write-Host ' 提示: 修改 PATH 后若程序仍找不到命令，请重启资源管理器或注销一次。' -ForegroundColor DarkGray
}
Write-Host ''
