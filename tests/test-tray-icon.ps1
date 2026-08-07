# Exercises the real WinForms notification-area API with the checked-in ICO.
# It runs for only the time needed to create and dispose a private test icon;
# it does not start the imgpaste tray loop, inspect the uploader, clipboard,
# SSH, or user Startup integration.
$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    throw 'test-tray-icon.ps1 must be launched with powershell.exe -STA.'
}

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'imgpaste-tray.ps1') -NoRun
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$selection = Get-ImgPasteTrayIcon
$notify = $null
try {
    if ($selection.IsFallback -or -not $selection.OwnsIcon) {
        throw "The checked-in branded ICO was not selected for the WinForms tray probe."
    }
    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = $selection.Icon
    $notify.Text = 'imgpaste icon verification'
    $notify.Visible = $true
    [System.Windows.Forms.Application]::DoEvents()
    if (-not $notify.Visible) { throw 'WinForms did not accept the branded tray icon.' }
}
finally {
    if ($notify) {
        $notify.Visible = $false
        $notify.Dispose()
    }
    if ($selection -and $selection.OwnsIcon -and $selection.Icon) { $selection.Icon.Dispose() }
}

Write-Host 'PASS: branded ICO was accepted by the real STA WinForms NotifyIcon API and disposed cleanly.'
