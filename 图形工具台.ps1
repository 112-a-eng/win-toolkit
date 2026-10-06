<#
.SYNOPSIS
    Windows 常用指令集 · 图形工具台（WinForms 图形界面）
.DESCRIPTION
    纯 PowerShell + WinForms 实现，不需要安装任何组件，双击「启动图形工具台.bat」即可运行。
    左侧选择工具 -> 右侧填写参数 -> 点「运行」，下方实时彩色显示脚本输出。
    所有功能都调用同目录 scripts\ 下的命令行脚本，结果与命令行完全一致。
.PARAMETER SelfTest
    只构建界面并自检内部输出管线，不显示窗口（用于环境验证）。
.EXAMPLE
    .\图形工具台.ps1
.EXAMPLE
    .\图形工具台.ps1 -SelfTest
#>
[CmdletBinding()]
param(
    [switch]$SelfTest,
    # 界面缩放：默认 1.3（比原来的 9pt 明显大一圈）。
    # 还想更大就传 1.5，想还原成最初大小就传 1.0。布局结构不变，只是整体等比放大。
    [ValidateRange(0.8, 2.5)][double]$UiScale = 1.3
)

$ErrorActionPreference = 'Continue'

# ============================================================
# 0. 环境准备
# ============================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# WinForms 需要 STA 线程；若不是则以 STA 重新启动自己
if (-not $SelfTest -and [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"' + $PSCommandPath + '"')
    )
    return
}

$script:AppRoot    = $PSScriptRoot
$script:ScriptDir  = Join-Path $PSScriptRoot 'scripts'
if (-not (Test-Path -LiteralPath $script:ScriptDir)) { $script:ScriptDir = $PSScriptRoot }
# 「打开速查手册」优先打开命令速查正文（19 章）；老版本没有该文件时退回 README
$script:ReadmePath = Join-Path $PSScriptRoot 'docs\命令速查.md'
if (-not (Test-Path -LiteralPath $script:ReadmePath)) { $script:ReadmePath = Join-Path $PSScriptRoot 'README.md' }
[Environment]::CurrentDirectory = $script:AppRoot

# ============================================================
# 1. 配色与工具函数
# ============================================================
# 界面缩放：像素过 S()，字号过 FS()。布局结构保持不变，只是整体等比放大。
$script:Scale = $UiScale
function S([double]$v)  { return [int][Math]::Round($v * $script:Scale) }
function FS([double]$v) { return [single]($v * $script:Scale) }

$script:UiFont   = New-Object System.Drawing.Font('Microsoft YaHei UI', (FS 9))
$script:UiFontB  = New-Object System.Drawing.Font('Microsoft YaHei UI', (FS 9), [System.Drawing.FontStyle]::Bold)
$script:TitleFont = New-Object System.Drawing.Font('Microsoft YaHei UI', (FS 12), [System.Drawing.FontStyle]::Bold)
$script:MonoFont = New-Object System.Drawing.Font('Consolas', (FS 10))

function Get-HtmlColor([string]$hex) { return [System.Drawing.ColorTranslator]::FromHtml($hex) }

# 控制台颜色 -> 深色主题下的可读颜色
function Get-OutColor([string]$Name) {
    switch ($Name) {
        'Black'        { return (Get-HtmlColor '#6A6A6A') }
        'DarkBlue'     { return (Get-HtmlColor '#569CD6') }
        'DarkGreen'    { return (Get-HtmlColor '#4EC9B0') }
        'DarkCyan'     { return (Get-HtmlColor '#4FC1FF') }
        'DarkRed'      { return (Get-HtmlColor '#F48771') }
        'DarkMagenta'  { return (Get-HtmlColor '#C586C0') }
        'DarkYellow'   { return (Get-HtmlColor '#DCDCAA') }
        'Gray'         { return (Get-HtmlColor '#CCCCCC') }
        'DarkGray'     { return (Get-HtmlColor '#9A9A9A') }
        'Blue'         { return (Get-HtmlColor '#569CD6') }
        'Green'        { return (Get-HtmlColor '#6FE3A0') }
        'Cyan'         { return (Get-HtmlColor '#4FC1FF') }
        'Red'          { return (Get-HtmlColor '#F48771') }
        'Magenta'      { return (Get-HtmlColor '#C586C0') }
        'Yellow'       { return (Get-HtmlColor '#E5E510') }
        'White'        { return (Get-HtmlColor '#FFFFFF') }
        default        { return (Get-HtmlColor '#D4D4D4') }
    }
}

