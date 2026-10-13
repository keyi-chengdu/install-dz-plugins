#requires -Version 5.1
<#
.SYNOPSIS
    把 dsh-plugins 下的 DSH 宿主插件安装进本机 DSH Web profile。

.DESCRIPTION
    单插件幂等安装：备份 profile package.json -> 物理拷贝插件到 node_modules\<name>
    （排除 .git）-> 幂等登记 file: 依赖与 dsh.profile.bundles -> 校验拷贝结果。
    不重启 DSH；生效需按安装指南第 2 节重启（须先经用户确认）。

    红线：禁止用 junction/symlink 链接插件目录（Node 按真实路径解析裸导入，
    junction 曾导致 ERR_MODULE_NOT_FOUND、插件静默加载失败）。必须物理拷贝。

.PARAMETER Name
    插件名（dsh-plugins 下的目录名，且必须是宿主插件：含 package.json + index.js）。

.PARAMETER PluginsDir
    dsh-plugins 目录。缺省时从本脚本位置逐级向上探测名为 dsh-plugins 的子目录。

.PARAMETER ProfileDir
    DSH profile 目录（含 package.json）。缺省按 %LOCALAPPDATA%\DSH Web\dsh-home.path 探测。

.EXAMPLE
    pwsh -File install-dsh-plugin.ps1 -Name dsh-gas-plan
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Name,

    [string]$PluginsDir,

    [string]$ProfileDir
)

$ErrorActionPreference = 'Stop'

function Fail([string]$Message) { throw "[install-dsh-plugin] $Message" }

# ---------- 1) 解析 dsh-plugins 目录 ----------
if (-not $PluginsDir) {
    $probe = Split-Path -Parent $PSScriptRoot   # ...\skills\install-dsh-plugins -> ...\skills
    for ($i = 0; $i -lt 8 -and $probe; $i++) {
        $candidate = Join-Path $probe 'dsh-plugins'
        if (Test-Path -LiteralPath $candidate) { $PluginsDir = $candidate; break }
        $probe = Split-Path -Parent $probe
    }
}
if (-not $PluginsDir -or -not (Test-Path -LiteralPath $PluginsDir)) {
    Fail "未找到 dsh-plugins 目录。请先把整个 dsh-plugins\ 拷贝到本机，再用 -PluginsDir 指定路径。"
}

# ---------- 2) 解析 DSH profile 目录 ----------
if (-not $ProfileDir) {
    $dshWeb   = Join-Path $env:LOCALAPPDATA 'DSH Web'
    $pathFile = Join-Path $dshWeb 'dsh-home.path'
    if (Test-Path -LiteralPath $pathFile) {
        $dshHome = (Get-Content -LiteralPath $pathFile -Raw -Encoding UTF8).Trim()
    } else {
        $dshHome = Join-Path $dshWeb 'dsh-home'
    }
    $ProfileDir = Join-Path $dshHome 'profiles\web'
}
$manifest = Join-Path $ProfileDir 'package.json'
if (-not (Test-Path -LiteralPath $manifest)) {
    Fail "profile 清单不存在: $manifest （确认 DSH Web 已安装，或用 -ProfileDir 指定）"
}

# ---------- 3) 校验插件是宿主插件 ----------
$knownNonPlugins = @('dsh-sync', 'dz-robot-local', 'dz-robot-plugin')
if ($knownNonPlugins -contains $Name) {
    Fail "$Name 不是 DSH 宿主插件（无 package.json/index.js），由 dsh-robot 按约定路径定位，不装进 profile。"
}
$src = Join-Path $PluginsDir $Name
if (-not (Test-Path -LiteralPath $src))          { Fail "插件目录不存在: $src" }
$srcManifest = Join-Path $src 'package.json'
if (-not (Test-Path -LiteralPath $srcManifest))  { Fail "$Name 缺少 package.json，不是宿主插件" }
if (-not (Test-Path -LiteralPath (Join-Path $src 'index.js'))) { Fail "$Name 缺少 index.js，不是宿主插件" }
$srcJson = Get-Content -LiteralPath $srcManifest -Raw -Encoding UTF8 | ConvertFrom-Json
if ($srcJson.name -and $srcJson.name -ne $Name) {
    Write-Warning "目录名($Name)与插件 package.json 的 name($($srcJson.name)) 不一致，登记使用目录名 $Name"
}

