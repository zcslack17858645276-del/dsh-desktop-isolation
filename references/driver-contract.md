# cua-driver 0.21.0 契约（本机实测精简版）

本文件只记录 `dshdesk.ps1` 依赖的驱动契约与坑。完整原始记录见工作区
`desktop-isolation\notes\driver-contract.md`（43KB，含 capability-manifest v3 全文、bounded 模式实测、11 类校验错误、serve 参数矩阵）。

二进制：`%LOCALAPPDATA%\hermes\tools\cua-driver-0.21.0-win32-x64\cua-driver.exe`
（同目录还有 `cua-driver-uia.exe`、`cua_driver_sdk.dll`、`cua_driver_abi.h`、`cua_driver_node_runtime.node`）。
daemon：named pipe `\\.\pipe\cua-driver`；本机实测 session=1 交互桌面、UIA OK、`check_permissions` → `{elevated:true, integrity_level:"High", uia:true, post_message:true}`。

## 1. 进程模型与命令

| 命令 | 说明 |
|---|---|
| `cua-driver serve` | 起 daemon（前台阻塞；wrapper 用 Start-Process 隐藏启动）。参数：`--socket <path>`、`--permission-mode standard\|bounded\|unrestricted`、`--capability-manifest <json>` + `--approve-capability-manifest`、`--dangerously-bypass-approvals`、`--embedded`、`--host-bundle-id` |
| `cua-driver mcp` | stdio MCP server；Windows 上 `--direct` 在 MCP 进程内直接持有 runtime（不依赖外部 daemon） |
| `cua-driver status` | 人类文本（**没有 --json**）：socket / pid / permission mode / capability manifest / authorization host；daemon 不在时退出码非 0 |
| `cua-driver stop` | 停 daemon |
| `cua-driver call <tool> [json]` | 调一个工具；JSON 从 stdin 传入（见 §2）；成功时直接输出工具的 structuredContent（**没有 MCP `content` envelope**） |
| `cua-driver sessions \| revoke --session X \| --all` | 会话租约查询/撤销（revoke 是 deny-only，不需 token） |
| `cua-driver dump-docs --type json` | 导出全部工具 schema（本机 dump 在 `notes\docs-raw.json`，结构 `mcp.tools[]`，schema 键名是 `input_schema`） |

权限模式（启动后不可变）：
- `standard`（本机当前）：全工具可用，按 driver 默认审批策略（本机实测无闪窗、可直接调用）。
- `bounded`：需 capability manifest。结构要点：`allow.tools[]` + `resources.desktop:{}` / `resources.apps[{executable|bundle_id}]` + `durations`（带单位）；缺项会被 11 类校验错误拒绝；manifest 记录 sha256，改动需重新 approve。
- `unrestricted`：不建议（doctor 会 WARN）。

## 2. call 的输入输出契约（Windows PowerShell 5.1 必读）

PowerShell 5.1 直接传位置参数会**吞掉 JSON 引号**：
```
error: positional JSON arg to 'cua-driver call' did not parse: key must be a string at line 1 column 2
```
必须用 stdin 管道，且非 ASCII 内容要先编码成 UTF-8 字节（.NET Framework 的 `ProcessStartInfo.StandardInputEncoding` 属性不存在，赋值会抛异常——这正是中文输入失败的根因）：
```powershell
$bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
$p = Start-Process -FilePath $drv 'call' $tool -RedirectStandardInput ... # 或用 .NET Process 写 BaseStream
$p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $p.StandardInput.BaseStream.Flush()
```
- 成功：stdout 是工具 structuredContent 的 pretty JSON；退出码 0。
- 失败：stderr/文本错误（非 JSON），退出码非 0；工具级拒绝仍走 stdout 的结构化 refusing 形状。
- 不要用 `Select-Object -First N` 截断 driver stdout（提前关闭管道会 exit 1）；先完整捕获再投影。
- **`.ps1` 含中文字面量必须存成 UTF-8 BOM**，否则 PS5.1 按 ANSI 读成乱码（`dshdesk.ps1` 刻意保持纯 ASCII，中文用 `\uXXXX` 正则）。

