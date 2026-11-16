# wb2api 看门狗（Windows PowerShell）
# 职责：负责拉起 wb2api，并在其异常退出 / 假死时自动重启。
#   - 进程退出 -> 立即重启
#   - 进程在但 /healthz 完全连不上（假死）连续 HangThreshold 次 -> 杀掉并重启
#   - /healthz 返回任何 HTTP 状态码（含 503）视为端口有响应：不计入假死，循环中不打印
# wb2api 的 stdout/stderr 合并写入 wb2api.log，方便实时查看连接日志。
# 看门狗自身若退出（含异常）不做任何自愈；结束时默认一并停止它拉起的 wb2api，
# 关窗口 / 强杀这类 finally 不执行的情况由 Job Object 兜底回收，避免残留实例占端口。
# 确需保留后台实例时显式加 -KeepChild。
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
    [switch]$KeepChild
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
$healthUrl = "http://127.0.0.1:$Port/healthz"

function Write-Log {
    param([string]$Msg)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] $Msg"
    Add-Content -Path $wlog -Value $line -Encoding UTF8
    Write-Host $line
}

# Job Object（KILL_ON_JOB_CLOSE）：记着 cmd 包装进程与真实 wb2api。
# 看门狗进程一消失（关窗口 / 被强杀 / 正常退出）句柄随之关闭，内核直接回收这两个进程，
# 覆盖 finally 不执行的场景，避免残留实例占住端口让下次启动预检失败。
function Initialize-JobObject {
    if (-not ('Wb2api.Job' -as [type])) {
        Add-Type -Namespace Wb2api -Name Job -MemberDefinition @'
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct IO_COUNTERS {
    public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
    public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
}
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
    public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
    public uint LimitFlags;
    public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
    public uint ActiveProcessLimit;
    public UIntPtr Affinity;
    public uint PriorityClass, SchedulingClass;
}
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
    public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
    public IO_COUNTERS IoInfo;
    public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
}
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)]
static extern IntPtr CreateJobObject(IntPtr attrs, string name);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint infoLen);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool CloseHandle(IntPtr handle);
public static IntPtr CreateKillOnCloseJob() {
    IntPtr job = CreateJobObject(IntPtr.Zero, null);
    if (job == IntPtr.Zero) { return IntPtr.Zero; }
    var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
    info.BasicLimitInformation.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    int len = System.Runtime.InteropServices.Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
    IntPtr buf = System.Runtime.InteropServices.Marshal.AllocHGlobal(len);
    try {
        System.Runtime.InteropServices.Marshal.StructureToPtr(info, buf, false);
        // JobObjectExtendedLimitInformation = 9
        if (!SetInformationJobObject(job, 9, buf, (uint)len)) { CloseHandle(job); return IntPtr.Zero; }
    } finally {
        System.Runtime.InteropServices.Marshal.FreeHGlobal(buf);
    }
    return job;
}
'@
    }
    $job = [Wb2api.Job]::CreateKillOnCloseJob()
    if ($job -eq [IntPtr]::Zero) {
        Write-Log '警告：创建 Job Object 失败，看门狗被强杀 / 关窗口时可能残留 wb2api 进程'
    }
    return $job
}

function Join-JobObject {
    param([IntPtr]$Job, $Target)
    if ($null -eq $Target -or $Job -eq [IntPtr]::Zero) { return }
    if ($Target.HasExited) { return }
    try {
        if (-not [Wb2api.Job]::AssignProcessToJobObject($Job, $Target.Handle)) {
            $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Write-Log "警告：pid=$($Target.Id) 未加入 Job Object（Win32 错误 $code），强杀时可能残留"
        }
    } catch {
        Write-Log "警告：pid=$($Target.Id) 未加入 Job Object：$($_.Exception.Message)"
    }
}

