# 启动 wb2api 网关（Windows PowerShell）
# 先把代理环境变量规范化成单一大写条目（删除小写物理条目、保留值），再 Start-Process 拉起，
# 绕开 PowerShell Start-Process 在大小写重复代理变量下抛 Item has already been added 的已知问题
# （根因：Windows 环境变量名大小写不敏感，而 .NET 构建子进程环境块用的是大小写不敏感
# 字典，当原始环境块里并存 HTTP_PROXY 与 http_proxy 两份物理条目时直接异常；机理见
# https://pedroreys.com/post/npm-env-vars-windows ）。
# 服务会脱离本 PowerShell 会话常驻，关闭本窗口不影响 wb2api 运行。

$ErrorActionPreference = 'Stop'

$dir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$exe = Join-Path $dir 'wb2api.exe'
if (-not (Test-Path $exe)) {
    Write-Host '[错误] 未找到 wb2api.exe，请先按 README “源码构建” 编译： go build -o wb2api.exe ./cmd/server' -ForegroundColor Red
    Read-Host '按 Enter 退出'
    exit 1
}

# 规范化代理变量：Windows 把大小写视为同一变量，原始环境块却可能并存两份物理条目
# （如 Git Bash / MSYS2 写入小写、IDE 写入大写）。这里统一删掉小写条目、确保大写条目带原值，
# 既消除重复又保留代理设置。仅作用于当前 PowerShell 会话，不改系统/用户级变量。
foreach ($lower in @('http_proxy', 'https_proxy', 'all_proxy', 'no_proxy', 'ftp_proxy', 'grpc_proxy')) {
    $upper = $lower.ToUpper()
    $val = [System.Environment]::GetEnvironmentVariable($upper, 'Process')
    if ($null -ne $val) {
        [System.Environment]::SetEnvironmentVariable($lower, $null, 'Process')
        [System.Environment]::SetEnvironmentVariable($upper, $val,  'Process')
    }
}

$log = Join-Path $dir 'wb2api.log'
$err = Join-Path $dir 'wb2api.err'
Start-Process -FilePath $exe -WorkingDirectory $dir -ArgumentList $args -RedirectStandardOutput $log -RedirectStandardError $err -WindowStyle Hidden

Write-Host "已启动（日志 -> $log / $err）。关闭本窗口不影响服务运行。"
Write-Host '验证： curl.exe -s http://127.0.0.1:7863/status -H "Authorization: Bearer test_key"'