# ============================================================
# 2. 工具定义（决定左侧列表与右侧参数区）
# ============================================================
$script:Tools = @(
    @{
        Name = '系统信息速查'; Script = '01-系统信息.ps1'
        Desc = '操作系统 / CPU / 内存 / 磁盘 / 显卡 / 网络 / 开机时长 / 补丁'
        Fields = @()
    }
    @{
        Name = '网络一键诊断'; Script = '02-网络诊断.ps1'
        Desc = '网卡 -> IP/网关 -> 公网连通 -> DNS 解析 -> 目标连通 -> HTTP'
        Fields = @(
            @{ Name = 'Target';    Label = '测试目标';  Kind = 'text'; Default = 'www.baidu.com'; Width = 190 }
            @{ Name = 'DnsServer'; Label = '对比 DNS'; Kind = 'text'; Default = '223.5.5.5';      Width = 130 }
        )
    }
    @{
        Name = '端口占用查询'; Script = '03-端口占用.ps1'
        Desc = '查询端口被哪个进程占用；端口留空则列出全部监听端口'
        Fields = @(
            @{ Name = 'Port'; Label = '端口号(可空)'; Kind = 'int'; Width = 90 }
            @{ Name = 'Kill'; Label = '结束后台占用进程'; Kind = 'switch'; Danger = $true }
        )
    }
    @{
        Name = '临时文件清理'; Script = '04-清理临时文件.ps1'
        Desc = '清理用户/系统临时目录与各类缓存，建议先用「仅预览」看一眼'
        Fields = @(
            @{ Name = 'DryRun';             Label = '仅预览不删除';        Kind = 'switch'; Default = $true; DangerWhenUnchecked = $true }
            @{ Name = 'IncludeCrashDumps';  Label = '含崩溃转储/缩略图缓存'; Kind = 'switch' }
            @{ Name = 'IncludeRecycleBin';  Label = '清空回收站(不可恢复)';  Kind = 'switch'; Danger = $true }
            @{ Name = 'IncludeUpdateCache'; Label = '含更新缓存(需管理员)';  Kind = 'switch'; Danger = $true }
            @{ Name = 'DaysOld';            Label = '仅清理N天前(0=全部)';   Kind = 'int'; Default = '0'; Width = 60 }
        )
    }
    @{
        Name = '文件夹备份'; Script = '05-文件夹备份.ps1'
        Desc = 'robocopy 增量复制或镜像同步，自动写日志文件'
        Fields = @(
            @{ Name = 'Source';      Label = '源目录';   Kind = 'folder'; Mandatory = $true; Width = 210 }
            @{ Name = 'Destination'; Label = '目标目录'; Kind = 'folder'; Mandatory = $true; Width = 210 }
            @{ Name = 'Mirror';      Label = '镜像模式(删除目标多余文件)'; Kind = 'switch'; Danger = $true }
            @{ Name = 'DryRun';      Label = '仅预览不复制'; Kind = 'switch' }
            @{ Name = 'ExcludeDir';  Label = '排除目录(逗号分隔)'; Kind = 'list'; Default = 'node_modules,.git'; Width = 190 }
        )
    }
    @{
        Name = '进程/服务速查'; Script = '06-进程服务速查.ps1'
        Desc = '占内存/CPU Top 进程、异常自启服务、启动项、监听端口'
        Fields = @(
            @{ Name = 'Top'; Label = '显示条数'; Kind = 'int'; Default = '12'; Width = 60 }
        )
    }
    @{
        Name = '大文件查找'; Script = '07-大文件查找.ps1'
        Desc = '按体积与未修改天数查找大文件，可导出 CSV'
        Fields = @(
            @{ Name = 'Path';          Label = '扫描目录(可空=系统盘)'; Kind = 'folder'; Width = 210 }
            @{ Name = 'MinMB';         Label = '大于(MB)';   Kind = 'int'; Default = '100'; Width = 70 }
            @{ Name = 'Top';           Label = '显示条数';   Kind = 'int'; Default = '30';  Width = 60 }
            @{ Name = 'OlderThanDays'; Label = '未修改天数'; Kind = 'int'; Default = '0';   Width = 60 }
            @{ Name = 'Export';        Label = '导出 CSV';   Kind = 'savefile'; Width = 200 }
        )
    }
    @{
        Name = '批量重命名'; Script = '08-批量重命名.ps1'
        Desc = '加前缀/后缀、正则替换、加序号；默认只预览，勾选「真正执行」才改名'
        Fields = @(
            @{ Name = 'Path';    Label = '目录';        Kind = 'folder'; Default = '$AppRoot'; Width = 190 }
            @{ Name = 'Filter';  Label = '通配符';      Kind = 'text';   Default = '*';   Width = 90 }
            @{ Name = 'Prefix';  Label = '前缀';        Kind = 'text';   Width = 100 }
            @{ Name = 'Suffix';  Label = '后缀';        Kind = 'text';   Width = 100 }
            @{ Name = 'Replace'; Label = '正则(查找)';  Kind = 'text';   Width = 110 }
            @{ Name = 'With';    Label = '替换为';      Kind = 'text';   Width = 100 }
            @{ Name = 'Number';  Label = '序号起始(-1不加)'; Kind = 'int'; Default = '-1'; Width = 50 }
            @{ Name = 'Pad';     Label = '序号位数';    Kind = 'int';    Default = '3';  Width = 45 }
            @{ Name = 'Recurse'; Label = '含子目录';    Kind = 'switch' }
            @{ Name = 'Apply';   Label = '真正执行(默认仅预览)'; Kind = 'switch'; Danger = $true }
        )
    }
    @{
        Name = '文件哈希校验'; Script = '09-文件哈希.ps1'
        Desc = '计算文件哈希（MD5/SHA1/SHA256/SHA512），也可按校验文件逐项比对'
        Fields = @(
            @{ Name = 'Path';      Label = '文件或目录'; Kind = 'folder'; Mandatory = $true; Width = 210 }
            @{ Name = 'Algorithm'; Label = '算法';       Kind = 'choice'; Default = 'SHA256'; Width = 95; Options = @('MD5','SHA1','SHA256','SHA512') }
            @{ Name = 'Recurse';   Label = '目录递归';   Kind = 'switch' }
            @{ Name = 'Verify';    Label = '校验文件(可空)'; Kind = 'text'; Width = 210 }
            @{ Name = 'Export';    Label = '导出 CSV';   Kind = 'savefile'; Width = 190 }
        )
    }
    @{
        Name = '局域网扫描'; Script = '10-局域网扫描.ps1'
        Desc = '并发 ping 扫网段 + 读 ARP 表，列出在线主机；网段留空则自动识别本机所在 /24'
        Fields = @(
            @{ Name = 'Subnet';       Label = '网段(可空)'; Kind = 'text'; Default = ''; Width = 150 }
            @{ Name = 'TimeoutMs';    Label = '超时(ms)';   Kind = 'int';  Default = '500'; Width = 60 }
            @{ Name = 'Throttle';     Label = '并发数';     Kind = 'int';  Default = '64';  Width = 55 }
            @{ Name = 'ResolveNames'; Label = '反查主机名'; Kind = 'switch' }
            @{ Name = 'Export';       Label = '导出 CSV';   Kind = 'savefile'; Width = 190 }
        )
    }
    @{
        Name = '服务管理'; Script = '11-服务管理.ps1'
        Desc = '查询筛选服务，并可启动 / 停止 / 重启 / 修改启动类型（改动操作需确认）'
        Fields = @(
            @{ Name = 'Filter';    Label = '关键字(可空)'; Kind = 'text';   Default = '';      Width = 140 }
            @{ Name = 'State';     Label = '状态';         Kind = 'choice'; Default = 'All';   Width = 100; Options = @('All','Running','Stopped') }
            @{ Name = 'StartType'; Label = '启动类型';     Kind = 'choice'; Default = 'All';   Width = 115; Options = @('All','Automatic','Manual','Disabled') }
            @{ Name = 'Top';       Label = '显示条数';     Kind = 'int';    Default = '30';    Width = 55 }
            @{ Name = 'Action';    Label = '操作';         Kind = 'choice'; Default = 'none';  Width = 105; Options = @('none','start','stop','restart','disable','enable','auto'); DangerValues = @('stop','restart','disable') }
            @{ Name = 'Name';      Label = '服务名(操作时必填)'; Kind = 'text'; Default = ''; Width = 160 }
        )
    }
    @{
        Name = '环境变量'; Script = '12-环境变量.ps1'
        Desc = '查看 / 设置 / 删除用户级与系统级环境变量，PATH 追加会自动去重并提示风险'
        Fields = @(
            @{ Name = 'Scope';  Label = '范围';   Kind = 'choice'; Default = 'All';  Width = 100; Options = @('All','User','Machine') }
            @{ Name = 'Action'; Label = '动作';   Kind = 'choice'; Default = 'show'; Width = 105; Options = @('show','set','remove','append','prepend'); DangerValues = @('set','remove','append','prepend') }
            @{ Name = 'Name';   Label = '变量名'; Kind = 'text';   Default = '';     Width = 160 }
            @{ Name = 'Value';  Label = '变量值'; Kind = 'text';   Default = '';     Width = 220 }
        )
    }
    @{
        Name = '系统修复'; Script = '13-系统修复.ps1'
        Desc = 'SFC / DISM / DNS 刷新 / 网络重置 / 更新缓存 / 图标缓存 —— 多数需要管理员权限'
        Fields = @(
            @{ Name = 'List';             Label = '只列出可做的事';   Kind = 'switch'; Default = $true }
            @{ Name = 'FlushDns';         Label = '刷新 DNS 缓存';    Kind = 'switch' }
            @{ Name = 'Sfc';              Label = 'SFC 扫描(5-20分钟)'; Kind = 'switch' }
            @{ Name = 'Dism';             Label = 'DISM 修复(5-20分钟)'; Kind = 'switch' }
            @{ Name = 'ResetNetwork';     Label = '重置网络(需重启)'; Kind = 'switch'; Danger = $true }
            @{ Name = 'ClearUpdateCache'; Label = '清更新缓存';       Kind = 'switch'; Danger = $true }
            @{ Name = 'RebuildIconCache'; Label = '重建图标缓存';     Kind = 'switch'; Danger = $true }
        )
    }
    @{
        Name = '常用命令速查'; Kind = 'cheat'
        Desc = '常用 CMD / PowerShell 命令一览，点「运行」输出到下方'
        Fields = @()
    }
    @{
        Name = '系统工具面板'; Kind = 'panels'
        Desc = '一键打开 服务 / 设备管理器 / 磁盘管理 / 事件查看器 等系统面板'
        Fields = @()
    }
)

