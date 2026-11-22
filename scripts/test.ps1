#Requires -Version 5.1
<#
.SYNOPSIS
    InvestAI 本地重建工程的启动 / 自检脚本。

.DESCRIPTION
    一键验证当前工程是否可用。默认全程离线（使用 scripts/mock-anthropic.ts
    作为本地 Messages API mock），不消耗任何 token、不依赖外部网络。

    自检覆盖：
      1. Bun / Node 运行时
      2. 依赖完整性（必要时自动 bun install）
      3. --version 快路径
      4. --help 参数解析
      5. mcp list 子命令
      6. 离线 -p 非交互查询链路
      7. 离线 Bash tool_use 工具调用链路
      8. （可选）-Live：真实 API 查询链路

    重要：模型配置放在项目根目录的 .env（Bun 自动加载），键名带 INVEST_
    前缀，由 compat/preload.ts 映射为 ANTHROPIC_*；并通过
    INVEST_CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST=1 使项目配置优先于
    ~/.claude/settings.json 的 env 段。离线测试仍带 `--setting-sources=`
    （空值）隔离用户级 settings，并用进程级 INVEST_* 变量覆盖 .env 中的
    端点，确保请求打到本地 mock 而非真实 API。

.PARAMETER Live
    额外跑一次针对真实 API 的 -p 查询（会消耗 token / 产生真实调用）。

.PARAMETER Repl
    自检结束后启动交互式 REPL（使用你自己的 Claude 配置与凭据）。

.PARAMETER SkipInstall
    跳过依赖检查与自动安装。

.PARAMETER MockPort
    本地 mock 服务监听端口，默认 8787。

.EXAMPLE
    .\scripts\test.ps1
    完整离线自检。

.EXAMPLE
    .\scripts\test.ps1 -Live
    离线自检 + 真实 API 自检。

.EXAMPLE
    .\scripts\test.ps1 -Repl
    离线自检 + 启动交互式 REPL。
#>
[CmdletBinding()]
param(
    [switch]$Live,
    [switch]$Repl,
    [switch]$SkipInstall,
    [int]$MockPort = 8787
)

$ErrorActionPreference = 'Continue'

$RepoRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
Set-Location -Path $RepoRoot

$script:Results = @()

# --------------------------------------------------------------------------
# 工具函数
# --------------------------------------------------------------------------

function Add-Result {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL', 'SKIP', 'INFO')][string]$Status,
        [string]$Detail = ''
    )
    $script:Results += [PSCustomObject]@{ Name = $Name; Status = $Status; Detail = $Detail }
    $color = switch ($Status) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        'SKIP' { 'Yellow' }
        default { 'Cyan' }
    }
    $suffix = if ($Detail) { " - $Detail" } else { '' }
    Write-Host ("  [{0}] {1}{2}" -f $Status, $Name, $suffix) -ForegroundColor $color
}

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ""
    Write-Host "== $Title ==" -ForegroundColor Cyan
}

