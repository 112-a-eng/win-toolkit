<#
.SYNOPSIS
    计算文件哈希（MD5/SHA1/SHA256/SHA512），可按校验文件逐项比对
.DESCRIPTION
    普通模式：列出每个文件的大小与哈希值，目录默认只算第一层，加 -Recurse 递归。
    校验模式（-Verify）：按 sha256sum 输出格式（每行「哈希 + 空格 + 文件名」）逐行比对，
    输出「匹配 / 不匹配 / 文件缺失」三态；只要有一项不匹配就以退出码 1 结束。
    哈希长度会自动识别算法，所以一份校验文件里混用 MD5/SHA1/SHA256/SHA512 也能比对。
.PARAMETER Path
    要计算哈希的文件或目录，可多个；-Verify 模式下同时作为校验文件里相对路径的基准目录。
.PARAMETER Algorithm
    哈希算法：MD5 / SHA1 / SHA256 / SHA512，默认 SHA256。
.PARAMETER Recurse
    -Path 是目录时递归子目录；单个文件时本参数无意义。
.PARAMETER Export
    把结果导出为 CSV，例如 D:\hash.csv（UTF-8，带 BOM）。校验模式下导出的是比对结果。
.PARAMETER Verify
    校验文件路径（sha256sum 格式），进入比对模式而不是重新计算。
.EXAMPLE
    .\09-文件哈希.ps1 -Path .\scripts\01-系统信息.ps1
.EXAMPLE
    .\09-文件哈希.ps1 -Path D:\备份 -Recurse -Algorithm SHA512 -Export D:\hash.csv
.EXAMPLE
    .\09-文件哈希.ps1 -Verify D:\checksums.sha256 -Path D:\下载