$script:CheatSheet = @'
================= 常用命令速查 =================
【文件目录】C:\> dir /a /s /b   |   cd /d D:\proj   |   md / rd /s /q
            copy / xcopy /E /I /H /Y   |   move   |   ren   |   del /f /q /s
            robocopy 源 目标 /MIR /Z /R:2 /W:2 /LOG:log.txt   <= 备份首选
            tree /f   |   attrib -h -r -s   |   mklink /D 链接 目标   |   where 命令
【系统信息】systeminfo   |   ver   |   hostname   |   whoami /groups
            driverquery /v   |   msinfo32   |   dxdiag   |   powercfg /batteryreport
            Get-ComputerInfo   |   Get-HotFix   |   (Get-CimInstance Win32_OperatingSystem)
【进程服务】tasklist   |   taskkill /PID 1234 /F   |   taskkill /IM notepad.exe /F /T
            sc query 服务名   |   sc config 服务名 start= disabled
            net start / net stop 服务名   |   Get-Process   |   Stop-Process -Name x -Force
            Get-Service | Where Status -eq Running
【网络排查】ipconfig /all   |   ipconfig /flushdns   |   ipconfig /release && ipconfig /renew
            ping -n 4 目标   |   ping -t 目标   |   tracert -d 目标   |   pathping 目标
            nslookup 域名 8.8.8.8   |   netstat -ano | findstr :8080
            route print   |   arp -a   |   netsh wlan show profiles
            netsh wlan show profile name="WiFi名" key=clear      <= 查已保存的 WiFi 密码
            netsh winsock reset   |   netsh int ip reset          <= 网络疑难重置
            Test-NetConnection 主机 -Port 443   |   curl.exe -I https://example.com
【磁盘修复】chkdsk C: /f /r   |   sfc /scannow   |   defrag C: /O   |   cleanmgr
            DISM /Online /Cleanup-Image /RestoreHealth            <= SFC 修不好时用
            Get-Volume   |   Get-Disk   |   Optimize-Volume -DriveLetter C -ReTrim
【用户权限】net user   |   net user 名字 密码 /add   |   net localgroup administrators 名字 /add
            runas /user:.\admin cmd   |   takeown /f 文件 /r /d y   |   icacls 文件 /grant 名字:F /t
            Get-LocalUser   |   Get-LocalGroupMember -Group Administrators
【注册策略】reg query / add / delete / export / import   |   regedit
            gpupdate /force   |   gpresult /h D:\gp.html   |   gpedit.msc
            set / setx 变量 值   |   $env:PATH   |   Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
【计划任务】schtasks /create /tn "任务名" /tr "程序" /sc daily /st 09:00 /ru SYSTEM /rl highest
            schtasks /query /tn "任务名" /v /fo LIST   |   schtasks /run /tn "任务名"
            Get-ScheduledTask   |   Start-ScheduledTask -TaskName 名字
【软件安装】winget search 7zip   |   winget install --id 7zip.7zip -e   |   winget upgrade --all
            choco install 包名   |   scoop install 包名   |   Get-AppxPackage *xbox* | Remove-AppxPackage
【电源关机】shutdown /s /t 60   |   shutdown /r /t 0   |   shutdown /a   |   shutdown /l   |   shutdown /h
            powercfg /a   |   powercfg /change monitor-timeout-ac 10   |   powercfg /sleepstudy
【远程传输】mstsc /v:192.168.1.10 /f   |   ssh 用户@主机 -p 22   |   scp 文件 用户@主机:/路径
            Enter-PSSession -ComputerName PC2   |   Invoke-Command -ComputerName PC2 -ScriptBlock { Get-Service }
            Get-ChildItem \\PC2\C$\Temp
【文本数据】find "错误" log.txt   |   findstr /s /i /n /c:"error" *.log   |   type a.txt | find /c /v ""
            Select-String -Path *.log -Pattern 'ERROR' -Context 1,2   |   fc a.txt b.txt
            Import-Csv data.csv | Where { [int]$_.age -gt 30 } | Export-Csv out.csv -NoTypeInformation
【压缩校验】tar -czf back.tar.gz D:\data   |   tar -xf back.tar.gz -C D:\restore
            Compress-Archive -Path D:\data\* -DestinationPath D:\back.zip -Force
            Expand-Archive -Path D:\back.zip -DestinationPath D:\restore -Force
            certutil -hashfile a.iso SHA256   |   Get-FileHash a.iso -Algorithm SHA256
