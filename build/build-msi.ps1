<#
.SYNOPSIS
    把「Windows 常用指令集 · 图形工具台」打包成 MSI 安装包
.DESCRIPTION
    用 WiX Toolset v3（candle + light）离线打包，特性：
      - 按用户安装：装到 %LOCALAPPDATA%\Programs\Windows常用指令集，卸载项进 HKCU，全程不需要管理员权限
      - 创建开始菜单 + 桌面快捷方式，写进「应用和功能」可正常卸载
      - 固定 UpgradeCode + 由相对路径确定性生成的组件 GUID，保证升级时能正确替换文件
      - 中文安装向导（覆盖显眼字符串，缺项会自动补齐后重试）
    实测（非管理员进程）：安装 → 29 个文件 + 两个快捷方式 + 卸载项注册 → 卸载 → 清理干净。
    第一次运行会自动下载 WiX 二进制（优先直连 GitHub，被墙时自动改走 GitHub API 通道），
    解压到 %LOCALAPPDATA%\WinToolkitBuild\wix，之后复用。
.PARAMETER Version
    产品版本，默认 1.1.0
.PARAMETER OutputPath
    输出 msi 路径，默认 <仓库根>\Windows常用指令集-<版本>.msi
.PARAMETER WixDir
    WiX 所在目录，默认 %LOCALAPPDATA%\WinToolkitBuild\wix
.PARAMETER EnglishUi
    安装向导改用英文（不生成中文语言包）
.PARAMETER KeepTemp
    保留中间产物（.wxs/.wxl/.wixobj）便于排查
.EXAMPLE
    .\build\build-msi.ps1
.EXAMPLE
    .\build\build-msi.ps1 -Version 1.2.0 -KeepTemp
#>
[CmdletBinding()]
param(
    [string]$Version = '1.1.0',
    [string]$OutputPath,
    [string]$WixDir,
    [switch]$EnglishUi,
    [switch]$KeepTemp
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root     = Split-Path $PSScriptRoot -Parent
$buildDir = $PSScriptRoot
if (-not $OutputPath) { $OutputPath = Join-Path $root ("Windows常用指令集-{0}.msi" -f $Version) }
if (-not $WixDir)     { $WixDir = Join-Path $env:LOCALAPPDATA 'WinToolkitBuild\wix' }

$ProductName       = 'Windows 常用指令集'
$Manufacturer      = '112-a-eng'
$UpgradeCode       = 'A7C3E9F1-5B24-4E8D-9C16-2F7A8B4D6E30'   # 固定不变，升级靠它识别
$Homepage          = 'https://github.com/112-a-eng/win-toolkit'
$InstallFolderName = 'Windows常用指令集'

function Write-Step([string]$t) { Write-Host ''; Write-Host ("== " + $t) -ForegroundColor Cyan }

# ============================================================
# 1. 准备 WiX
# ============================================================
Write-Step '检查 WiX Toolset'
$candle = Join-Path $WixDir 'candle.exe'
$light  = Join-Path $WixDir 'light.exe'
if (-not (Test-Path $candle)) {
    Write-Host '  未找到 WiX，开始下载（约 40 MB）…' -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $WixDir -Force | Out-Null
    $zip = Join-Path $env:TEMP 'wix-binaries.zip'
    $url = 'https://github.com/wixtoolset/wix3/releases/download/wix3141rtm/wix314-binaries.zip'
    $ok = $false
    try {
        Write-Host '  [1/2] 尝试直连 GitHub…' -ForegroundColor DarkGray
        & curl.exe -sL --max-time 600 -o $zip $url
        if ((Test-Path $zip) -and (Get-Item $zip).Length -gt 5MB) { $ok = $true }
    } catch { }
    if (-not $ok) {
        Write-Host '  直连失败，改走 GitHub API 通道…' -ForegroundColor Yellow
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        $cfg = Join-Path $env:TEMP 'wix-api.cfg'
        $rel = (& curl.exe -s --max-time 40 'https://api.github.com/repos/wixtoolset/wix3/releases/latest' | Out-String) | ConvertFrom-Json
        $asset = $rel.assets | Where-Object { $_.name -like '*binaries.zip' } | Select-Object -First 1
        if (-not $asset) { throw '取不到 WiX 发布资源' }
        $tok = $null
        try {
            $tmpIn = Join-Path $env:TEMP 'wix-cred.txt'
            [System.IO.File]::WriteAllText($tmpIn, "protocol=https`nhost=github.com`n`n", [System.Text.Encoding]::ASCII)
            $env:GIT_TERMINAL_PROMPT = '0'; $env:GCM_INTERACTIVE = 'never'
            $res = & cmd.exe /c "git credential fill < `"$tmpIn`" 2>&1" | Out-String
            Remove-Item $tmpIn -Force -ErrorAction SilentlyContinue
            if ($res -match '(?m)^password=(.+)$') { $tok = $Matches[1].Trim() }
        } catch { }
        [System.IO.File]::WriteAllText($cfg,
            ('header = "Accept: application/octet-stream"' + "`n" +
             $(if ($tok) { 'header = "Authorization: Bearer ' + $tok + '"' + "`n" } else { '' }) +
             'silent' + "`n"), [System.Text.Encoding]::ASCII)
        & curl.exe -K $cfg -L --max-time 900 -o $zip ("https://api.github.com/repos/wixtoolset/wix3/releases/assets/" + $asset.id)
        Remove-Item $cfg -Force -ErrorAction SilentlyContinue
        if ((Test-Path $zip) -and (Get-Item $zip).Length -gt 5MB) { $ok = $true }
    }
    if (-not $ok) { throw 'WiX 下载失败，请手动下载 wix314-binaries.zip 解压到 ' + $WixDir }
    Expand-Archive -LiteralPath $zip -DestinationPath $WixDir -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
}
if (-not (Test-Path $light)) { throw "WiX 不完整，缺少 light.exe：$WixDir" }
Write-Host ("  WiX 就绪: {0}" -f $WixDir) -ForegroundColor Green

