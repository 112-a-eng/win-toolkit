<#
.SYNOPSIS
    把「Windows 常用指令集 · 图形工具台」打包成单文件 EXE
.DESCRIPTION
    使用系统自带的 csc.exe（.NET Framework 4.x）编译，不需要安装任何第三方工具。
    会把下列文件作为资源嵌入 EXE，运行时自动解包：
        图形工具台.ps1 / scripts\*.ps1 / scripts\run.bat / 启动图形工具台.bat / README.md
.EXAMPLE
    .\build\build-exe.ps1
.EXAMPLE
    .\build\build-exe.ps1 -OutputName 'MyToolkit.exe'
#>
[CmdletBinding()]
param(
    [string]$OutputName = 'Windows常用指令集.exe'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$buildDir = $PSScriptRoot
$root     = Split-Path $buildDir -Parent
$payload  = Join-Path $buildDir 'payload'
$icoPath  = Join-Path $buildDir 'app.ico'
$csPath   = Join-Path $buildDir 'Launcher.cs'
$outExe   = Join-Path $root $OutputName

Write-Host ''
Write-Host ' === 打包 Windows 常用指令集 · 图形工具台 ===' -ForegroundColor White -BackgroundColor DarkBlue
Write-Host (" 源目录: {0}" -f $root)
Write-Host (" 输出  : {0}" -f $outExe)
Write-Host ''

# ---------- 1. 准备载荷（ASCII 资源名，字节级复制以保留 UTF-8 BOM）----------
$map = [ordered]@{
    'gui.ps1'      = (Join-Path $root '图形工具台.ps1')
    's01.ps1'      = (Join-Path $root 'scripts\01-系统信息.ps1')
    's02.ps1'      = (Join-Path $root 'scripts\02-网络诊断.ps1')
    's03.ps1'      = (Join-Path $root 'scripts\03-端口占用.ps1')
    's04.ps1'      = (Join-Path $root 'scripts\04-清理临时文件.ps1')
    's05.ps1'      = (Join-Path $root 'scripts\05-文件夹备份.ps1')
    's06.ps1'      = (Join-Path $root 'scripts\06-进程服务速查.ps1')
    's07.ps1'      = (Join-Path $root 'scripts\07-大文件查找.ps1')
    's08.ps1'      = (Join-Path $root 'scripts\08-批量重命名.ps1')
    's09.ps1'      = (Join-Path $root 'scripts\09-文件哈希.ps1')
    's10.ps1'      = (Join-Path $root 'scripts\10-局域网扫描.ps1')
    's11.ps1'      = (Join-Path $root 'scripts\11-服务管理.ps1')
    's12.ps1'      = (Join-Path $root 'scripts\12-环境变量.ps1')
    's13.ps1'      = (Join-Path $root 'scripts\13-系统修复.ps1')
    'menu.ps1'     = (Join-Path $root 'scripts\menu.ps1')
    'run.bat'      = (Join-Path $root 'scripts\run.bat')
    'launcher.bat' = (Join-Path $root '启动图形工具台.bat')
    'readme.md'    = (Join-Path $root 'README.md')
}
Remove-Item $payload -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $payload -Force | Out-Null
foreach ($k in $map.Keys) {
    if (-not (Test-Path -LiteralPath $map[$k])) { throw ("缺少文件: {0}" -f $map[$k]) }
    [System.IO.File]::WriteAllBytes((Join-Path $payload $k), [System.IO.File]::ReadAllBytes($map[$k]))
    Write-Host ("   打包 {0,-14} <- {1}" -f $k, (Split-Path $map[$k] -Leaf)) -ForegroundColor DarkGray
}

# ---------- 2. 生成图标 ----------
Add-Type -AssemblyName System.Drawing
$bmp = New-Object System.Drawing.Bitmap 256, 256
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'
$g.TextRenderingHint = 'AntiAliasGridFit'
$g.Clear([System.Drawing.Color]::Transparent)
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$w = 256; $r = 52; $d = $r * 2
$path.AddArc(4, 4, $d, $d, 180, 90)
$path.AddArc($w - $d - 4, 4, $d, $d, 270, 90)
$path.AddArc($w - $d - 4, $w - $d - 4, $d, $d, 0, 90)
$path.AddArc(4, $w - $d - 4, $d, $d, 90, 90)
$path.CloseFigure()
$brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 12, 88, 140))
$g.FillPath($brush, $path)
$font = New-Object System.Drawing.Font('Consolas', 108, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$fmt = New-Object System.Drawing.StringFormat
$fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
$g.DrawString('>_', $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, 8, 256, 256)), $fmt)
$g.Dispose()

$ms = New-Object System.IO.MemoryStream
$bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
$png = $ms.ToArray(); $ms.Dispose()

$icoStream = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($icoStream)
$bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]1)
$bw.Write([Byte]0); $bw.Write([Byte]0); $bw.Write([Byte]0); $bw.Write([Byte]0)   # 宽高 0 表示 256
$bw.Write([UInt16]1); $bw.Write([UInt16]32)
$bw.Write([UInt32]$png.Length); $bw.Write([UInt32]22)
$bw.Write($png); $bw.Flush()
[System.IO.File]::WriteAllBytes($icoPath, $icoStream.ToArray())
$bw.Dispose(); $icoStream.Dispose()
Write-Host ("   图标已生成 ({0} 字节)" -f (Get-Item $icoPath).Length) -ForegroundColor DarkGray

# ---------- 3. 保证 C# 源码是 UTF-8 with BOM（否则 csc 会按 GBK 读中文）----------
$utf8bom = New-Object System.Text.UTF8Encoding($true)
$code = [System.IO.File]::ReadAllText($csPath).TrimStart([char]0xFEFF, "`r", "`n")
if (-not $code.StartsWith('//')) { $code = '//' + $code }
[System.IO.File]::WriteAllText($csPath, (($code -replace "`r`n", "`n") -replace "`n", "`r`n"), $utf8bom)

# ---------- 4. 编译 ----------
$csc = @(
    'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) { throw '找不到 csc.exe（需要 .NET Framework 4.x，Windows 自带）' }
Write-Host ("   编译器: {0}" -f $csc) -ForegroundColor DarkGray

Remove-Item $outExe -Force -ErrorAction SilentlyContinue
$cscArgs = @(
    '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+',
    '/reference:System.Windows.Forms.dll',
    ('/win32icon:' + $icoPath),
    ('/out:' + $outExe)
)
$cscArgs += (Get-ChildItem $payload -File | Sort-Object Name | ForEach-Object { '/resource:' + $_.FullName })
$cscArgs += $csPath
& $csc @cscArgs
if ($LASTEXITCODE -ne 0) { throw ("编译失败，csc 退出码 {0}" -f $LASTEXITCODE) }

$f = Get-Item $outExe
Write-Host ''
Write-Host (" 编译成功: {0}" -f $f.FullName) -ForegroundColor Green
Write-Host (" 大小    : {0:N0} 字节 ({1:N0} KB)，内嵌 {2} 个文件" -f $f.Length, ($f.Length / 1KB), $map.Count) -ForegroundColor Green
Write-Host ''
