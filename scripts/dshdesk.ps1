<#
  dshdesk.ps1 - DSH desktop isolation wrapper around cua-driver 0.21.0

  Goal: let the agent drive GUI windows on Windows WITHOUT taking the user's
  foreground, moving the user's real mouse cursor, switching desktops, or
  capturing the whole screen. All work is scoped to explicitly CLAIMED
  windows, every action is audited, and the wrapper never auto-escalates.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File dshdesk.ps1 <command> [options]

  Run `dshdesk.ps1 help` for the command list and the escalation policy.

  Hard invariants enforced here (on top of the driver):
    H1 never bring a target to the foreground (background delivery only;
       any observed raise of the target is treated as a violation and the
       previous foreground is restored best-effort)
    H2 never move the user's real mouse cursor (only pg click/type use
       window-local pixels via PostMessage; cursor position is recorded
       before/after each action for the audit trail)
    H3 never switch virtual desktops (no such call exists in this wrapper)
    H4 only act on windows that were explicitly claimed via `claim`/`launch`
    H5 never capture the full desktop (window captures only; base64 never
       printed, screenshots go to files)

  Exit codes: 0 ok, 1 error/refused.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Command = 'status',
  [Parameter(Position = 1, ValueFromRemainingArguments = $true)]$Rest
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
try { $OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$script:Version = '1.0.0'
$script:StateDir = Join-Path $env:LOCALAPPDATA 'dsh-desktop'
$script:StateFile = Join-Path $script:StateDir 'state.json'
$script:AuditFile = Join-Path $script:StateDir 'audit.jsonl'
$script:SnapDir = Join-Path $script:StateDir 'snapshots'
$script:ShotDir = Join-Path $script:StateDir 'screenshots'
$script:Driver = $null
$script:Session = $null
$script:CurrentCmd = $Command
$script:Opt = @{}
$script:Pos = @()
$script:SensitivePattern = '(?i)(\u5bc6\u7801|password|passwd|sign[\s-]*in|\u767b\u5f55|\u652f\u4ed8|payment|verification code|\u9a8c\u8bc1\u7801|two[\s-]*factor|2fa|authenticator|windows security|\u7528\u6237\u5e10\u6237\u63a7\u5236|\buac\b|credit card|wallet|\u94b1\u5305|recovery key|\u6062\u590d\u5bc6\u94a5)'

# ---------------------------------------------------------------------------
# output / error helpers
# ---------------------------------------------------------------------------
function Write-Dir([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Write-Audit($Entry) {
  try {
    Write-Dir $script:StateDir
    $line = ($Entry | ConvertTo-Json -Compress -Depth 10)
    [System.IO.File]::AppendAllText($script:AuditFile, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
}

function Ok {
  param($Object, [int]$ExitCode = 0)
  Write-Output ($Object | ConvertTo-Json -Compress -Depth 12)
  exit $ExitCode
}

function Fail {
  param(
    [string]$Code,
    [string]$Message,
    [string]$Hint = '',
    $Extra = $null,
    [int]$ExitCode = 1
  )
  $obj = [ordered]@{ ok = $false; code = $Code; message = $Message }
  if ($Hint) { $obj['hint'] = $Hint }
  if ($Extra) { foreach ($k in @($Extra.Keys)) { $obj[$k] = $Extra[$k] } }
  Write-Audit ([ordered]@{ ts = (Get-Date).ToString('o'); cmd = $script:CurrentCmd; result = 'error'; code = $Code; message = $Message })
  Write-Output ($obj | ConvertTo-Json -Compress -Depth 10)
  exit $ExitCode
}

function Show-Usage {
  Write-Output @'
dshdesk - isolated background desktop control (cua-driver 0.21.0)

COMMANDS
  status                     driver/daemon/session/claims/foreground/cursor
  doctor                     environment + capability self-check (fails loudly)
  list [-app X] [-pid N]     compact window list (pid win app title flags)
  claim -app X | -pid N | -window N [-title X] [-kind user|launched]
                             claim exactly one window -> ref tN
  release [-ref t1] [-all]   drop claims
  capture [-ref t1] [-query S] [-max N] [-depth N] [-frames]
                             (-frames also prints element frames)
                             refresh element snapshot, print compact tree
  shot [-ref t1] [-path PATH] capture + PNG file (prints only the file path)
  click [-ref t1] -index N | -token T | -x X -y Y
                             [-double] [-right] [-count N] [-restore]
  type  [-ref t1] -index N | -token T | -x X -y Y -text S [-verify]
                             (text starting with '-' must be written -text=-foo)
  set   [-ref t1] -index N | -token T -value V
  key   [-ref t1] -key NAME [-index N] [-mods ctrl,shift] [-consent R]
  scroll [-ref t1] -direction up|down|left|right [-by line|page] [-amount N]
  restore [-ref t1]          un-minimize WITHOUT activation (then re-capture)
  park [-ref t1] [-x -3000] [-y 120]
                             move the window completely off-screen WITHOUT activation
                             (original rect saved in the claim; use for Electron/GUI apps
                             so the user never sees the window while it stays drivable)
  unpark [-ref t1]           move a parked window back to its original rect (no activation)
  launch -app NAME | -path EXE [-args STR] [-no-claim]
  close [-ref t1] [-consent R]        only for windows this wrapper launched
  verify [-ref t1] -index N [-value S] [-label S] [-enabled true|false]
  audit [-tail N]            tail the audit log
  done [-cleanup]            end session, release claims, optional close launches
  selftest                   run the end-to-end isolation self-test

GLOBAL OPTIONS
  -ref t1        claimed target (default: the only claim)
  -token T       raw element_token from capture (s########:N)
  -index N       element index from the LAST capture of this ref
  -consent "..." explicit user approval text (required for focus-risky paths)
  -foreground    explicit escalation for click/type/key (requires -consent)
  -verify        re-capture after set/type and report the value change
  -json          (actions always emit JSON; this is accepted and ignored)

ESCALATION LADDER (never skipped, never automatic)
  1. element + background      (default: UIA Invoke/ValuePattern + PostMessage)
  2. pixel + background        (click/type -x/-y: UIA hit-test, then PostMessage)
  3. foreground + SendInput    (ONLY with -foreground -consent "<user approval>";
                                briefly raises the target and moves the real
                                cursor - ask the user first)
  4. stop                      (Qt/KTextEditor-style input sinks: write the file
                                directly instead of synthesizing keys)

ERROR CODES
  UNKNOWN_REF / NO_CLAIM / AMBIGUOUS_REF / UNKNOWN_COMMAND
  TARGET_NOT_FOUND / AMBIGUOUS_TARGET / BLOCKED_TARGET / TARGET_GONE
  NO_SNAPSHOT / NO_ELEMENT / NO_TARGET
  STALE / WINDOW_MINIMIZED / BACKGROUND_UNAVAILABLE / SUSPECTED_NOOP
  SENSITIVE_SURFACE / HOTKEY_NEEDS_CONSENT / CONSENT_REQUIRED
  VIOLATION_FOCUS_STEAL / REFUSE_USER_APP_TERMINATION
  DAEMON_DOWN / DRIVER_NOT_FOUND / DRIVER_TEXT_ERROR / DRIVER_TIMEOUT
'@
  exit 0
}

# ---------------------------------------------------------------------------
# options
# ---------------------------------------------------------------------------
function Parse-Options {
  param([object[]]$Tokens)
  $o = @{}
  $p = @()
  $i = 0
  while ($null -ne $Tokens -and $i -lt $Tokens.Count) {
    $t = [string]$Tokens[$i]
    if ($t -match '^--?([A-Za-z][A-Za-z0-9_-]*)(?:=(.*))?$') {
      $name = $Matches[1].ToLowerInvariant()
      if ($Matches.Count -ge 3 -and $null -ne $Matches[2] -and $Matches[2] -ne '') {
        $o[$name] = $Matches[2]
      } elseif ($i + 1 -lt $Tokens.Count -and -not ([string]$Tokens[$i + 1] -match '^--?[A-Za-z][A-Za-z0-9_-]*$')) {
        $o[$name] = [string]$Tokens[$i + 1]
        $i++
      } else {
        $o[$name] = $true
      }
    } else {
      $p += $t
    }
    $i++
  }
  return @{ opt = $o; pos = $p }
}

function Get-Opt {
  param([string]$Name, $Default = $null)
  if ($script:Opt.ContainsKey($Name)) { return $script:Opt[$Name] }
  return $Default
}

function Has-Opt {
  param([string]$Name)
  return $script:Opt.ContainsKey($Name)
}

function Get-OptInt {
  param([string]$Name, [int]$Default = 0)
  $v = Get-Opt $Name $null
  if ($null -eq $v -or $v -eq $true) { return $Default }
  try { return [int]$v } catch { return $Default }
}

function Get-OptStr {
  param([string]$Name, [string]$Default = '')
  $v = Get-Opt $Name $null
  if ($null -eq $v -or $v -eq $true) { return $Default }
  return [string]$v
}

# ---------------------------------------------------------------------------
# process / driver plumbing
# ---------------------------------------------------------------------------
function Invoke-NativeProcess {
  param(
    [string]$FilePath,
    [string[]]$Arguments,
    [string]$StdinText,
    [int]$TimeoutMs = 30000
  )
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $psi.Arguments = ($Arguments -join ' ')
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  try {
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
  } catch { }
  try {
    $p = [System.Diagnostics.Process]::Start($psi)
  } catch {
    Fail 'DRIVER_LAUNCH_FAILED' ("failed to start " + $FilePath + ": " + $_.Exception.Message) 'check the driver path and antivirus/EDR'
  }
  $outTask = $p.StandardOutput.ReadToEndAsync()
  $errTask = $p.StandardError.ReadToEndAsync()
  try {
    if ($null -ne $StdinText) {
      # .NET Framework (PowerShell 5.1) has no StandardInputEncoding; write UTF-8 bytes to the base stream.
      $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes([string]$StdinText)
      $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
      $p.StandardInput.BaseStream.Flush()
    }
    $p.StandardInput.Close()
  } catch { }
  if (-not $p.WaitForExit($TimeoutMs)) {
    try { $p.Kill() } catch { }
    return @{ timeout = $true; stdout = ''; stderr = ''; exit = -1 }
  }
  $p.WaitForExit()
  return @{ timeout = $false; stdout = $outTask.Result; stderr = $errTask.Result; exit = $p.ExitCode }
}

function Get-DriverPath {
  if ($script:Driver) { return $script:Driver }
  $cands = @()
  if ($env:DSHDESK_DRIVER) { $cands += $env:DSHDESK_DRIVER }
  $base = Join-Path $env:LOCALAPPDATA 'hermes\tools'
  if (Test-Path -LiteralPath $base) {
    $dirs = Get-ChildItem -LiteralPath $base -Directory -Filter 'cua-driver-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    foreach ($d in $dirs) { $cands += (Join-Path $d.FullName 'cua-driver.exe') }
  }
  $cmd = Get-Command 'cua-driver.exe' -ErrorAction SilentlyContinue
  if ($cmd) { $cands += $cmd.Source }
  foreach ($c in $cands) {
    if ($c -and (Test-Path -LiteralPath $c)) {
      $script:Driver = (Resolve-Path -LiteralPath $c).Path
      return $script:Driver
    }
  }
  Fail 'DRIVER_NOT_FOUND' 'cua-driver.exe was not found' 'install hermes (cua-driver) or set env DSHDESK_DRIVER=<full path to cua-driver.exe>'
}

function Map-DriverTextError {
  param([string]$Raw)
  $r = $Raw -replace '\s+', ' '
  if ($r -match 'daemon .*not running|not running|failed to connect|pipe') {
    return @{ code = 'DAEMON_DOWN'; hint = 'start the driver daemon (cua-driver serve ...) or ask the user to start hermes/cua-driver' }
  }
  if ($r -match 'No window with window_id|No process with pid|does not belong') {
    return @{ code = 'TARGET_GONE'; hint = 'the window/process disappeared or was replaced; run list and claim again' }
  }
  if ($r -match 'stale') { return @{ code = 'STALE'; hint = 'run capture again and retry' } }
  return @{ code = 'DRIVER_TEXT_ERROR'; hint = 'the driver rejected the call; read message and adjust (no side effect was applied)' }
}

function Revive-Session {
  # A driver session can expire while the wrapper still holds its label (idle daemon restart,
  # end_session from another shell, ...). start_session with the same label revives it.
  $label = [string]$script:Session
  if (-not $label) {
    $st = Load-State
    if ($st.session) { $label = [string]$st.session; $script:Session = $label }
  }
  if (-not $label) { return $false }
  try {
    Invoke-DriverTool 'start_session' ([ordered]@{ session = $label }) -NoRevive | Out-Null
    Write-Audit ([ordered]@{ ts = (Get-Date).ToString('o'); cmd = 'session'; action = 'revive'; session = $label })
    return $true
  } catch {
    return $false
  }
}

function Invoke-DriverTool {
  param([string]$Tool, $Payload, [int]$TimeoutMs = 30000, [switch]$NoRevive)
  $exe = Get-DriverPath
  $json = '{}'
  if ($null -ne $Payload) {
    $json = ($Payload | ConvertTo-Json -Compress -Depth 15)
  }
  $attempt = 0
  while ($true) {
    $res = Invoke-NativeProcess -FilePath $exe -Arguments @('call', $Tool) -StdinText $json -TimeoutMs $TimeoutMs
    if ($res.timeout) {
      Fail 'DRIVER_TIMEOUT' ("cua-driver call " + $Tool + " timed out after " + $TimeoutMs + " ms") 'the driver may be stuck; run doctor/status and report'
    }
    $raw = ([string]$res.stdout).Trim()
    if ($raw -eq '') { $raw = ([string]$res.stderr).Trim() }
    if ($raw -eq '') {
      Fail 'DRIVER_TEXT_ERROR' ("cua-driver call " + $Tool + " produced no output (exit " + $res.exit + ")") 'run doctor'
    }
    if ((-not $NoRevive) -and ($attempt -lt 1) -and ($Tool -ne 'start_session') -and ($raw -match '(?i)(has ended|session[^\r\n]{0,80}ended|start_session to revive)')) {
      if (Revive-Session) {
        $attempt++
        continue
      }
    }
    try {
      return ($raw | ConvertFrom-Json)
    } catch {
      $m = Map-DriverTextError $raw
      Fail $m.code ($raw -replace '\s+', ' ') $m.hint
    }
  }
}

function Invoke-DriverCli {
  param([string[]]$Arguments, [int]$TimeoutMs = 30000)
  $exe = Get-DriverPath
  $res = Invoke-NativeProcess -FilePath $exe -Arguments $Arguments -StdinText $null -TimeoutMs $TimeoutMs
  if ($res.timeout) {
    Fail 'DRIVER_TIMEOUT' ("cua-driver " + ($Arguments -join ' ') + " timed out") 'run doctor'
  }
  $raw = ([string]$res.stdout).Trim()
  if ($raw -eq '') { $raw = ([string]$res.stderr).Trim() }
  return @{ text = $raw; exit = $res.exit; stderr = ([string]$res.stderr).Trim() }
}

# ---------------------------------------------------------------------------
# Win32 (foreground / cursor guards, non-activating restore)
# ---------------------------------------------------------------------------
if (-not ('DshDeskWin32' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class DshDeskWin32 {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
}
'@
}

function New-Guard {
  $h = [DshDeskWin32]::GetForegroundWindow()
  $procId = [uint32]0
  try { [void][DshDeskWin32]::GetWindowThreadProcessId($h, [ref]$procId) } catch { }
  $sb = New-Object System.Text.StringBuilder 512
  try { [void][DshDeskWin32]::GetWindowText($h, $sb, 512) } catch { }
  $p = New-Object DshDeskWin32+POINT
  try { [void][DshDeskWin32]::GetCursorPos([ref]$p) } catch { }
  $name = ''
  if ($procId -gt 0) { try { $name = (Get-Process -Id ([int]$procId) -ErrorAction Stop).ProcessName } catch { } }
  return [ordered]@{
    fg_hwnd  = [int64]$h
    fg_pid   = [int]$procId
    fg_name  = $name
    fg_title = $sb.ToString()
    cur_x    = [int]$p.X
    cur_y    = [int]$p.Y
  }
}

function Compare-Guard {
  param($Before, $After, $Claim)
  $fgChanged = ([int64]$Before.fg_hwnd -ne [int64]$After.fg_hwnd)
  $cursorMoved = (([int]$Before.cur_x -ne [int]$After.cur_x) -or ([int]$Before.cur_y -ne [int]$After.cur_y))
  $steal = $false
  if ($fgChanged -and $null -ne $Claim) {
    if ([int]$After.fg_pid -eq [int]$Claim.pid) {
      if ([int64]$After.fg_hwnd -eq [int64]$Claim.window_id) { $steal = $true }
    }
  }
  return @{ fg_changed = $fgChanged; cursor_moved = $cursorMoved; focus_steal = $steal }
}

function Get-WindowRectInfo {
  param([int64]$WindowId)
  $r = New-Object DshDeskWin32+RECT
  $ok = $false
  try { $ok = [DshDeskWin32]::GetWindowRect([IntPtr]$WindowId, [ref]$r) } catch { }
  if (-not $ok) { return $null }
  return @{ x = $r.Left; y = $r.Top; w = ($r.Right - $r.Left); h = ($r.Bottom - $r.Top) }
}

function Test-ForegroundFullscreen {
  param($Fg)
  $screenW = [DshDeskWin32]::GetSystemMetrics(0)
  $screenH = [DshDeskWin32]::GetSystemMetrics(1)
  $rect = Get-WindowRectInfo -WindowId ([int64]$Fg.fg_hwnd)
  if ($null -eq $rect) { return $false }
  return ([int]$rect.w -ge [int]$screenW -and [int]$rect.h -ge [int]$screenH)
}

# ---------------------------------------------------------------------------
# state / claims
# ---------------------------------------------------------------------------
function New-State {
  return [ordered]@{ version = 1; session = $null; next_ref = 1; claims = @() }
}

function Load-State {
  if (-not (Test-Path -LiteralPath $script:StateFile)) { return (New-State) }
  try {
    $raw = [System.IO.File]::ReadAllText($script:StateFile)
    $s = $raw | ConvertFrom-Json
    $st = New-State
    if ($s.PSObject.Properties.Name -contains 'session' -and $s.session) { $st.session = [string]$s.session }
    if ($s.PSObject.Properties.Name -contains 'next_ref' -and $s.next_ref) { $st.next_ref = [int]$s.next_ref }
    if ($s.PSObject.Properties.Name -contains 'claims' -and $s.claims) { $st.claims = @($s.claims) }
    return $st
  } catch {
    return (New-State)
  }
}

function Save-State {
  param($State)
  Write-Dir $script:StateDir
  $json = ($State | ConvertTo-Json -Depth 10)
  [System.IO.File]::WriteAllText($script:StateFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-Claim {
  param([string]$Ref)
  $st = Load-State
  $claims = @($st.claims)
  if ($Ref) {
    $hit = @($claims | Where-Object { [string]$_.ref -eq $Ref })
    if ($hit.Count -eq 0) { Fail 'UNKNOWN_REF' ("no claim named '" + $Ref + "'") 'run: list, then claim -app <name>' }
    return $hit[0]
  }
  if ($claims.Count -eq 1) { return $claims[0] }
  if ($claims.Count -eq 0) { Fail 'NO_CLAIM' 'no window is claimed' 'run: claim -app <name> (or -pid N / -window N)' }
  Fail 'AMBIGUOUS_REF' ('multiple claims exist: ' + ((@($claims | ForEach-Object { $_.ref + '=' + $_.app })) -join ', ')) 'pass -ref <id>'
}

function Get-AncestorPids {
  $result = @()
  $cur = [int]$PID
  $guard = 0
  while ($cur -gt 0 -and $guard -lt 14) {
    if ($result -contains $cur) { break }
    $result += $cur
    $parent = 0
    try {
      $ci = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = ' + $cur) -ErrorAction Stop
      if ($ci) { $parent = [int]$ci.ParentProcessId }
    } catch { }
    if ($parent -le 0) { break }
    $cur = $parent
    $guard++
  }
  return $result
}

function Get-DriverWindows {
  $data = Invoke-DriverTool 'list_windows' ([ordered]@{})
  $wins = @()
  if ($data.PSObject.Properties.Name -contains 'windows') { $wins = @($data.windows) }
  elseif ($data.PSObject.Properties.Name -contains '_legacy_windows') { $wins = @($data._legacy_windows) }
  return $wins
}

function Format-WindowLine {
  param($Window, $Fg, $ClaimRef = '')
  $wid = [int64]$Window.window_id
  $procId = [int]$Window.pid
  $app = ''
  try { $app = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { }
  $flags = @()
  if ($Fg -and [int64]$Fg.fg_hwnd -eq $wid) { $flags += 'FOCUS' }
  $b = $Window.bounds
  if ($null -ne $b -and [int]$b.x -le -30000) { $flags += 'MIN' }
  if (-not [bool]$Window.is_on_screen) { $flags += 'OFFSCREEN' }
  if ($ClaimRef) { $flags += ('REF=' + $ClaimRef) }
  return ('win=0x{0:x} pid={1} app={2} "{3}" {4}' -f $wid, $procId, $app, ([string]$Window.title), ($flags -join ' ')).Trim()
}

function Ensure-Alive {
  param($Claim)
  $p = Get-Process -Id ([int]$Claim.pid) -ErrorAction SilentlyContinue
  if (-not $p) {
    Fail 'TARGET_GONE' ('claimed process ' + $Claim.pid + ' is no longer running') 'release the claim and claim the window again'
  }
}

function Assert-SensitiveSurface {
  param($Claim, [string]$What = 'input')
  if (Has-Opt 'consent') { return }
  $title = [string]$Claim.title
  $labelHit = ''
  $hit = ($title -match $script:SensitivePattern)
  if (-not $hit) {
    $snap = Load-Snapshot ([string]$Claim.ref)
    if ($null -ne $snap -and (Has-Opt 'index')) {
      $idx = Get-OptInt 'index' -Default -1
      foreach ($e in @($snap.elements)) {
        if ([int]$e.i -eq $idx -and ([string]$e.label) -match $script:SensitivePattern) { $hit = $true; $labelHit = [string]$e.label; break }
      }
    }
  }
  if ($hit) {
    Fail 'SENSITIVE_SURFACE' ('refusing ' + $What + ' on a sensitive surface: window "' + $title + '"' + (if ($labelHit) { ', element "' + $labelHit + '"' } else { '' })) 'passwords / sign-in / payment / 2FA / UAC / recovery keys must be handled by the user. Ask the user to do this step, or re-run with -consent "<explicit user approval>" if they insist.'
  }
}

# ---------------------------------------------------------------------------
# snapshots
# ---------------------------------------------------------------------------
function Get-SnapshotPath([string]$Ref) { return (Join-Path $script:SnapDir ($Ref + '.json')) }

function Save-Snapshot {
  param([string]$Ref, $Snapshot)
  Write-Dir $script:SnapDir
  $json = ($Snapshot | ConvertTo-Json -Depth 10)
  [System.IO.File]::WriteAllText((Get-SnapshotPath $Ref), $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Load-Snapshot([string]$Ref) {
  $path = Get-SnapshotPath $Ref
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try { return ([System.IO.File]::ReadAllText($path) | ConvertFrom-Json) } catch { return $null }
}

function Resolve-Token {
  param($Claim, $Snapshot)
  if (Has-Opt 'token') { return [string](Get-Opt 'token') }
  if (Has-Opt 'index') {
    $idx = Get-OptInt 'index' -Default -1
    if ($null -eq $Snapshot) {
      Fail 'NO_SNAPSHOT' ('no capture recorded for ' + $Claim.ref) ('run: capture -ref ' + $Claim.ref)
    }
    foreach ($e in @($Snapshot.elements)) {
      if ([int]$e.i -eq $idx) { return [string]$e.token }
    }
    Fail 'NO_ELEMENT' ('element index ' + $idx + ' is not in the last capture of ' + $Claim.ref) 'run capture again (the tree may have changed)'
  }
  return $null
}

# ---------------------------------------------------------------------------
# driver session
# ---------------------------------------------------------------------------
function Ensure-Session {
  if ($script:Session) { return $script:Session }
  $st = Load-State
  if ($st.session) {
    $script:Session = [string]$st.session
    return $script:Session
  }
  $label = 'dshdesk-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
  try {
    Invoke-DriverTool 'start_session' ([ordered]@{ session = $label }) | Out-Null
  } catch { }
  $st.session = $label
  Save-State $st
  $script:Session = $label
  Write-Audit ([ordered]@{ ts = (Get-Date).ToString('o'); cmd = 'session'; action = 'start'; session = $label })
  return $label
}

# ---------------------------------------------------------------------------
# action execution
# ---------------------------------------------------------------------------
function Get-Refusal {
  param($Response)
  if ($null -eq $Response) { return $null }
  $props = @($Response.PSObject.Properties.Name)
  # 1) classic refusal envelope: {status:"refused", refusal:{code,message,...}}
  if (($props -contains 'status') -and ([string]$Response.status) -eq 'refused') {
    $code = 'REFUSED'
    $msg = 'driver refused the action'
    if (($props -contains 'refusal') -and ($null -ne $Response.refusal)) {
      if ($Response.refusal.PSObject.Properties.Name -contains 'code') { $code = [string]$Response.refusal.code }
      if ($Response.refusal.PSObject.Properties.Name -contains 'message') { $msg = [string]$Response.refusal.message }
    }
    return @{ code = $code; message = $msg; target_class = ''; event_kind = ''; escalation = '' }
  }
  # 2) structured delivery error: e.g. {code:"background_unavailable", escalation:{...}, target_class:"Chrome_WidgetWin_1"}
  if (($props -contains 'code') -and ($props -notcontains 'status') -and ($props -notcontains 'effect') -and ([string]$Response.code)) {
    $msg = [string]$Response.code
    if (($props -contains 'escalation') -and ($null -ne $Response.escalation)) {
      if ($Response.escalation.PSObject.Properties.Name -contains 'reason') { $msg = [string]$Response.escalation.reason }
      elseif ($Response.escalation.PSObject.Properties.Name -contains 'message') { $msg = [string]$Response.escalation.message }
    }
    $targetClass = ''
    if (($props -contains 'target_class') -and $null -ne $Response.target_class) { $targetClass = [string]$Response.target_class }
    $eventKind = ''
    if (($props -contains 'event_kind') -and $null -ne $Response.event_kind) { $eventKind = [string]$Response.event_kind }
    return @{ code = [string]$Response.code; message = $msg; target_class = $targetClass; event_kind = $eventKind; escalation = $(if ($props -contains 'escalation') { 'present' } else { '' }) }
  }
  return $null
}

function Get-RefusalCode {
  param([string]$DriverCode)
  switch -Regex ($DriverCode) {
    'stale' { return 'STALE' }
    'minimized' { return 'WINDOW_MINIMIZED' }
    'background_unavailable|background_delivery' { return 'BACKGROUND_UNAVAILABLE' }
    default { return ('REFUSED_' + ($DriverCode -replace '[^A-Za-z0-9_]', '_').ToUpperInvariant()) }
  }
}

function Get-RefusalHint {
  param([string]$DriverCode, [string]$TargetClass = '')
  if (($TargetClass -match 'Chrome|Electron|WidgetWin') -and ($DriverCode -match 'background_unavailable|background_delivery')) {
    return 'this Chromium/Electron surface drops synthetic keyboard input in the background; use the app own web/server channel (web UI + CDP) instead, or tell the user that a foreground escalation is needed and wait for approval'
  }
  switch -Regex ($DriverCode) {
    'stale' { return 'run capture again, then retry with the fresh element index' }
    'minimized' { return 'run restore -ref <ref> (un-minimize without activation), then capture and retry' }
    'background_unavailable|background_delivery' { return 'ladder step 2: pixel path with -x/-y from a -screenshot capture; if that also fails, ask the user before any foreground escalation' }
    default { return 'read the driver message; the action was not applied' }
  }
}

function Invoke-Action {
  param(
    [string]$Tool,
    $Payload,
    $Claim
  )
  $before = New-Guard
  $t0 = Get-Date
  $res = Invoke-DriverTool $Tool $Payload
  $ms = [int]((New-TimeSpan -Start $t0 -End (Get-Date)).TotalMilliseconds)
  # Electron/Chromium can activate asynchronously after an action returns; give the desktop
  # a moment before sampling the after-guard so a real focus steal is not missed (false negative).
  Start-Sleep -Milliseconds 250
  $after = New-Guard
  $cmp = Compare-Guard -Before $before -After $after -Claim $Claim
  $effect = ''
  $route = ''
  $delivery = ''
  if ($res.PSObject.Properties.Name -contains 'effect') { $effect = [string]$res.effect }
  if ($res.PSObject.Properties.Name -contains 'route') { $route = [string]$res.route }
  if ($res.PSObject.Properties.Name -contains 'delivery' -and $null -ne $res.delivery) {
    if ($res.delivery.PSObject.Properties.Name -contains 'mode') { $delivery = [string]$res.delivery.mode }
  }
  $audit = [ordered]@{
    ts                = (Get-Date).ToString('o')
    cmd               = $script:CurrentCmd
    ref               = [string]$Claim.ref
    pid               = [int]$Claim.pid
    win               = ('0x{0:x}' -f [int64]$Claim.window_id)
    action            = $Tool
    effect            = $effect
    route             = $route
    delivery          = $delivery
    duration_ms       = $ms
    fg_before         = $before.fg_hwnd
    fg_before_pid     = $before.fg_pid
    fg_after          = $after.fg_hwnd
    fg_after_pid      = $after.fg_pid
    fg_changed        = $cmp.fg_changed
    cursor_before     = ('' + $before.cur_x + ',' + $before.cur_y)
    cursor_after      = ('' + $after.cur_x + ',' + $after.cur_y)
    cursor_moved      = $cmp.cursor_moved
    consent           = [bool](Has-Opt 'consent')
    session           = $script:Session
  }

  if ($cmp.focus_steal) {
    $restored = $false
    try { $restored = [bool][DshDeskWin32]::SetForegroundWindow([IntPtr]$before.fg_hwnd) } catch { }
    Write-Audit ($audit + @{ result = 'violation'; code = 'VIOLATION_FOCUS_STEAL'; fg_restore_attempted = $true; fg_restore_ok = $restored })
    Fail 'VIOLATION_FOCUS_STEAL' ('the action raised claimed window ' + $Claim.ref + ' to the foreground - background delivery must never do this') 'stop and report to the user; foreground was restored best-effort' @{ ref = $Claim.ref; action = $Tool; fg_before = $before.fg_hwnd; fg_after = $after.fg_hwnd; restore_attempted = $true; restore_ok = $restored }
  }

  $refusal = Get-Refusal $res
  if ($refusal) {
    $code = Get-RefusalCode $refusal.code
    $hint = Get-RefusalHint $refusal.code $refusal.target_class
    Write-Audit ($audit + @{ result = 'refused'; code = $code; driver_code = $refusal.code; target_class = $refusal.target_class })
    Fail $code $refusal.message $hint @{ ref = [string]$Claim.ref; action = $Tool; driver_code = $refusal.code; target_class = $refusal.target_class }
  }

  if ($effect -eq 'suspected_noop' -or $effect -eq 'noop') {
    Write-Audit ($audit + @{ result = 'noop'; code = 'SUSPECTED_NOOP' })
    Fail 'SUSPECTED_NOOP' ('driver reports effect=' + $effect + ' (the background action did not visibly take)') 'ladder step 2: capture -screenshot, then click/type with -x/-y; if still a no-op, ask the user before foreground escalation' @{ ref = [string]$Claim.ref; action = $Tool; effect = $effect }
  }

  $verifyHint = $null
  if ($effect -eq 'unverifiable') { $verifyHint = 'effect unverifiable: capture again and check the postcondition (label/value/state)' }
  $audit['result'] = 'ok'
  Write-Audit $audit
  $out = [ordered]@{
    ok            = $true
    ref           = [string]$Claim.ref
    action        = $Tool
    effect        = $effect
    route         = $route
    delivery      = $delivery
    duration_ms   = $ms
    fg_changed    = $cmp.fg_changed
    cursor_moved  = $cmp.cursor_moved
  }
  if ($cmp.fg_changed) { $out['warning'] = 'foreground changed during the action (may be the user switching windows); background path should not do this' }
  if ($verifyHint) { $out['verify_hint'] = $verifyHint }
  return $out
}

# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------
function Get-DaemonStatus {
  $cli = Invoke-DriverCli @('status')
  $text = [string]$cli.text
  $info = [ordered]@{ running = $false; socket = ''; pid = 0; mode = ''; manifest = ''; raw = $text }
  if ($text -match 'daemon is running') { $info.running = $true }
  if ($text -match 'socket:\s*(\S+)') { $info.socket = $Matches[1] }
  if ($text -match 'pid:\s*(\d+)') { $info.pid = [int]$Matches[1] }
  if ($text -match 'permission mode:\s*([^\r\n]+)') { $info.mode = $Matches[1].Trim() }
  if ($text -match 'capability manifest:\s*([^\r\n]+)') { $info.manifest = $Matches[1].Trim() }
  return $info
}

function Cmd-Daemon {
  $sub = 'status'
  if (@($script:Pos).Count -gt 0) { $sub = ([string]$script:Pos[0]).ToLowerInvariant() }
  $st = Get-DaemonStatus
  if ($sub -eq 'status') {
    Write-Output ('daemon: running=' + $st.running + ' socket=' + $st.socket + ' pid=' + $st.pid + ' mode=' + $st.mode + ' manifest=' + $st.manifest)
    exit 0
  }
  if ($sub -eq 'start') {
    if ($st.running) { Write-Output ('daemon already running (socket=' + $st.socket + ' pid=' + $st.pid + ' mode=' + $st.mode + ')'); exit 0 }
    $drv = Get-DriverPath
    $argv = @('serve')
    if (Has-Opt 'unrestricted') { $argv += '--permission-mode'; $argv += 'unrestricted' }
    if (Has-Opt 'socket') { $argv += '--socket'; $argv += (Get-OptStr 'socket' '') }
    Start-Process -FilePath $drv -ArgumentList $argv -WindowStyle Hidden | Out-Null
    $deadline = (Get-Date).AddSeconds(15)
    $up = $false
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Milliseconds 400
      $st = Get-DaemonStatus
      if ($st.running) { $up = $true; break }
    }
    if (-not $up) { Fail 'DAEMON_START_FAILED' 'cua-driver serve did not come up within 15s' ('run manually: "' + $drv + '" serve') }
    Write-Audit ([ordered]@{ ts = (Get-Date).ToString('o'); cmd = 'daemon'; action = 'start'; socket = $st.socket; pid = $st.pid; mode = $st.mode })
    Write-Output ('daemon started socket=' + $st.socket + ' pid=' + $st.pid + ' mode=' + $st.mode)
    exit 0
  }
  if ($sub -eq 'stop') {
    if (-not (Has-Opt 'consent')) { Fail 'CONSENT_REQUIRED' 'stopping the driver daemon also stops any other hermes/dsh desktop session using it' 'ask the user, then re-run: daemon stop -consent "<approval>"' }
    if (-not $st.running) { Write-Output 'daemon is not running'; exit 0 }
    Invoke-DriverCli @('stop') | Out-Null
    Start-Sleep -Milliseconds 500
    $st = Get-DaemonStatus
    if ($st.running) { Fail 'DAEMON_STOP_FAILED' 'daemon still reports running after cua-driver stop' '' }
    Write-Audit ([ordered]@{ ts = (Get-Date).ToString('o'); cmd = 'daemon'; action = 'stop'; result = 'ok' })
    Write-Output 'daemon stopped'
    exit 0
  }
  Fail 'BAD_SUBCOMMAND' ('unknown daemon subcommand "' + $sub + '"') 'use: daemon status | daemon start | daemon stop -consent "<approval>"'
}
function Cmd-Status {
  $drv = Get-DriverPath
  $ver = 'unknown'
  try {
    $v = Invoke-DriverCli @('--version')
    if ($v.text) { $ver = ($v.text -split "`n")[0].Trim() }
  } catch { }
  $daemon = Get-DaemonStatus
  $st = Load-State
  $fg = New-Guard
  $fullscreen = Test-ForegroundFullscreen $fg
  Write-Output ('driver: ' + $ver + ' (' + $drv + ')')
  Write-Output ('daemon: running=' + $daemon.running + ' socket=' + $daemon.socket + ' pid=' + $daemon.pid + ' mode=' + $daemon.mode + ' manifest=' + $daemon.manifest)
  Write-Output ('session: ' + ($(if ($st.session) { $st.session } else { '(not started)' })))
  $claims = @($st.claims)
  if ($claims.Count -eq 0) {
    Write-Output 'claims: (none)'
  } else {
    foreach ($c in $claims) {
      $min = ''
      try { if ([DshDeskWin32]::IsIconic([IntPtr][int64]$c.window_id)) { $min = ' MIN' } } catch { }
      Write-Output ('claim: ref=' + $c.ref + ' pid=' + $c.pid + ' win=0x' + ('{0:x}' -f [int64]$c.window_id) + ' app=' + $c.app + $min + ' "' + $c.title + '"')
    }
  }
  Write-Output ('foreground: hwnd=0x' + ('{0:x}' -f [int64]$fg.fg_hwnd) + ' pid=' + $fg.fg_pid + ' app=' + $fg.fg_name + ' fullscreen=' + $fullscreen + ' title="' + $fg.fg_title + '"')
  Write-Output ('cursor: ' + $fg.cur_x + ',' + $fg.cur_y)
  Write-Output ('state: ' + $script:StateDir)
  exit 0
}

function Cmd-Doctor {
  $problems = 0
  $psv = $PSVersionTable.PSVersion.ToString()
  $lang = ''
  try { $lang = [string]$ExecutionContext.SessionState.LanguageMode } catch { }
  $sid = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
  $interactive = [Environment]::UserInteractive
  if ($sid -eq 0) {
    Write-Output ('FAIL session 0 (services session): desktop automation is impossible here; interactive user session required')
    $problems++
  } else {
    Write-Output ('PASS powershell ' + $psv + ' language=' + $lang + ' session=' + $sid + ' interactive=' + $interactive)
  }
  if ($lang -eq 'ConstrainedLanguage') {
    Write-Output 'FAIL ConstrainedLanguage mode: Add-Type/P-Invoke guards and driver calls need FullLanguage'
    $problems++
  }
  try {
    $drv = Get-DriverPath
    $v = Invoke-DriverCli @('--version')
    Write-Output ('PASS driver ' + ([string]$v.text).Trim() + ' at ' + $drv)
  } catch {
    Write-Output ('FAIL driver: ' + $_.Exception.Message)
    $problems++
  }
  $daemon = Get-DaemonStatus
  if ($daemon.running) {
    Write-Output ('PASS daemon running socket=' + $daemon.socket + ' pid=' + $daemon.pid + ' mode=' + $daemon.mode)
    if ($daemon.mode -match 'unrestricted') {
      Write-Output ('WARN daemon permission mode is unrestricted; prefer bounded + capability manifest for an isolated agent')
    }
  } else {
    Write-Output ('FAIL daemon not running (' + $daemon.raw + ')')
    $problems++
  }
  try {
    $perm = Invoke-DriverTool 'check_permissions' ([ordered]@{})
    $uia = [bool]$perm.uia
    $pm = [bool]$perm.post_message
    $elev = [bool]$perm.elevated
    if ($uia -and $pm) { Write-Output ('PASS permissions uia=' + $uia + ' post_message=' + $pm + ' elevated=' + $elev + ' integrity=' + [string]$perm.integrity_level) }
    else { Write-Output ('FAIL permissions uia=' + $uia + ' post_message=' + $pm); $problems++ }
  } catch {
    Write-Output ('FAIL check_permissions: ' + $_.Exception.Message)
    $problems++
  }
  try {
    $size = Invoke-DriverTool 'get_screen_size' ([ordered]@{})
    Write-Output ('PASS capture screen=' + $size.width + 'x' + $size.height + ' scale=' + $size.scale_factor)
  } catch {
    Write-Output ('FAIL get_screen_size: ' + $_.Exception.Message)
    $problems++
  }
  try {
    Write-Dir $script:StateDir
    $probe = Join-Path $script:StateDir '.write-probe'
    [System.IO.File]::WriteAllText($probe, 'ok', (New-Object System.Text.UTF8Encoding($false)))
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    Write-Output ('PASS state dir writable: ' + $script:StateDir)
  } catch {
    Write-Output ('FAIL state dir: ' + $_.Exception.Message)
    $problems++
  }
  if ($problems -gt 0) {
    Write-Output ('RESULT: ' + $problems + ' problem(s) - desktop control is NOT ready')
    exit 1
  }
  Write-Output 'RESULT: ready'
  exit 0
}

function Cmd-List {
  $fg = New-Guard
  $st = Load-State
  $claims = @($st.claims)
  $wins = Get-DriverWindows
  $appFilter = (Get-OptStr 'app' '').ToLowerInvariant()
  $pidFilter = -1
  if (Has-Opt 'pid') { $pidFilter = Get-OptInt 'pid' -Default -1 }
  $shown = 0
  foreach ($w in $wins) {
    if ($pidFilter -gt 0 -and [int]$w.pid -ne $pidFilter) { continue }
    $app = ''
    try { $app = (Get-Process -Id ([int]$w.pid) -ErrorAction Stop).ProcessName } catch { }
    $title = [string]$w.title
    if ($appFilter -and -not (($app.ToLowerInvariant().Contains($appFilter)) -or ($title.ToLowerInvariant().Contains($appFilter)))) { continue }
    $ref = @($claims | Where-Object { [int64]$_.window_id -eq [int64]$w.window_id } | ForEach-Object { [string]$_.ref })
    $refText = ''
    if ($ref.Count -gt 0) { $refText = [string]$ref[0] }
    Write-Output (Format-WindowLine -Window $w -Fg $fg -ClaimRef $refText)
    $shown++
  }
  Write-Output ('-- ' + $shown + ' window(s); claims=' + $claims.Count + '; use: claim -app <name> | -pid N | -window N')
  exit 0
}

function Add-Claim {
  param([int]$ProcId, [int64]$WindowId, [string]$App, [string]$Title, [string]$Kind, $Bounds, [bool]$OnScreen)
  $st = Load-State
  $claims = @($st.claims)
  $existing = @($claims | Where-Object { [int64]$_.window_id -eq $WindowId })
  if ($existing.Count -gt 0) { return @{ ref = [string]$existing[0].ref; existing = $true } }
  $ref = 't' + ([int]$st.next_ref)
  $claim = [ordered]@{
    ref        = $ref
    pid        = $ProcId
    window_id  = $WindowId
    app        = $App
    title      = $Title
    kind       = $Kind
    claimed_at = (Get-Date).ToString('o')
    session    = $script:Session
    bounds     = $Bounds
    on_screen  = $OnScreen
  }
  $st.claims = @($st.claims) + @($claim)
  $st.next_ref = [int]$st.next_ref + 1
  Save-State $st
  Write-Audit ([ordered]@{ ts = (Get-Date).ToString('o'); cmd = $script:CurrentCmd; result = 'ok'; action = 'claim'; ref = $ref; pid = $ProcId; win = ('0x{0:x}' -f $WindowId); app = $App; title = $Title })
  return @{ ref = $ref; existing = $false; claim = $claim }
}

function Cmd-Claim {
  Ensure-Session | Out-Null
  $st = Load-State
  $claims = @($st.claims)
  $fg = New-Guard
  $wins = Get-DriverWindows
  $ancestors = Get-AncestorPids
  $wantPid = -1
  $wantWin = $null
  if (Has-Opt 'pid') { $wantPid = Get-OptInt 'pid' -Default -1 }
  if (Has-Opt 'window') {
    $rawWin = (Get-OptStr 'window' '').Trim()
    try {
      if ($rawWin -match '^0[xX]') { $wantWin = [int64][Convert]::ToInt64($rawWin.Substring(2), 16) }
      elseif ($rawWin) { $wantWin = [int64]$rawWin }
    } catch { Fail 'BAD_WINDOW' ('could not parse -window "' + $rawWin + '"') 'pass the numeric window_id from list (decimal or 0xHEX)' }
  }
  $appFilter = (Get-OptStr 'app' '').ToLowerInvariant()
  $titleFilter = (Get-OptStr 'title' '').ToLowerInvariant()

  $cands = @()
  foreach ($w in $wins) {
    if ($wantPid -gt 0 -and [int]$w.pid -ne $wantPid) { continue }
    if ($null -ne $wantWin -and [int64]$w.window_id -ne $wantWin) { continue }
    $app = ''
    try { $app = (Get-Process -Id ([int]$w.pid) -ErrorAction Stop).ProcessName } catch { }
    $title = [string]$w.title
    if ($appFilter -and -not (($app.ToLowerInvariant().Contains($appFilter)) -or ($title.ToLowerInvariant().Contains($appFilter)))) { continue }
    if ($titleFilter -and -not $title.ToLowerInvariant().Contains($titleFilter)) { continue }
    $cands += [pscustomobject]@{ w = $w; app = $app; title = $title }
  }
  if ($cands.Count -eq 0) {
    Fail 'TARGET_NOT_FOUND' 'no window matched the claim filter' ('run: list' + $(if ($appFilter) { ' (or correct -app ' + $appFilter + ')' } else { '' }))
  }
  $safe = @()
  foreach ($c in $cands) {
    $app = [string]$c.app
    $title = [string]$c.title
    $procId = [int]$c.w.pid
    $blocked = ''
    if ($ancestors -contains $procId) { $blocked = 'this process is an ancestor of the agent (the DSH app/pwsh host) - refusing to drive the harness UI' }
    elseif ($app -match '^(cua-driver|cua-driver-uia)$') { $blocked = 'this is the cua-driver daemon process' }
    elseif ($title -match '^Cua\.AgentCursorOverlay') { $blocked = 'this is the cua-driver agent-cursor overlay' }
    if ($blocked) {
      Write-Audit ([ordered]@{ ts = (Get-Date).ToString('o'); cmd = 'claim'; result = 'refused'; code = 'BLOCKED_TARGET'; pid = $procId; title = $title })
      if ($cands.Count -eq 1) { Fail 'BLOCKED_TARGET' ('cannot claim pid ' + $procId + ' "' + $title + '": ' + $blocked) 'claim the application window the user asked you to operate instead' }
      continue
    }
    $safe += $c
  }
  if ($safe.Count -eq 0) { Fail 'TARGET_NOT_FOUND' 'all matching windows are blocked targets' 'claim a normal application window' }
  if ($safe.Count -gt 1 -and $wantPid -le 0 -and $null -eq $wantWin) {
    $lines = @($safe | ForEach-Object { Format-WindowLine -Window $_.w -Fg $fg })
    Fail 'AMBIGUOUS_TARGET' ('claim matched ' + $safe.Count + ' windows: ' + ($lines -join ' | ')) 'narrow with -pid N or -window 0xN (or -title substring)'
  }
  $sel = $safe[0]
  $ac = Add-Claim -ProcId ([int]$sel.w.pid) -WindowId ([int64]$sel.w.window_id) -App ([string]$sel.app) -Title ([string]$sel.title) -Kind (Get-OptStr 'kind' 'user') -Bounds $sel.w.bounds -OnScreen ([bool]$sel.w.is_on_screen)
  if ($ac.existing) {
    $st2 = Load-State
    $c = @($st2.claims | Where-Object { [string]$_.ref -eq [string]$ac.ref })[0]
    Write-Output ('already claimed: ref=' + $ac.ref + ' pid=' + $c.pid + ' win=0x' + ('{0:x}' -f [int64]$c.window_id) + ' "' + $c.title + '"')
    exit 0
  }
  $claim = $ac.claim
  $min = ''
  try { if ([DshDeskWin32]::IsIconic([IntPtr][int64]$claim.window_id)) { $min = ' (MINIMIZED: clicks are refused; restore first)' } } catch { }
  Write-Output ('claimed ref=' + $claim.ref + ' pid=' + $claim.pid + ' win=0x' + ('{0:x}' -f [int64]$claim.window_id) + ' app=' + $claim.app + $min)
  Write-Output ('next: capture -ref ' + $claim.ref + '   (then click/type/set/key by -index)')
  exit 0
}

function Cmd-Release {
  $st = Load-State
  $claims = @($st.claims)
  if (Has-Opt 'all') {
    $st.claims = @()
    Save-State $st
    Write-Audit ([ordered]@{ ts = (Get-Date).ToString('o'); cmd = 'release'; result = 'ok'; ref = 'all' })
    Write-Output 'released all claims'
    exit 0
  }
  $ref = Get-OptStr 'ref' ''
  if ($ref) {
    $keep = @($claims | Where-Object { [string]$_.ref -ne $ref })
    if ($keep.Count -eq $claims.Count) { Fail 'UNKNOWN_REF' ('no claim named "' + $ref + '"') 'run: list' }
    $st.claims = $keep
  } else {
    $st.claims = @()
  }
  Save-State $st
  Write-Audit ([ordered]@{ ts = (Get-Date).ToString('o'); cmd = 'release'; result = 'ok'; ref = $(if ($ref) { $ref } else { 'all' }) })
  Write-Output ('released ' + $(if ($ref) { $ref } else { 'all claims' }))
  exit 0
}

function Invoke-Capture {
  param($Claim, [bool]$WantScreenshot, [string]$OutPath)
  Ensure-Session | Out-Null
  $max = Get-OptInt 'max' 120
  $depth = Get-OptInt 'depth' 12
  if ($max -lt 1) { $max = 120 }
  if ($depth -lt 1) { $depth = 12 }
  $req = [ordered]@{
    pid                = [int]$Claim.pid
    window_id          = [int64]$Claim.window_id
    include_screenshot = $WantScreenshot
    max_elements       = $max
    max_depth          = $depth
    session            = $script:Session
  }
  $query = Get-OptStr 'query' ''
  if ($query) { $req['query'] = $query }
  if ($WantScreenshot) {
    if (-not $OutPath) {
      Write-Dir $script:ShotDir
      $OutPath = Join-Path $script:ShotDir ([string]$Claim.ref + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.png')
    }
    $req['screenshot_out_file'] = $OutPath
  }
  $data = Invoke-DriverTool 'get_window_state' $req 30000
  if ($data.PSObject.Properties.Name -contains 'status' -and ([string]$data.status) -eq 'refused') {
    $refusal = Get-Refusal $data
    Fail (Get-RefusalCode $refusal.code) $refusal.message (Get-RefusalHint $refusal.code)
  }
  $shotPath = ''
  if ($WantScreenshot -and $data.PSObject.Properties.Name -contains 'screenshot_file_path') { $shotPath = ([string]$data.screenshot_file_path) -replace '^\\\\\?\\', '' }
  $elements = @()
  if ($data.PSObject.Properties.Name -contains 'elements') { $elements = @($data.elements) }
  $snapId = ''
  if ($data.PSObject.Properties.Name -contains 'snapshot_id') { $snapId = [string]$data.snapshot_id }
  $stored = [ordered]@{
    snapshot_id = $snapId
    ts          = (Get-Date).ToString('o')
    ref         = [string]$Claim.ref
    pid         = [int]$Claim.pid
    window_id   = [int64]$Claim.window_id
    elements    = @()
  }
  $lines = @()
  foreach ($e in $elements) {
    $i = [int]$e.element_index
    $role = [string]$e.role
    $label = [string]$e.label
    $val = ''
    if ($e.PSObject.Properties.Name -contains 'value' -and $null -ne $e.value) { $val = [string]$e.value }
    $enabled = $true
    if ($e.PSObject.Properties.Name -contains 'enabled') { $enabled = [bool]$e.enabled }
    $token = ''
    if ($e.PSObject.Properties.Name -contains 'element_token') { $token = [string]$e.element_token }
    $stored.elements += @([ordered]@{ i = $i; token = $token; role = $role; label = $label })
    if ($label.Length -gt 90) { $label = $label.Substring(0, 90) + '...' }
    $line = '' + $i + ' ' + $role + ' "' + $label + '"'
    if ($val) {
      $vshow = $val
      if ($vshow.Length -gt 100) { $vshow = $vshow.Substring(0, 100) + '...' }
      $line += ' = "' + $vshow + '"'
    }
    if (-not $enabled) { $line += ' (disabled)' }
    if (Has-Opt 'frames' -and $e.PSObject.Properties.Name -contains 'frame' -and $null -ne $e.frame) {
      $line += (' @' + $e.frame.x + ',' + $e.frame.y)
    }
    $lines += $line
  }
  Save-Snapshot ([string]$Claim.ref) $stored
  $total = 0
  if ($data.PSObject.Properties.Name -contains 'total_element_count') { $total = [int]$data.total_element_count }
  $complete = $true
  if ($data.PSObject.Properties.Name -contains 'elements_complete') { $complete = [bool]$data.elements_complete }
  $win = ('0x{0:x}' -f [int64]$Claim.window_id)
  $min = ''
  try { if ([DshDeskWin32]::IsIconic([IntPtr][int64]$Claim.window_id)) { $min = ' (minimized: clicks are refused; use restore)' } } catch { }
  $outLines = @()
  $outLines += ('ref=' + $Claim.ref + ' pid=' + $Claim.pid + ' win=' + $win + ' snap=' + $snapId + ' elements=' + $elements.Count + '/' + $total + $min)
  foreach ($l in $lines) { $outLines += ('  ' + $l) }
  if (($elements.Count -lt $total) -and (-not $query)) { $outLines += '  (tree filtered: only matching elements are shown)' } elseif ((-not $complete) -and ($elements.Count -ge $max) -and (-not $query)) { $outLines += '  (tree may be truncated: raise -max/-depth or use -query to narrow)' }
  if ($shotPath) {
    $outLines += ('  shot=' + $shotPath + ' ' + $data.screenshot_width + 'x' + $data.screenshot_height + ' ' + $data.screenshot_mime_type)
  } elseif ($WantScreenshot) {
    $outLines += '  (screenshot requested but the driver returned no image: minimized/occluded windows may not capture; run restore -ref <ref> then shot again)'
  }
  Write-Audit ([ordered]@{ ts = (Get-Date).ToString('o'); cmd = $script:CurrentCmd; result = 'ok'; ref = [string]$Claim.ref; pid = [int]$Claim.pid; win = $win; action = 'get_window_state'; snapshot = $snapId; elements = $elements.Count; screenshot = $shotPath })
  return @{ data = $data; snapshot = $stored; shot = $shotPath; lines = $outLines }
}

function Cmd-Capture {
  $claim = Get-Claim (Get-OptStr 'ref' '')
  Ensure-Alive $claim
  $wantShot = [bool](Has-Opt 'screenshot')
  if (Has-Opt 'out') { $wantShot = $true }
  $out = Get-OptStr 'path' ''
  $r = Invoke-Capture -Claim $claim -WantScreenshot $wantShot -OutPath $out
  foreach ($l in @($r.lines)) { Write-Output $l }
  exit 0
}

function Cmd-Shot {
  $claim = Get-Claim (Get-OptStr 'ref' '')
  Ensure-Alive $claim
  $out = Get-OptStr 'path' ''
  $r = Invoke-Capture -Claim $claim -WantScreenshot $true -OutPath $out
  foreach ($l in @($r.lines)) { Write-Output $l }
  exit 0
}

function Cmd-Click {
  $claim = Get-Claim (Get-OptStr 'ref' '')
  Ensure-Alive $claim
  $snap = Load-Snapshot ([string]$claim.ref)
  $px = $false
  $x = 0.0
  $y = 0.0
  if ((Has-Opt 'x') -and (Has-Opt 'y')) {
    $px = $true
    $x = [double](Get-OptStr 'x' '0')
    $y = [double](Get-OptStr 'y' '0')
    if ($null -eq $snap) { Write-Audit ([ordered]@{ ts = (Get-Date).ToString('o'); cmd = 'click'; result = 'warn'; code = 'PX_WITHOUT_SNAPSHOT' }) }
  }
  $useForeground = [bool](Has-Opt 'foreground')
  if ($useForeground) {
    if (-not (Has-Opt 'consent')) { Fail 'CONSENT_REQUIRED' 'foreground delivery requires explicit user approval' 'ask the user, then re-run with -foreground -consent "<approval>"' }
  }
  $token = $null
  if (-not $px) {
    $token = Resolve-Token -Claim $claim -Snapshot $snap
    if (-not $token) { Fail 'NO_TARGET' 'click needs -index N, -token T, or -x X -y Y' 'run capture first, then click -index N' }
  }
  $tool = 'click'
  if (Has-Opt 'double') { $tool = 'double_click' }
  elseif (Has-Opt 'right') { $tool = 'right_click' }
  if (Has-Opt 'restore') {
    Cmd-Restore -Claim $claim -Silent
    $claim = Get-Claim ([string]$claim.ref)
    $snap = Load-Snapshot ([string]$claim.ref)
    if (-not $px) {
      $token = Resolve-Token -Claim $claim -Snapshot $snap
    }
  }
  $payload = [ordered]@{
    pid           = [int]$claim.pid
    window_id     = [int64]$claim.window_id
    delivery_mode = $(if ($useForeground) { 'foreground' } else { 'background' })
    session       = $script:Session
  }
  if ($px) { $payload['x'] = $x; $payload['y'] = $y }
  else { $payload['element_token'] = [string]$token }
  if (Has-Opt 'count') { $payload['count'] = (Get-OptInt 'count' 1) }
  $res = Invoke-Action -Tool $tool -Payload $payload -Claim $claim
  Ok $res
}

function Cmd-Type {
  $claim = Get-Claim (Get-OptStr 'ref' '')
  Ensure-Alive $claim
  $text = Get-OptStr 'text' ''
  if (-not (Has-Opt 'text')) { Fail 'NO_TEXT' 'type needs -text "..."' 'pass the exact text to insert' }
  Assert-SensitiveSurface -Claim $claim -What 'typing'
  $snap = Load-Snapshot ([string]$claim.ref)
  $px = $false
  $x = 0.0
  $y = 0.0
  if ((Has-Opt 'x') -and (Has-Opt 'y')) {
    $px = $true
    $x = [double](Get-OptStr 'x' '0')
    $y = [double](Get-OptStr 'y' '0')
  }
  $useForeground = [bool](Has-Opt 'foreground')
  if ($useForeground -and -not (Has-Opt 'consent')) { Fail 'CONSENT_REQUIRED' 'foreground delivery requires explicit user approval' 'ask the user, then re-run with -foreground -consent "<approval>"' }
  $token = $null
  if (-not $px) {
    $token = Resolve-Token -Claim $claim -Snapshot $snap
    if (-not $token) { Fail 'NO_TARGET' 'type needs -index N, -token T, or -x X -y Y' 'run capture first' }
  }
  $payload = [ordered]@{
    pid           = [int]$claim.pid
    window_id     = [int64]$claim.window_id
    text          = $text
    delivery_mode = $(if ($useForeground) { 'foreground' } else { 'background' })
    session       = $script:Session
  }
  if ($px) { $payload['x'] = $x; $payload['y'] = $y }
  else { $payload['element_token'] = [string]$token }
  $res = Invoke-Action -Tool 'type_text' -Payload $payload -Claim $claim
  $res['text_len'] = $text.Length
  Ok $res
}

function Cmd-Set {
  $claim = Get-Claim (Get-OptStr 'ref' '')
  Ensure-Alive $claim
  if (-not (Has-Opt 'value')) { Fail 'NO_VALUE' 'set needs -value "..."' 'pass the new value' }
  $value = Get-OptStr 'value' ''
  Assert-SensitiveSurface -Claim $claim -What 'setting a value'
  $snap = Load-Snapshot ([string]$claim.ref)
  if ($null -eq $snap) { Fail 'NO_SNAPSHOT' ('no capture recorded for ' + $claim.ref) ('run: capture -ref ' + $claim.ref) }
  $idx = -1
  $wantToken = ''
  if (Has-Opt 'index') { $idx = Get-OptInt 'index' -1 }
  elseif (Has-Opt 'token') { $wantToken = Get-OptStr 'token' '' }
  if ($idx -lt 0 -and $wantToken) {
    foreach ($e in @($snap.elements)) { if ([string]$e.token -eq $wantToken) { $idx = [int]$e.i; break } }
  }
  if ($idx -lt 0) { Fail 'NO_ELEMENT' 'set needs -index N or a current -token T' ('run: capture -ref ' + $claim.ref + ' and use a current index') }
  $payload = [ordered]@{
    pid           = [int]$claim.pid
    window_id     = [int64]$claim.window_id
    value         = $value
    element_index = [int]$idx
    snapshot_id   = [string]$snap.snapshot_id
    session       = $script:Session
  }
  if ($wantToken) { $payload['element_token'] = $wantToken }
  if ($env:DSH_DESK_DEBUG) { [System.IO.File]::WriteAllText("$env:TEMP\dsh-desk-test\set-payload.json", (($payload | ConvertTo-Json -Compress -Depth 15))) }
  $res = Invoke-Action -Tool 'set_value' -Payload $payload -Claim $claim
  if (Has-Opt 'verify') {
    Start-Sleep -Milliseconds 150
    $after = Invoke-Capture -Claim $claim -WantScreenshot $false -OutPath ''
    $idx = Get-OptInt 'index' -1
    $actual = ''
    foreach ($e in @($after.data.elements)) {
      if ([int]$e.element_index -eq $idx) { if ($e.PSObject.Properties.Name -contains 'value' -and $null -ne $e.value) { $actual = [string]$e.value }; break }
    }
    $res['verify'] = $(if ($actual -eq $value) { 'ok' } else { 'value-mismatch' })
    $res['actual'] = $actual
  }
  Ok $res
}

function Cmd-Key {
  $claim = Get-Claim (Get-OptStr 'ref' '')
  Ensure-Alive $claim
  if (-not (Has-Opt 'key')) { Fail 'NO_KEY' 'key needs -key NAME (return, tab, escape, up/down/..., f1-f12, a-z, 0-9)' '' }
  $key = Get-OptStr 'key' ''
  $snap = Load-Snapshot ([string]$claim.ref)
  $token = $null
  if (Has-Opt 'index' -or Has-Opt 'token') { $token = Resolve-Token -Claim $claim -Snapshot $snap }
  $mods = @()
  if (Has-Opt 'mods') {
    $mods = @((Get-OptStr 'mods' '') -split ',' | Where-Object { $_ -ne '' } | ForEach-Object { $_.Trim().ToLowerInvariant() })
  }
  if ($mods.Count -gt 0) {
    if (-not (Has-Opt 'consent')) {
      Fail 'HOTKEY_NEEDS_CONSENT' ('modifier combo "' + ($mods -join '+') + '+' + $key + '" may use SendInput + a brief SetForegroundWindow on legacy Win32 targets, which can flash the user''s screen and steal focus') 'prefer element/invoke routes; if the combo is really needed, ask the user and re-run with -consent "<approval>"'
    }
    $payload = [ordered]@{
      pid           = [int]$claim.pid
      window_id     = [int64]$claim.window_id
      keys          = @(@($mods) + @($key))
      delivery_mode = $(if (Has-Opt 'foreground') { 'foreground' } else { 'background' })
      session       = $script:Session
    }
    if ($token) { $payload['element_token'] = [string]$token }
    $res = Invoke-Action -Tool 'hotkey' -Payload $payload -Claim $claim
    $res['warning'] = 'modifier combos can briefly raise the target on legacy Win32 apps; this was explicitly approved via -consent'
    Ok $res
  }
  $payload = [ordered]@{
    pid           = [int]$claim.pid
    window_id     = [int64]$claim.window_id
    key           = $key
    delivery_mode = $(if (Has-Opt 'foreground') { 'foreground' } else { 'background' })
    session       = $script:Session
  }
  if ($token) { $payload['element_token'] = [string]$token }
  $res = Invoke-Action -Tool 'press_key' -Payload $payload -Claim $claim
  Ok $res
}

function Cmd-Scroll {
  $claim = Get-Claim (Get-OptStr 'ref' '')
  Ensure-Alive $claim
  if (-not (Has-Opt 'direction')) { Fail 'NO_DIRECTION' 'scroll needs -direction up|down|left|right' '' }
  $direction = Get-OptStr 'direction' 'down'
  $by = Get-OptStr 'by' 'line'
  $amount = Get-OptInt 'amount' 3
  $snap = Load-Snapshot ([string]$claim.ref)
  $payload = [ordered]@{
    pid           = [int]$claim.pid
    window_id     = [int64]$claim.window_id
    direction     = $direction
    by            = $by
    amount        = $amount
    delivery_mode = 'background'
    session       = $script:Session
  }
  if (Has-Opt 'index' -or Has-Opt 'token') {
    $token = Resolve-Token -Claim $claim -Snapshot $snap
    if ($token) { $payload['element_token'] = [string]$token }
  }
  $res = Invoke-Action -Tool 'scroll' -Payload $payload -Claim $claim
  Ok $res
}

function Set-ClaimField {
  param([string]$Ref, [string]$Name, $Value)
  $st = Load-State
  $claims = @($st.claims)
  foreach ($c in $claims) {
    if ([string]$c.ref -eq $Ref) {
      if ($c.PSObject.Properties.Name -contains $Name) { $c.$Name = $Value }
      else { $c | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
    }
  }
  $st.claims = $claims
  Save-State $st
}

function Cmd-Park {
  # Move the claimed window completely off-screen without activating it, so the agent can
  # drive it (UIA/capture still work) while the user never sees it. The original rect is
  # remembered in the claim so unpark can put it back.
  $claim = Get-Claim (Get-OptStr 'ref' '')
  Ensure-Alive $claim
  $h = [IntPtr][int64]$claim.window_id
  $parkX = Get-OptInt 'x' -3000
  $parkY = Get-OptInt 'y' 120
  $before = New-Guard
  $orig = $null
  if ($claim.PSObject.Properties.Name -contains 'park_rect' -and $null -ne $claim.park_rect) { $orig = $claim.park_rect }
  if ($null -eq $orig) {
    $rect = Get-WindowRectInfo -WindowId ([int64]$claim.window_id)
    if ($null -ne $rect) {
      Set-ClaimField -Ref ([string]$claim.ref) -Name 'park_rect' -Value ([ordered]@{ x = $rect.x; y = $rect.y; w = $rect.w; h = $rect.h })
    }
  }
  $wasIconic = $false
  try { $wasIconic = [bool][DshDeskWin32]::IsIconic($h) } catch { }
  if ($wasIconic) {
    try { [void][DshDeskWin32]::ShowWindow($h, 4) } catch { }   # un-minimize first; may briefly show
    Start-Sleep -Milliseconds 300
  }
  $ok = $false
  try { $ok = [bool][DshDeskWin32]::SetWindowPos($h, [IntPtr]::Zero, $parkX, $parkY, 0, 0, 0x15) } catch { }   # SWP_NOACTIVATE|NOZORDER|NOSIZE
  Start-Sleep -Milliseconds 300
  $after = New-Guard
  $cmp = Compare-Guard -Before $before -After $after -Claim $claim
  $rectNow = Get-WindowRectInfo -WindowId ([int64]$claim.window_id)
  $iconicNow = $false
  try { $iconicNow = [bool][DshDeskWin32]::IsIconic($h) } catch { }
  Write-Audit ([ordered]@{
      ts = (Get-Date).ToString('o'); cmd = 'park'; result = $(if ($ok) { 'ok' } else { 'warn' })
      ref = [string]$claim.ref; pid = [int]$claim.pid; win = ('0x{0:x}' -f [int64]$claim.window_id)
      was_minimized = $wasIconic; iconic_after = $iconicNow
      parked_x = $parkX; parked_y = $parkY
      fg_before = $before.fg_hwnd; fg_after = $after.fg_hwnd; fg_changed = $cmp.fg_changed
      cursor_moved = $cmp.cursor_moved
    })
  if ($cmp.focus_steal) {
    $restored = $false
    try { $restored = [bool][DshDeskWin32]::SetForegroundWindow([IntPtr]$before.fg_hwnd) } catch { }
    Fail 'VIOLATION_FOCUS_STEAL' ('parking ' + $claim.ref + ' raised it to the foreground') 'stop and report to the user; foreground was restored best-effort' @{ ref = [string]$claim.ref; fg_restored = $restored }
  }
  $out = [ordered]@{
    ok                  = $ok
    ref                 = [string]$claim.ref
    parked              = $ok
    was_minimized       = $wasIconic
    iconic_after        = $iconicNow
    rect                = $(if ($null -ne $rectNow) { '' + $rectNow.x + ',' + $rectNow.y + ',' + $rectNow.w + ',' + $rectNow.h } else { '' })
    saved_original_rect = $(if ($null -ne $orig) { 'yes' } else { 'saved-now' })
    fg_changed          = $cmp.fg_changed
    cursor_moved         = $cmp.cursor_moved
  }
  if ($wasIconic) { $out['warning'] = 'window was minimized; it was un-minimized then parked - run capture before acting' }
  Ok $out
}

function Cmd-Unpark {
  $claim = Get-Claim (Get-OptStr 'ref' '')
  Ensure-Alive $claim
  if (-not ($claim.PSObject.Properties.Name -contains 'park_rect') -or ($null -eq $claim.park_rect)) {
    Write-Output ('claim ' + $claim.ref + ' is not parked; nothing to do')
    exit 0
  }
  $pr = $claim.park_rect
  $h = [IntPtr][int64]$claim.window_id
  $before = New-Guard
  $ok = $false
  try { $ok = [bool][DshDeskWin32]::SetWindowPos($h, [IntPtr]::Zero, [int]$pr.x, [int]$pr.y, [int]$pr.w, [int]$pr.h, 0x14) } catch { }   # SWP_NOACTIVATE|NOZORDER (move+size)
  Start-Sleep -Milliseconds 300
  $after = New-Guard
  $cmp = Compare-Guard -Before $before -After $after -Claim $claim
  Write-Audit ([ordered]@{ ts = (Get-Date).ToString('o'); cmd = 'unpark'; result = $(if ($ok) { 'ok' } else { 'warn' }); ref = [string]$claim.ref; pid = [int]$claim.pid; win = ('0x{0:x}' -f [int64]$claim.window_id); fg_before = $before.fg_hwnd; fg_after = $after.fg_hwnd; fg_changed = $cmp.fg_changed })
  $out = [ordered]@{ ok = $ok; ref = [string]$claim.ref; unparked = $ok; fg_changed = $cmp.fg_changed; cursor_moved = $cmp.cursor_moved }
  Ok $out
}

function Cmd-Restore {
  param($Claim, [switch]$Silent)
  if (-not $Claim) { $Claim = Get-Claim (Get-OptStr 'ref' '') }
  Ensure-Alive $Claim
  $h = [IntPtr][int64]$Claim.window_id
  $before = New-Guard
  $isIconic = $false
  try { $isIconic = [bool][DshDeskWin32]::IsIconic($h) } catch { }
  if (-not $isIconic) {
    if (-not $Silent) { Write-Output ('window ' + $Claim.ref + ' is not minimized; nothing to restore') }
    return
  }
  $ok = $false
  try { $ok = [bool][DshDeskWin32]::ShowWindow($h, 4) } catch { }   # SW_SHOWNOACTIVATE: un-minimizes without activating
  Start-Sleep -Milliseconds 350
  $after = New-Guard
  $fgChanged = ([int64]$before.fg_hwnd -ne [int64]$after.fg_hwnd)
  $restoreOk = $false
  if ($fgChanged) {
    try { $restoreOk = [bool][DshDeskWin32]::SetForegroundWindow([IntPtr]$before.fg_hwnd) } catch { }
    Start-Sleep -Milliseconds 200
  }
  $final = New-Guard
  Write-Audit ([ordered]@{
      ts = (Get-Date).ToString('o'); cmd = 'restore'; result = $(if ($fgChanged -and -not $restoreOk) { 'warn' } else { 'ok' })
      ref = [string]$Claim.ref; pid = [int]$Claim.pid; win = ('0x{0:x}' -f [int64]$Claim.window_id)
      showwindow_ok = $ok; fg_changed = $fgChanged; fg_restored = $restoreOk
      fg_before = $before.fg_hwnd; fg_final = $final.fg_hwnd
    })
  if (-not $Silent) {
    $out = [ordered]@{
      ok                  = $true
      ref                 = [string]$Claim.ref
      unminimized         = $ok
      fg_changed          = $fgChanged
      fg_restore_attempted = $fgChanged
      fg_restored         = $restoreOk
    }
    if ($fgChanged -and -not $restoreOk) { $out['warning'] = 'un-minimize may have changed the foreground; verify with status' }
    Write-Output ($out | ConvertTo-Json -Compress -Depth 6)
  }
}

function Start-AppDirect {
  # Launch a GUI app with a sanitized environment. DSH injects ELECTRON_RUN_AS_NODE=1 into the
  # shell environment, and the cua-driver daemon inherits it, so its launch_app turns Electron
  # apps into node processes that exit immediately. This fallback strips those variables for the
  # child only, redirects the child's stdio to files (so it cannot hold the agent's pipe open)
  # and returns the new pid.
  param([string]$Path, [string[]]$ArgParts, [switch]$Minimized)
  $names = @('ELECTRON_RUN_AS_NODE', 'ELECTRON_NO_ATTACH_CONSOLE', 'ELECTRON_ENABLE_LOGGING', 'NODE_OPTIONS')
  $saved = @{}
  foreach ($n in $names) { $saved[$n] = [System.Environment]::GetEnvironmentVariable($n, 'Process') }
  $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
  $ts = Get-Date -Format 'yyyyMMddHHmmss'
  $log = Join-Path $env:TEMP ('dshdesk-launch-' + $base + '-' + $ts + '.out.log')
  $errLog = Join-Path $env:TEMP ('dshdesk-launch-' + $base + '-' + $ts + '.err.log')
  $p = $null
  try {
    foreach ($n in $names) { [System.Environment]::SetEnvironmentVariable($n, $null, 'Process') }
    $sp = @{
      FilePath               = $Path
      WorkingDirectory       = (Split-Path -Parent $Path)
      PassThru               = $true
      RedirectStandardOutput = $log
      RedirectStandardError  = $errLog
    }
    if ($ArgParts -and $ArgParts.Count -gt 0) { $sp['ArgumentList'] = $ArgParts }
    if ($Minimized) { $sp['WindowStyle'] = 'Minimized' }
    $p = Start-Process @sp
  } finally {
    foreach ($n in $names) {
      if ($null -ne $saved[$n]) { [System.Environment]::SetEnvironmentVariable($n, $saved[$n], 'Process') }
    }
  }
  if ($null -eq $p) { Fail 'LAUNCH_FAILED' ('could not start "' + $Path + '"') 'check the path; run list to see if a window appeared anyway' }
  return @{ pid = [int]$p.Id; log = $log; err_log = $errLog; sanitized = $names }
}

function Cmd-Launch {
  Ensure-Session | Out-Null
  $payload = [ordered]@{ session = $script:Session }
  $label = ''
  if (Has-Opt 'app') { $label = (Get-OptStr 'app' ''); $payload['name'] = $label }
  elseif (Has-Opt 'path') { $label = (Get-OptStr 'path' ''); $payload['path'] = $label }
  elseif (Has-Opt 'aumid') { $label = (Get-OptStr 'aumid' ''); $payload['aumid'] = $label }
  else { Fail 'NO_APP' 'launch needs -app NAME, -path C:\...\app.exe, or -aumid ID' 'example: launch -app notepad' }
  if ($label -match '(?i)(cua-driver|dshdesk|regedit|taskmgr|\bmmc\b|wscript|cscript|mshta|cmd\.exe|powershell|pwsh)') {
    Fail 'BLOCKED_LAUNCH' ('refusing to launch "' + $label + '": shells/tools are out of scope for desktop automation') 'use the pwsh tool for commands; launch only real GUI applications'
  }
  $argParts = @()
  if (Has-Opt 'args') {
    $argText = Get-OptStr 'args' ''
    $argParts = @($argText -split ' ' | Where-Object { $_ -ne '' })
    if ($argParts.Count -gt 0) { $payload['additional_arguments'] = $argParts }
  }
  if (Has-Opt 'minimized') { $payload['start_minimized'] = $true }

  # Electron apps cannot be launched through the daemon because it inherited ELECTRON_RUN_AS_NODE=1.
  # Detect the classic Electron payload layout and prefer the sanitized direct launch.
  $useDirect = [bool](Has-Opt 'direct')
  if ((-not $useDirect) -and (Has-Opt 'path') -and $label) {
    $dir = Split-Path -Parent $label
    if ($dir -and (Test-Path -LiteralPath (Join-Path $dir 'resources\app'))) { $useDirect = $true }
  }
  if ($useDirect) {
    if (-not (Has-Opt 'path')) { Fail 'DIRECT_NEEDS_PATH' '-direct requires -path C:\...\app.exe' 'pass the exact executable path' }
    $before = New-Guard
    $t0 = Get-Date
    $dp = Start-AppDirect -Path $label -ArgParts $argParts -Minimized:([bool](Has-Opt 'minimized'))
    $procId = [int]$dp.pid
    $wins = @()
    $alive = $true
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Milliseconds 250
      try { $null = Get-Process -Id $procId -ErrorAction Stop; $alive = $true } catch { $alive = $false }
      $all = Get-DriverWindows
      $wins = @($all | Where-Object { [int]$_.pid -eq $procId })
      if ($wins.Count -gt 0) { break }
      if (-not $alive) { break }
    }
    $ms = [int]((New-TimeSpan -Start $t0 -End (Get-Date)).TotalMilliseconds)
    $after = New-Guard
    $fgChanged = ([int64]$before.fg_hwnd -ne [int64]$after.fg_hwnd)
    $steal = ($fgChanged -and $procId -gt 0 -and [int]$after.fg_pid -eq $procId)
    # Electron shows its main window as soon as it starts: move it off-screen immediately so the
    # user never sees it. The pre-park rect is remembered for unpark.
    $parkedId = [int64]0
    $parkRect = $null
    if (-not (Has-Opt 'no-park')) {
      foreach ($w in $wins) {
        if ([bool]$w.is_on_screen) {
          $parkRect = Get-WindowRectInfo -WindowId ([int64]$w.window_id)
          try {
            if ([bool][DshDeskWin32]::SetWindowPos([IntPtr][int64]$w.window_id, [IntPtr]::Zero, -3000, 120, 0, 0, 0x15)) { $parkedId = [int64]$w.window_id }
          } catch { }
          break
        }
      }
      if ($parkedId -ne 0) { Start-Sleep -Milliseconds 250 }
    }
    Write-Audit ([ordered]@{
        ts = (Get-Date).ToString('o'); cmd = 'launch'; result = 'ok'; action = 'launch_direct'
        pid = $procId; label = $label; windows = $wins.Count; duration_ms = $ms
        alive = $alive; fg_before = $before.fg_hwnd; fg_after = $after.fg_hwnd
        fg_changed = $fgChanged; focus_steal = $steal; parked = $parkedId; log = $dp.log
      })
    if ($steal) {
      $restored = $false
      try { $restored = [bool][DshDeskWin32]::SetForegroundWindow([IntPtr]$before.fg_hwnd) } catch { }
      Fail 'VIOLATION_FOCUS_STEAL' ('launching "' + $label + '" raised its window to the foreground') 'stop and report to the user; foreground restore attempted' @{ pid = $procId; restored = $restored; log = $dp.log }
    }
    $winList = @()
    foreach ($w in $wins) { $winList += [ordered]@{ window_id = [int64]$w.window_id; title = [string]$w.title; is_on_screen = [bool]$w.is_on_screen } }
    $out = [ordered]@{
      ok            = $true
      action        = 'launch_direct'
      label         = $label
      pid           = $procId
      duration_ms   = $ms
      alive         = $alive
      env_sanitized = @($dp.sanitized)
      fg_changed    = $fgChanged
      parked        = ($parkedId -ne 0)
      windows       = $winList
      log           = $dp.log
      err_log       = $dp.err_log
    }
    if (($wins.Count -eq 1) -and (-not (Has-Opt 'no-claim'))) {
      $w0 = $wins[0]
      $appName = ''
      try { $appName = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { }
      $ac = Add-Claim -ProcId $procId -WindowId ([int64]$w0.window_id) -App $appName -Title ([string]$w0.title) -Kind 'launched' -Bounds $w0.bounds -OnScreen ([bool]$w0.is_on_screen)
      Set-ClaimField -Ref ([string]$ac.ref) -Name 'provenance' -Value 'process_sanitized'
      if ($parkedId -ne 0 -and $parkRect) { Set-ClaimField -Ref ([string]$ac.ref) -Name 'park_rect' -Value ([ordered]@{ x = $parkRect.x; y = $parkRect.y; w = $parkRect.w; h = $parkRect.h }) }
      $out['ref'] = [string]$ac.ref
      $out['next'] = 'capture -ref ' + [string]$ac.ref
    } elseif ($wins.Count -gt 1) {
      $out['next'] = 'run list, then claim -pid ' + $procId
    } elseif ($wins.Count -eq 0) {
      $out['next'] = 'no window yet; run list and claim it when it appears'
    }
    Ok $out
  }

  $before = New-Guard
  $t0 = Get-Date
  $res = Invoke-DriverTool 'launch_app' $payload 60000
  $ms = [int]((New-TimeSpan -Start $t0 -End (Get-Date)).TotalMilliseconds)
  $after = New-Guard
  $fgChanged = ([int64]$before.fg_hwnd -ne [int64]$after.fg_hwnd)
  $procId = 0
  if ($res.PSObject.Properties.Name -contains 'pid' -and $null -ne $res.pid) { $procId = [int]$res.pid }
  $steal = ($fgChanged -and $procId -gt 0 -and [int]$after.fg_pid -eq $procId)
  $wins = @()
  if ($res.PSObject.Properties.Name -contains 'windows' -and $null -ne $res.windows) { $wins = @($res.windows) }
  Write-Audit ([ordered]@{
      ts          = (Get-Date).ToString('o')
      cmd         = 'launch'
      result      = 'ok'
      action      = 'launch_app'
      pid         = $procId
      label       = $label
      windows     = $wins.Count
      duration_ms = $ms
      fg_before   = $before.fg_hwnd
      fg_after    = $after.fg_hwnd
      fg_changed  = $fgChanged
      focus_steal = $steal
    })
  if ($steal) {
    $restored = $false
    try { $restored = [bool][DshDeskWin32]::SetForegroundWindow([IntPtr]$before.fg_hwnd) } catch { }
    Fail 'VIOLATION_FOCUS_STEAL' ('launching "' + $label + '" stole the foreground') 'stop and report to the user; foreground restore attempted' @{ pid = $procId; restored = $restored }
  }
  $winList = @()
  foreach ($w in $wins) {
    $winList += [ordered]@{ window_id = [int64]$w.window_id; title = [string]$w.title; is_on_screen = [bool]$w.is_on_screen }
  }
  $out = [ordered]@{
    ok          = $true
    action      = 'launch_app'
    label       = $label
    pid         = $procId
    duration_ms = $ms
    fg_changed  = $fgChanged
    windows     = $winList
  }
  if (($wins.Count -eq 1) -and (-not (Has-Opt 'no-claim'))) {
    $w0 = $wins[0]
    $appName = ''
    try { $appName = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { }
    $ac = Add-Claim -ProcId $procId -WindowId ([int64]$w0.window_id) -App $appName -Title ([string]$w0.title) -Kind 'launched' -Bounds $w0.bounds -OnScreen ([bool]$w0.is_on_screen)
    $out['ref'] = [string]$ac.ref
    $out['next'] = 'capture -ref ' + [string]$ac.ref
  } elseif ($wins.Count -gt 1) {
    $out['next'] = 'run list, then claim -pid ' + $procId
  } elseif ($wins.Count -eq 0) {
    $out['next'] = 'no window yet; run list and claim it when it appears'
  }
  Ok $out
}

function Cmd-Close {
  $claim = Get-Claim (Get-OptStr 'ref' '')
  Ensure-Alive $claim
  if ([string]$claim.kind -ne 'launched') {
    Fail 'REFUSE_USER_APP_TERMINATION' ('refusing to close ' + $claim.ref + ' (' + $claim.app + '): this window was not launched by this wrapper and may hold the user''s unsaved work') 'ask the user to close it themselves; only wrapper-launched apps can be closed'
  }
  if (-not (Has-Opt 'consent')) { Fail 'CONSENT_REQUIRED' 'closing an app requires explicit user approval' 're-run with -consent "<approval>"' }
  $procId = [int]$claim.pid
  $closedBy = ''
  # Preferred: a background UIA click on the window's own close button (no kill, no focus change).
  try {
    $r = Invoke-Capture -Claim $claim -WantScreenshot $false -OutPath ''
    $closeToken = ''
    foreach ($e in @($r.snapshot.elements)) {
      $role = [string]$e.role
      $label = [string]$e.label
      if ($role -eq 'Button' -and ($label -match '(?i)^(close|\u5173\u95ed|\u5173\u95ed\u7a97\u53e3)$')) { $closeToken = [string]$e.token; break }
    }
    if ($closeToken) {
      $payload = [ordered]@{
        pid           = $procId
        window_id     = [int64]$claim.window_id
        element_token = $closeToken
        delivery_mode = 'background'
        session       = $script:Session
      }
      Invoke-Action -Tool 'click' -Payload $payload -Claim $claim | Out-Null
      $deadline = (Get-Date).AddSeconds(4)
      while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $procId -ErrorAction SilentlyContinue)) { $closedBy = 'uia_close_click'; break }
        Start-Sleep -Milliseconds 150
      }
    }
  } catch { }
  if (-not $closedBy) {
    try {
      Invoke-DriverTool 'kill_app' ([ordered]@{ pid = $procId; session = $script:Session }) | Out-Null
      Start-Sleep -Milliseconds 400
      if (-not (Get-Process -Id $procId -ErrorAction SilentlyContinue)) { $closedBy = 'kill_app' }
    } catch { }
  }
  if (-not $closedBy) {
    # A process started by launch -direct has no driver provenance, so kill_app refuses it.
    # It is still ours (the wrapper created it), so Stop-Process is the sanctioned fallback.
    $prov = ''
    if ($claim.PSObject.Properties.Name -contains 'provenance') { $prov = [string]$claim.provenance }
    if ($prov -eq 'process_sanitized') {
      try {
        Stop-Process -Id $procId -Force -ErrorAction Stop
        Start-Sleep -Milliseconds 400
        if (-not (Get-Process -Id $procId -ErrorAction SilentlyContinue)) { $closedBy = 'stop_process_sanitized' }
      } catch { }
    }
  }
  if (-not $closedBy) {
    Fail 'CLOSE_FAILED' ('could not close ' + $claim.ref + ' (pid ' + $procId + ')') 'the app may be showing a save/discard dialog; ask the user, then retry or kill it manually'
  }
  Write-Audit ([ordered]@{ ts = (Get-Date).ToString('o'); cmd = 'close'; result = 'ok'; ref = [string]$claim.ref; pid = $procId; closed_by = $closedBy; consent = $true })
  Ok ([ordered]@{ ok = $true; ref = [string]$claim.ref; closed = $true; closed_by = $closedBy })
}
function Cmd-Verify {
  $claim = Get-Claim (Get-OptStr 'ref' '')
  Ensure-Alive $claim
  if (-not (Has-Opt 'index') -and -not (Has-Opt 'token')) { Fail 'NO_TARGET' 'verify needs -index N or -token T' '' }
  $r = Invoke-Capture -Claim $claim -WantScreenshot $false -OutPath ''
  $snap = $r.snapshot
  $idx = Get-OptInt 'index' -1
  $wantToken = ''
  if (Has-Opt 'token') { $wantToken = Get-OptStr 'token' '' }
  $found = $null
  foreach ($e in @($snap.elements)) {
    if ($wantToken -and [string]$e.token -eq $wantToken) { $found = $e; break }
    if (-not $wantToken -and [int]$e.i -eq $idx) { $found = $e; break }
  }
  if ($null -eq $found) { Fail 'NO_ELEMENT' 'element not found in the fresh capture' 'run capture and use a current index' }
  $actualValue = ''
  $actualLabel = [string]$found.label
  $actualEnabled = $true
  foreach ($e in @($r.data.elements)) {
    if ([string]$e.element_token -eq [string]$found.token) {
      if ($e.PSObject.Properties.Name -contains 'value' -and $null -ne $e.value) { $actualValue = [string]$e.value }
      if ($e.PSObject.Properties.Name -contains 'enabled') { $actualEnabled = [bool]$e.enabled }
      break
    }
  }
  $checks = [ordered]@{}
  $pass = $true
  if (Has-Opt 'value') {
    $want = Get-OptStr 'value' ''
    $checks['value'] = @{ expected = $want; actual = $actualValue; ok = ($want -eq $actualValue) }
    if ($want -ne $actualValue) { $pass = $false }
  }
  if (Has-Opt 'label') {
    $want = Get-OptStr 'label' ''
    $checks['label'] = @{ expected = $want; actual = $actualLabel; ok = ($actualLabel.Contains($want)) }
    if (-not $actualLabel.Contains($want)) { $pass = $false }
  }
  if (Has-Opt 'enabled') {
    $want = ((Get-OptStr 'enabled' 'true').ToLowerInvariant() -eq 'true')
    $checks['enabled'] = @{ expected = $want; actual = $actualEnabled; ok = ($want -eq $actualEnabled) }
    if ($want -ne $actualEnabled) { $pass = $false }
  }
  Write-Audit ([ordered]@{ ts = (Get-Date).ToString('o'); cmd = 'verify'; result = $(if ($pass) { 'ok' } else { 'mismatch' }); ref = [string]$claim.ref; index = $idx })
  Ok ([ordered]@{ ok = $pass; ref = [string]$claim.ref; index = $idx; checks = $checks })
}

function Cmd-Audit {
  $tail = Get-OptInt 'tail' -1
  if ($tail -lt 1) { $tail = Get-OptInt 'limit' 20 }
  if ($tail -lt 1) { $tail = 20 }
  if (-not (Test-Path -LiteralPath $script:AuditFile)) { Write-Output 'audit: (empty)'; exit 0 }
  $lines = @(Get-Content -LiteralPath $script:AuditFile -Tail $tail -Encoding UTF8)
  foreach ($l in $lines) {
    try {
      $o = $l | ConvertFrom-Json
      $parts = @()
      if ($o.ts) { $parts += [string]$o.ts }
      if ($o.cmd) { $parts += [string]$o.cmd }
      if ($o.action) { $parts += [string]$o.action }
      if ($o.ref) { $parts += ('ref=' + [string]$o.ref) }
      if ($o.result) { $parts += ('result=' + [string]$o.result) }
      if ($o.code) { $parts += ('code=' + [string]$o.code) }
      if ($o.effect) { $parts += ('effect=' + [string]$o.effect) }
      if ($o.code -and $o.message) { $parts += ('msg=' + [string]$o.message) }
      Write-Output ($parts -join ' ')
    } catch { Write-Output $l }
  }
  exit 0
}

function Cmd-Done {
  $st = Load-State
  $claims = @($st.claims)
  $closed = 0
  if (Has-Opt 'cleanup') {
    if (Has-Opt 'consent') {
      foreach ($c in $claims) {
        if ([string]$c.kind -eq 'launched') {
          try { Invoke-DriverTool 'kill_app' ([ordered]@{ pid = [int]$c.pid; session = $script:Session }) | Out-Null; $closed++ } catch { }
        }
      }
    } else {
      Write-Output 'cleanup skipped: -cleanup also needs -consent "<approval>"'
    }
  }
  if ($st.session) {
    try { Invoke-DriverTool 'end_session' ([ordered]@{ session = [string]$st.session }) | Out-Null } catch { }
  }
  $st.claims = @()
  $st.session = $null
  Save-State $st
  Write-Audit ([ordered]@{ ts = (Get-Date).ToString('o'); cmd = 'done'; result = 'ok'; claims_released = $claims.Count; launched_closed = $closed })
  Write-Output ('done: released ' + $claims.Count + ' claim(s), ended session, closed ' + $closed + ' launched app(s)')
  exit 0
}

# ---------------------------------------------------------------------------
# main dispatch
# ---------------------------------------------------------------------------
$parsed = Parse-Options $Rest
$script:Opt = $parsed.opt
$script:Pos = $parsed.pos

switch ($Command.ToLowerInvariant()) {
  'help' { Show-Usage }
  '-h' { Show-Usage }
  '--help' { Show-Usage }
  'daemon' { Cmd-Daemon }
  'driver' { Cmd-Daemon }
  'status' { Cmd-Status }
  'doctor' { Cmd-Doctor }
  'list' { Cmd-List }
  'claim' { Cmd-Claim }
  'release' { Cmd-Release }
  'capture' { Cmd-Capture }
  'shot' { Cmd-Shot }
  'screenshot' { Cmd-Shot }
  'click' { Cmd-Click }
  'type' { Cmd-Type }
  'set' { Cmd-Set }
  'key' { Cmd-Key }
  'scroll' { Cmd-Scroll }
  'restore' { Cmd-Restore -Claim $null }
  'park' { Cmd-Park }
  'unpark' { Cmd-Unpark }
  'launch' { Cmd-Launch }
  'close' { Cmd-Close }
  'verify' { Cmd-Verify }
  'audit' { Cmd-Audit }
  'done' { Cmd-Done }
  'selftest' {
    $st = Join-Path $PSScriptRoot 'dshdesk-selftest.ps1'
    if (-not (Test-Path -LiteralPath $st)) { Fail 'NO_SELFTEST' 'dshdesk-selftest.ps1 not found next to this script' '' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $st -Wrapper $PSCommandPath
    exit $LASTEXITCODE
  }
  default {
    Write-Output ('unknown command: ' + $Command)
    Show-Usage
  }
}
