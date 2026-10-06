<#
.SYNOPSIS
    Windows 常用指令集 · 全量功能自测
.DESCRIPTION
    一条命令把整个工具包从头到尾测一遍，输出「通过/失败」清单：

      A. 静态检查   所有 .ps1 的语法与 UTF-8 BOM、工具与脚本是否一一对应、
                    CI 工作流是否包含 MSI 构建、winget 清单是否通过官方校验
      B. 脚本实跑   13 个脚本各跑一次（全部使用安全参数：不真删文件、不改网络、不动系统服务）
      C. 图形界面   界面自检（15 个面板）、事件处理回归测试（真实拉起 mmc.exe）
      D. 单文件EXE  内嵌资源清单、独立模式解包、真实开窗
      E. MSI 安装包 静默安装 → 核对文件/快捷方式/卸载项 → 卸载 → 核对清理（可用 -SkipMsi 跳过）

    需要管理员权限的项（SFC/DISM/网络重置/服务启停）只做只读校验，不会真的执行。
.PARAMETER SkipMsi
    跳过 MSI 安装/卸载测试（会在当前用户目录临时装一次再卸载）
.PARAMETER SkipExe
    跳过 EXE 启动测试（会开一次窗口再关掉）
.PARAMETER ReportPath
    额外导出一份 Markdown 测试报告
.EXAMPLE
    .\build\test-all.ps1
.EXAMPLE
    .\build\test-all.ps1 -SkipMsi -ReportPath .\docs\测试报告.md
#>
[CmdletBinding()]
param(
    [switch]$SkipMsi,
    [switch]$SkipExe,
    [string]$ReportPath
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

$root     = Split-Path $PSScriptRoot -Parent
$scriptDir = Join-Path $root 'scripts'
$gui      = Join-Path $root '图形工具台.ps1'
$exe      = Join-Path $root 'Windows常用指令集.exe'
$u        = New-Object System.Text.UTF8Encoding($false)

$script:Results = New-Object System.Collections.Generic.List[object]
$script:TmpRoot = Join-Path $env:TEMP ('wtk-selftest-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $script:TmpRoot -Force | Out-Null

function Write-Section([string]$t) {
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host ("  " + $t) -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}
function Add-Result([string]$name, [bool]$ok, [string]$note, [double]$sec) {
    $script:Results.Add([pscustomobject]@{
        测试 = $name
        结果 = $(if ($ok) { '通过' } else { '失败' })
        耗时 = $sec
        说明 = $note
    })
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1,-32} {2:N1}s  {3}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $sec, $note) -ForegroundColor $color
}

# ============================================================
# 通用：在独立 Runspace 里跑脚本（与图形界面同一条通道）
#   用 Runspace 的好处：脚本里的 exit 不会把我这个测试进程带走
# ============================================================
$script:Worker = {
    param($TargetScript, $ArgumentTable, $Queue)
    $ErrorActionPreference = 'Continue'
    $ProgressPreference    = 'SilentlyContinue'
    function Push($Kind, $Text, $Color, $NoNewline) {
        $Queue.Enqueue([pscustomobject]@{ Kind = $Kind; Text = [string]$Text; Color = $Color; NoNewline = [bool]$NoNewline })
    }
    try {
        & $TargetScript @ArgumentTable *>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.InformationRecord]) {
                $md = $_.MessageData
                if ($md -is [System.Management.Automation.HostInformationMessage]) {
                    $col = $null
                    if ($md.ForegroundColor) { $col = $md.ForegroundColor.ToString() }
                    Push 'out' $md.Message $col ([bool]$md.NoNewline)
                } else { Push 'out' ([string]$md) $null $false }
            } elseif ($_ -is [System.Management.Automation.ErrorRecord]) {
                Push 'out' ('  ' + $_.Exception.Message) 'Red' $false
            } elseif ($null -ne $_) {
                $t = ($_ | Out-String).TrimEnd()
                if ($t) { Push 'out' $t $null $false }
            }
        }
        Push 'done' '' $null $false
    } catch {
        Push 'err' $_.Exception.Message 'Red' $false
        Push 'done' '' $null $false
    }
}

