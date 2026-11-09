# dsh-desktop-isolation

**让 DSH / Agent 在后台操作 Windows 图形界面，同时不打扰正在用电脑的用户。**

隔离式后台桌面控制：通过 UIA 元素树 + 后台消息投递驱动真实窗口，全程 **不抢前台、不动真实光标、不切换虚拟桌面**，默认只截取目标窗口（而不是整屏）。

> A DSH skill that lets an agent drive Windows GUI apps in the background without stealing the user's foreground window, moving the real cursor, or switching desktops. Built on top of `cua-driver` with a policy-enforcement wrapper.

---

## 为什么需要它

普通的桌面自动化（pyautogui / SendInput / 前台点击）会：抢走用户正在看的窗口、移动鼠标、把用户正在打字的输入截走。这个 skill 的目标是让 Agent 的 GUI 操作与用户的操作**物理上隔离**，用户甚至不需要知道 Agent 在操作什么窗口。

## 隔离保证（硬规则）

| 规则 | 内容 |
|---|---|
| **H1** | 永不主动抢占前台（`SetForegroundWindow` / 前台投递默认禁止，升级前台需要用户显式批准） |
| **H2** | 永不移动真实光标（不使用 `SetCursorPos` / `SendInput` 做常规操作） |
| **H3** | 永不切换虚拟桌面；对"显示即上屏"的窗口（Electron/Chromium）默认 **park 到屏幕外** |
| **H4** | 只操作被 `claim` 的目标进程/窗口，越界直接拒绝 |
| **H5** | 默认不截全屏：只按窗口截图（PrintWindow 语义），截图落盘为文件路径，不把 base64 塞进模型上下文 |

动作前后成对测量前台窗口 HWND 与光标位置；一旦发现窗口在动作期间被意外激活，立即尝试恢复原前台，并以 `VIOLATION_FOCUS_STEAL` 拒绝该结果（写审计日志）。

## 工作原理

```
SKILL.md（给 Agent 的指令与工作流）
        │
scripts/dshdesk.ps1  ← 策略层：claim 范围 / 前后台守卫 / park / 验证阶梯 / 错误码 / audit
        │  stdin JSON（UTF-8），cua-driver call <tool>
cua-driver 0.21.0 daemon（\\.\pipe\cua-driver）
        │
Windows UIA + PostMessage/WM_* + per-window capture
```

- **元素树优先于坐标**：每轮 `capture` 得到 `ref` 与元素快照（`element_token`）；旧快照的 token 会 fail-closed 返回 `STALE`，不会误点。
- **后台优先**：`click` / `type` / `set` / `key` / `scroll` 先走 accessibility 与后台消息投递；只有拿到结构化的 `BACKGROUND_UNAVAILABLE` 证据才允许升级。
- **验证阶梯**：`effect=confirmed` 不重放；`effect=unverifiable` 必须自己读回验证（`verify` / 再 `capture`）；`STALE` 重新 capture 重试一次；仍不行则升级坐标路径，最后才向用户申请前台。
- **停车隔离**：`park` 把窗口移到屏幕外（`SetWindowPos` 带 `SWP_NOACTIVATE`）并保持未最小化，窗口仍可被完整捕获与后台驱动；`unpark` 还原原窗口矩形。

## 前置条件

- Windows 10/11，交互式用户 session（Session 0 会明确报错）
- Hermes 自带的 `cua-driver` 0.21.0（默认路径 `%LOCALAPPDATA%\hermes\tools\cua-driver-*\cua-driver.exe`，可用环境变量 `DSHDESK_DRIVER` 覆盖）
- Windows PowerShell 5.1（脚本以 PS 5.1 兼容方式编写；不支持 `pwsh` 7 独占语法）

## 安装

方式一（作为 DSH skill 使用，推荐）：

```powershell
git clone https://github.com/zcslack17858645276-del/dsh-desktop-isolation.git "$env:USERPROFILE\.dsh\skills\desktop-isolation"
```