【排障一条命令】
            系统文件坏 -> sfc /scannow 然后 DISM /Online /Cleanup-Image /RestoreHealth
            网页打不开 -> ipconfig /flushdns
            网络全异常 -> netsh winsock reset + netsh int ip reset 后重启
            更新失败   -> 停 wuauserv/bits，删 SoftwareDistribution\Download，再启动服务
            资源管理器卡 -> taskkill /IM explorer.exe /F && start explorer.exe
            打印无响应 -> net stop spooler && net start spooler
【快捷面板】Win+R 输入：services.msc  diskmgmt.msc  devmgmt.msc  eventvwr.msc  taskschd.msc
            compmgmt.msc  gpedit.msc  ncpa.cpl  appwiz.cpl  sysdm.cpl  firewall.cpl  powercfg.cpl
            control  shell:startup  %temp%  cleanmgr
================================================
'@

# ============================================================
# 3. 后台执行用的 Worker（在独立 Runspace 中运行目标脚本）
# ============================================================
$script:WorkerScript = @'
param($TargetScript, $ArgumentTable, $Queue)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

function Push($Kind, $Text, $Color, $NoNewline) {
    $Queue.Enqueue([pscustomobject]@{
        Kind = $Kind; Text = [string]$Text; Color = $Color; NoNewline = [bool]$NoNewline
    })
}

try {
    & $TargetScript @ArgumentTable *>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.InformationRecord]) {
            $md = $_.MessageData
            if ($md -is [System.Management.Automation.HostInformationMessage]) {
                $col = $null
                if ($md.ForegroundColor) { $col = $md.ForegroundColor.ToString() }
                Push 'out' $md.Message $col ([bool]$md.NoNewline)
            } else {
                Push 'out' ([string]$md) $null $false
            }
        } elseif ($_ -is [System.Management.Automation.ErrorRecord]) {
            Push 'out' ('  ' + $_.Exception.Message) 'Red' $false
        } elseif ($null -ne $_) {
            $t = ($_ | Out-String).TrimEnd()
            if ($t) { Push 'out' $t $null $false }
        }
    }
} catch {
    Push 'out' ('执行出错: ' + $_.Exception.Message) 'Red' $false
} finally {
    Push 'done' '' $null $false
}
'@

# ============================================================
# 4. 界面构建
# ============================================================
$script:FieldControls = @{}
$script:SelectedIndex = 0
$script:Running       = $false
$script:Queue         = $null
$script:PowerShell    = $null
$script:Runspace      = $null
$script:Handle        = $null
$script:StartTime     = Get-Date

$form = New-Object System.Windows.Forms.Form
$form.Text            = 'Windows 常用指令集 · 图形工具台'
$form.Size            = New-Object System.Drawing.Size((S 1020), (S 730))
$form.MinimumSize     = New-Object System.Drawing.Size((S 900), (S 620))
$form.StartPosition   = 'CenterScreen'
$form.Font            = $script:UiFont
$form.BackColor       = (Get-HtmlColor '#1E1E1E')
$form.ForeColor       = (Get-HtmlColor '#D4D4D4')
$script:Form = $form

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ---------- 顶部标题栏 ----------
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = (S 48)
$header.BackColor = (Get-HtmlColor '#2D2D30')

$title = New-Object System.Windows.Forms.Label
$title.Text = '  Windows 常用指令集 · 图形工具台'
$title.Font = $script:TitleFont
$title.ForeColor = (Get-HtmlColor '#FFFFFF')
$title.AutoSize = $false
$title.Dock = 'Left'
$title.Width = (S 460)
$title.TextAlign = 'MiddleLeft'
$header.Controls.Add($title)

$script:AdminButton = New-Object System.Windows.Forms.Button
$script:AdminButton.Text = '以管理员身份重启'
$script:AdminButton.Size = New-Object System.Drawing.Size((S 140), (S 30))
$script:AdminButton.FlatStyle = 'Flat'
$script:AdminButton.FlatAppearance.BorderColor = (Get-HtmlColor '#3F3F46')
$script:AdminButton.BackColor = (Get-HtmlColor '#3A3D41')
$script:AdminButton.ForeColor = (Get-HtmlColor '#FFFFFF')
$script:AdminButton.Anchor = 'Top,Right'
$script:AdminButton.Location = New-Object System.Drawing.Point(($form.ClientSize.Width - (S 300)), (S 9))
$header.Controls.Add($script:AdminButton)

$script:RoleLabel = New-Object System.Windows.Forms.Label
$script:RoleLabel.Text = $(if ($isAdmin) { '管理员' } else { '普通用户' })
$script:RoleLabel.ForeColor = $(if ($isAdmin) { Get-HtmlColor '#6FE3A0' } else { Get-HtmlColor '#DCDCAA' })
$script:RoleLabel.AutoSize = $false
$script:RoleLabel.Width = (S 140)
$script:RoleLabel.Height = (S 30)
$script:RoleLabel.TextAlign = 'MiddleRight'
$script:RoleLabel.Anchor = 'Top,Right'
$script:RoleLabel.Location = New-Object System.Drawing.Point(($form.ClientSize.Width - (S 160)), (S 9))
$header.Controls.Add($script:RoleLabel)
if ($isAdmin) { $script:AdminButton.Visible = $false }

# ---------- 左侧工具列表 ----------
$leftPanel = New-Object System.Windows.Forms.Panel
$leftPanel.Dock = 'Left'
$leftPanel.Width = (S 212)
$leftPanel.BackColor = (Get-HtmlColor '#252526')

$leftTitle = New-Object System.Windows.Forms.Label
$leftTitle.Text = '  选择工具'
$leftTitle.Dock = 'Top'
$leftTitle.Height = (S 30)
$leftTitle.TextAlign = 'MiddleLeft'
$leftTitle.ForeColor = (Get-HtmlColor '#9A9A9A')
$leftPanel.Controls.Add($leftTitle)