## 3. 被 wrapper 使用的工具（精确 required 字段）

| tool | required | 常用可选 | 备注 |
|---|---|---|---|
| `get_window_state` | `pid, window_id` | `query, max_elements(默认5000), max_depth(默认25), include_screenshot(默认true), screenshot_out_file, session` | 返回 `elements[]`（element_index, element_token, role, label, value?, enabled, frame, parent_index, depth）、`snapshot_id`、`tree_markdown`、`total_element_count`、`elements_complete`；截图时返回 `screenshot_file_path`（**不是 base64**） |
| `click` / `double_click` / `right_click` | 无（但需寻址） | `pid, window_id, element_token` 或 `element_index+snapshot_id` 或 `x,y`；`delivery_mode`；`count 1-3`；`button`；`session` | background 是 mandatory first attempt；坐标是窗口内截图像素 |
| `type_text` | `text` | 同上寻址 + `delivery_mode` | 逐字符 PostMessage(WM_CHAR)；XAML/WinUI/UWP 不消费 → 用 `set_value` |
| `set_value` | `pid, value` | **必须** `element_index + snapshot_id`（实测只给 token 会报 "Missing required integer fields pid, window_id, and element_index."）、`window_id`、`element_token` | UIA ValuePattern；输入框首选 |
| `press_key` | `key` | `modifiers[], element_index+snapshot_id, scope=window\|desktop` | 单键走 PostMessage |
| `hotkey` | `keys[]`（≥2） | `element_index+snapshot_id, delivery_mode, session` | **Legacy Win32 目标带修饰键时会用 SendInput + 短暂 SetForegroundWindow（闪前台）**；XAML/WinUI/UWP 走 UIA 背景 |
| `scroll` | `direction` | `by=line\|page, amount 1-50, element_token, delivery_mode` | |
| `launch_app` | 无 | `name / path / aumid / additional_arguments[] / start_minimized / urls / session` | 用 SW_SHOWNOACTIVATE；返回 `{pid, windows[{window_id,title,bounds,is_on_screen}]}`；**windows[] 内没有 pid 字段**，claim 用顶层 pid |
| `list_windows` | 无 | — | `{windows[], _legacy_windows[], current_space_id}`；字段 window_id,pid,title,bounds,is_on_screen,layer,z_index |
| `kill_app` | `pid` | `session` | **session-provenance 作用域**：launch 与 kill 必须带同一个显式 session label，否则 `foreign_process_termination_denied` |
| `start_session` | — | `session`（label）、`cursor_theme` | 会话租约；动作工具都接受 `session` |
| `end_session` | — | `session` | |
| `verify_state` | `pid, window_id, expect[]` | `stable_samples, timeout_ms, session` | `value_equals` 要用完整 capture 回读的精确值（例如 charmap 会追加 `\r`） |
| `check_permissions` / `get_screen_size` | — | — | 环境自检用 |
| `get_desktop_state` | — | — | 全屏截图，wrapper **不暴露** |
| `move_cursor` / `bring_to_front` | — | — | wrapper **永不调用** |

## 4. effect / refusal 语义

- 动作返回 `delivery.mode`（background/foreground/unknown）、`route`（accessibility/global_input/...）、`effect` ∈ `confirmed | unverifiable | suspected_noop`（`confirmed` 常带 `evidence[{kind:"value_readback"}]`）。
- 拒绝形状：`{"status":"refused","effect":"refused","code":"...","refusal":{"code":"...","message":"..."}}`，退出码 0，但 `dshdesk` 会映射成 `{"ok":false,"code":...}`。
- 已知 refusal：`stale_element_token`（旧快照，无副作用）、`window_minimized`（iconic sentinel，需 restore）、`background_unavailable`（目标吞事件）、`sensitive_surface`（driver 端敏感面拦截）。
- `effect=unverifiable` 很常见（UIA 无法证明 UI 真变化）：**必须**用 `verify_state` 或重新 `get_window_state` 回读，不能据此认定成功或失败。