DSH 会热发现 `%USERPROFILE%\.dsh\skills\` 下的目录（无需重启），下一轮对话即可在 skill 列表里看到 `desktop-isolation`。

方式二（不装 skill，直接当 CLI 用）：克隆到任意目录，直接调用 `scripts\dshdesk.ps1`。

## 快速开始

```powershell
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$dshdesk = "$env:USERPROFILE\.dsh\skills\desktop-isolation\scripts\dshdesk.ps1"

# 0. 自检（驱动 / daemon / UIA / 屏幕 / 状态目录）
& $ps -NoProfile -ExecutionPolicy Bypass -File $dshdesk doctor

# 1. 看看有哪些窗口；只操作你点名的应用/pid
& $ps -NoProfile -ExecutionPolicy Bypass -File $dshdesk list -app "记事本"

# 2. 认领窗口（得到 ref，如 t1），之后所有动作都必须带 ref
& $ps -NoProfile -ExecutionPolicy Bypass -File $dshdesk claim -pid 12345

# 3. 读取控件树（不截图）
& $ps -NoProfile -ExecutionPolicy Bypass -File $dshdesk capture -ref t1

# 4. 后台操作：按元素 index / token
& $ps -NoProfile -ExecutionPolicy Bypass -File $dshdesk click -ref t1 -index 7
& $ps -NoProfile -ExecutionPolicy Bypass -File $dshdesk set -ref t1 -index 3 -value "Hello 中文"
& $ps -NoProfile -ExecutionPolicy Bypass -File $dshdesk type -ref t1 -token "s00000012:3" -text=-dash-leading
& $ps -NoProfile -ExecutionPolicy Bypass -File $dshdesk verify -ref t1 -index 3 -value "Hello 中文"

# 5. 需要看窗口时：停车/还原（不激活）
& $ps -NoProfile -ExecutionPolicy Bypass -File $dshdesk park -ref t1
& $ps -NoProfile -ExecutionPolicy Bypass -File $dshdesk unpark -ref t1