$list = New-Object System.Windows.Forms.ListBox
$list.Dock = 'Fill'
$list.BorderStyle = 'None'
$list.BackColor = (Get-HtmlColor '#252526')
$list.ForeColor = (Get-HtmlColor '#DDDDDD')
$list.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', (FS 10))
$list.DrawMode = 'OwnerDrawFixed'
$list.ItemHeight = (S 30)
$list.IntegralHeight = $false
$leftPanel.Controls.Add($list)
$list.BringToFront()
$list.Add_DrawItem({
    param($sender, $e)
    if ($e.Index -lt 0) { return }
    $e.DrawBackground()
    $isSel = (($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -eq [System.Windows.Forms.DrawItemState]::Selected)
    $bg = if ($isSel) { Get-HtmlColor '#094771' } else { Get-HtmlColor '#252526' }
    $fg = if ($isSel) { Get-HtmlColor '#FFFFFF' } else { Get-HtmlColor '#DDDDDD' }
    $bgBrush = New-Object System.Drawing.SolidBrush($bg)
    $e.Graphics.FillRectangle($bgBrush, $e.Bounds)
    $bgBrush.Dispose()
    $fgBrush = New-Object System.Drawing.SolidBrush($fg)
    $pt = New-Object System.Drawing.PointF(($e.Bounds.X + (S 10)), ($e.Bounds.Y + (S 6)))
    $e.Graphics.DrawString([string]$sender.Items[$e.Index], $script:UiFont, $fgBrush, $pt)
    $fgBrush.Dispose()
})
$script:ToolList = $list
foreach ($t in $script:Tools) { [void]$list.Items.Add($t.Name) }

# ---------- 右侧主区域 ----------
$rightPanel = New-Object System.Windows.Forms.Panel
$rightPanel.Dock = 'Fill'
$rightPanel.BackColor = (Get-HtmlColor '#1E1E1E')

$script:DescLabel = New-Object System.Windows.Forms.Label
$script:DescLabel.Dock = 'Top'
$script:DescLabel.Height = (S 28)
$script:DescLabel.TextAlign = 'MiddleLeft'
$script:DescLabel.ForeColor = (Get-HtmlColor '#9CDCFE')
$script:DescLabel.BackColor = (Get-HtmlColor '#1E1E1E')
$script:DescLabel.Padding = New-Object System.Windows.Forms.Padding((S 8), 0, 0, 0)

$paramPanel = New-Object System.Windows.Forms.Panel
$paramPanel.Dock = 'Top'
$paramPanel.Height = (S 132)
$paramPanel.BackColor = (Get-HtmlColor '#252526')
$paramPanel.AutoScroll = $true
$script:ParamFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$script:ParamFlow.Dock = 'Fill'
$script:ParamFlow.FlowDirection = 'LeftToRight'
$script:ParamFlow.WrapContents = $true
$script:ParamFlow.AutoScroll = $true
$script:ParamFlow.Padding = New-Object System.Windows.Forms.Padding((S 8), (S 6), (S 8), (S 6))
$script:ParamFlow.BackColor = (Get-HtmlColor '#252526')
$paramPanel.Controls.Add($script:ParamFlow)

$actionPanel = New-Object System.Windows.Forms.Panel
$actionPanel.Dock = 'Top'
$actionPanel.Height = (S 46)
$actionPanel.BackColor = (Get-HtmlColor '#1E1E1E')
$actionFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$actionFlow.Dock = 'Fill'
$actionFlow.FlowDirection = 'LeftToRight'
$actionFlow.WrapContents = $false
$actionFlow.Padding = New-Object System.Windows.Forms.Padding((S 8), (S 8), (S 8), (S 8))
$actionFlow.BackColor = (Get-HtmlColor '#1E1E1E')
$actionPanel.Controls.Add($actionFlow)

function New-ActionButton([string]$Text, [int]$Width, [string]$Back = '#0E639C') {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Size = New-Object System.Drawing.Size((S $Width), (S 28))
    $b.FlatStyle = 'Flat'
    $b.BackColor = (Get-HtmlColor $Back)
    $b.ForeColor = (Get-HtmlColor '#FFFFFF')
    $b.FlatAppearance.BorderColor = (Get-HtmlColor '#3F3F46')
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, (S 6), 0)
    return $b
}

$script:RunButton    = New-ActionButton '▶  运行' 88 '#0E639C'
$script:StopButton   = New-ActionButton '■  停止' 74 '#5A2D2D'
$script:ClearButton  = New-ActionButton '清空输出' 84 '#3A3D41'
$script:CopyButton   = New-ActionButton '复制输出' 84 '#3A3D41'
$script:SaveButton   = New-ActionButton '保存输出' 84 '#3A3D41'
$script:ReadmeButton = New-ActionButton '打开速查手册' 116 '#3A3D41'
$script:FolderButton = New-ActionButton '打开脚本目录' 116 '#3A3D41'
$script:StopButton.Enabled = $false
foreach ($b in @($script:RunButton, $script:StopButton, $script:ClearButton, $script:CopyButton,
                 $script:SaveButton, $script:ReadmeButton, $script:FolderButton)) {
    $actionFlow.Controls.Add($b)
}

$script:OutputBox = New-Object System.Windows.Forms.RichTextBox
$script:OutputBox.Dock = 'Fill'
$script:OutputBox.BackColor = (Get-HtmlColor '#1E1E1E')
$script:OutputBox.ForeColor = (Get-HtmlColor '#D4D4D4')
$script:OutputBox.Font = $script:MonoFont
$script:OutputBox.ReadOnly = $true
$script:OutputBox.WordWrap = $false
$script:OutputBox.BorderStyle = 'None'
$script:OutputBox.DetectUrls = $true
$script:OutputBox.ScrollBars = 'Both'
$script:OutputBox.HideSelection = $false

$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusStrip.BackColor = (Get-HtmlColor '#007ACC')
$statusStrip.ForeColor = (Get-HtmlColor '#FFFFFF')
$statusStrip.SizingGrip = $false
$statusStrip.Font = $script:UiFont
$script:StatusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$script:StatusLabel.Text = ' 就绪'
$script:StatusLabel.Spring = $true
$script:StatusLabel.TextAlign = 'MiddleLeft'
$statusStrip.Items.Add($script:StatusLabel) | Out-Null
$script:Progress = New-Object System.Windows.Forms.ToolStripProgressBar
$script:Progress.Style = 'Marquee'
$script:Progress.MarqueeAnimationSpeed = 30
$script:Progress.Visible = $false
$script:Progress.Width = (S 120)
$statusStrip.Items.Add($script:Progress) | Out-Null

# 注意：Dock 的布局优先级与添加顺序相反（后添加的优先占位）
$rightPanel.Controls.Add($script:OutputBox)
$rightPanel.Controls.Add($statusStrip)
$rightPanel.Controls.Add($actionPanel)
$rightPanel.Controls.Add($paramPanel)
$rightPanel.Controls.Add($script:DescLabel)
$form.Controls.Add($rightPanel)
$form.Controls.Add($leftPanel)
$form.Controls.Add($header)

# ============================================================
# 5. 输出与运行控制
# ============================================================
function Add-OutputText {
    param([string]$Text, [string]$Color, [switch]$NoNewline)
    $box = $script:OutputBox
    $box.SelectionStart = $box.TextLength
    $box.SelectionLength = 0
    $box.SelectionColor = (Get-OutColor $Color)
    if ($Text) { $box.AppendText($Text) }
    if (-not $NoNewline) { $box.AppendText("`r`n") }
    $box.SelectionColor = $box.ForeColor
    $box.SelectionStart = $box.TextLength
    $box.ScrollToCaret()
}

