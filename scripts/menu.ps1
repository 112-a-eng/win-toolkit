<#
.SYNOPSIS
    Windows 常用工具集 主菜单
.DESCRIPTION
    交互式菜单，选择运行本目录下的各个实用脚本。
.EXAMPLE
    .\menu.ps1
#>
[CmdletBinding()]
param(
    [switch]$NoPause
)

$ErrorActionPreference = 'Continue'
$Host.UI.RawUI.WindowTitle = 'Windows 常用指令集工具包'

$items = @(
    [pscustomobject]@{ Key = '1'; Name = '系统信息速查';     File = '01-系统信息.ps1';      Hint = 'OS/CPU/内存/磁盘/显卡/开机时长' }
    [pscustomobject]@{ Key = '2'; Name = '网络一键诊断';     File = '02-网络诊断.ps1';      Hint = 'IP/网关/丢包/DNS/HTTP，只读' }
    [pscustomobject]@{ Key = '3'; Name = '端口占用查询';     File = '03-端口占用.ps1';      Hint = '查端口被谁占用，可选结束进程' }
    [pscustomobject]@{ Key = '4'; Name = '清理临时文件';     File = '04-清理临时文件.ps1';  Hint = '默认预览模式，安全' }
    [pscustomobject]@{ Key = '5'; Name = '文件夹备份';       File = '05-文件夹备份.ps1';    Hint = 'robocopy 增量/镜像同步' }
    [pscustomobject]@{ Key = '6'; Name = '进程服务速查';     File = '06-进程服务速查.ps1';  Hint = '卡顿排查：Top 进程与异常服务' }
    [pscustomobject]@{ Key = '7'; Name = '大文件查找';       File = '07-大文件查找.ps1';    Hint = '找出占用空间的大文件' }
    [pscustomobject]@{ Key = '8'; Name = '批量重命名';       File = '08-批量重命名.ps1';    Hint = '预览为先，-Apply 才执行' }
)

# 非交互环境（-NonInteractive / 管道调用）下 Read-Host 会报错，这里统一兜底，避免菜单死循环
$script:NoInput = $false
function Read-Input([string]$Prompt) {
    try { return (Read-Host $Prompt) }
    catch { $script:NoInput = $true; return 'q' }
}
function Show-Menu {
    Clear-Host
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
    Write-Host '              Windows 常用指令集 · 工具包' -ForegroundColor White
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
    Write-Host ("   速查手册: {0}" -f (Join-Path (Split-Path $PSScriptRoot -Parent) 'README.md')) -ForegroundColor DarkGray
    Write-Host ("   运行身份: {0}\{1}{2}" -f $env:USERDOMAIN, $env:USERNAME,
        $(if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { '（管理员）' } else { '（普通用户）' })) -ForegroundColor DarkGray
    Write-Host ''
    foreach ($i in $items) {
        Write-Host '   [' -NoNewline -ForegroundColor DarkGray
        Write-Host ($i.Key) -NoNewline -ForegroundColor Yellow
        Write-Host ('] {0,-16}' -f $i.Name) -NoNewline
        Write-Host ('  ' + $i.Hint) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '   [h] 打开速查手册      [q] 退出' -ForegroundColor Gray
    Write-Host ''
}

function Invoke-Tool([object]$Item) {
    $file = Join-Path $PSScriptRoot $Item.File
    if (-not (Test-Path -LiteralPath $file)) {
        Write-Host (" 找不到脚本: {0}" -f $file) -ForegroundColor Red
        return
    }
    Write-Host ''
    Write-Host (" ---- 运行 {0} ----" -f $Item.Name) -ForegroundColor Cyan

    switch ($Item.Key) {
        '3' {
            $port = Read-Input ' 请输入端口号（直接回车=列出所有监听端口）'
            if ($port -match '^\d+$') {
                & $file -Port ([int]$port)
            } else {
                & $file
            }
        }
        '4' {
            $mode = Read-Input ' 直接回车=预览模式，输入 c 回车=执行清理'
            if ($mode -eq 'c') { & $file -IncludeCrashDumps } else { & $file -DryRun }
        }
        '5' {
            $src = Read-Input ' 源目录（如 D:\work）'
            $dst = Read-Input ' 目标目录（如 E:\backup\work）'
            if ($src -and $dst) {
                $mirror = Read-Input ' 镜像模式(/MIR，会删除目标多余文件)? 输入 m 启用，回车=增量复制'
                if ($mirror -eq 'm') { & $file -Source $src -Destination $dst -Mirror } else { & $file -Source $src -Destination $dst }
            } else {
                Write-Host ' 目录未填写，已取消。' -ForegroundColor Yellow
            }
        }
        '7' {
            $p = Read-Input ' 扫描目录（回车=系统盘根目录）'
            $mb = Read-Input ' 最小体积 MB（回车=100）'
            $params = @{}
            if ($p)  { $params.Path  = $p }
            if ($mb -match '^\d+$') { $params.MinMB = [int]$mb }
            & $file @params
        }
        '8' {
            $p = Read-Input ' 目录（回车=当前目录）'
            $f = Read-Input ' 通配符（回车=*）'
            $pre = Read-Input ' 前缀（可空）'
            $params = @{}
            if ($p) { $params.Path = $p }
            if ($f) { $params.Filter = $f }
            if ($pre) { $params.Prefix = $pre }
            & $file @params
        }
        default {
            & $file
        }
    }
}

while ($true) {
    Show-Menu
    $choice = Read-Input ' 请选择'
    if ($choice -eq 'q') { break }
    if ($choice -eq 'h') {
        $readme = Join-Path (Split-Path $PSScriptRoot -Parent) 'README.md'
        if (Test-Path -LiteralPath $readme) { Start-Process $readme }
        else { Write-Host ' 未找到 README.md' -ForegroundColor Yellow }
        Start-Sleep -Milliseconds 600
        continue
    }
    $item = $items | Where-Object { $_.Key -eq $choice }
    if (-not $item) { Write-Host ' 无效选择。' -ForegroundColor Yellow; Start-Sleep -Seconds 1; continue }

    try {
        Invoke-Tool $item
    } catch {
        Write-Host (" 执行出错: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }

    if (-not $NoPause) {
        Write-Host ''
        Read-Input ' 按回车返回菜单' | Out-Null
    }
}
Write-Host ' 已退出。' -ForegroundColor DarkGray