# 6. 收尾：结束会话 + 释放 claim
& $ps -NoProfile -ExecutionPolicy Bypass -File $dshdesk done
```

启动应用：`launch -app notepad` / `launch -path C:\Windows\System32\charmap.exe`；Electron 应用加 `-direct`（见下文）。关闭应用：`close -ref <ref> -consent "reason"`（只允许关闭本 skill 启动的进程）。

## 输出契约

- 动作类命令输出单行 JSON：`{ok,ref,action,effect,route,delivery,duration_ms,fg_changed,cursor_moved[,verify_hint]}`
- 失败：`{ok:false,code,message,hint}`
- `capture` / `list` / `status` 输出精简文本行，避免把整棵 UIA 树塞进上下文
- 审计日志：`%LOCALAPPDATA%\dsh-desktop\audit.jsonl`（每个动作一行 JSON）

常用错误码：

| code | 含义 / 处理 |
|---|---|
| `UNCLAIMED` / `NO_CLAIM` | 先 `claim`，再 `capture` |
| `STALE` | 快照过期，重新 `capture` 后重试一次 |
| `BACKGROUND_UNAVAILABLE` | 目标表面拒绝后台投递；不要自动升级前台，按 hint 走 web/headless 通道或请用户批准 |
| `WINDOW_MINIMIZED` | 先 `restore`（或 `park`/`unpark`）再操作 |
| `SENSITIVE_SURFACE` | 密码框/支付/UAC 等敏感面，只读不写 |
| `VIOLATION_FOCUS_STEAL` | 动作期间窗口被激活，已复原前台，结果作废 |
| `REFUSE_USER_APP_TERMINATION` | 只允许关闭本 skill `launch` 的进程 |
| `DAEMON_DOWN` / `DRIVER_*` | 运行 `daemon start` / 检查 `doctor` |

## Electron / Chromium 应用（实测边界）

1. **启动**：DSH 注入 `ELECTRON_RUN_AS_NODE=1` 时，直接的 `launch_app` 会把 Electron 当 Node 执行并立刻退出。用 `launch -direct`（自动检测 `resources\app`）：清理 `ELECTRON_RUN_AS_NODE` / `NODE_OPTIONS` 等变量、重定向 stdio，窗口出现后立即 `park`。
2. **输入**：Chromium/Electron **丢弃后台合成键盘事件**（`type` / `set` 返回 `BACKGROUND_UNAVAILABLE`，`target_class=Chrome_WidgetWin_1`）。纯 GUI 后台打字在 Electron 里做不到，这是渲染层行为，不是参数问题。正确做法是走应用自带的 web/headless 通道（例如很多 Electron 应用支持 `--headless` 或本地调试端口，用无头浏览器 + CDP 驱动），或请用户批准前台输入。
3. **点击**：UIA 点击与后台像素点击通常可用（窗口未最小化即可）；最小化时 `capture` 返回 0 元素、点击被拒绝。
4. 详见 `references/coexistence-policy.md` 与 `references/driver-contract.md`。

## 验证

```powershell
& $ps -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\dshdesk-selftest.ps1"
```

自带 30 项断言：daemon/doctor、窗口 claim、capture、后台 set + 读回、后台 click 生效、type、stale 无副作用、窗口截图、restore、**park/unpark 不抢前台**、launch/close、audit，以及收尾时的"前台窗口与真实光标未被改变、0 次前台违规"断言。selftest 会启动自己的离屏 WinForms 测试窗口（`dshdesk-testapp.ps1`），不会碰用户窗口。

本机实测结果：`SELFTEST PASS (30/30 checks, 0 warning(s))`，全程用户前台窗口与光标未变。

## 目录结构

```
SKILL.md                        # Agent 读的指令、工作流、命令表、错误码、升级阶梯
README.md                       # 本文件
scripts/
  dshdesk.ps1                   # 唯一入口 wrapper（daemon 生命周期/claim/capture/动作/park/audit）
  dshdesk-selftest.ps1          # 30 项自动化验收
  dshdesk-testapp.ps1           # 离屏、永不激活的 WinForms 测试目标
references/
  coexistence-policy.md         # 隔离策略：H1-H5、允许/需批准/硬禁止、升级阶梯、敏感面、清理
  driver-contract.md            # cua-driver 实测契约：进程模型、stdin/UTF-8、effect/refusal、session
```

## 安全与隐私

- 只操作 `claim` 过的 `(pid, window_id)`；不会遍历或操作用户其它窗口
- `capture` 默认不截图；截图只写目标窗口，落盘到 `%LOCALAPPDATA%\dsh-desktop\screenshots\`
- 敏感面（密码框、UAC、支付、隐私聊天等）只读不写，需用户本人操作
- 不删除用户文件、不清空回收站、不改用户配置；杀进程只针对本 skill `launch` 的进程
- daemon 默认复用已有实例（与 Hermes 共用），`daemon stop` 需要显式 `-consent`

## 已知限制

- 依赖 `cua-driver` 0.21.0（Hermes 自带）；版本升级可能影响工具 schema
- 需要交互式桌面会话；锁屏 / RDP 断开会话下无法驱动
- 用户窗口需要点名（`-app` / `-pid`），不会自动猜"用户想操作哪个窗口"
- Electron/Chromium 的后台文本输入见上文边界
- `bounded` 权限模式 + capability manifest 的加固需要重启 daemon（默认 `standard` 模式即可工作）

## 参考

- Hermes `background-desktop-control` 文档（元素树寻址、background-first、验证-升级阶梯、单一写者、能力天花板的契约来源）
- `cua-driver`（Windows UIA + 后台投递驱动，随 Hermes 分发）