function Resolve-BunExe {
    # 优先使用真实 bun.exe，绕开 npm shim（bun.ps1 会把正常输出标成 stderr 噪声）
    if ($env:INVESTAI_BUN -and (Test-Path $env:INVESTAI_BUN)) { return $env:INVESTAI_BUN }
    $candidates = @(
        (Join-Path $env:APPDATA 'npm\node_modules\bun\bin\bun.exe'),
        (Join-Path $env:USERPROFILE '.bun\bin\bun.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    $cmd = Get-Command bun -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Quote-Arg {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

function Invoke-BunCapture {
    <#
      执行 bun 并分别捕获 stdout / stderr 与退出码。
      PS 5.1 的 Start-Process 没有 -Environment，因此临时设置再还原进程环境变量。
    #>
    param(
        [Parameter(Mandatory)][string[]]$BunArgs,
        [hashtable]$EnvVars = @{}
    )
    $saved = @{}
    foreach ($key in @($EnvVars.Keys)) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, [string]$EnvVars[$key], 'Process')
    }
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $argList = @()
        foreach ($a in $BunArgs) { $argList += (Quote-Arg $a) }
        $proc = Start-Process -FilePath $script:BunExe -ArgumentList $argList `
            -WorkingDirectory $RepoRoot -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $stdout = ''
        $stderr = ''
        if (Test-Path $outFile) { $stdout = [string](Get-Content -Raw -Path $outFile -ErrorAction SilentlyContinue) }
        if (Test-Path $errFile) { $stderr = [string](Get-Content -Raw -Path $errFile -ErrorAction SilentlyContinue) }
        return [PSCustomObject]@{ ExitCode = $proc.ExitCode; Stdout = $stdout; Stderr = $stderr }
    } finally {
        foreach ($key in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process')
        }
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-ToolOutput {
    param([Parameter(Mandatory)]$Result)
    $text = ''
    if ($Result.Stdout) { $text += $Result.Stdout }
    if ($Result.Stderr) { $text += "`n" + $Result.Stderr }
    return $text.Trim()
}

function Start-MockServer {
    <# 启动本地 mock，返回 @{ Process = $p; OutFile = $f; ErrFile = $f } #>
    param([Parameter(Mandatory)][int]$Port)
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $savedPort = $env:MOCK_PORT
    $env:MOCK_PORT = "$Port"
    try {
        $proc = Start-Process -FilePath $script:BunExe -ArgumentList @('run', 'scripts/mock-anthropic.ts') `
            -WorkingDirectory $RepoRoot -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    } finally {
        if ($null -eq $savedPort) {
            Remove-Item Env:\MOCK_PORT -ErrorAction SilentlyContinue
        } else {
            $env:MOCK_PORT = $savedPort
        }
    }
    return [PSCustomObject]@{ Process = $proc; OutFile = $outFile; ErrFile = $errFile }
}

function Wait-MockReady {
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutSec = 20
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/" -TimeoutSec 2 -UseBasicParsing
            if ($resp.StatusCode -eq 200) { return $true }
        } catch {
            Start-Sleep -Milliseconds 300
        }
    }
    return $false
}

# --------------------------------------------------------------------------
# 开始
# --------------------------------------------------------------------------

Write-Host ""
Write-Host "InvestAI 工程自检" -ForegroundColor Green
Write-Host "  仓库根目录: $RepoRoot" -ForegroundColor DarkGray
Write-Host "  模式      : $(if ($Live) { '离线 + 真实 API' } else { '离线（不访问外部 API）' })" -ForegroundColor DarkGray

$script:BunExe = Resolve-BunExe
if (-not $script:BunExe) {
    Add-Result -Name 'Bun 运行时' -Status 'FAIL' -Detail '未找到 bun，请先安装：https://bun.sh'
    Write-Host ""
    Write-Host "自检中止：缺少 Bun 运行时。" -ForegroundColor Red
    exit 1
}

# --- 1. 运行时 -----------------------------------------------------------
Write-Section '运行时'

$bunVersion = (& $script:BunExe --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -eq 0 -and $bunVersion) {
    Add-Result -Name 'Bun 运行时' -Status 'PASS' -Detail "v$bunVersion  ($($script:BunExe))"
} else {
    Add-Result -Name 'Bun 运行时' -Status 'FAIL' -Detail "bun --version 失败 (exit $LASTEXITCODE)"
}

$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if ($nodeCmd) {
    $nodeVersion = (& node --version 2>&1 | Out-String).Trim()
    Add-Result -Name 'Node 运行时（可选）' -Status 'INFO' -Detail $nodeVersion
} else {
    Add-Result -Name 'Node 运行时（可选）' -Status 'INFO' -Detail '未安装（本工程运行只需 Bun）'
}

# --- 2. 依赖 -------------------------------------------------------------
Write-Section '依赖'

$depProbe = Join-Path $RepoRoot 'node_modules\@anthropic-ai\sdk\package.json'
if ($SkipInstall) {
    Add-Result -Name '依赖安装' -Status 'SKIP' -Detail '-SkipInstall 已指定'
} elseif (Test-Path $depProbe) {
    Add-Result -Name '依赖安装' -Status 'PASS' -Detail 'node_modules 已就绪'
} else {
    Write-Host '  未检测到 node_modules，正在执行 bun install ...' -ForegroundColor Yellow
    $install = Invoke-BunCapture -BunArgs @('install')
    if ($install.ExitCode -eq 0) {
        Add-Result -Name '依赖安装' -Status 'PASS' -Detail 'bun install 完成'
    } else {
        Add-Result -Name '依赖安装' -Status 'FAIL' -Detail "bun install 失败 (exit $($install.ExitCode))"
    }
}

$envFile = Join-Path $RepoRoot '.env'
if (Test-Path $envFile) {
    Add-Result -Name '项目 .env' -Status 'INFO' -Detail '已就绪（Bun 自动加载模型配置）'
} else {
    Add-Result -Name '项目 .env' -Status 'SKIP' -Detail '未找到；将回退到 ~/.claude/settings.json（可复制 .env.example）'
}

# --- 3. CLI 快路径与子命令 ------------------------------------------------
Write-Section 'CLI 基本功能'

$verRes = Invoke-BunCapture -BunArgs @('run', 'start', '--', '--version')
$verOut = Get-ToolOutput $verRes
if ($verRes.ExitCode -eq 0 -and $verOut -match '\d+\.\d+\.\d+\s+\(Claude Code\)') {
    Add-Result -Name '--version' -Status 'PASS' -Detail $verOut
} else {
    Add-Result -Name '--version' -Status 'FAIL' -Detail "exit $($verRes.ExitCode): $verOut"
}

$helpRes = Invoke-BunCapture -BunArgs @('run', 'start', '--', '--help')
$helpOut = Get-ToolOutput $helpRes
if ($helpRes.ExitCode -eq 0 -and $helpOut -match 'Usage:') {
    Add-Result -Name '--help' -Status 'PASS' -Detail ("共 " + ($helpOut -split "`n").Count + " 行输出")
} else {
    Add-Result -Name '--help' -Status 'FAIL' -Detail "exit $($helpRes.ExitCode): $helpOut"
}

$mcpRes = Invoke-BunCapture -BunArgs @('run', 'start', '--', '--bare', '--setting-sources=', 'mcp', 'list')
$mcpOut = Get-ToolOutput $mcpRes
if ($mcpRes.ExitCode -eq 0) {
    Add-Result -Name 'mcp list' -Status 'PASS' -Detail $mcpOut
} else {
    Add-Result -Name 'mcp list' -Status 'FAIL' -Detail "exit $($mcpRes.ExitCode): $mcpOut"
}

# --- 4. 离线端到端 -------------------------------------------------------
Write-Section '离线端到端（本地 mock，不访问外部 API）'

$mock = $null
try {
    $mock = Start-MockServer -Port $MockPort
    if (-not (Wait-MockReady -Port $MockPort)) {
        $err = ''
        if (Test-Path $mock.ErrFile) { $err = [string](Get-Content -Raw -Path $mock.ErrFile) }
        Add-Result -Name "mock 服务启动 (:$MockPort)" -Status 'FAIL' -Detail ("未就绪 " + $err.Trim())
    } else {
        Add-Result -Name "mock 服务启动 (:$MockPort)" -Status 'PASS' -Detail 'scripts/mock-anthropic.ts 已监听'

        $mockEnv = @{
            'INVEST_ANTHROPIC_BASE_URL' = "http://127.0.0.1:$MockPort"
            'INVEST_ANTHROPIC_API_KEY'  = 'test'
            'INVEST_ANTHROPIC_AUTH_TOKEN' = 'test'
            # INVEST_* 进程变量优先于 .env，preload 会映射到 ANTHROPIC_*，
            # 确保离线打到 mock
            'CLAUDE_CODE_SIMPLE' = '1'
        }

        $pingRes = Invoke-BunCapture -BunArgs @('run', 'start', '--', '--bare', '--setting-sources=', '-p', 'ping') -EnvVars $mockEnv
        $pingOut = Get-ToolOutput $pingRes
        if ($pingRes.ExitCode -eq 0 -and $pingOut -match 'pong \(mock') {
            Add-Result -Name '非交互查询 (-p)' -Status 'PASS' -Detail $pingOut
        } else {
            Add-Result -Name '非交互查询 (-p)' -Status 'FAIL' -Detail "exit $($pingRes.ExitCode): $pingOut"
        }

        $toolRes = Invoke-BunCapture -BunArgs @('run', 'start', '--', '--bare', '--setting-sources=', '-p', 'TOOLCALL please') -EnvVars $mockEnv
        $toolOut = Get-ToolOutput $toolRes
        if ($toolRes.ExitCode -eq 0 -and $toolOut -match 'pong-after-tool \(mock-tool-ok\)') {
            Add-Result -Name 'Bash tool_use 工具链路' -Status 'PASS' -Detail $toolOut
        } else {
            Add-Result -Name 'Bash tool_use 工具链路' -Status 'FAIL' -Detail "exit $($toolRes.ExitCode): $toolOut"
        }
    }
} finally {
    if ($mock) {
        if ($mock.Process) {
            # bun run 会派生子进程，需连同进程树一起结束，否则 mock 会继续监听端口
            & taskkill /PID $mock.Process.Id /T /F *> $null
        }
        Remove-Item $mock.OutFile, $mock.ErrFile -Force -ErrorAction SilentlyContinue
    }
}

# --- 5. 真实 API（可选）--------------------------------------------------
Write-Section '真实 API 链路'

if ($Live) {
    Write-Host '  使用项目 .env 中的模型配置（缺失时回退到 ~/.claude/settings.json）' -ForegroundColor DarkGray
    $liveRes = Invoke-BunCapture -BunArgs @('run', 'start', '--', '--bare', '-p', 'ping')
    $liveOut = Get-ToolOutput $liveRes
    if ($liveRes.ExitCode -eq 0 -and $liveOut) {
        Add-Result -Name '真实 API 查询 (-p)' -Status 'PASS' -Detail ($liveOut -replace '\s+', ' ').Substring(0, [Math]::Min(120, $liveOut.Length))
    } else {
        Add-Result -Name '真实 API 查询 (-p)' -Status 'FAIL' -Detail "exit $($liveRes.ExitCode): $liveOut"
    }
} else {
    Add-Result -Name '真实 API 查询 (-p)' -Status 'SKIP' -Detail '未指定 -Live，跳过（避免消耗 token）'
}

# --- 汇总 ----------------------------------------------------------------
Write-Section '汇总'

$pass = @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count
$fail = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
$skip = @($script:Results | Where-Object { $_.Status -eq 'SKIP' }).Count

foreach ($r in $script:Results) {
    $color = switch ($r.Status) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        'SKIP' { 'Yellow' }
        default { 'Gray' }
    }
    Write-Host ("  {0,-6} {1}" -f $r.Status, $r.Name) -ForegroundColor $color
}

Write-Host ""
Write-Host ("  通过 {0} / 失败 {1} / 跳过 {2}" -f $pass, $fail, $skip) -ForegroundColor $(if ($fail -gt 0) { 'Red' } else { 'Green' })
Write-Host ""

if ($fail -eq 0) {
    Write-Host "  工程可用 ✅" -ForegroundColor Green
} else {
    Write-Host "  工程存在问题 ❌ 详见上方 FAIL 项" -ForegroundColor Red
}

# --- 6. 交互式 REPL（可选）----------------------------------------------
if ($Repl) {
    Write-Host ""
    Write-Host "启动交互式 REPL（使用你自己的 Claude 配置与凭据，Ctrl+C 退出）..." -ForegroundColor Cyan
    Write-Host ""
    & $script:BunExe run start
}

exit $(if ($fail -gt 0) { 1 } else { 0 })
