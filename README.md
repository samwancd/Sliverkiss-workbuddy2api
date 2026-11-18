<p align="center">
  <img src="https://raw.githubusercontent.com/DGZSbot/ai-icon/refs/heads/main/WorkBuddy.png" alt="WorkBuddy2API" width="120">
</p>

<h1 align="center">WorkBuddy2API</h1>

<p align="center">
  <b>把 CodeBuddy 账号变成 OpenAI 兼容 API 的多账号网关</b><br>
  OAuth 登录 · 账号池轮转 · 熔断与冷却 · 会话粘性 · 积分补充
</p>

<p align="center">
  <img alt="Go" src="https://img.shields.io/badge/Go-1.22.5-00ADD8?logo=go&logoColor=white&style=flat-square">
  <img alt="API" src="https://img.shields.io/badge/API-OpenAI_Compatible-412991?style=flat-square">
  <img alt="Deploy" src="https://img.shields.io/badge/Deploy-Docker_Compose-2496ED?logo=docker&logoColor=white&style=flat-square">
  <img alt="Transport" src="https://img.shields.io/badge/Transport-SSE%20%2F%20Streaming-0DBD8B?style=flat-square">
  <a href="https://t.me/sliverkiss_blog"><img alt="Telegram" src="https://img.shields.io/badge/Telegram-%E9%A2%91%E9%81%93-blue?logo=telegram&logoColor=white&style=flat-square"></a>
</p>

---

## 目录