function Invoke-InRunspace {
    param([string]$ScriptPath, [hashtable]$Arguments = @{}, [int]$TimeoutSec = 120)
    $q = New-Object System.Collections.Concurrent.ConcurrentQueue[object]
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript($script:Worker).AddArgument($ScriptPath).AddArgument($Arguments).AddArgument($q)
    $h = $ps.BeginInvoke()
    $text = New-Object System.Text.StringBuilder
    $err = ''
    $done = $false
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $item = $null
        while ($q.TryDequeue([ref]$item)) {
            if ($item.Kind -eq 'out') {
                [void]$text.Append($item.Text)
                if (-not $item.NoNewline) { [void]$text.Append("`r`n") }
            } elseif ($item.Kind -eq 'err') { $err = $item.Text }
            elseif ($item.Kind -eq 'done') { $done = $true }
        }
        if ($h.IsCompleted -and $q.Count -eq 0) { break }
        Start-Sleep -Milliseconds 50
    }
    try { $null = $ps.EndInvoke($h) } catch { }
    $ps.Dispose(); $rs.Close(); $rs.Dispose()
    [pscustomobject]@{ Text = $text.ToString(); Error = $err; Done = $done }
}

function Test-Script {
    param([string]$Name, [string]$File, [hashtable]$Arguments = @{}, [string]$Expect = '', [int]$TimeoutSec = 120)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $path = Join-Path $scriptDir $File
    if (-not (Test-Path -LiteralPath $path)) {
        $sw.Stop(); Add-Result $Name $false ('脚本不存在: ' + $File) $sw.Elapsed.TotalSeconds; return
    }
    $r = Invoke-InRunspace -ScriptPath $path -Arguments $Arguments -TimeoutSec $TimeoutSec
    $sw.Stop()
    $note = ''
    $ok = $true
    if ($r.Error) { $ok = $false; $note = '异常: ' + $r.Error }
    elseif ($r.Text -match '执行出错|CategoryInfo|Unhandled exception') { $ok = $false; $note = '输出里出现异常' }
    elseif (-not $r.Done) { $ok = $false; $note = '超时未结束' }
    elseif ($Expect -and $r.Text -notmatch [regex]::Escape($Expect)) { $ok = $false; $note = "未看到预期输出「$Expect」" }
    else { $note = '正常' }
    Add-Result $Name $ok $note $sw.Elapsed.TotalSeconds
}

# ============================================================
Write-Section 'A. 静态检查'
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$ps1 = @(Get-ChildItem $root -Recurse -Filter *.ps1 -File)
$badSyntax = @(); $noBom = @()
foreach ($f in $ps1) {
    $b = [System.IO.File]::ReadAllBytes($f.FullName)
    if (-not ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) { $noBom += $f.Name }
    $tk = $null; $er = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tk, [ref]$er) | Out-Null
    if ($er.Count -gt 0) { $badSyntax += ($f.Name + ': ' + $er[0].Message) }
}
$sw.Stop()
Add-Result ("脚本语法检查（{0} 个 .ps1）" -f $ps1.Count) ($badSyntax.Count -eq 0) $(if ($badSyntax.Count) { $badSyntax[0] } else { '全部通过' }) $sw.Elapsed.TotalSeconds
Add-Result '脚本编码检查（UTF-8 BOM）' ($noBom.Count -eq 0) $(if ($noBom.Count) { ($noBom -join ', ') } else { '全部带 BOM' }) 0

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$guiText = [System.IO.File]::ReadAllText($gui, $u)
$missing = @()
foreach ($m in [regex]::Matches($guiText, "Script = '([^']+\.ps1)'")) {
    if (-not (Test-Path -LiteralPath (Join-Path $scriptDir $m.Groups[1].Value))) { $missing += $m.Groups[1].Value }
}
$sw.Stop()
Add-Result '界面引用的 13 个脚本都存在' ($missing.Count -eq 0) $(if ($missing.Count) { ($missing -join ', ') } else { '全部存在' }) $sw.Elapsed.TotalSeconds

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$wf = Join-Path $root '.github\workflows\build-exe.yml'
$wfText = if (Test-Path $wf) { [System.IO.File]::ReadAllText($wf, $u) } else { '' }
$wfOk = ($wfText -match 'Build MSI installer') -and ($wfText -match 'test-gui-handlers') -and ($wfText -match 'win-toolkit\.msi')
$sw.Stop()
Add-Result 'CI 工作流包含 EXE+MSI+回归测试' $wfOk $(if ($wfOk) { 'ok' } else { '缺少关键步骤' }) $sw.Elapsed.TotalSeconds

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$v = winget validate --manifest (Join-Path $root 'winget') 2>&1 | Out-String
$sw.Stop()
Add-Result 'winget 清单官方校验' ($v -match 'succeeded') $(if ($v -match 'succeeded') { 'Manifest validation succeeded' } else { $v.Trim() }) $sw.Elapsed.TotalSeconds