function Clear-Output {
    $script:OutputBox.Clear()
}

function Complete-Run([string]$Status) {
    $script:Timer.Stop()
    if ($script:PowerShell) {
        try { $null = $script:PowerShell.EndInvoke($script:Handle) } catch { }
        try { $script:PowerShell.Dispose() } catch { }
        $script:PowerShell = $null
    }
    if ($script:Runspace) {
        try { $script:Runspace.Close() } catch { }
        try { $script:Runspace.Dispose() } catch { }
        $script:Runspace = $null
    }
    $script:Handle  = $null
    $script:Running = $false
    $script:RunButton.Enabled  = $true
    $script:StopButton.Enabled = $false
    $script:Progress.Visible   = $false
    $sec = ((Get-Date) - $script:StartTime).TotalSeconds
    $script:StatusLabel.Text = (' {0} · 耗时 {1:N1} 秒' -f $Status, $sec)
    Add-OutputText -Text ('──── {0}，耗时 {1:N1} 秒 ────' -f $Status, $sec) -Color 'Cyan'
    Add-OutputText -Text ''
}

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 80
$script:Timer.Add_Tick({
    $item = $null
    while ($script:Queue -and $script:Queue.TryDequeue([ref]$item)) {
        if ($item.Kind -eq 'out') {
            Add-OutputText -Text $item.Text -Color $item.Color -NoNewline:$item.NoNewline
        } elseif ($item.Kind -eq 'done') {
            Complete-Run -Status '完成'
            return
        }
    }
    if ($script:Running -and $script:Handle -and $script:Handle.IsCompleted) {
        Complete-Run -Status '完成'
    }
})

function Start-ToolRun {
    if ($script:Running) { return }
    $tool = $script:Tools[$script:SelectedIndex]

    # 无需脚本的特殊工具
    if ($tool.Kind -eq 'cheat') {
        Clear-Output
        Add-OutputText -Text $script:CheatSheet -Color 'Gray'
        $script:StatusLabel.Text = ' 已输出速查表'
        return
    }
    if ($tool.Kind -eq 'panels') { return }

    $scriptPath = Join-Path $script:ScriptDir $tool.Script
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        [System.Windows.Forms.MessageBox]::Show(("找不到脚本:`r`n{0}" -f $scriptPath), '错误') | Out-Null
        return
    }

    # 脚本若声明了 -Yes，就总是传 -Yes：确认环节由界面负责。
    # 否则脚本会在无交互的 Runspace 里调用 Read-Host，报「主机不支持用户交互」。
    $supportsYes = $false
    try { if ([System.IO.File]::ReadAllText($scriptPath) -match '\[switch\]\s*\$Yes\b') { $supportsYes = $true } } catch { }

    # 收集参数
    $argTable = @{}
    $missing  = @()
    $danger   = @()
    foreach ($f in $tool.Fields) {
        $ctl = $script:FieldControls[$f.Name]
        if (-not $ctl) { continue }
        switch ($f.Kind) {
            'switch' {
                if ($ctl.Checked) { $argTable[$f.Name] = $true }
                if ($ctl.Checked -and $f.Danger) { $danger += $f.Label }
                # 「勾选才安全」的开关（如清理脚本的 -DryRun）：取消勾选=真正执行，同样要确认
                if (-not $ctl.Checked -and $f.DangerWhenUnchecked) { $danger += ($f.Label + '（已取消勾选 → 会真正执行）') }
            }
            'int' {
                $txt = $ctl.Text.Trim()
                if ($txt -match '^-?\d+$') { $argTable[$f.Name] = [int]$txt }
                elseif ($f.Mandatory) { $missing += $f.Label }
            }
            'choice' {
                $val = [string]$ctl.SelectedItem
                if (-not $val) { $val = $ctl.Text.Trim() }
                if ($val) { $argTable[$f.Name] = $val }
                elseif ($f.Mandatory) { $missing += $f.Label }
                if ($val -and $f.DangerValues -and ($f.DangerValues -contains $val)) {
                    $danger += ('{0} = {1}' -f $f.Label, $val)
                }
            }
            'list' {
                $txt = $ctl.Text.Trim()
                if ($txt) {
                    $argTable[$f.Name] = @($txt -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                }
            }
            default {
                $txt = $ctl.Text.Trim()
                if ($txt) { $argTable[$f.Name] = $txt }
                elseif ($f.Mandatory) { $missing += $f.Label }
            }
        }
    }

    if ($missing.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show(("请填写必填项：`r`n  - " + ($missing -join "`r`n  - ")), '参数不完整') | Out-Null
        return
    }

    if ($danger.Count -gt 0) {
        $msg = "以下操作具有破坏性或不可恢复，确认继续？`r`n`r`n  - " + ($danger -join "`r`n  - ") + "`r`n`r`n（对应脚本会跳过二次询问）"
        $r = [System.Windows.Forms.MessageBox]::Show($msg, '危险操作确认', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }
    }
    if ($supportsYes) { $argTable['Yes'] = $true }   # 界面确认已做过，让脚本别再问


    # 启动
    Clear-Output
    Add-OutputText -Text ('▶ {0}' -f $tool.Name) -Color 'White'
    Add-OutputText -Text ('  脚本: {0}' -f $scriptPath) -Color 'DarkGray'
    if ($argTable.Count -gt 0) {
        $parts = @()
        foreach ($k in ($argTable.Keys | Sort-Object)) {
            $parts += ('-{0} {1}' -f $k, ($argTable[$k] -join ','))
        }
        Add-OutputText -Text ('  参数: {0}' -f ($parts -join '  ')) -Color 'DarkGray'
    }
    Add-OutputText -Text ''

    $script:Queue      = New-Object System.Collections.Concurrent.ConcurrentQueue[object]
    $script:Runspace   = [runspacefactory]::CreateRunspace()
    $script:Runspace.Open()
    $script:PowerShell = [powershell]::Create()
    $script:PowerShell.Runspace = $script:Runspace
    $null = $script:PowerShell.AddScript($script:WorkerScript).
        AddArgument($scriptPath).AddArgument($argTable).AddArgument($script:Queue)
    $script:Handle    = $script:PowerShell.BeginInvoke()
    $script:StartTime = Get-Date
    $script:Running   = $true
    $script:RunButton.Enabled  = $false
    $script:StopButton.Enabled = $true
    $script:Progress.Visible   = $true
    $script:StatusLabel.Text   = (' 正在运行：{0}' -f $tool.Name)
    $script:Timer.Start()
}