- [项目简介](#intro)
- [核心能力](#features)
- [架构总览](#architecture)
- [快速开始](#quickstart)
  - [环境要求](#requirements)
  - [第 1 步：准备文件与构建产物](#step1)
  - [第 2 步：登录一次，添加账号](#step2)
  - [第 3 步：启动网关](#step3)
  - [第 4 步：验证](#step4)
  - [以后怎么用 / 什么时候要重新登录](#daily)
  - [辅助工具：手动查积分 / 手动补签](#tools)
  - [源码构建与测试（开发者）](#dev)
- [验证：调用 OpenAI 兼容接口](#api)
- [安全与合规](#compliance)
- [免责声明](#disclaimer)
- [Coffee](#coffee)
- [License](#license)

<a id="intro"></a>

## 项目简介

WorkBuddy2API 是一个自托管的 **OpenAI 兼容反向代理网关**，将 ```CodeBuddy``` 账号包装为统一的 `/v1/chat/completions` 服务。

- 官方不提供 OpenAI 形态的开放 API，本项目通过 **OAuth 设备授权**（`login.sh`）获取账号凭证，在网关侧做 token 自动刷新、账号池调度与流量治理；
- 面向 **个人多账号** 场景：多账号共享、单号故障自动换号、冷却 / 熔断防止雪崩、会话粘性保证多轮上下文不跳号；
- 对客户端只暴露 OpenAI 兼容接口，现有 SDK / 前端 / 工具 **零改造接入**。

> ⚠️ 合规须知：本项目是**非官方**网关，使用 ```CodeBuddy``` 账号作为上游，**仅限本人授权账号、本机 / 私有环境测试**。详细边界见[安全与合规](#compliance)。

📖 完整文档见 [GitHub Wiki](https://github.com/Sliverkiss/workbuddy2api/wiki)。

<a id="features"></a>

## 核心能力

### 账号池治理

- **OAuth 设备授权登录** — `login.sh` 一条命令完成：取授权 URL → 浏览器登录 → token 轮询 → 凭证落盘 → 重启加载，全程无 PKCE（state 由服务端签发），重复执行即可连续添加多账号
- **四因子加权随机选号** — `credits 比例 ×10 + 闲置补偿 + 成功率 ×3 + 快过期积分占比 ×8` 四项加权（`pool.expiring_soon` 窗口内的积分优先消耗，默认 7 天），按权重降序取 **Top-5 候选短名单**，再在短名单内加权抽签（等权重候选先随机打乱防惊群、LRU 兜底覆盖全部候选），兼顾积分多、闲置久、成功率高、快过期积分先用掉的账号
- **防惊群** — 跳过 100ms 内刚被选中的账号，多账号同时待命时不打爆同一台
- **在途租约** — 单账号最大在途请求数（`pool.max_in_flight`）限制并发占用，占满的号不参与选号，避免单号过载
- **账本择优** — 每次成功请求按 `usage.credit` 折算每千 token 单价记入 `(账号, 模型)` 账本，免费 / 便宜的账号优先；观测按 EMA 平滑、6 小时未更新即失效，成本随上游活动实时变化

### 流量治理

- **分级熔断与冷却** — 429 软冷却（600s 起指数退避、封顶 `soft_rate_max`）、404 固定浅冷却、402 / 余额耗尽硬冷却至次日 04:00、连续失败熔断（`breaker_threshold` 触发后指数退避封顶 6h）
- **模型级限流独立冷却** — 6004（该模型使用量超限）只冷却触发调用的模型，切其他模型立即可用；`/status` 透出 `rate_limited_models` 台账
- **状态持久化** — 池状态（积分 / 冷却 / 熔断 / 计数）本地原子落盘 `state.json`，可选镜像至 Upstash Redis，重启后择优恢复

### 请求链路

- **流式 + 非流式** — 出站强制 `stream:true`；SSE 帧按 OpenAI 规范白名单重建；非流式由本地聚合为单响应
- **DeepSeek 思维链注入** — 出站请求体注入 `thinking.type=enabled` + 默认档位，`reasoning_content` 多轮回填，`reasoning_effort` 按模型档位自动降级
- **系统提示词体系** — 默认透传客户端原始 system（`passthrough` 模式，缺省），仅自定义配置 `custom` 时网关用自有提示词替换客户端 system/developer（从源头消除模板句误报）；`passthrough` 模式遇拦截自动降级中性提示词重试
- **会话头族注入** — 出站携带官方客户端会话头族（`X-Conversation-Request-ID` 聚合主键 · `X-Conversation-ID` 透传 · B3 链路），轮转 / 重试 / 路径回退复用同键，后台按对话轮聚合不再碎片化（issue #35）
- **指纹脱敏** — 出站请求体黑名单指纹字段清洗（可开关），与提示词体系两层叠加

### 定时积分任务

- **签到**（09 / 21 点）— 每日签到 + 余额查询，余额恢复自动解冻冷却账号
- **活跃上报**（10 点）— 对话事件连发上报，点亮连登天数、解锁领养前置，回读 streak 自检
- **猫猫旅行**（09 / 21 点）— 独立排程：领养 / 派出 / 领奖闭环推进
- **token 保活**（22 点）— 全账号刷新 token，session 失效连续 3 次才禁用
- **开学季任务**（12 点）— 任务点亮 + claim + 自动抽空抽奖余额，活动下线时自动跳过
- **夜猫子任务**（01 点）— 夜猫窗口（23:00–08:00 CST）内补一次 black_cat 任务

六类任务独立排程、独立开关（`schedule.*_enabled`），互不影响。

### 双域适配

- 同时适配**国内版（CN，`copilot.tencent.com` / `www.codebuddy.cn`）与国际版（Global，`www.workbuddy.ai`）**账号
- 共享同一账号池，由账号 `realm` 或请求模型名前缀（`cn:` / `global:`）决定路由；`global.enabled` 可一键锁死纯 CN 部署
- 国际版支持注册激活、地区完善、一次性 trial 加油包领取（`./trial.sh`）

### 辅助工具

- 积分日报：`./credit.sh`（美化 / `-json`，realm 感知双域）
- 手动签到：`./signin.sh`（批量、幂等不重复计）
- 领养联动 / 任务查询：`scripts/task_runner.py`（成长任务一体机，默认 dry-run）
- 个性化提示词：`prompt.file` 指向自定义提示词文件即整体替换内置默认

<a id="architecture"></a>

## 架构总览

```mermaid
flowchart LR
    Client["客户端 / SDK\nOpenAI 兼容请求"] --> H

    subgraph GWI["WorkBuddy2API 网关 :7863"]
        H["HTTP Handler\n鉴权 · 请求体上限 · 提示词改写 · 轮转"] --> P
        H --> S
        P["账号池\n三因子加权 · 熔断 · 冷却 · 租约"] --> U
        S["会话粘性路由"] -.绑定镜像.-> REDIS
        T["定时调度\n签到 09/21 · 旅行 09/21 · 活跃 10 · 保活 22"] --> P
        U["上游 Client\nChatHTTP 流式 · 短 RPC"]
    end

    P -. "读凭证 (0600)" .-> AUTH[("auths/*.json")]
    P -. "状态镜像" .-> REDIS[("Upstash Redis\n可选")]
    U -->|"chat/completions (SSE)"| CB["CodeBuddy\ncopilot.tencent.com"]
    U -->|"billing / auth / growth"| CB
```

上游请求在出站前经历统一的改写管线（`internal/upstream/payload.go`）：强制 `stream:true`、`developer` 角色归一、tool_choice 归一、DeepSeek 思维链注入、`reasoning_effort` 档位降级、`reasoning_content` 回填、指纹脱敏。

<a id="quickstart"></a>

## 快速开始

> 先记住一条主线：**准备 → 登录 → 启动 → 验证**。网关只提供 API 服务，不会替你完成 OAuth 登录，也不会自动运行 `login` / `signin_bin` / `credit`。

<a id="requirements"></a>

### 环境要求

- **Docker + Docker Compose**（推荐部署方式，镜像内已含 `app` 低权限用户、网关二进制与工具脚本）
- 或 **Windows + Go ≥ 1.22**（用仓库自带的 `.bat` / `.ps1` 直接跑本机编译的二进制）
- 一个或多个已注册的 CodeBuddy 账号，用于 OAuth 登录

<a id="step1"></a>

### 第 1 步：准备文件与构建产物

**Docker / Linux / macOS**：

<details>
<summary>克隆仓库并准备 <code>config.json</code></summary>

```bash
git clone https://github.com/Sliverkiss/workbuddy2api.git
cd workbuddy2api
cp config.example.json config.json
```

</details>

编辑 `config.json`，**至少设置 `api_key`**（`留空 = 不鉴权`，公网部署务必设置）。示例中的 `test_key` 等均为占位符，`config.example.json` 不含任何真实密钥。

**Windows 二进制**：同样先准备好 `config.json`，然后构建下面四个工具（三种 shell 任选其一；`CGO_ENABLED=0 命令` 这种「环境变量内联前缀」是 Unix shell 专属语法，**Windows CMD / PowerShell 不认**，会报「'CGO_ENABLED' 不是内部或外部命令」）。Linux 下 `./login.sh` 会在首次运行时自动编译 `./login`（源码改动后需手动 `go build -o login ./cmd/login`）：

<details>
<summary>Git Bash / Linux / macOS：构建命令</summary>

```bash
CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o wb2api ./cmd/server
CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o login ./cmd/login
CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o credit ./cmd/credit
CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o signin_bin ./cmd/signin
```

</details>

<details>
<summary>Windows CMD：构建命令</summary>

`set "VAR=val"` 设置环境变量，再用 `&&` 串联；输出加 `.exe` 后缀；`-ldflags` 用空格分隔而非 `=`。

```cmd
set "CGO_ENABLED=0" && go build -trimpath -ldflags "-s -w" -o wb2api.exe ./cmd/server
set "CGO_ENABLED=0" && go build -trimpath -ldflags "-s -w" -o login.exe ./cmd/login
set "CGO_ENABLED=0" && go build -trimpath -ldflags "-s -w" -o credit.exe ./cmd/credit
set "CGO_ENABLED=0" && go build -trimpath -ldflags "-s -w" -o signin_bin.exe ./cmd/signin
```

</details>

<details>
<summary>Windows PowerShell：构建命令</summary>

`$env:VAR="值"` 设置环境变量，用 `;` 串联。

```powershell
$env:CGO_ENABLED="0"; go build -trimpath -ldflags "-s -w" -o wb2api.exe ./cmd/server
$env:CGO_ENABLED="0"; go build -trimpath -ldflags "-s -w" -o login.exe ./cmd/login
$env:CGO_ENABLED="0"; go build -trimpath -ldflags "-s -w" -o credit.exe ./cmd/credit
$env:CGO_ENABLED="0"; go build -trimpath -ldflags "-s -w" -o signin_bin.exe ./cmd/signin
```

</details>

> Windows 下 `go build` 默认就会给输出加 `.exe`，写不写后缀都行；上面统一带 `.exe` 仅为直观。第一次用只需要 `wb2api` + `login`；`credit` / `signin_bin` 是后面「辅助工具」才用得到的可选产物。

<a id="step2"></a>

### 第 2 步：登录一次，添加账号

> 网关**只在启动时扫描 `auths/` 凭证目录**（`cmd/server/main.go` 的 `auth.LoadDir`），原生二进制不热加载。因此**首次使用必须先登录再启动**；如果已经启动了网关，登录后必须重启一次。

**Docker / Linux / macOS**：

<details>
<summary><code>./login.sh</code> 登录（交互式选域 / 指定 cn / global）</summary>

```bash
./login.sh                  # 交互式选域，默认国内版 cn
./login.sh --realm=cn       # 直达国内版
./login.sh --realm=global   # 直达国际版
```

</details>

脚本会打印一个授权链接；在浏览器里打开后，**扫码或手机号登录任选一种**完成授权，再回到终端按 `y`。脚本随后轮询 token、写入 `auths/workbuddy-<uid>.json`；若容器已在运行会自动 `docker restart` 加载新账号，否则等下次启动自然加载。重复执行 `./login.sh` 即可继续添加多个账号。

**Windows（PowerShell）** —— 同样分两步，中间在浏览器完成**扫码或手机号登录**：

<details>
<summary><code>login url</code> + <code>poll</code> 落盘 auth 文件</summary>

```powershell
# 1) 取授权链接（realm 可选 cn / global；不传回落 cn）
login.exe --realm=cn url
#   ↓ 复制终端打印的 https://copilot.tencent.com/login?... 链接，浏览器打开并完成登录

# 2) 登录完成后，轮询 token 并落盘为 auths/workbuddy-<uid>.json（格式与网关读取一致）
#    注意：Windows PowerShell 5.1 默认按系统 OEM 码页（中文系统为 GBK）解码外部程序
#    stdout，而 login.exe 输出 UTF-8，需先切到 UTF-8，否则中文 nickname 会乱码。
$prevEnc = [Console]::OutputEncoding
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$json = login.exe --realm=cn poll | ConvertFrom-Json
[Console]::OutputEncoding = $prevEnc
$uid  = $json.uid
$exp  = [int][datetime]::UtcNow.Subtract([datetime]'1970-01-01').TotalSeconds + [int]$json.expires_in
$auth = @{
    account = @{ uid = $uid; enterpriseId = $json.enterprise_id; nickname = $json.nickname }
    auth    = @{
        accessToken  = $json.access_token
        refreshToken = $json.refresh_token
        expiresAt    = $exp
        domain       = $json.domain
        realm        = 'cn'
    }
} | ConvertTo-Json -Depth 5
New-Item -ItemType Directory -Force -Path auths | Out-Null
[System.IO.File]::WriteAllText("auths/workbuddy-$uid.json", $auth, [System.Text.UTF8Encoding]::new($false))
Write-Host "已保存 auths/workbuddy-$uid.json"
```

</details>

仓库里的 `*.sh` 是 bash 脚本，Windows 无法直接运行；它们只是对 `login` / `signin_bin` / `credit` 的封装，Windows 直接用对应的 `.exe` 即可。若你在 Git Bash 下构建，产物可能不带 `.exe` 后缀，命令里去掉即可（如 `./login`、`signin_bin`）。CN 账号首次签到可省略，网关内置 09 / 21 点定时签到。

<a id="step3"></a>

### 第 3 步：启动网关

**Docker**：

```bash
docker compose up -d --build
```

**Windows 二进制**（二选一，不要两个同时跑）：

**CMD**：

```cmd
start.bat              :: 简单常驻，脱离终端，日志 wb2api.log / wb2api.err
start-watchdog.bat     :: 看门狗，进程退出或假死时自动重启，日志 watchdog.log
```

**PowerShell**：

```powershell
.\start.ps1            :: start.bat 的 PowerShell 等价版
.\watchdog.ps1         :: 看门狗本体，可加 -Port 7863 -IntervalSec 5 -HangThreshold 3
```

`start.bat` 只拉起 `wb2api.exe` 并把参数透传；看门狗也只托管 `wb2api.exe`（进程退出立即重启，`/healthz` 连续 `HangThreshold` 次完全连不上才判定假死并重启；**含 503 的任何 HTTP 响应都算「还活着」，不重启**）。两个启动脚本都**不会**调用 login / credit / signin，也不需要你手动跑这些工具才能启动服务。

> ⚠️ **看门狗不接管手动已运行的实例**：启动前确保 7863 端口没有已在运行的 `wb2api`，否则看门狗预检会直接拒绝启动，避免端口冲突造成「秒退→重启」风暴。看门狗默认退出时一并停止它拉起的 `wb2api`；要留后台实例加 `-KeepChild`（`start-watchdog.bat -KeepChild`）。

**不使用脚本的启动方式**（前台占住终端 / 后台落日志）：

<details>
<summary>Git Bash / Linux / macOS：前台与后台启动命令</summary>

```bash
cd /path/to/workbuddy2api
./wb2api                          # 前台，Ctrl+C 停止
./wb2api > wb2api.log 2>&1 &      # Git Bash 后台
```

</details>

<details>
<summary>Windows PowerShell：前台与 Start-Process 后台命令</summary>

```powershell
cd D:\path\to\workbuddy2api
.\wb2api.exe                     # 前台，Ctrl+C 停止
Start-Process -FilePath ".\wb2api.exe" -RedirectStandardOutput "wb2api.log" -RedirectStandardError "wb2api.err"
```

</details>

> 🪟 **PowerShell `Start-Process` 已知坑**：若环境里同时存在大小写重复的代理变量（如 `HTTPS_PROXY` 与 `https_proxy`），直接 `Start-Process .\wb2api.exe` 会抛 `Item has already been added`；根因是 Windows 环境变量名大小写不敏感而 .NET 用大小写不敏感字典构建子进程环境块。**优先用 `start.bat` / `start.ps1`**；或先 `Remove-Item Env:https_proxy` 清掉小写副本，或改用 `cmd /c start "" wb2api.exe`。前台直接 `.\wb2api.exe` 不受影响。

<a id="step4"></a>

### 第 4 步：验证

<details>
<summary><code>/healthz</code> 与 <code>/status</code> 健康检查</summary>

```bash
curl -s http://localhost:7863/healthz
# {"healthy":2,"total":3,"service":"workbuddy2api"}  （无可用账号时 503）

curl -s http://localhost:7863/status -H "Authorization: Bearer your-api-key"
# healthy > 0 即账号已加载；disabled 账号会透出 disabled_reason
```

</details>

> **Windows 提示**：PowerShell 中 `curl` 是 `Invoke-WebRequest` 的别名，调用真正的 curl 必须写 `curl.exe`（Windows 10 / 11 已内置）。

<a id="daily"></a>

### 以后怎么用 / 什么时候要重新登录

**日常只需要第 3 步**：进程退出、关机、看门狗重启后，重跑启动脚本即可，**不用重新登录**。网关会自动做 token 刷新（请求前临近过期就刷，另有 22 点全账号保活）、09 / 21 点签到与余额查询、活跃上报、猫猫旅行等定时任务；这些都由 `wb2api` 内置完成，**不需要也不自动运行** `credit` / `signin_bin`。

只有在以下情况才重跑第 2 步，并重启网关加载新凭证（原生二进制不热加载）：

- 新增账号，或更换账号凭证；
- `/status` 中账号 `disabled` 且 `disabled_reason` 出现 `12153 session dead`、`re-login required`（如 `11140 request illegal`）；
- 日志出现 `refresh_failed ... re-login required`。

`/healthz` 返回 503 只表示「服务还活着但账号池暂时不可服务」，不是重登信号；看门狗也会把它当作存活，不会重启。

<a id="tools"></a>

### 辅助工具：手动查积分 / 手动补签（可选，不属于启动流程）

先分清「自动」和「手动」：网关 `wb2api` 内置定时任务，每天 09 / 21 点自动给所有账号签到并查余额、22 点自动刷新 token（见「定时积分任务」）。下面两个工具是**同功能的一次性手动版本**：不会开机自启，也不被 `start.bat` / `start-watchdog.bat` / 网关调用，**从来不运行它们也完全不影响正常使用**。仓库根目录的本机 `go build` 产物（Windows 下带 `.exe` 后缀）被 `.gitignore` 忽略，不随仓库分发。

<details>
<summary><code>credit</code> —— 积分日报（只看不改）</summary>

- **干什么**：遍历 `auths/workbuddy-*.json`，逐个查询上游积分，输出每个账号的「剩余 / 已用 / 总额 / 积分包数 / 是否查询成功」以及全体合计。**纯只读**：不改 auth 文件、不签到、不消耗积分。
- **什么时候用**：
  - 想立刻知道各账号还剩多少积分、哪个号快耗尽；
  - 核对网关 `/status` 里的积分数字是否与上游一致（对账）；
  - 刚加完账号或刚领完活动加油包，确认积分是否到账；
  - 出现 402「余额不足」冷却时，确认是全体没额度还是个别号没额度。
- **怎么用**：`credit -pretty`（人类可读日报）或 `credit`（默认原始 JSON，便于脚本解析）；Linux / 容器用 `./credit.sh`（默认美化）、`./credit.sh -json`（原始 JSON）。可用环境变量 `WB2A_AUTH_DIR` 改凭证目录。

</details>

<details>
<summary><code>signin_bin</code> —— 批量签到（会写回 token）</summary>

- **干什么**：遍历 `auths/workbuddy-*.json`，对每个账号依次：token 快过期（2 小时内）先自动刷新并**写回 auth 文件** → 调每日签到（幂等，「今天已签到」显示为 `ALREADY`，不算失败）→ 顺带回读余额；最后打印 `uid | nick | status | remain | detail` 表格与汇总。`status` 为 `OK` / `ALREADY` / `FAIL` / `AUTH_INVALID` / `LOAD_ERR` 之一，可直接看出哪个号签到失败或凭证已失效。
- **什么时候用**：
  - 刚登录完新账号，想立刻领当天签到，不想等下一个 09 / 21 点整点；
  - 定时签到那两个时点机器没开机，或关掉了 `schedule.checkin_enabled`，需要手动补签；
  - 怀疑某号签到失败，跑一次看 `status` / `detail` 里的上游报错；
  - 长期关机后重新开机，想手动刷新一批快过期的 token 并落盘。
- **怎么用**：`signin_bin`（默认读 `auths`）或 `signin_bin D:\path\to\auths`；Linux / 容器用 `./signin.sh [auths_dir]`，`./checkin.sh` 会额外打印 `/status` 网关状态头、并在缺失时自动编译 `signin_bin`。
- **注意**：它只改磁盘上的 auth 文件、**不重启网关**。已在运行的网关持有自己那份账号状态，会按请求自动刷新 token，两者不会冲突；新增账号仍要走第 2 步并重启。

</details>

<details>
<summary><code>login</code> —— 登录 / 重登</summary>

只在第 2 步添加账号、或上一节「什么时候要重新登录」重登时用，不是日常工具。用法见第 2 步。

</details>

| 速查 | Windows | Linux / 容器 |
| --- | --- | --- |
| 查积分 | `credit -pretty` / `credit`（JSON） | `./credit.sh` / `./credit.sh -json` |
| 手动补签 | `signin_bin [auths目录]` | `./signin.sh [auths目录]` / `./checkin.sh` |
| 登录 / 重登 | `login --realm=cn url` → `poll` | `./login.sh [--realm=cn&#124;global]` |

<a id="dev"></a>

### 源码构建与测试（开发者）

<details>
<summary>Go 构建 / 静态检查 / 测试 / 前台运行</summary>

```bash
go build ./...
go vet ./...
go test ./...      # 完整测试套件
go run ./cmd/server -config config.json
```

</details>

`go build` 产物是 `wb2api`（Windows 下为 `wb2api.exe`）。它**必须从项目根目录启动**——会读取当前工作目录下的 `config.json`（用 `-config <路径>` 可换位置）与 `auths/` 凭证目录，默认监听 `:7863`。

**停止服务**：

<details>
<summary>停止 wb2api 进程</summary>

```powershell
Stop-Process -Name wb2api          # PowerShell
```
```bash
pkill -f wb2api                     # Git Bash / Linux
```

</details>

> ⚠️ `wb2api` 是常驻前台进程：**关闭终端、注销、重启电脑都会让它退出**（用 `start.bat` / `start-watchdog.bat` 可避免）。

<a id="api"></a>

## 验证：调用 OpenAI 兼容接口

<details>
<summary>bash / Git Bash / Linux / macOS 的 curl 调用</summary>

```bash
# 模型列表
curl -s http://localhost:7863/v1/models -H "Authorization: Bearer your-api-key"

# 账号状态（汇总 + 每账号详情，disabled 账号透出 disabled_reason）
curl -s http://localhost:7863/status -H "Authorization: Bearer your-api-key"

# 流式聊天
curl -sN http://localhost:7863/v1/chat/completions \
  -H "Authorization: Bearer your-api-key" \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"hi"}],"stream":true}'

# 非流式聊天（本地聚合）
curl -s http://localhost:7863/v1/chat/completions \
  -H "Authorization: Bearer your-api-key" \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"hi"}],"stream":false}'
```

</details>

> **Windows 提示**：PowerShell 中 `curl` 是 `Invoke-WebRequest` 的别名，**必须用 `curl.exe`** 调用真正的 curl 程序；Windows 10 / 11 已内置 curl（cmd 与 PowerShell 均可直接用）。下面给出与上方等价的 Windows 写法。

**CMD（命令提示符）** —— 行尾用 `^` 续行；JSON 内的双引号用 `\"` 转义：

<details>
<summary>CMD（命令提示符）curl 调用</summary>

```cmd
:: 流式聊天
curl -sN http://localhost:7863/v1/chat/completions ^
  -H "Authorization: Bearer your-api-key" ^
  -H "Content-Type: application/json" ^
  -d "{\"model\":\"deepseek-v4.1-flash\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":true}"

:: 非流式聊天（本地聚合）
curl -s http://localhost:7863/v1/chat/completions ^
  -H "Authorization: Bearer your-api-key" ^
  -H "Content-Type: application/json" ^
  -d "{\"model\":\"deepseek-v4.1-flash\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":false}"
```

</details>

**PowerShell** —— **不能**像 bash 那样用 `-d '{...}'` 单引号直接包 JSON 传给 curl。PowerShell 5.1 会把 JSON 开头 `{` 紧跟的前双引号吞掉，导致服务端收到 `{model...` 而报 `invalid character 'm'`（错误码 11101）。两种可靠写法：

写法 A（推荐，零转义 + 多行不依赖续行符）—— 先把 JSON 写成**无 BOM 的 UTF-8** 文件，再用 `-d @文件` 让 curl 读取；多行参数用 PowerShell 数组（**splatting**，`@(...)`）传递，**不依赖反引号续行，复制粘贴混进尾随空格也不会断行**：

<details>
<summary>PowerShell 写法 A（splatting，推荐）</summary>

```powershell
# 流式聊天
$json = '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"hi"}],"stream":true}'
[System.IO.File]::WriteAllText("$PWD\body.json", $json, [System.Text.UTF8Encoding]::new($false))
$argList = @(
  '-sN'
  'http://localhost:7863/v1/chat/completions'
  '-H', 'Authorization: Bearer your-api-key'
  '-H', 'Content-Type: application/json'
  '-d', "@$PWD\body.json"
)
curl.exe @argList

# 非流式聊天（本地聚合）
$json = '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"hi"}],"stream":false}'
[System.IO.File]::WriteAllText("$PWD\body.json", $json, [System.Text.UTF8Encoding]::new($false))
$argList = @(
  '-s'
  'http://localhost:7863/v1/chat/completions'
  '-H', 'Authorization: Bearer your-api-key'
  '-H', 'Content-Type: application/json'
  '-d', "@$PWD\body.json"
)
curl.exe @argList
```

</details>

写法 B（单行，类似 CMD）—— 在 `curl.exe` 后加 `--%` 停止解析，后续引号按 CMD 风格用 `\"` 转义：

<details>
<summary>PowerShell 写法 B（--% 单行）</summary>

```powershell
# 流式聊天
curl.exe --% -sN http://localhost:7863/v1/chat/completions -H "Authorization: Bearer your-api-key" -H "Content-Type: application/json" -d "{\"model\":\"deepseek-v4.1-flash\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":true}"

# 非流式聊天（本地聚合）
curl.exe --% -s http://localhost:7863/v1/chat/completions -H "Authorization: Bearer your-api-key" -H "Content-Type: application/json" -d "{\"model\":\"deepseek-v4.1-flash\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":false}"
```

</details>


<a id="compliance"></a>

## 安全与合规

### 发布来源与合规边界

- **无预编译 release**：仓库无 Release / tag，产物 = 源码自构建（Dockerfile 多阶段在本地构建时完成）
- 登录 / 签到 / 积分工具：`./login.sh` / `./signin.sh` / `./credit.sh`（Linux / 容器环境）。这三个脚本均为 Go 原生二进制（`login` / `signin_bin` / `credit`）的薄封装，Windows 下直接调用对应的 `.exe`（如 `login.exe`）即可，用法见「快速开始」第 2 步与「辅助工具」。
- **无产物校验和**：`go.sum` 仅约束 Go 模块依赖；Docker 镜像由本地 `docker compose build` 生成，未引用第三方镜像
- 上游 CodeBuddy 属第三方商业产品，本项目是其**非官方 OpenAI 兼容网关**；使用其账号做 API 网关涉及目标平台服务条款与账号风险，作者不对账号封禁、条款违约或使用结果负责

### 授权使用边界

- 仅限**本人授权账号**、本机 / 私有环境测试
- 不得共享、转售、违规分发，或用于违反目标平台条款的用途
- 遵守 CodeBuddy 平台服务条款与所在地法律
- 妥善保管 `auths/`（明文凭证）与网关端口

<a id="disclaimer"></a>

## 免责声明

本项目（包括但不限于代码、脚本、文档、配置示例及仓库内任何资源，下称「本项目内容」）**仅供个人学习与研究使用**。使用本项目表示您已阅读并接受本声明全部条款；如不同意，请立即停止使用并删除全部相关内容。

**1. 用途限制。** 本项目内容仅可用于个人学习、研究等非商业用途；请勿将本项目用于任何商业目的或牟利行为，请勿违反所属国家 / 地区 / 组织的任何法律法规。本项目不构成对任何软件、服务、平台的使用建议或授权。

**2. 账号与数据责任。** 本项目可能涉及个人账号凭证的获取、存储与使用。您应仅使用本人持有且已获授权的账号，自行确认相关平台的服务条款与允许范围，并自行承担使用、存储凭证（如 `auths/` 中的文件）及调用上游服务所产生的全部责任与风险。本项目不参与、不介入您与任何平台之间的契约关系。

**3. 内容与第三方界限。** 本项目内容中引用的第三方产品、服务、LOGO、图片、文案等，其权利均归各自权利人所有；本项目不保证此类内容的准确性、完整性、合法性，亦不代表支持或推荐任何第三方。如实存在侵权情形，请通过 Issues 告知，经核实后本项目会尽快处理。

**4. 无担保与风险自担。** 本项目内容按「现状」提供，不附带任何明示或默示的担保（包括但不限于适销性、特定用途适用性、准确性、不侵权等）。使用本项目（包括直接或间接）所产生的任何风险与后果（包括但不限于账号异常、数据丢失、服务中断、纠纷或损失），均由使用者自行承担，与本项目及其全部贡献者无关。

**5. 责任限定。** 在任何情况下，本项目及其作者、贡献者均不对任何直接、间接、偶然、特殊或后果性损害承担责任，无论该等损害是否基于合同、侵权或其他法律理论，即使已被告知发生该等损害的可能性。

**6. 修改与分发。** 基于本项目源代码进行的任何修改、衍生均系第三方自发行为，与本项目无关，相应后果由该第三方自行承担。本项目内所有资源文件，禁止任何公众号、自媒体进行任何形式的转载、发布。未经授权，任何组织或个人不得将本项目内容用于转载、发布或再分发。

**7. 条款变更。** 本项目保留随时修改、补充本声明的权利。修改后的声明自发布之日起生效，继续使用本项目即视为接受修订后的声明。本项目所有内容仅供学习和研究使用，请于学习研究完成后及时删除。

<a id="coffee"></a>

## ☕ Coffee

如果这个项目对你有帮助，欢迎请我喝杯咖啡～

<table>
  <tr>
    <td align="center"><b>💰 Solana</b></td>
    <td><code>AZAKF74rTu7UFVSNRzsKV4HHpTwarax6cG8KAh4fP5rQ</code></td>
  </tr>
  <tr>
    <td align="center"><b>💎 Ethereum</b></td>
    <td><code>0x1d418627aD6B043900CBE11fe439759bDF2b5170</code></td>
  </tr>
  <tr>
    <td align="center"><b>₿ Bitcoin</b></td>
    <td><code>bc1q9w7h4j9msyd9q6lhl0398n4s3g8h4vchpqvc2k</code></td>
  </tr>
</table>

<a id="license"></a>

## License

本项目采用 [MIT License](LICENSE) 开源协议。

- 在遵守 MIT License 前提下，允许使用、复制、修改、合并本项目源代码
- 再分发（源码或二进制形式）时，须保留原仓库的 MIT 版权声明与许可声明，并在 NOTICE 或 README 中注明原始出处 `https://github.com/Sliverkiss/workbuddy2api`
- 本项目不授予任何上游（CodeBuddy）接口或服务的权利；使用者仍需自行遵守上游服务条款
- 本项目的使用同时受上方**免责声明**约束；如免责声明与 MIT License 存在不一致，以免责声明为准
