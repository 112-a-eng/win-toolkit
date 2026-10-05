<#
.SYNOPSIS
    启动图形工具台并自动截图（用于 README 展示图）
.DESCRIPTION
    以「便携模式」启动 图形工具台.ps1，找到主窗口后自动点击「▶ 运行」按钮，
    等输出区填满内容后用 PrintWindow 抓取窗口位图（只抓这个窗口，不会拍到桌面其它内容），
    保存为 PNG 后关闭窗口。
.PARAMETER OutPath
    输出 PNG 路径，默认 <仓库根>\docs\screenshot.png
.PARAMETER WaitSeconds
    启动后等待窗口出现的秒数，默认 15
.PARAMETER OutputWaitSeconds
    点击“运行”后等待输出刷新的秒数，默认 8
.PARAMETER NoClickRun
    只截启动后的初始界面，不自动点击“运行”
.EXAMPLE
    .\build\capture-screenshot.ps1
#>
[CmdletBinding()]
param(
    [string]$OutPath,
    [int]$WaitSeconds = 15,
    [int]$OutputWaitSeconds = 8,
    [switch]$NoClickRun
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path $PSScriptRoot -Parent
if (-not $OutPath) { $OutPath = Join-Path $root 'docs\screenshot.png' }
$gui = Join-Path $root '图形工具台.ps1'
if (-not (Test-Path -LiteralPath $gui)) { throw ("找不到 GUI 脚本: {0}" -f $gui) }
$outDir = Split-Path $OutPath -Parent
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# ---------- Win32 ----------
Add-Type -Namespace Shot -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint nFlags);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
'@

$BM_CLICK = 0x00F5
$SW_RESTORE = 9
$PW_RENDERFULLCONTENT = 2

Write-Host '1) 启动图形工具台…'
$proc = Start-Process powershell.exe -PassThru -ArgumentList @(
    '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"' + $gui + '"')
)

Write-Host '2) 等待主窗口…'
$hwnd = [IntPtr]::Zero
$deadline = (Get-Date).AddSeconds($WaitSeconds)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    # 只认自己启动的那个进程，避免抓到残留窗口
    $p = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
    if ($p) {
        $p.Refresh()
        if ($p.MainWindowTitle -like '*图形工具台*' -and $p.MainWindowHandle -ne [IntPtr]::Zero) {
            $hwnd = $p.MainWindowHandle
            break
        }
    } elseif ($proc.HasExited) {
        throw '图形工具台进程已退出（可能启动失败）'
    }
}
if ($hwnd -eq [IntPtr]::Zero) {
    try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
    throw '没能找到图形工具台的主窗口'
}
Write-Host ("   窗口句柄: {0}" -f $hwnd)

[void][Shot.Native]::ShowWindow($hwnd, $SW_RESTORE)
[void][Shot.Native]::SetForegroundWindow($hwnd)
Start-Sleep -Seconds 2

# ---------- 自动点“运行”，让输出区有内容 ----------
if (-not $NoClickRun) {
    Write-Host '3) 自动点击「▶ 运行」按钮…'
    $buttons = New-Object System.Collections.Generic.List[IntPtr]
    $cb = [Shot.Native+EnumWindowsProc]{
        param($h, $l)
        $sb = New-Object System.Text.StringBuilder 256
        [void][Shot.Native]::GetWindowTextW($h, $sb, 256)
        $t = $sb.ToString()
        if ($t -match '运行') { $buttons.Add($h) }
        return $true
    }
    [void][Shot.Native]::EnumChildWindows($hwnd, $cb, [IntPtr]::Zero)
    if ($buttons.Count -gt 0) {
        [void][Shot.Native]::SendMessageW($buttons[0], $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)
        Write-Host '   已点击，等待脚本输出…'
        Start-Sleep -Seconds $OutputWaitSeconds
    } else {
        Write-Host '   没找到按钮，改为截取初始界面' -ForegroundColor Yellow
    }
}

Write-Host '4) 抓取窗口位图…'
$rect = New-Object Shot.Native+RECT
[void][Shot.Native]::GetWindowRect($hwnd, [ref]$rect)
$w = $rect.Right - $rect.Left
$h = $rect.Bottom - $rect.Top
if ($w -le 0 -or $h -le 0) { throw '窗口尺寸异常' }
Write-Host ("   尺寸: {0} x {1}" -f $w, $h)

$bmp = New-Object System.Drawing.Bitmap $w, $h
$gfx = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $gfx.GetHdc()
$ok = [Shot.Native]::PrintWindow($hwnd, $hdc, $PW_RENDERFULLCONTENT)
$gfx.ReleaseHdc($hdc)
$gfx.Dispose()
if (-not $ok) { Write-Host '   PrintWindow 返回失败，图可能不完整' -ForegroundColor Yellow }

$bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

Write-Host '5) 关闭窗口…'
try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
Get-Process powershell -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -like '*图形工具台*' } |
    ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }

$f = Get-Item -LiteralPath $OutPath
Write-Host ("  已保存: {0}  ({1:N0} 字节)" -f $f.FullName, $f.Length) -ForegroundColor Green