# ============================================================
# 6. 参数区渲染
# ============================================================
function New-FieldPanel($field) {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.AutoSize = $true
    $panel.Margin = New-Object System.Windows.Forms.Padding(0, (S 4), (S 16), (S 4))

    $lab = New-Object System.Windows.Forms.Label
    $lab.Text = [string]$field.Label
    $lab.AutoSize = $false
    $lab.Size = New-Object System.Drawing.Size(($lab.Text.Length * (S 13) + (S 16)), (S 24))
    $lab.TextAlign = 'MiddleLeft'
    $lab.ForeColor = (Get-HtmlColor '#C8C8C8')
    $lab.Location = New-Object System.Drawing.Point(0, (S 2))
    $panel.Controls.Add($lab)

    $x = $lab.Width + (S 2)

    if ($field.Kind -eq 'switch') {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = ''
        $cb.Size = New-Object System.Drawing.Size((S 20), (S 22))
        $cb.Location = New-Object System.Drawing.Point($x, (S 3))
        $cb.ForeColor = (Get-HtmlColor '#D4D4D4')
        if ($field.Default) { $cb.Checked = $true }
        $panel.Controls.Add($cb)
        $panel.Size = New-Object System.Drawing.Size(($x + (S 24)), (S 28))
        $script:FieldControls[$field.Name] = $cb
        if ($field.Danger) {
            $lab.ForeColor = (Get-HtmlColor '#F48771')
            $panel.Size = New-Object System.Drawing.Size(($x + (S 24)), (S 28))
        }
        return $panel
    }

    if ($field.Kind -eq 'choice') {
        $w = 140
        if ($field.Width) { $w = [int]$field.Width }
        $cbo = New-Object System.Windows.Forms.ComboBox
        $cbo.DropDownStyle = 'DropDownList'
        $cbo.FlatStyle = 'Flat'
        $cbo.Size = New-Object System.Drawing.Size($w, (S 24))
        $cbo.Location = New-Object System.Drawing.Point($x, (S 2))
        $cbo.BackColor = (Get-HtmlColor '#333337')
        $cbo.ForeColor = (Get-HtmlColor '#FFFFFF')
        foreach ($opt in $field.Options) { [void]$cbo.Items.Add([string]$opt) }
        if ($field.Default -and $cbo.Items.Contains([string]$field.Default)) { $cbo.SelectedItem = [string]$field.Default }
        elseif ($cbo.Items.Count -gt 0) { $cbo.SelectedIndex = 0 }
        $panel.Controls.Add($cbo)
        $script:FieldControls[$field.Name] = $cbo
        $panel.Size = New-Object System.Drawing.Size(($x + $w), (S 28))
        return $panel
    }

    $w = 120
    if ($field.Width) { $w = [int]$field.Width }

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Size = New-Object System.Drawing.Size($w, (S 24))
    $tb.Location = New-Object System.Drawing.Point($x, (S 2))
    $tb.BackColor = (Get-HtmlColor '#333337')
    $tb.ForeColor = (Get-HtmlColor '#FFFFFF')
    $tb.BorderStyle = 'FixedSingle'
    $val = [string]$field.Default
    if ($val -eq '$AppRoot') { $val = $script:AppRoot }
    $tb.Text = $val
    $panel.Controls.Add($tb)
    $script:FieldControls[$field.Name] = $tb
    $totalW = $x + $w

    if ($field.Kind -eq 'folder' -or $field.Kind -eq 'savefile') {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = '...'
        $btn.Size = New-Object System.Drawing.Size((S 30), (S 24))
        $btn.Location = New-Object System.Drawing.Point(($x + $w + (S 4)), (S 2))
        $btn.FlatStyle = 'Flat'
        $btn.BackColor = (Get-HtmlColor '#3A3D41')
        $btn.ForeColor = (Get-HtmlColor '#FFFFFF')
        $btn.FlatAppearance.BorderColor = (Get-HtmlColor '#3F3F46')
        # 目标输入框与类型存进控件自己的 Tag，事件里用 $sender 取。
        # 注意：不能直接引用 $target/$kind 这类局部变量 —— 本函数返回后它们就没了，
        # 事件触发时会变成 $null，Start-Process/ShowDialog 就会报“系统找不到指定的文件”。
        $btn.Tag = @{ Kind = $field.Kind; Box = $tb }
        $btn.Add_Click({
            param($sender, $e)
            $kind   = $sender.Tag.Kind
            $target = $sender.Tag.Box
            if ($kind -eq 'folder') {
                $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                $dlg.Description = '选择目录'
                $dlg.ShowNewFolderButton = $true
                if ($target.Text -and (Test-Path -LiteralPath $target.Text)) { $dlg.SelectedPath = $target.Text }
                if ($dlg.ShowDialog() -eq 'OK') { $target.Text = $dlg.SelectedPath }
            } else {
                $dlg = New-Object System.Windows.Forms.SaveFileDialog
                $dlg.Filter = 'CSV 文件 (*.csv)|*.csv|文本文件 (*.txt)|*.txt|所有文件 (*.*)|*.*'
                $dlg.FileName = 'result.csv'
                if ($dlg.ShowDialog() -eq 'OK') { $target.Text = $dlg.FileName }
            }
        })
        $panel.Controls.Add($btn)
        $totalW = $x + $w + (S 36)
    }

    $panel.Size = New-Object System.Drawing.Size($totalW, (S 28))
    return $panel
}