#>
[CmdletBinding()]
param(
    [string[]]$Path = @(),
    [ValidateSet('MD5', 'SHA1', 'SHA256', 'SHA512')]
    [string]$Algorithm = 'SHA256',   # 支持 MD5/SHA1/SHA256/SHA512
    [switch]$Recurse,
    [string]$Export,                 # 导出 CSV
    [string]$Verify                  # 校验模式：指向校验文件
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

$Algorithm = $Algorithm.ToUpperInvariant()

function Write-Title([string]$Text) {
    $line = '=' * [Math]::Max(4, 58 - $Text.Length)
    Write-Host ''
    Write-Host "== $Text " -ForegroundColor Cyan -NoNewline
    Write-Host $line -ForegroundColor DarkCyan
}

# 按哈希字符串长度猜算法（32=MD5 40=SHA1 64=SHA256 128=SHA512）
function Get-AlgorithmByLength([string]$Hash) {
    switch ($Hash.Length) {
        32  { return 'MD5' }
        40  { return 'SHA1' }
        64  { return 'SHA256' }
        128 { return 'SHA512' }
        default { return $Algorithm }
    }
}

# 计算单个文件哈希，任何失败都只返回 $null，不抛异常
function Get-FileHashSafe([string]$FilePath, [string]$Alg) {
    try {
        $h = Get-FileHash -LiteralPath $FilePath -Algorithm $Alg -ErrorAction Stop
        if ($h) { return $h.Hash.ToUpperInvariant() }
    } catch { }
    return $null
}

function Format-Size([int64]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

Write-Host ''
Write-Host ' 文件哈希计算 / 校验' -ForegroundColor White -BackgroundColor DarkBlue

# ---------------- 参数预处理 ----------------
$pathList  = @()
$pathMiss  = @()
if ($Path) {
    foreach ($p in $Path) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if (Test-Path -LiteralPath $p) {
            $pathList += (Resolve-Path -LiteralPath $p).ProviderPath.TrimEnd('\')
        } else {
            $pathMiss += $p
        }
    }
}

foreach ($p in $pathMiss) {
    Write-Host (" 路径不存在：{0}" -f $p) -ForegroundColor Red
}
if ($pathMiss.Count -gt 0) {
    Write-Host ' 请检查路径是否写错，或该位置已被移除；支持一次传多个路径。' -ForegroundColor DarkGray
}
if ($Path -and $pathList.Count -eq 0) {
    Write-Host ' 没有任何可用路径，已退出。' -ForegroundColor Red
    exit 1
}

# ================= 模式一：-Verify 校验 =================
if ($Verify) {
    Write-Host (" 校验文件: {0}" -f $Verify) -ForegroundColor DarkGray

    if (-not (Test-Path -LiteralPath $Verify -PathType Leaf)) {
        Write-Host ''
        Write-Host (" 找不到校验文件：{0}" -f $Verify) -ForegroundColor Red
        Write-Host ' 校验文件应为 sha256sum 格式，每行: <哈希>  <文件名或相对路径>' -ForegroundColor DarkGray
        Write-Host ''
        exit 1
    }

    # 相对路径的基准目录：优先 -Path，其次校验文件所在目录
    $baseDir = $null
    if ($pathList.Count -gt 0) {
        $baseDir = $pathList[0]
        if (-not (Test-Path -LiteralPath $baseDir -PathType Container)) {
            $baseDir = Split-Path -Parent $baseDir
        }
    }
    if (-not $baseDir) {
        $verifyFull = (Resolve-Path -LiteralPath $Verify).ProviderPath
        $baseDir = Split-Path -Parent $verifyFull
    }
    Write-Host (" 基准目录: {0}" -f $baseDir) -ForegroundColor DarkGray
    Write-Host (" 默认算法: {0}（按哈希长度自动识别）" -f $Algorithm) -ForegroundColor DarkGray

    $lines = @(Get-Content -LiteralPath $Verify -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) {
        Write-Host ''
        Write-Host ' 校验文件为空，没有可比对的内容。' -ForegroundColor Yellow
        Write-Host ''
        exit 0
    }

    Write-Title '逐项比对'

    $match = 0
    $bad = 0
    $missing = 0
    $skipped = 0
    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($raw in $lines) {
        $line = "$raw".Trim()
        if ($line.Length -eq 0) { continue }
        if ($line.StartsWith('#')) { continue }

        # sha256sum 格式：哈希 空格（或 *）文件名；文件名里允许有空格
        $m = [regex]::Match($line, '^([0-9A-Fa-f]{32,128})\s+\*?(.+)$')
        if (-not $m.Success) {
            $skipped++
            Write-Host ("   [跳过] {0}" -f $line) -ForegroundColor DarkGray
            continue
        }

        $expect = $m.Groups[1].Value.ToUpperInvariant()
        $name   = $m.Groups[2].Value.Trim().Trim('"')
        $alg    = Get-AlgorithmByLength $expect

        # 相对路径拼到基准目录下
        if ([System.IO.Path]::IsPathRooted($name)) {
            $full = $name
        } else {
            $full = Join-Path $baseDir $name
        }

        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            $missing++
            Write-Host ("   [文件缺失] {0}" -f $name) -ForegroundColor Yellow
            $rows.Add([pscustomobject]@{
                状态 = '文件缺失'; 算法 = $alg; 文件 = $name; 期望哈希 = $expect; 实际哈希 = ''
            })
            continue
        }

        $actual = Get-FileHashSafe $full $alg
        if (-not $actual) {
            $skipped++
            Write-Host ("   [无法读取] {0}（文件被占用或没有权限）" -f $name) -ForegroundColor Yellow
            $rows.Add([pscustomobject]@{
                状态 = '无法读取'; 算法 = $alg; 文件 = $name; 期望哈希 = $expect; 实际哈希 = ''
            })
            continue
        }

        if ($actual -eq $expect) {
            $match++
            Write-Host ("   [匹配]     {0}" -f $name) -ForegroundColor Green
            $rows.Add([pscustomobject]@{
                状态 = '匹配'; 算法 = $alg; 文件 = $name; 期望哈希 = $expect; 实际哈希 = $actual
            })
        } else {
            $bad++
            Write-Host ("   [不匹配]   {0}" -f $name) -ForegroundColor Red
            Write-Host ("             期望 {0}" -f $expect) -ForegroundColor DarkGray
            Write-Host ("             实际 {0}" -f $actual) -ForegroundColor DarkGray
            $rows.Add([pscustomobject]@{
                状态 = '不匹配'; 算法 = $alg; 文件 = $name; 期望哈希 = $expect; 实际哈希 = $actual
            })
        }
    }

    Write-Title '比对统计'
    Write-Host ("   匹配: {0}    不匹配: {1}    文件缺失: {2}" -f $match, $bad, $missing) -ForegroundColor Yellow
    if ($skipped -gt 0) {
        Write-Host ("   跳过/无法读取: {0}" -f $skipped) -ForegroundColor DarkGray
    }
    if ($bad -gt 0 -or $missing -gt 0) {
        Write-Host ("   注意: 有 {0} 个文件校验不通过、{1} 个文件缺失。" -f $bad, $missing) -ForegroundColor Red
    }

    if ($Export) {
        try {
            $rows | Export-Csv -LiteralPath $Export -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
            Write-Host (" 已导出比对结果 {0} 条到: {1}" -f $rows.Count, $Export) -ForegroundColor Green
        } catch {
            Write-Host (" 导出失败: {0}" -f $_.Exception.Message) -ForegroundColor Red
        }
    }

    Write-Host ''
    if ($bad -gt 0) {
        Write-Host ' 结论: 存在不匹配的文件，内容可能已损坏或被改动。' -ForegroundColor Red
        Write-Host ''
        exit 1
    }
    if ($missing -gt 0) {
        Write-Host ' 结论: 没有哈希不匹配，但有文件缺失，请先补齐再校验。' -ForegroundColor Yellow
        Write-Host ''
        exit 0
    }
    Write-Host (" 结论: 全部 {0} 项校验通过，文件完整。" -f $match) -ForegroundColor Green
    Write-Host ''
    exit 0
}

# ================= 模式二：普通计算 =================
if ($pathList.Count -eq 0) {
    if ($Path) { exit 1 }
    $pathList = @((Get-Location).Path)
    Write-Host (" 未指定 -Path，按当前目录处理: {0}" -f $pathList[0]) -ForegroundColor DarkGray
}
Write-Host (" 算法: {0}{1}" -f $Algorithm, $(if ($Recurse) { '   递归: 是' } else { '   递归: 否' })) -ForegroundColor DarkGray

Write-Title '文件清单'

$files = @()
$seen  = @{}
foreach ($p in $pathList) {
    if (Test-Path -LiteralPath $p -PathType Container) {
        $items = @(Get-ChildItem -LiteralPath $p -Recurse:$Recurse -File -Force -ErrorAction SilentlyContinue)
    } else {
        $items = @(Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue)
    }
    foreach ($f in $items) {
        $key = "$($f.FullName)".ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $files += $f
        }
    }
}
$files = @($files | Sort-Object FullName)
$fileCount = $files.Count
$totalSize = ($files | Measure-Object Length -Sum).Sum

