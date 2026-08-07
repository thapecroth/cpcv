# One-shot: upload clipboard image, put remote path on clipboard, toast result.
param([switch]$Silent)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "imgpaste-core.ps1")

function Show-Toast {
    param([string]$Title, [string]$Body)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.SystemIcons]::Information
        $notify.Visible = $true
        $notify.BalloonTipTitle = $Title
        $notify.BalloonTipText = $Body
        $notify.ShowBalloonTip(2500)
        Start-Sleep -Milliseconds 400
        $notify.Dispose()
    }
    catch { }
}

$result = Publish-ClipboardImage -CopyPath -Force
if (-not $result.Ok) {
    $msg = if ($result.Reason -eq "no-image") { "No image on clipboard. Screenshot/copy an image first." } else { "imgpaste failed: $($result.Reason)" }
    if ($result.Reason -eq "configuration-invalid" -and $result.Detail) { $msg = "imgpaste configuration error: $($result.Detail)" }
    if (-not $Silent) { Show-Toast "imgpaste" $msg; Write-Host $msg }
    exit 1
}
if (-not $Silent) { Show-Toast "imgpaste" $result.RemotePath; Write-Host $result.RemotePath }
exit 0