function Show-ToolPanel([int]$Index) {
    $tool = $script:Tools[$Index]
    foreach ($c in @($script:ParamFlow.Controls)) { try { $c.Dispose() } catch { } }
    $script:ParamFlow.Controls.Clear()
    $script:FieldControls = @{}
    $script:DescLabel.Text = ('  {0}   —   {1}' -f $tool.Name, $tool.Desc)
    $script:RunButton.Enabled = $true

    if ($tool.Kind -eq 'panels') {
        $script:RunButton.Enabled = $false
        $panels = @(
            @{ Text = '服务';         Target = 'services.msc' }
            @{ Text = '设备管理器';   Target = 'devmgmt.msc' }
            @{ Text = '磁盘管理';     Target = 'diskmgmt.msc' }
            @{ Text = '事件查看器';   Target = 'eventvwr.msc' }
            @{ Text = '任务计划';     Target = 'taskschd.msc' }
            @{ Text = '计算机管理';   Target = 'compmgmt.msc' }
            @{ Text = '程序和功能';   Target = 'appwiz.cpl' }
            @{ Text = '网络连接';     Target = 'ncpa.cpl' }
            @{ Text = '系统属性';     Target = 'sysdm.cpl' }
            @{ Text = '电源选项';     Target = 'powercfg.cpl' }
            @{ Text = '防火墙';       Target = 'firewall.cpl' }
            @{ Text = '系统配置';     Target = 'msconfig' }
            @{ Text = '资源监视器';   Target = 'resmon' }
            @{ Text = '注册表编辑器'; Target = 'regedit' }
            @{ Text = '系统信息';     Target = 'msinfo32' }
            @{ Text = '临时目录';     Target = $env:TEMP }
            @{ Text = '启动文件夹';   Target = 'shell:startup' }
            @{ Text = '用户账户';     Target = 'netplwiz' }
        )
        foreach ($p in $panels) {
            $b = New-ActionButton $p.Text 104 '#3A3D41'
            $b.Margin = New-Object System.Windows.Forms.Padding(0, (S 4), (S 8), (S 4))
            # 目标存进控件 Tag，事件里用 $sender.Tag 取；不要引用循环变量 $t（函数返回后即失效）
            $b.Tag = $p.Target
            $b.Add_Click({
                param($sender, $e)
                try { Start-Process $sender.Tag }
                catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '打开失败') | Out-Null }
            })
            $script:ParamFlow.Controls.Add($b)
        }
        return
    }

    if ($tool.Kind -eq 'cheat') { return }

    foreach ($f in $tool.Fields) {
        $script:ParamFlow.Controls.Add((New-FieldPanel $f))
    }
}

# ============================================================
# 7. 事件绑定
# ============================================================
$script:Ready = $false
$list.Add_SelectedIndexChanged({
    if (-not $script:Ready) { return }
    if ($script:Running) {
        [System.Windows.Forms.MessageBox]::Show('当前有任务在运行，请先停止或等待完成。', '提示') | Out-Null
        $script:Ready = $false
        $script:ToolList.SelectedIndex = $script:SelectedIndex
        $script:Ready = $true
        return
    }
    $script:SelectedIndex = $script:ToolList.SelectedIndex
    Show-ToolPanel $script:SelectedIndex
})

$script:RunButton.Add_Click({ Start-ToolRun })
$script:StopButton.Add_Click({
    if ($script:PowerShell) {
        $script:StatusLabel.Text = ' 正在停止…'
        try { $script:PowerShell.Stop() } catch { }
        Complete-Run -Status '已停止'
    }
})
$script:ClearButton.Add_Click({ Clear-Output; $script:StatusLabel.Text = ' 已清空输出' })
$script:CopyButton.Add_Click({
    if ($script:OutputBox.TextLength -gt 0) {
        [System.Windows.Forms.Clipboard]::SetText($script:OutputBox.Text)
        $script:StatusLabel.Text = ' 输出已复制到剪贴板'
    }
})
$script:SaveButton.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = '文本文件 (*.txt)|*.txt|所有文件 (*.*)|*.*'
    $dlg.FileName = ('工具台输出-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    if ($dlg.ShowDialog() -eq 'OK') {
        $script:OutputBox.Text | Set-Content -LiteralPath $dlg.FileName -Encoding UTF8
        $script:StatusLabel.Text = (' 已保存到 {0}' -f $dlg.FileName)
    }
})
$script:ReadmeButton.Add_Click({
    if (Test-Path -LiteralPath $script:ReadmePath) { Start-Process $script:ReadmePath }
    else { [System.Windows.Forms.MessageBox]::Show('未找到 README.md', '提示') | Out-Null }
})
$script:FolderButton.Add_Click({ Start-Process $script:AppRoot })
$script:AdminButton.Add_Click({
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"' + $PSCommandPath + '"')
        )
        $script:Form.Close()
    } catch {
        [System.Windows.Forms.MessageBox]::Show('提权被取消或被拒绝。', '提示') | Out-Null
    }
})
$script:OutputBox.Add_LinkClicked({
    param($sender, $e)
    try { Start-Process $e.LinkText } catch { }
})
$form.Add_Shown({
    $script:Ready = $true
    $script:ToolList.SelectedIndex = 0
    Show-ToolPanel 0
    Add-OutputText -Text '欢迎使用「Windows 常用指令集 · 图形工具台」。' -Color 'White'
    Add-OutputText -Text '左侧选择工具 → 填好参数 → 点「▶ 运行」，输出会实时显示在这里。' -Color 'DarkGray'
    Add-OutputText -Text '提示：涉及删除/镜像同步/结束进程的操作，运行前会弹窗二次确认。' -Color 'DarkGray'
    Add-OutputText -Text ''
    $script:StatusLabel.Text = ' 就绪'
})
$form.Add_FormClosing({
    if ($script:Running -and $script:PowerShell) {
        try { $script:PowerShell.Stop() } catch { }
    }
})
$form.Add_Resize({
    $w = $script:Form.ClientSize.Width
    $script:AdminButton.Location = New-Object System.Drawing.Point(($w - (S 300)), (S 9))
    $script:RoleLabel.Location    = New-Object System.Drawing.Point(($w - (S 160)), (S 9))
})

# ============================================================
# 8. 自检模式（不显示窗口，验证界面与输出管线）
# ============================================================
if ($SelfTest) {
    Write-Host '[SelfTest] 界面构建完成'
    foreach ($i in 0..($script:Tools.Count - 1)) {
        Show-ToolPanel $i
        Write-Host ('  [OK] 面板 {0,-14} 参数控件 {1} 个' -f $script:Tools[$i].Name, $script:ParamFlow.Controls.Count)
    }
    $testScript = Join-Path $script:ScriptDir '01-系统信息.ps1'
    Write-Host ('[SelfTest] 通过内部管线运行: {0}' -f $testScript)
    $q = New-Object System.Collections.Concurrent.ConcurrentQueue[object]
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript($script:WorkerScript).AddArgument($testScript).AddArgument(@{}).AddArgument($q)
    $h = $ps.BeginInvoke()
    $lines = 0
    $colored = 0
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        $it = $null
        while ($q.TryDequeue([ref]$it)) {
            if ($it.Kind -eq 'out') {
                $lines++
                if ($it.Color) { $colored++ }
                if ($lines -le 12) { Write-Host ('   | ' + $it.Text) }
            }
        }
        if ($h.IsCompleted -and $q.Count -eq 0) { break }
        Start-Sleep -Milliseconds 60
    }
    try { $null = $ps.EndInvoke($h) } catch { }
    $ps.Dispose(); $rs.Close(); $rs.Dispose()
    Write-Host ('  [OK] 管线输出 {0} 行，其中彩色 {1} 行' -f $lines, $colored)
    Write-Host '[SelfTest] 通过'
    return
}

# ============================================================
# 9. 显示窗口
# ============================================================
[void]$form.ShowDialog()
$form.Dispose()
