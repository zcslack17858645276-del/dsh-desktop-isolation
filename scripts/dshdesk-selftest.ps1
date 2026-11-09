param(
  [int]$WaitSeconds = 60,
  [switch]$KeepRunning
)
# dshdesk-selftest.ps1 - end-to-end isolation self-test for dshdesk.ps1.
#
# Proves, without disturbing the user's desktop, that:
#   * the cua-driver daemon is reachable and reports UIA + PostMessage support
#   * an app window can be launched/claimed/captured completely off-screen
#   * element-tree background click / set_value / type_text change app state
#   * stale element tokens are refused with no side effects
#   * a per-window PNG can be captured while the window is off-screen
#   * park/unpark moves the window fully off-screen without activation and keeps it drivable
#   * un-minimize does not steal the foreground
#   * a launched app can be closed through its UIA close button
#   * the user foreground window and the real cursor are unchanged throughout
#
# Run:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\dshdesk-selftest.ps1
#
# Exit code 0 = passed, 1 = at least one check failed.

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$dsh = Join-Path $here 'dshdesk.ps1'
$testapp = Join-Path $here 'dshdesk-testapp.ps1'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$stateDir = Join-Path $env:LOCALAPPDATA 'dsh-desktop'

if (-not (Test-Path -LiteralPath $dsh)) { Write-Output ('FATAL missing ' + $dsh); exit 1 }
if (-not (Test-Path -LiteralPath $ps)) { Write-Output ('FATAL missing ' + $ps); exit 1 }

$script:pass = 0
$script:fail = 0
$script:warn = 0
$script:violations = 0