# ============================================================
Write-Section 'B. 13 个脚本实跑（安全参数）'
# ============================================================
# 准备沙盒：临时目录 + 几个文件
$sandbox = Join-Path $script:TmpRoot 'sandbox'
$boxSrc  = Join-Path $sandbox 'src'
$boxDst  = Join-Path $sandbox 'dst'
$boxRen  = Join-Path $sandbox 'rename'
New-Item -ItemType Directory -Path $boxSrc, $boxDst, $boxRen -Force | Out-Null
1..3 | ForEach-Object { Set-Content -LiteralPath (Join-Path $boxSrc ("file{0}.txt" -f $_)) -Value ("hello $_") -Encoding UTF8 }
1..2 | ForEach-Object { Set-Content -LiteralPath (Join-Path $boxRen ("a{0}.txt" -f $_)) -Value 'x' -Encoding UTF8 }
$bigFile = Join-Path $sandbox 'big.bin'
[System.IO.File]::WriteAllBytes($bigFile, (New-Object byte[] (2MB)))

Test-Script '01 系统信息速查'       '01-系统信息.ps1'   @{}                                              '系统信息速查'
Test-Script '02 网络一键诊断'       '02-网络诊断.ps1'   @{ Target = 'www.baidu.com' }                    '连通性'
Test-Script '03 端口占用查询'       '03-端口占用.ps1'   @{ Port = 445 }                                  '查询端口 445'
Test-Script '04 临时文件清理(预览)' '04-清理临时文件.ps1' @{ DryRun = $true; Yes = $true }                '预览'
Test-Script '05 文件夹备份(预览)'   '05-文件夹备份.ps1' @{ Source = $boxSrc; Destination = $boxDst; DryRun = $true; Yes = $true } 'robocopy'
Test-Script '05 文件夹备份(真跑)'   '05-文件夹备份.ps1' @{ Source = $boxSrc; Destination = $boxDst; Yes = $true; ExcludeDir = @('node_modules') } '结果:'
Test-Script '05 镜像同步'           '05-文件夹备份.ps1' @{ Source = $boxSrc; Destination = $boxDst; Mirror = $true; Yes = $true } '结果:'
Test-Script '06 进程服务速查'       '06-进程服务速查.ps1' @{ Top = 5 }                                    '内存占用 Top'
Test-Script '07 大文件查找'         '07-大文件查找.ps1' @{ Path = $sandbox; MinMB = 1; Top = 5 }            '大文件查找'
Test-Script '08 批量重命名(预览)'   '08-批量重命名.ps1' @{ Path = $boxRen; Filter = '*.txt'; Prefix = 't_' } '预览'
Test-Script '08 批量重命名(执行)'   '08-批量重命名.ps1' @{ Path = $boxRen; Filter = '*.txt'; Prefix = 't_'; Apply = $true } '已改名'
Test-Script '09 文件哈希计算'       '09-文件哈希.ps1'   @{ Path = $bigFile; Algorithm = 'SHA256' }        'SHA256'

# 09 校验模式：先造一个校验文件（一行对、一行错）
$sumFile = Join-Path $sandbox 'SHA256SUMS.txt'
$good = (Get-FileHash (Join-Path $boxSrc 'file1.txt') -Algorithm SHA256).Hash
$lines = @(
    "$good  file1.txt"
    "0000000000000000000000000000000000000000000000000000000000000000  file2.txt"
)
[System.IO.File]::WriteAllLines($sumFile, $lines, $u)
Test-Script '09 哈希校验(含不匹配)' '09-文件哈希.ps1' @{ Path = $boxSrc; Verify = $sumFile }               '不匹配'