function Start-Child {
    $argList = @()
    if ($ConfigPath -ne '') { $argList += @('-config', $ConfigPath) }
    # Go 的 log.Printf 走 stderr；用 cmd 把 stdout/stderr 合并进同一个 wb2api.log。
    $exeArg = $exe -replace '"', '\"'
    $logArg = $glog -replace '"', '\"'
    $arguments = ''
    if ($argList.Count -gt 0) {
        foreach ($a in $argList) { $arguments += ' "' + ($a -replace '"', '\"') + '"' }
    }
    $launch = '"' + $exeArg + '"' + $arguments
    $command = '( ' + $launch + ') > "' + $logArg + '" 2>&1'
    $startArgs = @{
        FilePath               = $env:ComSpec
        WorkingDirectory       = $dir
        ArgumentList           = @('/c', $command)
        WindowStyle            = 'Hidden'
        PassThru               = $true
    }
    try {
        $wrapper = Start-Process @startArgs
        $childPid = $null
        for ($i = 0; $i -lt 20 -and -not $childPid; $i++) {
            $childPid = Get-ChildProcessId -Parent $wrapper
            if (-not $childPid) { Start-Sleep -Milliseconds 100 }
        }
        if (-not $childPid) {
            Write-Log "启动失败: 未找到 wb2api 子进程（cmd pid=$($wrapper.Id)）"
            return $null
        }
        $p = Get-Process -Id $childPid -ErrorAction Stop
        Join-JobObject -Job $job -Target $wrapper
        Join-JobObject -Job $job -Target $p
        Write-Log "拉起 wb2api pid=$($p.Id) 参数=[$($argList -join ' ')] 日志=$glog"
        return $p
    } catch {
        Write-Log "启动失败: $($_.Exception.Message)"
        return $null
    }
}

function Get-ChildProcessId {
    param($Parent)
    if ($null -eq $Parent) { return $null }
    $name = [System.IO.Path]::GetFileName($exe)
    try {
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$($Parent.Id)" |
            Where-Object { $_.Name -eq $name } |
            Select-Object -First 1 -ExpandProperty ProcessId
    } catch { $null }
}

function Stop-Child {
    param($Child)
    if ($Child -and -not $Child.HasExited) {
        try { $Child.Kill() } catch {}
    }
}

# 干净退出时（Ctrl+C）默认停止子进程；加 -KeepChild 才保留后台实例。
# $child 由主流程写、finally 读，均为脚本作用域，无需事件订阅。
# -KeepChild 时连 Job 都不建：Windows 无法把进程移出 Job，一旦加入就会随看门狗被杀。
# 用裸开关而非 -KeepChild:$false：start-watchdog.bat 以 powershell -File 调用，
# 该形式下开关不认 :$false，会直接抛参数转换错误。
$child = $null
$job = [IntPtr]::Zero
if (-not $KeepChild) { $job = Initialize-JobObject }

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
    $probeStatus = $null
    if ($_.Exception.Response) {
        try { $probeStatus = [int]$_.Exception.Response.StatusCode } catch {}
    }
    if ($null -ne $probeStatus) {
        $statusText = if ($probeStatus -eq 503) { '账号池当前不可服务，服务已监听' } else { '服务已监听' }
        Write-Log "/healthz 返回 HTTP $probeStatus（$statusText）：端口 $Port 已有 wb2api 实例。"
        Write-Log "为避免重复拉起导致端口冲突重启风暴，请先停止已有实例，再启动看门狗。看门狗退出。"
        exit 2
    }
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

        # 2) 进程在 -> 探活。只要收到 HTTP 响应（含 503）就算端口活着；
        #    账号池不可服务期间不打印，避免每 5 秒刷屏误导。
        try {
            $null = Invoke-WebRequest -Uri $healthUrl -TimeoutSec $HealthTimeoutSec -UseBasicParsing -ErrorAction Stop
            $hangCount = 0
        } catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
            }
            if ($null -ne $statusCode) {
                $hangCount = 0
                continue
            }
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
    if ($KeepChild) {
        # Job 已随进程退出关闭，不建 Job 时后台实例得以存活
        Write-Log '看门狗退出（-KeepChild：wb2api 继续在后台运行，如需停止请手动结束进程）'
    } elseif ($child) {
        Write-Log '看门狗退出，正在停止 wb2api'
        Stop-Child $child
    }
}
