param(
  [string]$EventFile = "$env:TEMP\dsh-desk-test\events.log",
  [string]$Title = 'DSH Desk Test',
  [int]$Left = -1700,
  [int]$Top = 120
)
# Minimal WinForms target used to verify DSH background desktop control.
# The form is created with WS_EX_NOACTIVATE + ShowWithoutActivation so it can
# appear on the desktop WITHOUT stealing focus from the user's foreground app.
# Every user-visible interaction is appended to $EventFile so tests can verify
# effects WITHOUT screenshots and WITHOUT touching the user's screen.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Windows.Forms;
public class DshNoActivateForm : Form
{
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
            return cp;
        }
    }
}
"@

$logDir = Split-Path -Parent $EventFile
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
function Log($m) {
  try { Add-Content -Path $EventFile -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $m) } catch {}
}

$form = New-Object DshNoActivateForm
$form.Text = $Title
$form.Width = 820
$form.Height = 560
$form.StartPosition = 'Manual'
$form.Left = $Left
$form.Top = $Top

$lbl = New-Object System.Windows.Forms.Label
$lbl.Name = 'lblStatus'
$lbl.Text = 'IDLE'
$lbl.Left = 20
$lbl.Top = 120
$lbl.Width = 760
$lbl.Height = 60
$form.Controls.Add($lbl)

$txt = New-Object System.Windows.Forms.TextBox
$txt.Name = 'txtInput'
$txt.AccessibleName = 'InputBox'
$txt.Left = 20
$txt.Top = 20
$txt.Width = 320
$form.Controls.Add($txt)

$btn = New-Object System.Windows.Forms.Button
$btn.Name = 'btnApply'
$btn.Text = 'Apply'
$btn.Left = 20
$btn.Top = 60
$btn.Width = 140
$btn.Add_Click({
  Log ("apply text=" + $txt.Text)
  $lbl.Text = 'APPLIED:' + $txt.Text
})
$form.Controls.Add($btn)

$btn2 = New-Object System.Windows.Forms.Button
$btn2.Name = 'btnPing'
$btn2.Text = 'Ping'
$btn2.Left = 180
$btn2.Top = 60
$btn2.Width = 140
$btn2.Add_Click({
  Log 'ping'
  $lbl.Text = 'PINGED'
})
$form.Controls.Add($btn2)

$form.Add_Shown({ Log 'shown' })
$form.Add_FormClosed({ Log 'closed'; [System.Windows.Forms.Application]::Exit() })

Log ("startup pid=" + $PID)
[System.Windows.Forms.Application]::Run($form)