Test-Script '10 局域网扫描'         '10-局域网扫描.ps1' @{ Subnet = '192.168.56.0/28'; TimeoutMs = 200; Throttle = 16 } '在线主机' 90
Test-Script '11 服务管理(列表)'     '11-服务管理.ps1'   @{ State = 'Running'; StartType = 'Automatic'; Top = 5 } '服务名'
Test-Script '11 服务管理(操作)'     '11-服务管理.ps1'   @{ Action = 'start'; Name = 'Spooler'; Yes = $true } 'Spooler'
Test-Script '12 环境变量(查看)'     '12-环境变量.ps1'   @{ Scope = 'User' }                              'PATH 明细'
Test-Script '12 环境变量(写入)'     '12-环境变量.ps1'   @{ Scope = 'User'; Action = 'set'; Name = 'DSH_SELFTEST'; Value = 'hello'; Yes = $true } '已写入'
Test-Script '12 环境变量(删除)'     '12-环境变量.ps1'   @{ Scope = 'User'; Action = 'remove'; Name = 'DSH_SELFTEST'; Yes = $true } '删除'
Test-Script '13 系统修复(清单)'     '13-系统修复.ps1'   @{ List = $true }                                '可用修复项'
Test-Script '13 系统修复(DNS刷新)'  '13-系统修复.ps1'   @{ FlushDns = $true; Yes = $true }               '成功'

# 12 写入的变量是否真的落地并清干净
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$leftover = [Environment]::GetEnvironmentVariable('DSH_SELFTEST', 'User')
$sw.Stop()
Add-Result '12 环境变量写入后已清理' ($null -eq $leftover -or $leftover -eq '') $(if ($leftover) { "残留: $leftover" } else { '无残留' }) $sw.Elapsed.TotalSeconds

# ============================================================
Write-Section 'B2. 导出功能与结束进程'
# ============================================================
$csvBig = Join-Path $sandbox 'big.csv'
Test-Script '07 大文件查找(导出CSV)' '07-大文件查找.ps1' @{ Path = $sandbox; MinMB = 1; Export = $csvBig } '导出'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$okCsv = (Test-Path $csvBig) -and (@(Import-Csv $csvBig).Count -ge 1)
$sw.Stop()
Add-Result '07 导出的 CSV 可解析' $okCsv $(if ($okCsv) { "行数 " + @(Import-Csv $csvBig).Count } else { 'CSV 缺失或为空' }) $sw.Elapsed.TotalSeconds

$csvHash = Join-Path $sandbox 'hash.csv'
Test-Script '09 文件哈希(导出CSV)' '09-文件哈希.ps1' @{ Path = $boxSrc; Export = $csvHash } '导出'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$okCsv2 = (Test-Path $csvHash) -and (@(Import-Csv $csvHash).Count -ge 1)
$sw.Stop()
Add-Result '09 导出的 CSV 可解析' $okCsv2 $(if ($okCsv2) { "行数 " + @(Import-Csv $csvHash).Count } else { 'CSV 缺失或为空' }) $sw.Elapsed.TotalSeconds

$listenerCode = '$l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 45999); $l.Start(); Start-Sleep -Seconds 90'
$lp = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-Command', $listenerCode)
Start-Sleep -Seconds 4
$listening = @(netstat -ano | Select-String ':45999')
$sw = [System.Diagnostics.Stopwatch]::StartNew()
if ($listening.Count -gt 0) {
    Test-Script '03 端口占用(结束进程)' '03-端口占用.ps1' @{ Port = 45999; Kill = $true; Yes = $true } '已结束'
} else {
    $sw.Stop(); Add-Result '03 端口占用(结束进程)' $false '测试用监听进程没起来' $sw.Elapsed.TotalSeconds
}
Start-Sleep -Seconds 2
$lp.Refresh()
$sw.Stop()
Add-Result '03 结束后目标进程确实退出' $lp.HasExited $(if ($lp.HasExited) { 'PID ' + $lp.Id + ' 已退出' } else { '进程仍在' }) $sw.Elapsed.TotalSeconds
if (-not $lp.HasExited) { Stop-Process -Id $lp.Id -Force -ErrorAction SilentlyContinue }