Write-Host "== 安装 $Name =="
Write-Host "   插件源 : $src"
Write-Host "   profile: $ProfileDir"

# ---------- 4) 幂等登记 file: 依赖 + bundles ----------
$raw   = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8
$json  = $raw | ConvertFrom-Json

$needDep    = -not ($json.dependencies -and $json.dependencies.PSObject.Properties[$Name])
$needBundle = -not ($json.dsh -and $json.dsh.profile -and $json.dsh.profile.bundles -and @($json.dsh.profile.bundles) -contains $Name)

if ($needDep) {
    $fileDep  = '"file:' + ($PluginsDir -replace '\\', '/') + '/' + $Name + '"'
    $depCount = 0
    if ($json.dependencies) { $depCount = @($json.dependencies.PSObject.Properties).Count }
    $entry = if ($depCount -gt 0) { '    "{0}": {1},' -f $Name, $fileDep } else { '    "{0}": {1}' -f $Name, $fileDep }
    $pattern = '("dependencies"\s*:\s*\{)'
    if ($raw -notmatch $pattern) { Fail 'profile package.json 缺少 dependencies 块' }
    $raw = $raw -replace $pattern, ('$1' + "`r`n" + $entry)
}
if ($needBundle) {
    $bCount = 0
    if ($json.dsh -and $json.dsh.profile -and $json.dsh.profile.bundles) { $bCount = @($json.dsh.profile.bundles).Count }
    $bEntry = if ($bCount -gt 0) { '        "{0}",' -f $Name } else { '        "{0}"' -f $Name }
    $pattern2 = '("bundles"\s*:\s*\[)'
    if ($raw -notmatch $pattern2) { Fail 'profile package.json 缺少 dsh.profile.bundles 块' }
    $raw = $raw -replace $pattern2, ('$1' + "`r`n" + $bEntry)
}

if ($needDep -or $needBundle) {
    # 校验失败则抛异常，不落盘
    $null = $raw | ConvertFrom-Json
    $backup = Join-Path $ProfileDir ('package.json.backup-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath $manifest -Destination $backup -Force
    [System.IO.File]::WriteAllText($manifest, $raw, (New-Object System.Text.UTF8Encoding($false)))
    # 回读确认登记成功
    $check = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $check.dependencies.PSObject.Properties[$Name]) { Fail '回读校验失败：dependencies 未登记成功' }
    if (@($check.dsh.profile.bundles) -notcontains $Name)    { Fail '回读校验失败：bundles 未登记成功' }
    Write-Host "   [1/2] 已登记 file: 依赖 + bundles（原清单备份: $(Split-Path -Leaf $backup)）"
} else {
    Write-Host '   [1/2] package.json 已登记过该插件，跳过清单修改'
}

# ---------- 5) 物理拷贝（禁止 junction/symlink） ----------
$dst = Join-Path $ProfileDir (Join-Path 'node_modules' $Name)
if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
$dstGit = Join-Path $dst '.git'
if (Test-Path -LiteralPath $dstGit) { Remove-Item -LiteralPath $dstGit -Recurse -Force }
Write-Host '   [2/2] 已物理拷贝到 node_modules（排除 .git）'

# ---------- 6) 拷贝结果校验 ----------
foreach ($f in @('package.json', 'index.js')) {
    if (-not (Test-Path -LiteralPath (Join-Path $dst $f))) { Fail "拷贝后缺少 $f，请检查源目录" }
}
if ($Name -eq 'dsh-robot' -and -not (Test-Path -LiteralPath (Join-Path $dst 'bootstrap'))) {
    Write-Warning 'dsh-robot 拷贝缺 bootstrap/ —— 检查其 package.json 的 files 白名单（pnpm install 按白名单裁剪时会丢弃）'
}

Write-Host ''
Write-Host '完成。生效还需重启 DSH Web（约 1 分钟离线，已开会话可恢复）：'
Write-Host '  - 经用户确认后，优先用 dsh-plugins\dsh-sync\restart-dsh-web.ps1；'
Write-Host '  - 或按 dsh-plugins\安装指南.md 第 2 节手动重启。'
if ($Name -eq 'dsh-robot') {
    Write-Host 'dsh-robot 装完必做（安装指南第 3 节）：设置页确认 + 安装-初始化.cmd + 凭据入 secrets.local.yaml。'
}
