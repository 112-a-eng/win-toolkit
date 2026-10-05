<#
.SYNOPSIS
    图形工具台事件处理回归测试
.DESCRIPTION
    专门盯一类曾经踩过的坑：按钮的事件脚本块引用了「函数局部变量」。

    Show-ToolPanel / New-FieldPanel 构建完按钮就返回了，局部变量随之销毁；
    如果事件里直接引用 $t / $target / $kind，触发时它们是 $null，
    表现为点击「系统工具面板」任意按钮弹出：
        「由于出现以下错误，无法运行此命令：系统找不到指定的文件。」

    正确做法是把目标写进控件自己的 Tag，事件里用 $sender 取。
    本脚本在无窗口模式下构建界面，用反射直接触发 Click 事件来验证这条链路。

.EXAMPLE
    .\build\test-gui-handlers.ps1
#>
[CmdletBinding()]
param(
    # CI 里用：只做结构与 Tag 检查，不真的拉起 mmc/notepad（runner 上更稳）
    [switch]$SkipLaunch
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root = Split-Path $PSScriptRoot -Parent
$gui  = Join-Path $root '图形工具台.ps1'
if (-not (Test-Path -LiteralPath $gui)) { throw "找不到 GUI 脚本: $gui" }

$script:Fail = 0
function Fail([string]$msg) {
    Write-Host ("  FAIL  " + $msg) -ForegroundColor Red
    $script:Fail++
}
function Pass([string]$msg) { Write-Host ("  OK    " + $msg) -ForegroundColor Green }

# 无窗口构建界面（-SelfTest 跑完自检后 return，不会 ShowDialog）
Write-Host '构建界面（-SelfTest）…' -ForegroundColor DarkGray
. $gui -SelfTest | Out-Null

# 反射取 Control.OnClick（PerformClick 在窗口未显示时会被 CanSelect 拦下）
$onClick = [System.Windows.Forms.Control].GetMethod('OnClick',
    [System.Reflection.BindingFlags]'NonPublic,Instance')
function Invoke-Click($btn) { $onClick.Invoke($btn, @([System.EventArgs]::Empty)) }

Write-Host ''
Write-Host '=== 1. 系统工具面板：每个按钮都必须带 Target ==='
$panelBtns = @($script:ParamFlow.Controls) | Where-Object { $_.Tag -is [string] -and $_.Tag }
Write-Host ("  面板按钮数: {0}" -f $panelBtns.Count)
if ($panelBtns.Count -lt 15) { Fail ("面板按钮数量异常: " + $panelBtns.Count) } else { Pass ("按钮数量正常: " + $panelBtns.Count) }
$noTag = @($panelBtns | Where-Object { -not $_.Tag })
if ($noTag.Count -gt 0) { Fail ("有 " + $noTag.Count + " 个按钮没设 Tag") } else { Pass '所有按钮都写入了 Tag' }

Write-Host ''
Write-Host '=== 2. 真实触发：点「事件查看器」应拉起 mmc.exe ==='
$evt = $panelBtns | Where-Object { $_.Tag -like '*eventvwr*' } | Select-Object -First 1
if ($SkipLaunch) {
    Write-Host '  （-SkipLaunch：跳过真实启动测试）' -ForegroundColor DarkGray
} elseif (-not $evt) {
    Fail '找不到 事件查看器 按钮'
} else {
    $before = @(Get-Process mmc -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    Write-Host ("  触发 [" + $evt.Text + "] -> " + $evt.Tag) -ForegroundColor DarkGray
    Invoke-Click $evt
    Start-Sleep -Seconds 7
    $new = @(Get-Process mmc -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id })
    if ($new.Count -gt 0) {
        Pass ("成功拉起 mmc.exe（PID " + ($new.Id -join ',') + "），事件链路通")
        $new | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    } else {
        Fail '没有拉起 mmc.exe（事件里拿到的目标很可能是 $null）'
    }
}

Write-Host ''
Write-Host '=== 3. 换一个目标再触发，确认读的是 Tag 而不是写死的值 ==='
$svc = $panelBtns | Where-Object { $_.Tag -like '*services.msc*' } | Select-Object -First 1
if ($SkipLaunch) {
    Write-Host '  （-SkipLaunch：跳过真实启动测试）' -ForegroundColor DarkGray
} elseif (-not $svc) {
    Fail '找不到 服务 按钮'
} else {
    $before = @(Get-Process mmc -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    $svc.Tag = 'notepad.exe'          # 临时改成无害目标
    Write-Host ("  把 [" + $svc.Text + "] 的 Tag 临时改为 notepad.exe 后触发") -ForegroundColor DarkGray
    Invoke-Click $svc
    Start-Sleep -Seconds 4
    $np = @(Get-Process notepad -ErrorAction SilentlyContinue)
    if ($np.Count -gt 0) {
        Pass ("成功拉起 notepad.exe（PID " + ($np.Id -join ',') + "），确认目标来自 Tag")
        $np | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    } else {
        Fail '没有拉起 notepad.exe'
    }
}

Write-Host ''
Write-Host '=== 4. 目录 / CSV 选择按钮（结构检查）==='
$idx = -1
for ($i = 0; $i -lt $script:Tools.Count; $i++) { if ($script:Tools[$i].Name -eq '大文件查找') { $idx = $i } }
if ($idx -lt 0) {
    Fail '找不到「大文件查找」工具'
} else {
    Show-ToolPanel $idx
    $dots = @($script:ParamFlow.Controls | ForEach-Object { $_.Controls } | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -eq '...' })
    Write-Host ("  「...」按钮数: {0}" -f $dots.Count)
    if ($dots.Count -lt 2) {
        Fail '没有找到选择按钮'
    } else {
        $badTag = @($dots | Where-Object { -not $_.Tag -or -not $_.Tag.Box -or -not $_.Tag.Kind })
        if ($badTag.Count -gt 0) {
            Fail ("有 " + $badTag.Count + " 个选择按钮的 Tag 不完整")
        } else {
            $kinds = ($dots | ForEach-Object { $_.Tag.Kind } | Select-Object -Unique) -join ','
            $boxes = ($dots | ForEach-Object { $_.Tag.Box.GetType().Name } | Select-Object -Unique) -join ','
            Pass ("Tag 完整：Kind=" + $kinds + "  Box=" + $boxes)
        }
    }
}

Write-Host ''
if ($script:Fail -eq 0) {
    Write-Host '全部通过 ✅' -ForegroundColor Green
    exit 0
} else {
    Write-Host ("失败 " + $script:Fail + " 项 ❌") -ForegroundColor Red
    exit 1
}