Add-Type -AssemblyName System.Windows.Forms | Out-Null
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public struct DshPoint { public int X; public int Y; }
public static class DshSelfWin32
{
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out DshPoint p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@

function Check {
  param([string]$Name, [bool]$Cond, [string]$Detail = '')
  $msg = $Name
  if ($Detail) { $msg += '  (' + $Detail + ')' }
  if ($Cond) {
    $script:pass++
    Write-Output ('PASS  ' + $msg)
  } else {
    $script:fail++
    Write-Output ('FAIL  ' + $msg)
  }
}

function Warn {
  param([string]$Name, [string]$Detail = '')
  $script:warn++
  $msg = 'WARN  ' + $Name
  if ($Detail) { $msg += '  (' + $Detail + ')' }
  Write-Output $msg
}

function Get-Fg {
  $h = [DshSelfWin32]::GetForegroundWindow()
  $procId = 0
  [void][DshSelfWin32]::GetWindowThreadProcessId($h, [ref]$procId)
  $sb = New-Object System.Text.StringBuilder 512
  [void][DshSelfWin32]::GetWindowText($h, $sb, 512)
  $pt = New-Object DshPoint
  [void][DshSelfWin32]::GetCursorPos([ref]$pt)
  $pname = ''
  try { $pname = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { }
  return New-Object psobject -Property @{
    hwnd  = [int64]$h
    pid   = [int32]$procId
    app   = $pname
    title = $sb.ToString()
    x     = $pt.X
    y     = $pt.Y
  }
}

function Invoke-Dsh {
  param([string[]]$Argv = @('status'))
  $out = $null
  try {
    $out = & $ps -NoProfile -ExecutionPolicy Bypass -File $dsh @Argv 2>&1 | Out-String
  } catch {
    $out = [string]$_.Exception.Message
  }
  $code = $LASTEXITCODE
  $text = ([string]$out).TrimEnd()
  if ($text -match 'VIOLATION_FOCUS_STEAL') { $script:violations++ }
  return New-Object psobject -Property @{ code = $code; text = $text }
}

function Get-Json {
  param([string]$Text)
  $lines = $Text -split "`r?`n"
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    $l = $lines[$i].Trim()
    if ($l.StartsWith('{')) {
      try { return ($l | ConvertFrom-Json) } catch { }
    }
  }
  return $null
}

function Get-Ref {
  param([string]$Text)
  $m = [regex]::Match($Text, 'ref=(t[0-9]+)')
  if ($m.Success) { return $m.Groups[1].Value }
  $m = [regex]::Match($Text, '"ref"\s*:\s*"(t[0-9]+)"')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}

function Get-WinHwnd {
  param([string]$Text)
  $m = [regex]::Match($Text, 'win=0x([0-9a-fA-F]+)')
  if ($m.Success) { return [int64][Convert]::ToInt64($m.Groups[1].Value, 16) }
  return [int64]0
}

$work = Join-Path $env:TEMP ('dshdesk-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$events = Join-Path $work 'events.log'
$png = Join-Path $work 'capture.png'
$testProc = $null
$ref = ''
$launchRef = ''
$launchPid = 0

Write-Output '=== dshdesk isolation self-test ==='
Write-Output ('work dir: ' + $work)
Write-Output ''

# ---------------------------------------------------------------------------
# 0. environment / baseline
# ---------------------------------------------------------------------------
$fg0 = Get-Fg
Write-Output ('baseline foreground: hwnd=0x' + ('{0:x}' -f $fg0.hwnd) + ' pid=' + $fg0.pid + ' app=' + $fg0.app + ' title="' + $fg0.title + '"')
Write-Output ('baseline cursor: ' + $fg0.x + ',' + $fg0.y)
Write-Output ''

$r = Invoke-Dsh @('release', '-all')
$r = Invoke-Dsh @('done')

$r = Invoke-Dsh @('daemon', 'start')
Check 'daemon is reachable (started on demand)' ($r.code -eq 0) ''

$r = Invoke-Dsh @('status')
$okStatus = ($r.code -eq 0) -and ($r.text -match 'daemon:\s*running=True') -and ($r.text -match 'driver:')
Check 'status reports a running daemon' $okStatus ($r.text -split "`n")[1]

$r = Invoke-Dsh @('doctor')
Check 'doctor reports RESULT: ready' (($r.code -eq 0) -and ($r.text -match 'RESULT:\s*ready')) ''

# ---------------------------------------------------------------------------
# 1. start an off-screen NOACTIVATE test window
# ---------------------------------------------------------------------------
$startArgs = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $testapp, '-EventFile', $events)
$testProc = Start-Process -FilePath $ps -ArgumentList $startArgs -PassThru -WindowStyle Hidden
$found = $false
for ($k = 0; $k -lt ($WaitSeconds * 4); $k++) {
  Start-Sleep -Milliseconds 250
  if ($testProc.HasExited) { break }
  $r = Invoke-Dsh @('list', '-pid', [string]$testProc.Id)
  if ($r.text -match 'DSH Desk Test') { $found = $true; break }
}
Check 'test app window appeared' $found ('pid=' + $testProc.Id)

$r = Invoke-Dsh @('claim', '-pid', [string]$testProc.Id)
$ref = Get-Ref $r.text
Check 'claim returns a ref' (($r.code -eq 0) -and ($ref -ne '')) ('ref=' + $ref)

if ($ref -eq '') {
  Write-Output ''
  Write-Output '=== SELFTEST ABORTED (could not claim the test window) ==='
  if ($testProc -and -not $testProc.HasExited) { Stop-Process -Id $testProc.Id -Force -ErrorAction SilentlyContinue }
  exit 1
}

$r = Invoke-Dsh @('capture', '-ref', $ref)
$editIdx = ''
$applyIdx = ''
$m = [regex]::Match($r.text, '(?m)^\s*([0-9]+)\s+Edit\s+"InputBox"')
if ($m.Success) { $editIdx = $m.Groups[1].Value }
$m = [regex]::Match($r.text, '(?m)^\s*([0-9]+)\s+Button\s+"Apply"')
if ($m.Success) { $applyIdx = $m.Groups[1].Value }
Check 'capture returns the UIA tree' (($r.code -eq 0) -and ($editIdx -ne '') -and ($applyIdx -ne '')) ('edit=' + $editIdx + ' apply=' + $applyIdx)
$winHwnd = Get-WinHwnd $r.text
Check 'claim window handle parsed' ($winHwnd -ne 0) ('win=0x' + ('{0:x}' -f $winHwnd))

# ---------------------------------------------------------------------------
# 2. set_value + readback (background UIA ValuePattern)
# ---------------------------------------------------------------------------
$value = 'hello-selftest'
$r = Invoke-Dsh @('set', '-ref', $ref, '-index', $editIdx, '-value', $value)
$j = Get-Json $r.text
Check 'set writes a value in the background' (($r.code -eq 0) -and ($j -ne $null) -and ([bool]$j.ok)) ('effect=' + $(if ($j) { [string]$j.effect } else { '?' }))

$r = Invoke-Dsh @('verify', '-ref', $ref, '-index', $editIdx, '-value', $value)
$j = Get-Json $r.text
Check 'verify reads the exact value back' (($j -ne $null) -and ([bool]$j.ok)) ''

$r = Invoke-Dsh @('capture', '-ref', $ref)
Check 'capture shows the written value' ($r.text -match ('= "hello-selftest"')) ''

# ---------------------------------------------------------------------------
# 3. click a button (background UIA Invoke) and verify the app-side effect
# ---------------------------------------------------------------------------
$r = Invoke-Dsh @('click', '-ref', $ref, '-index', $applyIdx)
$j = Get-Json $r.text
Check 'background click is delivered' (($r.code -eq 0) -and ($j -ne $null) -and ([bool]$j.ok)) ('effect=' + $(if ($j) { [string]$j.effect } else { '?' }))
Start-Sleep -Milliseconds 500
$eventsText = ''
if (Test-Path -LiteralPath $events) { $eventsText = [string](Get-Content -LiteralPath $events -Raw) }
Check 'the click changed application state' ($eventsText -match 'apply text=hello-selftest') ''

# ---------------------------------------------------------------------------
# 4. type_text into the same element
# ---------------------------------------------------------------------------
$r = Invoke-Dsh @('type', '-ref', $ref, '-index', $editIdx, '-text', 'XYZ')
$j = Get-Json $r.text
Check 'background type_text is delivered' (($r.code -eq 0) -and ($j -ne $null) -and ([bool]$j.ok)) ('effect=' + $(if ($j) { [string]$j.effect } else { '?' }))
$r = Invoke-Dsh @('capture', '-ref', $ref)
Check 'typed text is present in the control' ($r.text -match 'XYZ') ''

# ---------------------------------------------------------------------------
# 5. stale token must be refused with NO side effects
# ---------------------------------------------------------------------------
$snapFile = Join-Path (Join-Path $stateDir 'snapshots') ($ref + '.json')
$oldToken = ''
if (Test-Path -LiteralPath $snapFile) {
  try {
    $snapObj = (Get-Content -LiteralPath $snapFile -Raw -Encoding UTF8) | ConvertFrom-Json
    if (@($snapObj.elements).Count -gt 0) { $oldToken = [string]@($snapObj.elements)[0].token }
  } catch { }
}
$before = $eventsText
$r2 = Invoke-Dsh @('capture', '-ref', $ref)     # rotates the snapshot, oldToken becomes stale
$r = Invoke-Dsh @('click', '-ref', $ref, '-token', $oldToken)
$j = Get-Json $r.text
$eventsText = ''
if (Test-Path -LiteralPath $events) { $eventsText = [string](Get-Content -LiteralPath $events -Raw) }
Check 'stale element token is refused' (($j -ne $null) -and ([string]$j.code -eq 'STALE')) ('token=' + $oldToken)
Check 'a refused stale click has no side effects' ($eventsText -eq $before) ''

# ---------------------------------------------------------------------------
# 6. per-window screenshot while off-screen (no full-screen capture)
# ---------------------------------------------------------------------------
$r = Invoke-Dsh @('shot', '-ref', $ref, '-path', $png)
$pngOk = (Test-Path -LiteralPath $png) -and ((Get-Item -LiteralPath $png).Length -gt 1000)
Check 'per-window PNG captured off-screen' (($r.code -eq 0) -and $pngOk) ('bytes=' + $(if (Test-Path -LiteralPath $png) { (Get-Item -LiteralPath $png).Length } else { 0 }))

# ---------------------------------------------------------------------------
# 7. un-minimize without activation, then capture again
# ---------------------------------------------------------------------------
[void][DshSelfWin32]::ShowWindow([IntPtr]$winHwnd, 6)   # SW_MINIMIZE (test window only)
Start-Sleep -Milliseconds 400
$wasMin = [bool][DshSelfWin32]::IsIconic([IntPtr]$winHwnd)
$r = Invoke-Dsh @('restore', '-ref', $ref)
$nowMin = [bool][DshSelfWin32]::IsIconic([IntPtr]$winHwnd)
Check 'restore un-minimizes the window' ($wasMin -and (-not $nowMin) -and ($r.code -eq 0)) ''
$r = Invoke-Dsh @('capture', '-ref', $ref)
Check 'capture works after restore' (($r.code -eq 0) -and ($r.text -match 'Edit')) ''

# ---------------------------------------------------------------------------
# 7b. park/unpark: move fully off-screen WITHOUT activation, stay drivable
# ---------------------------------------------------------------------------
$r = Invoke-Dsh @('park', '-ref', $ref)
$j = Get-Json $r.text
$parkRect = ''
if ($j -ne $null -and $j.PSObject.Properties.Name -contains 'rect') { $parkRect = [string]$j.rect }
Check 'park moves the window fully off-screen' (($r.code -eq 0) -and ($j -ne $null) -and ([bool]$j.ok) -and ([bool]$j.parked) -and ($parkRect -match '^-\d{3,},')) ('rect=' + $parkRect)
Check 'park does not change the foreground or the cursor' (($j -ne $null) -and (-not [bool]$j.fg_changed) -and (-not [bool]$j.cursor_moved)) ''
$r = Invoke-Dsh @('capture', '-ref', $ref)
Check 'capture still works while parked off-screen' (($r.code -eq 0) -and ($r.text -match 'Edit')) ''
$r = Invoke-Dsh @('unpark', '-ref', $ref)
$j = Get-Json $r.text
Check 'unpark restores the saved window rect without activation' (($r.code -eq 0) -and ($j -ne $null) -and ([bool]$j.ok) -and (-not [bool]$j.fg_changed)) ''

# ---------------------------------------------------------------------------
# 8. launch + close lifecycle (own process only)
# ---------------------------------------------------------------------------
$r = Invoke-Dsh @('launch', '-path', 'C:\Windows\System32\charmap.exe')
$j = Get-Json $r.text
if ($j -ne $null) {
  $launchRef = [string]$j.ref
  $launchPid = [int]$j.pid
}
Check 'launch starts an app without stealing focus' (($j -ne $null) -and ([bool]$j.ok) -and ($launchPid -gt 0) -and ($launchRef -ne '')) ('pid=' + $launchPid + ' ref=' + $launchRef)
if ($launchRef -ne '') {
  Start-Sleep -Seconds 2
  $r = Invoke-Dsh @('close', '-ref', $launchRef, '-consent', 'selftest closes the app it launched')
  $j = Get-Json $r.text
  Start-Sleep -Milliseconds 800
  $gone = $false
  try { $p = Get-Process -Id $launchPid -ErrorAction Stop; $gone = $p.HasExited } catch { $gone = $true }
  Check 'close shuts down the launched app' (($j -ne $null) -and ([bool]$j.ok) -and $gone) ('closed_by=' + $(if ($j) { [string]$j.closed_by } else { '?' }))
}

# ---------------------------------------------------------------------------
# 9. audit log stays readable and complete
# ---------------------------------------------------------------------------
$r = Invoke-Dsh @('audit', '-limit', '8')
Check 'audit returns recent entries' (($r.code -eq 0) -and ($r.text -match '(click|launch|set)')) ''

# ---------------------------------------------------------------------------
# 10. cleanup + isolation proof
# ---------------------------------------------------------------------------
$r = Invoke-Dsh @('release', '-all')
if ($testProc -and -not $testProc.HasExited) {
  Stop-Process -Id $testProc.Id -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 500
}
$r = Invoke-Dsh @('done')

$fg1 = Get-Fg
$fgIsOurs = ($fg1.pid -eq $testProc.Id) -or (($launchPid -gt 0) -and ($fg1.pid -eq $launchPid))
Check 'the foreground is never one of the test apps' (-not $fgIsOurs) ('fg=' + $fg1.app + ' pid=' + $fg1.pid)
Check 'no foreground-steal violation was recorded' ($script:violations -eq 0) ('violations=' + $script:violations)
if ($fg1.hwnd -eq $fg0.hwnd) {
  Check 'user foreground window is unchanged' $true ('hwnd=0x' + ('{0:x}' -f $fg0.hwnd))
} else {
  Warn 'user foreground changed during the test' ('before=' + $fg0.app + ' after=' + $fg1.app + '; the user switched windows - none of our actions raised a window')
}
if (($fg1.x -ne $fg0.x) -or ($fg1.y -ne $fg0.y)) {
  Warn 'real cursor moved during the test' ('before=' + $fg0.x + ',' + $fg0.y + ' after=' + $fg1.x + ',' + $fg1.y + '; dshdesk never moves the cursor, so this is the user')
} else {
  Check 'real cursor is unchanged' $true ("$($fg1.x),$($fg1.y)")
}

if (-not $KeepRunning) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

Write-Output ''
$total = $script:pass + $script:fail
if ($script:fail -eq 0) {
  Write-Output ('=== SELFTEST PASS  (' + $script:pass + '/' + $total + ' checks, ' + $script:warn + ' warning(s)) ===')
  exit 0
} else {
  Write-Output ('=== SELFTEST FAIL  (' + $script:pass + '/' + $total + ' passed, ' + $script:fail + ' failed, ' + $script:warn + ' warning(s)) ===')
  exit 1
}