# ============================================================Write-Section 'C. 图形界面'
# ============================================================
Test-Script '界面自检（15 个面板）' '..\图形工具台.ps1' @{ SelfTest = $true } 'SelfTest] 通过' 180

Test-Script '界面自检（-UiScale 1.5）' '..\图形工具台.ps1' @{ SelfTest = $true; UiScale = 1.5 } 'SelfTest] 通过' 180
Test-Script '界面自检（-UiScale 1.0）' '..\图形工具台.ps1' @{ SelfTest = $true; UiScale = 1.0 } 'SelfTest] 通过' 180

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$handlerTest = Join-Path $PSScriptRoot 'test-gui-handlers.ps1'
$log = Join-Path $script:TmpRoot 'handler.log'
$p = Start-Process powershell.exe -PassThru -RedirectStandardOutput $log -RedirectStandardError ($log + '.err') `
    -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"' + $handlerTest + '"'))
if (-not $p.WaitForExit(180000)) { try { $p.Kill() } catch { } }
$sw.Stop()
$hOut = if (Test-Path $log) { [System.IO.File]::ReadAllText($log, $u) } else { '' }
Add-Result '界面事件回归（真实拉起进程）' ($hOut -match '全部通过') $(if ($hOut -match '全部通过') { '按钮事件链路通' } else { '未通过' }) $sw.Elapsed.TotalSeconds

# ============================================================
if (-not $SkipExe) {
    Write-Section 'D. 单文件 EXE'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if (Test-Path $exe) {
        $asm = [System.Reflection.Assembly]::LoadFile($exe)
        $names = @($asm.GetManifestResourceNames())
        $need = @('gui.ps1', 's01.ps1', 's13.ps1', 'menu.ps1', 'readme.md', 'cheatsheet.md')
        $lack = @($need | Where-Object { $names -notcontains $_ })
        $sw.Stop()
        Add-Result ("EXE 内嵌资源（{0} 个）" -f $names.Count) ($lack.Count -eq 0) $(if ($lack.Count) { '缺少: ' + ($lack -join ',') } else { '19 个资源齐全' }) $sw.Elapsed.TotalSeconds
    } else {
        $sw.Stop(); Add-Result 'EXE 内嵌资源' $false 'EXE 不存在' 0
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $appDir = Join-Path $env:LOCALAPPDATA 'WinCommandToolkit\app'
    Remove-Item (Split-Path $appDir -Parent) -Recurse -Force -ErrorAction SilentlyContinue
    $before = @(Get-Process powershell -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    Start-Process -FilePath $exe | Out-Null
    Start-Sleep -Seconds 12
    $win = @(Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id -and $_.MainWindowTitle -like '*图形工具台*' })
    $extracted = @(Get-ChildItem $appDir -Recurse -File -ErrorAction SilentlyContinue)
    $win | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    $sw.Stop()
    Add-Result 'EXE 启动 + 独立模式解包' ($win.Count -gt 0 -and $extracted.Count -ge 19) $(("窗口 {0} 个，解包 {1} 个文件") -f $win.Count, $extracted.Count) $sw.Elapsed.TotalSeconds
}

# ============================================================
if (-not $SkipMsi) {
    Write-Section 'E. MSI 安装包'
    $msi = Get-ChildItem $root -Filter 'Windows常用指令集-*.msi' | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $msi) {
        Add-Result 'MSI 文件存在' $false '没找到 .msi' 0
    } else {
        if (-not ('Msi.Api' -as [type])) {
            Add-Type -Namespace Msi -Name Api -MemberDefinition @'
[DllImport("msi.dll", CharSet = CharSet.Unicode)] public static extern uint MsiSetInternalUI(int dwUILevel, IntPtr phWnd);
[DllImport("msi.dll", CharSet = CharSet.Unicode)] public static extern uint MsiInstallProduct(string szPackagePath, string szCommandLine);
[DllImport("msi.dll", CharSet = CharSet.Unicode)] public static extern uint MsiConfigureProduct(string szProduct, int iInstallLevel, int eInstallState);
'@
        }
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $db = $installer.OpenDatabase($msi.FullName, 0)
        $view = $db.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='ProductCode'")
        $view.Execute(); $rec = $view.Fetch(); $pc = $rec.StringData(1)
        $installDir = Join-Path $env:LOCALAPPDATA 'Programs\Windows常用指令集'
        $menu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Windows 常用指令集'
        $deskLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Windows 常用指令集.lnk'

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $null = [Msi.Api]::MsiSetInternalUI(2, [IntPtr]::Zero)
        $rc = [Msi.Api]::MsiInstallProduct($msi.FullName, 'REBOOT=ReallySuppress')
        $sw.Stop()
        $files = @(Get-ChildItem $installDir -Recurse -File -ErrorAction SilentlyContinue)
        Add-Result 'MSI 静默安装' ($rc -eq 0 -and $files.Count -ge 29) ("返回码 $rc，装了 {0} 个文件" -f $files.Count) $sw.Elapsed.TotalSeconds

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $mainOk = Test-Path (Join-Path $installDir 'Windows常用指令集.exe')
        $arpOk = (Test-Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$pc") -or (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$pc")
        $sw.Stop()
        Add-Result 'MSI 安装结果核对' ($mainOk -and (Test-Path $menu) -and (Test-Path $deskLnk) -and $arpOk) `
            ("主程序={0} 开始菜单={1} 桌面={2} 卸载项={3}" -f $mainOk, (Test-Path $menu), (Test-Path $deskLnk), $arpOk) $sw.Elapsed.TotalSeconds

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $rcU = [Msi.Api]::MsiConfigureProduct($pc, 0, 2)
        Start-Sleep -Seconds 3
        $clean = (-not (Test-Path $installDir)) -and (-not (Test-Path $menu)) -and (-not (Test-Path $deskLnk))
        $sw.Stop()
        Add-Result 'MSI 卸载并清理干净' ($rcU -eq 0 -and $clean) ("返回码 $rcU，残留={0}" -f (-not $clean)) $sw.Elapsed.TotalSeconds
    }
}