# ============================================================
# 2. 组装要安装的文件
# ============================================================
Write-Step '收集要打包的文件'
$stage = Join-Path $env:TEMP ('wtk-msi-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $stage -Force | Out-Null

# 注意：这里必须是「函数返回、调用方累加」——
# 若在函数里写 $manifest += ...，改的是函数局部变量，外层拿不到。
function Get-Payload([string]$source, [string]$folder) {
    $out = @()
    if (-not (Test-Path -LiteralPath $source)) {
        Write-Host ("  跳过（不存在）: {0}" -f $source) -ForegroundColor DarkGray
        return $out
    }
    $item = Get-Item -LiteralPath $source
    if ($item.PSIsContainer) {
        foreach ($f in (Get-ChildItem -LiteralPath $source -File -Recurse)) {
            $rel = $f.FullName.Substring($source.Length).TrimStart('\')
            $out += [pscustomobject]@{ Source = $f.FullName; Folder = $folder; Rel = $rel }
        }
    } else {
        $out += [pscustomobject]@{ Source = $item.FullName; Folder = $folder; Rel = $item.Name }
    }
    return $out
}

$manifest = @()
foreach ($f in 'Windows常用指令集.exe', '图形工具台.ps1', '启动图形工具台.bat', 'README.md', 'LICENSE') {
    $manifest += Get-Payload (Join-Path $root $f) ''
}
$manifest += Get-Payload (Join-Path $root 'scripts') 'scripts'
$manifest += Get-Payload (Join-Path $root 'docs')    'docs'
$manifest += Get-Payload (Join-Path $root 'build')   'build'
$manifest = @($manifest | Where-Object { $_.Source -notmatch '\\payload\\' -and $_.Source -notmatch '\.wixobj$' -and $_.Source -notmatch '\.wxs$' })

Write-Host ("  共 {0} 个文件" -f $manifest.Count)
$manifest | Group-Object Folder | ForEach-Object {
    Write-Host ("    {0,-10} {1} 个" -f $(if ($_.Name) { $_.Name } else { '(根目录)' }), $_.Count) -ForegroundColor DarkGray
}

# ============================================================
# 3. 生成 .wxs
# ============================================================
Write-Step '生成 WiX 源文件'
function New-DeterministicGuid([string]$seed) {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $hash = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($seed))
    $bytes = New-Object byte[] 16
    [Array]::Copy($hash, $bytes, 16)
    return ([Guid]::new($bytes)).ToString().ToUpper()
}
function Get-SafeId([string]$rel) {
    $s = $rel -replace '[^A-Za-z0-9]', '_'
    if ($s -match '^[0-9]') { $s = 'x' + $s }
    return $s
}

$subDirs = @{ 'scripts' = 'DirScripts'; 'docs' = 'DirDocs'; 'build' = 'DirBuild' }
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
[void]$sb.AppendLine('<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">')
[void]$sb.AppendLine(('  <Product Id="*" Name="{0}" Language="2052" Version="{1}" Manufacturer="{2}" UpgradeCode="{3}">' -f $ProductName, $Version, $Manufacturer, $UpgradeCode))
[void]$sb.AppendLine(('    <Package Id="*" Keywords="Installer" Description="{0}：CMD/PowerShell 速查手册 + 13 个脚本工具 + WinForms 图形工具台"' -f $ProductName))
[void]$sb.AppendLine(('             Comments="{0}" Manufacturer="{1}" InstallerVersion="500" Compressed="yes"' -f $Homepage, $Manufacturer))
[void]$sb.AppendLine('             InstallScope="perUser" Platform="x64" Languages="2052" />')
[void]$sb.AppendLine('    <MajorUpgrade DowngradeErrorMessage="已经安装了更新的版本，请先在「设置 → 应用」里卸载后再安装。" />')
[void]$sb.AppendLine('    <MediaTemplate EmbedCab="yes" CompressionLevel="high" />')
[void]$sb.AppendLine('    <Property Id="ARPPRODUCTICON" Value="AppIcon" />')
[void]$sb.AppendLine(('    <Property Id="ARPHELPLINK" Value="{0}" />' -f $Homepage))
[void]$sb.AppendLine(('    <Property Id="ARPURLINFOABOUT" Value="{0}" />' -f $Homepage))
[void]$sb.AppendLine('    <Property Id="ARPNOREPAIR" Value="1" />')
# 按用户安装：ALLUSERS=2 + MSIINSTALLPERUSER=1，且必须 Secure="yes"，
# 否则在由安装服务代执行的托管安装里属性传不到服务端会话，会退化成机器级注册。
[void]$sb.AppendLine('    <Property Id="ALLUSERS" Value="2" Secure="yes" />')
[void]$sb.AppendLine('    <Property Id="MSIINSTALLPERUSER" Value="1" Secure="yes" />')
# ARPINSTALLLOCATION 直接写 Property 会被当成非法属性引用（CNDL1077），要用 SetProperty 生成 type 51 自定义动作
[void]$sb.AppendLine('    <SetProperty Id="ARPINSTALLLOCATION" Value="[INSTALLFOLDER]" After="CostFinalize" Sequence="both" />')
[void]$sb.AppendLine('    <Property Id="WIXUI_INSTALLDIR" Value="INSTALLFOLDER" />')
[void]$sb.AppendLine('    <UIRef Id="WixUI_InstallDir" />')
[void]$sb.AppendLine(('    <Icon Id="AppIcon" SourceFile="{0}" />' -f (Join-Path $buildDir 'app.ico')))

[void]$sb.AppendLine('    <Directory Id="TARGETDIR" Name="SourceDir">')
[void]$sb.AppendLine('      <Directory Id="LocalAppDataFolder">')
[void]$sb.AppendLine('        <Directory Id="ProgramsFolder" Name="Programs">')
[void]$sb.AppendLine(('          <Directory Id="INSTALLFOLDER" Name="{0}">' -f $InstallFolderName))
foreach ($k in $subDirs.Keys) { [void]$sb.AppendLine(('            <Directory Id="{0}" Name="{1}" />' -f $subDirs[$k], $k)) }
[void]$sb.AppendLine('          </Directory>')
[void]$sb.AppendLine('        </Directory>')
[void]$sb.AppendLine('      </Directory>')
[void]$sb.AppendLine('      <Directory Id="ProgramMenuFolder">')
[void]$sb.AppendLine(('        <Directory Id="AppMenuFolder" Name="{0}" />' -f $ProductName))
[void]$sb.AppendLine('      </Directory>')
[void]$sb.AppendLine('      <Directory Id="DesktopFolder" />')
[void]$sb.AppendLine('    </Directory>')

# 快捷方式组件：装在用户目录里，KeyPath 必须是 HKCU 注册表键（否则 ICE38/43/57 报错）
$scGuidMenu = New-DeterministicGuid 'win-toolkit:shortcut:startmenu'
$scGuidDesk = New-DeterministicGuid 'win-toolkit:shortcut:desktop'
[void]$sb.AppendLine('    <DirectoryRef Id="AppMenuFolder">')
[void]$sb.AppendLine(('      <Component Id="cmp_StartMenuShortcut" Guid="{0}">' -f $scGuidMenu))
[void]$sb.AppendLine(('        <Shortcut Id="StartMenuLink" Name="{0}" Description="打开图形工具台" Target="[INSTALLFOLDER]Windows常用指令集.exe" WorkingDirectory="INSTALLFOLDER" />' -f $ProductName))
[void]$sb.AppendLine('        <RemoveFolder Id="rmAppMenuFolder" Directory="AppMenuFolder" On="uninstall" />')
[void]$sb.AppendLine('        <RegistryValue Root="HKCU" Key="Software\112-a-eng\WinToolkit" Name="StartMenu" Type="integer" Value="1" KeyPath="yes" />')
[void]$sb.AppendLine('      </Component>')
[void]$sb.AppendLine('    </DirectoryRef>')
[void]$sb.AppendLine('    <DirectoryRef Id="DesktopFolder">')
[void]$sb.AppendLine(('      <Component Id="cmp_DesktopShortcut" Guid="{0}">' -f $scGuidDesk))
[void]$sb.AppendLine(('        <Shortcut Id="DesktopLink" Name="{0}" Description="打开图形工具台" Target="[INSTALLFOLDER]Windows常用指令集.exe" WorkingDirectory="INSTALLFOLDER" />' -f $ProductName))
[void]$sb.AppendLine('        <RegistryValue Root="HKCU" Key="Software\112-a-eng\WinToolkit" Name="Desktop" Type="integer" Value="1" KeyPath="yes" />')
[void]$sb.AppendLine('      </Component>')
[void]$sb.AppendLine('    </DirectoryRef>')

# 文件组件：装到用户配置目录，KeyPath 用 HKCU 注册表键（ICE38）；
# 每个目录的第一个组件负责登记目录删除（ICE64）。
$dirIds = @{ '' = 'INSTALLFOLDER' }
foreach ($k in $subDirs.Keys) { $dirIds[$k] = $subDirs[$k] }
$removeMap = @{
    ''        = @('INSTALLFOLDER', 'ProgramsFolder')
    'scripts' = @('DirScripts')
    'docs'    = @('DirDocs')
    'build'   = @('DirBuild')
}
foreach ($folder in ($manifest | Group-Object Folder)) {
    $dirId = $dirIds[$folder.Name]
    [void]$sb.AppendLine(('    <DirectoryRef Id="{0}">' -f $dirId))
    $first = $true
    foreach ($item in $folder.Group) {
        $cmpId  = 'cmp_' + (Get-SafeId ($folder.Name + '_' + $item.Rel))
        $fileId = 'fil_' + (Get-SafeId ($folder.Name + '_' + $item.Rel))
        $guid   = New-DeterministicGuid ('win-toolkit:' + $folder.Name + '/' + $item.Rel)
        [void]$sb.AppendLine(('      <Component Id="{0}" Guid="{1}">' -f $cmpId, $guid))
        [void]$sb.AppendLine(('        <File Id="{0}" Source="{1}" />' -f $fileId, $item.Source))
        [void]$sb.AppendLine(('        <RegistryValue Root="HKCU" Key="Software\112-a-eng\WinToolkit\Components" Name="{0}" Type="integer" Value="1" KeyPath="yes" />' -f $cmpId))
        if ($first) {
            foreach ($rm in $removeMap[$folder.Name]) {
                [void]$sb.AppendLine(('        <RemoveFolder Id="rmf_{0}" Directory="{1}" On="uninstall" />' -f (Get-SafeId $rm), $rm))
            }
            $first = $false
        }
        [void]$sb.AppendLine('      </Component>')
    }
    [void]$sb.AppendLine('    </DirectoryRef>')
}

[void]$sb.AppendLine(('    <Feature Id="MainFeature" Title="{0}" Level="1" Display="expand" Description="图形工具台、命令行脚本与速查手册">' -f $ProductName))
[void]$sb.AppendLine('      <ComponentRef Id="cmp_StartMenuShortcut" />')
[void]$sb.AppendLine('      <ComponentRef Id="cmp_DesktopShortcut" />')
foreach ($folder in ($manifest | Group-Object Folder)) {
    foreach ($item in $folder.Group) {
        [void]$sb.AppendLine(('      <ComponentRef Id="cmp_{0}" />' -f (Get-SafeId ($folder.Name + '_' + $item.Rel))))
    }
}
[void]$sb.AppendLine('    </Feature>')
[void]$sb.AppendLine('  </Product>')
[void]$sb.AppendLine('</Wix>')

$wxsPath = Join-Path $stage 'installer.wxs'
[System.IO.File]::WriteAllText($wxsPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("  {0}（{1:N0} 字节，{2} 个组件）" -f $wxsPath, (Get-Item $wxsPath).Length, $manifest.Count + 2) -ForegroundColor DarkGray

# ============================================================
# 4. 中文语言包（只覆盖显眼字符串，其余回落内置英文）
# ============================================================
$locArgs = @()
if (-not $EnglishUi) {
    Write-Step '生成中文安装向导语言包'
    $zh = @'
<?xml version="1.0" encoding="utf-8"?>
<WixLocalization Culture="zh-CN" Codepage="936" xmlns="http://schemas.microsoft.com/wix/2006/localization">
  <String Id="WixUIBack">上一步(&amp;B)</String>
  <String Id="WixUINext">下一步(&amp;N)</String>
  <String Id="WixUICancel">取消</String>
  <String Id="WixUIFinish">完成(&amp;F)</String>
  <String Id="WixUIOK">确定</String>
  <String Id="WixUIYes">是(&amp;Y)</String>
  <String Id="WixUINo">否(&amp;N)</String>
  <String Id="WixUIRetry">重试(&amp;R)</String>
  <String Id="WixUIIgnore">忽略(&amp;I)</String>
  <String Id="WelcomeDlgTitle">欢迎使用 [ProductName] 安装向导</String>
  <String Id="WelcomeDlgDescription">安装向导将引导你完成 [ProductName] 的安装。点击“下一步”继续，或点击“取消”退出。</String>
  <String Id="InstallDirDlgTitle">选择安装位置</String>
  <String Id="InstallDirDlgDescription">请选择 [ProductName] 的安装文件夹，然后点击“下一步”。</String>
  <String Id="InstallDirDlgFolderLabel">安装到：</String>
  <String Id="InstallDirDlgChange">更改(&amp;C)…</String>
  <String Id="DiskCostDlgTitle">磁盘空间要求</String>
  <String Id="DiskCostDlgDescription">下列卷上需要有足够的磁盘空间。</String>
  <String Id="VerifyReadyDlgInstallTitle">准备安装</String>
  <String Id="VerifyReadyDlgInstallText">点击“安装”开始安装 [ProductName]。若要检查或更改设置，请点击“上一步”。</String>
  <String Id="VerifyReadyDlgChangeTitle">准备更改</String>
  <String Id="VerifyReadyDlgChangeText">点击“安装”开始更改 [ProductName] 的安装。</String>
  <String Id="VerifyReadyDlgRepairTitle">准备修复</String>
  <String Id="VerifyReadyDlgRepairText">点击“修复”开始修复 [ProductName]。</String>
  <String Id="VerifyReadyDlgRemoveTitle">准备卸载</String>
  <String Id="VerifyReadyDlgRemoveText">点击“卸载”从计算机中移除 [ProductName]。</String>
  <String Id="VerifyReadyDlgUpdateTitle">准备更新</String>
  <String Id="VerifyReadyDlgUpdateText">点击“安装”开始更新 [ProductName]。</String>
  <String Id="ProgressDlgTitleInstalling">正在安装 [ProductName]</String>
  <String Id="ProgressDlgTextInstalling">安装向导正在安装 [ProductName]，请稍候。</String>
  <String Id="ProgressDlgTitleChanging">正在更改 [ProductName]</String>
  <String Id="ProgressDlgTextChanging">安装向导正在更改 [ProductName] 的安装，请稍候。</String>
  <String Id="ProgressDlgTitleRepairing">正在修复 [ProductName]</String>
  <String Id="ProgressDlgTextRepairing">安装向导正在修复 [ProductName]，请稍候。</String>
  <String Id="ProgressDlgTitleRemoving">正在卸载 [ProductName]</String>
  <String Id="ProgressDlgTextRemoving">安装向导正在卸载 [ProductName]，请稍候。</String>
  <String Id="ProgressDlgTitleUpdating">正在更新 [ProductName]</String>
  <String Id="ProgressDlgTextUpdating">安装向导正在更新 [ProductName]，请稍候。</String>
  <String Id="ProgressDlgStatusLabel">状态：</String>
  <String Id="ProgressDlgProgressBar">进度</String>
  <String Id="ExitDialogTitle">已完成 [ProductName] 安装向导</String>
  <String Id="ExitDialogDescription">已成功安装 [ProductName]。点击“完成”关闭安装向导。</String>
  <String Id="UserExitTitle">[ProductName] 安装向导被中断</String>
  <String Id="UserExitDescription1">[ProductName] 未完成安装，你的系统没有被修改。若要稍后继续请重新运行安装程序。</String>
  <String Id="UserExitDescription2">点击“完成”关闭安装向导。</String>
  <String Id="FatalErrorTitle">[ProductName] 安装向导被中断</String>
  <String Id="FatalErrorDescription1">[ProductName] 安装失败，你的系统没有被修改。</String>
  <String Id="FatalErrorDescription2">点击“完成”关闭安装向导。</String>
  <String Id="CancelDlgText">确定要取消 [ProductName] 的安装吗？</String>
  <String Id="CancelDlgTitle">取消安装</String>
  <String Id="FilesInUseTitle">文件正在使用</String>
  <String Id="FilesInUseDescription">下列程序正在使用需要更新的文件，请关闭后点击“重试”，或点击“退出”结束安装。</String>
  <String Id="FilesInUseExit">退出(&amp;X)</String>
  <String Id="MaintenanceWelcomeDlgTitle">欢迎使用 [ProductName] 维护向导</String>
  <String Id="MaintenanceWelcomeDlgDescription">安装向导允许你修复或移除 [ProductName]。点击“下一步”继续。</String>
  <String Id="MaintenanceTypeDlgTitle">更改、修复或卸载</String>
  <String Id="MaintenanceTypeDlgDescription">请选择要对 [ProductName] 执行的操作。</String>
  <String Id="MaintenanceTypeDlgRepairButton">修复(&amp;R)</String>
  <String Id="MaintenanceTypeDlgRepairText">修复安装过程中的错误、快捷方式与注册表项。</String>
  <String Id="MaintenanceTypeDlgRemoveButton">卸载(&amp;M)</String>
  <String Id="MaintenanceTypeDlgRemoveText">从计算机中移除 [ProductName]。</String>
  <String Id="UITextTimeRemaining">剩余时间：[TimeRemaining]</String>
  <String Id="UITextMB">[MB] MB</String>
  <String Id="UITextKB">[KB] KB</String>
  <String Id="UITextGB">[GB] GB</String>
  <String Id="UITextbytes">[BYTES] 字节</String>
</WixLocalization>
'@
    $wxlPath = Join-Path $stage 'zh-CN.wxl'
    [System.IO.File]::WriteAllText($wxlPath, $zh, (New-Object System.Text.UTF8Encoding($false)))
    $locArgs = @('-loc', $wxlPath)
    Write-Host ("  {0}" -f $wxlPath) -ForegroundColor DarkGray
}

# ============================================================
# 5. 编译
# ============================================================
Write-Step '编译 MSI'
$wixobj = Join-Path $stage 'installer.wixobj'
$msiTmp = Join-Path $stage 'out.msi'
$uiExt  = Join-Path $WixDir 'WixUIExtension.dll'

Write-Host '  candle…' -ForegroundColor DarkGray
& $candle -nologo -ext $uiExt -out $wixobj $wxsPath
if ($LASTEXITCODE -ne 0) { throw ("candle 失败，退出码 " + $LASTEXITCODE) }

Write-Host '  light…' -ForegroundColor DarkGray
$lightArgs = @('-nologo', '-ext', $uiExt, '-cultures:zh-CN', '-sice:ICE91', '-out', $msiTmp) + $locArgs + @($wixobj)
if ($EnglishUi) { $lightArgs = @('-nologo', '-ext', $uiExt, '-sice:ICE91', '-out', $msiTmp) + @($wixobj) }
$lightOut = & $light @lightArgs 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Host $lightOut -ForegroundColor DarkGray
    $missing = [regex]::Matches($lightOut, '!\(loc\.([A-Za-z0-9_]+)\)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    if ($missing.Count -gt 0 -and -not $EnglishUi) {
        Write-Host ("  语言包缺 {0} 项，自动补齐后重试…" -f $missing.Count) -ForegroundColor Yellow
        $extra = ($missing | ForEach-Object { '  <String Id="' + $_ + '"></String>' }) -join "`r`n"
        $cur = [System.IO.File]::ReadAllText($wxlPath)
        $cur = $cur -replace '</WixLocalization>', ($extra + "`r`n</WixLocalization>")
        [System.IO.File]::WriteAllText($wxlPath, $cur, (New-Object System.Text.UTF8Encoding($false)))
        $lightOut = & $light @lightArgs 2>&1 | Out-String
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host $lightOut -ForegroundColor DarkGray
        throw ("light 失败，退出码 " + $LASTEXITCODE)
    }
}
if ($lightOut.Trim()) { $lightOut.Trim() -split "`r?`n" | ForEach-Object { Write-Host ('    ' + $_) -ForegroundColor DarkGray } }

Copy-Item -LiteralPath $msiTmp -Destination $OutputPath -Force
$f = Get-Item -LiteralPath $OutputPath
Write-Host ''
Write-Host ("  生成成功: {0}" -f $f.FullName) -ForegroundColor Green
Write-Host ("  大小    : {0:N0} 字节 ({1:N0} KB)" -f $f.Length, ($f.Length / 1KB)) -ForegroundColor Green
Write-Host ("  SHA256  : {0}" -f (Get-FileHash $f.FullName -Algorithm SHA256).Hash)

if (-not $KeepTemp) {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Host ("  中间产物: {0}" -f $stage) -ForegroundColor DarkGray
}
Write-Host ''