if ($fileCount -eq 0) {
    Write-Host ' 没有找到任何文件。' -ForegroundColor Yellow
    if (-not $Recurse) {
        Write-Host ' 如果文件在子目录里，请加上 -Recurse。' -ForegroundColor DarkGray
    }
    Write-Host ''
    exit 0
}

Write-Host ("   共 {0} 个文件，合计 {1}" -f $fileCount, (Format-Size ([int64]$totalSize))) -ForegroundColor Yellow

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$results = New-Object System.Collections.Generic.List[object]
$failed  = 0

foreach ($f in $files) {
    $hash = Get-FileHashSafe $f.FullName $Algorithm
    $rel  = $f.FullName
    foreach ($p in $pathList) {
        if (Test-Path -LiteralPath $p -PathType Container) {
            $pfx = "$p".TrimEnd('\')
            if ($f.FullName.StartsWith($pfx + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                $rel = $f.FullName.Substring($pfx.Length + 1)
                break
            }
        }
    }

    if ($hash) {
        Write-Host ("   [{0}] {1}" -f $Algorithm, $rel) -ForegroundColor Green
    } else {
        $failed++
        Write-Host ("   [读取失败] {0}（文件被占用或没有权限）" -f $rel) -ForegroundColor Red
    }
    Write-Host ("           大小: {0}" -f (Format-Size ([int64]$f.Length))) -ForegroundColor DarkGray
    Write-Host ("           哈希: {0}" -f $(if ($hash) { $hash } else { '(无法计算)' })) -ForegroundColor DarkGray

    $results.Add([pscustomobject]@{
        文件      = $f.FullName
        相对路径  = $rel
        大小      = $f.Length
        大小可读  = Format-Size ([int64]$f.Length)
        算法      = $Algorithm
        哈希      = $hash
        修改时间  = $f.LastWriteTime
    })
}
$sw.Stop()

Write-Title '汇总'
Write-Host ("   文件数: {0}    合计大小: {1}" -f $fileCount, (Format-Size ([int64]$totalSize))) -ForegroundColor Yellow
Write-Host ("   算法: {0}    耗时: {1:N1} 秒" -f $Algorithm, $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray
if ($failed -gt 0) {
    Write-Host ("   有 {0} 个文件读取失败，未计入哈希。" -f $failed) -ForegroundColor Yellow
}

if ($Export) {
    try {
        $results | Export-Csv -LiteralPath $Export -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        Write-Host (" 已导出 {0} 条到: {1}" -f $results.Count, $Export) -ForegroundColor Green
    } catch {
        Write-Host (" 导出失败: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

Write-Host ''
Write-Host ' 小提示: 校验文件就是把这里的「哈希 + 两个空格 + 文件名」保存成文本，再用 -Verify 比对。' -ForegroundColor DarkGray
if (-not $Recurse) {
    Write-Host ' 小提示: 目录当前只算第一层，需要包含子目录请加 -Recurse。' -ForegroundColor DarkGray
}
Write-Host ''
