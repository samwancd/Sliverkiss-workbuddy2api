# wb2api 看门狗（Windows PowerShell）
# 职责：负责拉起 wb2api，并在其异常退出 / 假死时自动重启。
#   - 进程退出 -> 立即重启
#   - 进程在但 /healthz 连不上（假死）连续 HangThreshold 次 -> 杀掉并重启
#   - 进程在但 /healthz 返回 503（账号/凭证问题，非崩溃）-> 仅记录，不重启（避免无意义重启风暴）
# 看门狗自身若退出（含异常），本脚本不做任何自愈；如需关闭服务，结束本脚本即可。
# 启动前会先规范化代理环境变量（删除小写物理条目、保留值），绕开 PowerShell Start-Process
# 在大小写重复代理变量下抛 Item has already been added 的已知问题（机理见 README 启动段）。

[CmdletBinding()]
param(
    [string]$BinName = 'wb2api.exe',
    [int]   $Port = 7863,
    [string]$ConfigPath = '',
    [int]   $IntervalSec = 5,
    [int]   $HangThreshold = 3,
    [int]   $HealthTimeoutSec = 5,
    [switch]$StopOnExit
)

$ErrorActionPreference = 'Stop'

$dir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$exe = Join-Path $dir $BinName
if (-not (Test-Path $exe)) {
    $alt = Join-Path $dir 'wb2api'
    if (Test-Path $alt) { $exe = $alt }
}
if (-not (Test-Path $exe)) {
    Write-Host "[错误] 未找到 $BinName，请先按 README 源码构建编译： go build -o wb2api.exe ./cmd/server" -ForegroundColor Red
    Read-Host '按 Enter 退出'
    exit 1
}

# 规范化代理变量：Windows 把大小写视为同一变量，原始环境块却可能并存两份物理条目
# （如 Git Bash/MSYS2 写小写、IDE 写大写）。统一删小写条目、确保大写条目带原值，
# 既消除重复又保留代理设置。仅作用于当前会话，不改系统/用户级变量。
foreach ($lower in @('http_proxy', 'https_proxy', 'all_proxy', 'no_proxy', 'ftp_proxy', 'grpc_proxy')) {
    $upper = $lower.ToUpper()
    $val = [System.Environment]::GetEnvironmentVariable($upper, 'Process')
    if ($null -ne $val) {
        [System.Environment]::SetEnvironmentVariable($lower, $null, 'Process')
        [System.Environment]::SetEnvironmentVariable($upper, $val,  'Process')
    }
}

$wlog  = Join-Path $dir 'watchdog.log'
$glog  = Join-Path $dir 'wb2api.log'
$gerr  = Join-Path $dir 'wb2api.err'
$healthUrl = "http://127.0.0.1:$Port/healthz"

function Write-Log {
    param([string]$Msg)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] $Msg"
    Add-Content -Path $wlog -Value $line -Encoding UTF8
    Write-Host $line
}

function Start-Child {
    $argList = @()
    if ($ConfigPath -ne '') { $argList += @('-config', $ConfigPath) }
    $startArgs = @{
        FilePath               = $exe
        WorkingDirectory       = $dir
        RedirectStandardOutput = $glog
        RedirectStandardError  = $gerr
        WindowStyle            = 'Hidden'
        PassThru               = $true
    }
    if ($argList.Count -gt 0) { $startArgs['ArgumentList'] = $argList }
    try {
        $p = Start-Process @startArgs
        Write-Log "拉起 wb2api pid=$($p.Id) 参数=[$($argList -join ' ')]"
        return $p
    } catch {
        Write-Log "启动失败: $($_.Exception.Message)"
        return $null
    }
}

function Stop-Child {
    param($Child)
    if ($Child -and -not $Child.HasExited) {
        try { $Child.Kill() } catch {}
    }
}

# 干净退出时（Ctrl+C）按需停止子进程；看门狗自身退出不自愈，符合设计。
$child = $null
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    if ($StopOnExit -and $child) { try { $child.Kill() } catch {} }
} | Out-Null

Write-Log "看门狗启动：bin=$exe port=$Port interval=${IntervalSec}s hangThreshold=$HangThreshold healthTimeout=${HealthTimeoutSec}s"
Write-Log "健康检查端点 $healthUrl"

# 预检：若目标端口已有实例在跑（/healthz 可达），看门狗不应重复拉起，
# 否则会因端口冲突陷入「秒退 -> 重启」风暴。请先停止已有实例再启动看门狗。
try {
    $probe = Invoke-WebRequest -Uri $healthUrl -TimeoutSec $HealthTimeoutSec -UseBasicParsing -ErrorAction Stop
    Write-Log "/healthz 已可达（HTTP $($probe.StatusCode)）：端口 $Port 似乎已有 wb2api 实例在运行。"
    Write-Log "为避免重复拉起导致端口冲突重启风暴，请先停止已有实例，再启动看门狗。看门狗退出。"
    exit 2
} catch {
    Write-Log "端口 $Port 当前无运行实例，开始托管"
}

$child = Start-Child
$restartCount = 0
$hangCount = 0
$lastStart = Get-Date

try {
    while ($true) {
        Start-Sleep -Seconds $IntervalSec

        # 1) 进程是否还活着
        $alive = $false
        if ($child -and -not $child.HasExited) {
            try {
                $p = Get-Process -Id $child.Id -ErrorAction SilentlyContinue
                $alive = ($null -ne $p)
            } catch { $alive = $false }
        }

        if (-not $alive) {
            Write-Log "检测到 wb2api 已退出（pid=$($child.Id)），准备重启（第 $($restartCount + 1) 次）"
            # 轻量退避，避免端口仍被占用时高频重启风暴
            $gap = (Get-Date) - $lastStart
            if ($gap.TotalSeconds -lt 2) { Start-Sleep -Seconds 2 }
            $child = Start-Child
            if ($child) {
                $restartCount++
                $lastStart = Get-Date
                $hangCount = 0
            }
            continue
        }

        # 2) 进程在 -> 探活。连不上才算假死，503 不算。
        try {
            $resp = Invoke-WebRequest -Uri $healthUrl -TimeoutSec $HealthTimeoutSec -UseBasicParsing -ErrorAction Stop
            $hangCount = 0
            if ($resp.StatusCode -ne 200) {
                Write-Log "/healthz 返回 $($resp.StatusCode)（账号/凭证不可用，非崩溃，不重启）"
            }
        } catch {
            $hangCount++
            Write-Log "/healthz 不可达（$($_.Exception.Message)）；假死疑似 $hangCount/$HangThreshold"
            if ($hangCount -ge $HangThreshold) {
                Write-Log "判定 wb2api 假死（端口无响应），杀掉 pid=$($child.Id) 并重启"
                try { $child.Kill() } catch {}
                Start-Sleep -Seconds 2
                $child = Start-Child
                if ($child) {
                    $restartCount++
                    $lastStart = Get-Date
                    $hangCount = 0
                }
            }
        }
    }
} finally {
    if ($StopOnExit -and $child) {
        Write-Log '看门狗退出，正在停止 wb2api'
        Stop-Child $child
    } else {
        Write-Log '看门狗退出（wb2api 继续在后台运行，如需停止请手动结束进程）'
    }
}