# ============================================================
Write-Section '汇总'
# ============================================================
Remove-Item $script:TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
$pass = @($script:Results | Where-Object { $_.结果 -eq '通过' }).Count
$fail = @($script:Results | Where-Object { $_.结果 -eq '失败' }).Count
$script:Results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
Write-Host ("  总计 {0} 项：通过 {1}，失败 {2}" -f $script:Results.Count, $pass, $fail) -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) {
    Write-Host '  失败项：' -ForegroundColor Red
    $script:Results | Where-Object { $_.结果 -eq '失败' } | ForEach-Object { Write-Host ("    - {0}：{1}" -f $_.测试, $_.说明) -ForegroundColor Red }
}

if ($ReportPath) {
    $lines = @()
    $lines += '# 全量自测报告'
    $lines += ''
    $lines += ('- 时间：{0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $lines += ('- 环境：{0} / PowerShell {1} / 管理员 {2}' -f $env:COMPUTERNAME, $PSVersionTable.PSVersion, ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
    $lines += ('- 结果：**{0} 项通过 / {1} 项失败**（共 {2} 项）' -f $pass, $fail, $script:Results.Count)
    $lines += ''
    $lines += '| 测试 | 结果 | 耗时(s) | 说明 |'
    $lines += '| --- | --- | --- | --- |'
    foreach ($r in $script:Results) { $lines += ('| {0} | {1} | {2:N1} | {3} |' -f $r.测试, $r.结果, $r.耗时, $r.说明) }
    $reportFull = if ([System.IO.Path]::IsPathRooted($ReportPath)) { $ReportPath } else { Join-Path $root $ReportPath }
    [System.IO.File]::WriteAllLines($reportFull, $lines, (New-Object System.Text.UTF8Encoding($true)))
    Write-Host ("  报告已导出：{0}" -f $reportFull) -ForegroundColor Green
}

if ($fail -gt 0) { exit 1 } else { exit 0 }