## 5. 已实测的 Windows 行为

- **完全离屏/被全屏视频遮挡的窗口**：UIA 元素点击、`set_value`、`type_text` 全部成功，前台与光标不变（charmap、WinForms 验证）。
- **最小化窗口**：`get_window_state` 可读（frame 为 iconic sentinel，如 x≈-31980），但 `click` 被 `window_minimized` 拒绝；`ShowWindow(hwnd, SW_SHOWNOACTIVATE=4)` 恢复不抢前台（`SW_SHOWNA=8` 无法恢复最小化）。
- **截图**：`include_screenshot + screenshot_out_file` 对离屏窗口返回真实内容 PNG（PrintWindow 式），不需要截全屏。
- `launch_app` 对 UWP/singleton（如本机 notepad）可能返回后 2 秒内进程消失，不可靠；`charmap.exe` 是稳定目标。
- 关闭应用的优先路径：`get_window_state` 找 `role=Button, label≈关闭/Close` → background click → 进程退出；失败再 `kill_app`（同 session）。

## 6. 安全加固（可选，非默认）

当前 daemon 是 `standard` 模式（本机 hermes 共用）。若要给 agent 更硬的边界，可用 `bounded` + capability manifest 限死允许的工具与 app：
```json
{"version": 3,
 "allow": {"tools": ["get_window_state","click","set_value","type_text","press_key","scroll","launch_app","kill_app","list_windows","start_session","end_session"]},
 "resources": {"desktop": {}, "apps": [{"executable": "C:\\Windows\\System32\\charmap.exe"}]},
 "durations": {"session_max": "30m", "action_timeout": "30s"}}
```
注意：manifest 需 `--approve-capability-manifest`，模式启动后不可变；改 manifest 要重启 daemon（会影响用户其他 hermes 会话，需先问用户）。

## 补充实测（2026-11-09，wrapper 联调）

- **session 过期**：任意工具调用可能返回 `session '<label>' has ended; tool call '<tool>' was rejected. Call start_session with this id to revive it`。用 `start_session {"session":"<label>"}` 复活（返回 `revived=true`），再重试原调用。wrapper 已内置自动 revive。
- **顶层结构化投递错误**：Chromium/Electron 目标的后台键盘输入返回 `{"code":"background_unavailable","escalation":{"reason":"background input is dropped by this surface; retry this action with delivery_mode:\"foreground\".","recommended":"foreground"},"event_kind":"text_input","target_class":"Chrome_WidgetWin_1"}` —— 没有 `status`/`refusal` 包裹，解析器必须兼容这种形状。
- **max_elements 截断**：`get_window_state` 的 `max_elements=20` 可能只返回 8 个元素；随后用快照里不存在的 index 点击会被拒 `element_index 9 out of range (snapshot had 8 elements)`。默认取 200+，或先用 `query` 投影。
- **park/unpark 不经过 driver**：Win32 `SetWindowPos(hwnd, 0, -3000, 120, 0, 0, 0x15)` 可把 Electron 窗口移到屏外并保持未最小化（`iconic=False`），driver 仍可完整 capture（实测 15 元素），前台/光标不变。恢复用 `SetWindowPos(..., 0x14)`；两处均带 `SWP_NOACTIVATE`。
- **Electron 后台键盘不可用**：`type_text`（element token 或像素）均返回 `background_unavailable`；但 UIA 点击 / 后台像素点击可用（`effect=unverifiable`、`route=synthetic_events`）。
- **关闭顺序**（wrapper 三级）：① fresh capture 找 UIA 关闭按钮并后台点击；② `kill_app`（必须带 launch 时同一显式 session label，否则 `foreign_process_termination_denied`）；③ wrapper direct 启动且 claim provenance=`process_sanitized` 时 `Stop-Process -Force`；仍失败才 `CLOSE_FAILED`。